"""REST + SSE 接口。"""
from __future__ import annotations

import json
import uuid
from datetime import date, timedelta
from pathlib import Path

from fastapi import APIRouter, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel

from agent import load_cfg, run_agent
from db import FILES, db, dump, get_setting, insert, now_iso, one, rows, set_setting, today_str
from llm import LLMError, complete, extract_json
from parsing import clean, extract_pages
from retrieval import index_material, remove_material_index

router = APIRouter(prefix="/api")


def sse(event: str, data: dict) -> str:
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"


# ---------------------------------------------------------------- health / settings


@router.get("/health")
def health():
    with db() as conn:
        has_key = bool(get_setting(conn, "api_key"))
    return {"ok": True, "version": "0.2.0", "has_key": has_key}


class SettingsIn(BaseModel):
    api_key: str | None = None
    base_url: str | None = None
    model: str | None = None
    reason_model: str | None = None


@router.get("/settings")
def get_settings():
    with db() as conn:
        key = get_setting(conn, "api_key")
        return {
            "api_key": ("sk-" + "•" * 8 + key[-4:]) if len(key) > 8 else ("已配置" if key else ""),
            "has_key": bool(key),
            "base_url": get_setting(conn, "base_url", "https://api.deepseek.com"),
            "model": get_setting(conn, "model", "deepseek-flash"),
            "reason_model": get_setting(conn, "reason_model", "deepseek-v4-pro"),
        }


@router.put("/settings")
def put_settings(payload: SettingsIn):
    with db() as conn:
        if payload.api_key is not None and "•" not in payload.api_key:
            set_setting(conn, "api_key", payload.api_key.strip())
        if payload.base_url:
            set_setting(conn, "base_url", payload.base_url.strip())
        if payload.model:
            set_setting(conn, "model", payload.model.strip())
        if payload.reason_model:
            set_setting(conn, "reason_model", payload.reason_model.strip())
    return get_settings()


@router.post("/settings/test")
async def test_settings():
    with db() as conn:
        cfg = load_cfg(conn)
    if not cfg["api_key"]:
        return {"ok": False, "message": "还没有填写 API Key"}
    try:
        text, _ = await complete(
            cfg,
            [{"role": "user", "content": "只回复两个字：可用"}],
            temperature=0,
            max_tokens=8,
        )
        return {"ok": True, "message": f"连接正常（{cfg['model']}）：{text[:20]}"}
    except LLMError as exc:
        return {"ok": False, "message": str(exc)}
    except Exception as exc:  # 网络错误等
        return {"ok": False, "message": f"连接失败：{exc}"}


# ---------------------------------------------------------------- conversations


class ConversationIn(BaseModel):
    title: str = "新对话"
    mode: str = "answer"


class ConversationPatch(BaseModel):
    title: str | None = None
    mode: str | None = None


@router.get("/conversations")
def list_conversations():
    with db() as conn:
        items = rows(conn, "SELECT * FROM conversations ORDER BY updated_at DESC LIMIT 100")
        for conv in items:
            last = conn.execute(
                "SELECT content, role FROM messages WHERE conversation_id=? ORDER BY id DESC LIMIT 1",
                (conv["id"],),
            ).fetchone()
            conv["preview"] = (last[0] or "")[:60] if last else ""
            conv["messages"] = conn.execute(
                "SELECT COUNT(*) FROM messages WHERE conversation_id=?", (conv["id"],)
            ).fetchone()[0]
    return items


@router.post("/conversations")
def create_conversation(payload: ConversationIn):
    now = now_iso()
    with db() as conn:
        conv_id = insert(
            conn,
            "conversations",
            {
                "title": payload.title or "新对话",
                "mode": payload.mode or "answer",
                "created_at": now,
                "updated_at": now,
            },
        )
    return {"id": conv_id}


@router.patch("/conversations/{conversation_id}")
def patch_conversation(conversation_id: int, payload: ConversationPatch):
    fields = {k: v for k, v in payload.model_dump().items() if v is not None}
    if not fields:
        return {"ok": True}
    with db() as conn:
        sets = ",".join(f"{k}=?" for k in fields)
        conn.execute(f"UPDATE conversations SET {sets} WHERE id=?", (*fields.values(), conversation_id))
    return {"ok": True}


@router.delete("/conversations/{conversation_id}")
def delete_conversation(conversation_id: int):
    with db() as conn:
        conn.execute("DELETE FROM messages WHERE conversation_id=?", (conversation_id,))
        conn.execute("DELETE FROM conversations WHERE id=?", (conversation_id,))
    return {"ok": True}


@router.get("/conversations/{conversation_id}/messages")
def conversation_messages(conversation_id: int):
    with db() as conn:
        items = rows(
            conn, "SELECT * FROM messages WHERE conversation_id=? ORDER BY id", (conversation_id,)
        )
        for item in items:
            try:
                item["steps"] = json.loads(item.get("steps") or "[]")
            except json.JSONDecodeError:
                item["steps"] = []
            try:
                item["refs"] = json.loads(item.get("refs") or "[]")
            except json.JSONDecodeError:
                item["refs"] = []
    return items


# ---------------------------------------------------------------- chat


class ChatIn(BaseModel):
    conversation_id: int | None = None
    text: str = ""
    attachments: list[str] = []
    mode: str = "answer"


@router.post("/chat")
async def chat(payload: ChatIn):
    text = (payload.text or "").strip()
    if not text and not payload.attachments:
        raise HTTPException(400, "消息不能为空")

    with db() as conn:
        conv_id = payload.conversation_id
        if not conv_id:
            now = now_iso()
            conv_id = insert(
                conn,
                "conversations",
                {
                    "title": "新对话",
                    "mode": payload.mode,
                    "created_at": now,
                    "updated_at": now,
                },
            )
        conv = one(conn, "SELECT * FROM conversations WHERE id=?", (conv_id,))
        if not conv:
            raise HTTPException(404, "会话不存在")
        user_message_id = insert(
            conn,
            "messages",
            {
                "conversation_id": conv_id,
                "role": "user",
                "content": text,
                "steps": "[]",
                "refs": "[]",
                "created_at": now_iso(),
            },
        )
        if (conv.get("title") or "") in ("", "新对话"):
            conn.execute(
                "UPDATE conversations SET title=? WHERE id=?",
                ((text[:20] or "新对话"), conv_id),
            )
        conn.execute("UPDATE conversations SET updated_at=? WHERE id=?", (now_iso(), conv_id))

    async def generator():
        with db() as conn:
            async for event in run_agent(
                conn,
                conv_id,
                user_message_id,
                text or "（见附件）",
                payload.attachments,
                payload.mode,
            ):
                yield sse(event["event"], event["data"])
            conn.execute("UPDATE conversations SET updated_at=? WHERE id=?", (now_iso(), conv_id))

    return StreamingResponse(
        generator(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


# ---------------------------------------------------------------- materials


@router.post("/upload")
async def upload(file: UploadFile = File(...)):
    raw = await file.read()
    if len(raw) > 30 * 1024 * 1024:
        raise HTTPException(413, "文件太大（上限 30MB），先压缩或截取需要的部分。")
    name = file.filename or "file"
    ext = Path(name).suffix.lower()
    mime = file.content_type or ""
    saved = FILES / f"{uuid.uuid4().hex}{ext}"
    saved.write_bytes(raw)

    is_image = mime.startswith("image/") or ext in {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp"}
    if is_image:
        with db() as conn:
            upload_id = insert(
                conn,
                "uploads",
                {"name": name, "path": str(saved), "mime": mime or "image/png", "created_at": now_iso()},
            )
        return {"kind": "image", "id": f"img_{upload_id}", "name": name}

    try:
        pages = [clean(page) for page in extract_pages(saved, ext)]
    except Exception as exc:
        saved.unlink(missing_ok=True)
        raise HTTPException(400, f"解析失败：{exc}") from exc

    total = sum(len(page) for page in pages)
    if total < 10:
        saved.unlink(missing_ok=True)
        raise HTTPException(400, "这个文件里几乎抽不到文字（可能是扫描件）。可以先截图，再用图片提问。")

    with db() as conn:
        material_id = insert(
            conn,
            "materials",
            {
                "name": name,
                "kind": ext.lstrip("."),
                "path": str(saved),
                "status": "ready",
                "pages": len(pages),
                "chars": total,
                "created_at": now_iso(),
            },
        )
        chunks = index_material(conn, material_id, pages)

    return {
        "kind": "material",
        "id": f"mat_{material_id}",
        "name": name,
        "pages": len(pages),
        "chars": total,
        "chunks": chunks,
        "preview": (pages[0][:200] if pages else ""),
    }


@router.get("/materials")
def list_materials():
    with db() as conn:
        return rows(conn, "SELECT * FROM materials ORDER BY id DESC")


@router.get("/materials/{material_id}/preview")
def material_preview(material_id: int):
    with db() as conn:
        material = one(conn, "SELECT * FROM materials WHERE id=?", (material_id,))
        if not material:
            raise HTTPException(404, "资料不存在")
        chunks = rows(
            conn,
            "SELECT page, text FROM chunks WHERE material_id=? ORDER BY id LIMIT 4",
            (material_id,),
        )
    text = "\n\n".join(f"p.{c['page']}\n{c['text']}" for c in chunks)
    return {
        "id": material_id,
        "name": material["name"],
        "kind": material["kind"],
        "pages": material["pages"],
        "chars": material["chars"],
        "text": text[:5000] or "（没有可显示的文字）",
    }


@router.delete("/materials/{material_id}")
def delete_material(material_id: int):
    with db() as conn:
        remove_material_index(conn, material_id)
        conn.execute("DELETE FROM materials WHERE id=?", (material_id,))
    return {"ok": True}


@router.get("/uploads/{upload_id}")
def get_upload(upload_id: int):
    with db() as conn:
        row = one(conn, "SELECT * FROM uploads WHERE id=?", (upload_id,))
    if not row or not Path(row["path"]).exists():
        raise HTTPException(404, "图片不存在")
    return FileResponse(row["path"], media_type=row.get("mime") or "image/png")


# ---------------------------------------------------------------- tasks / today


class TaskIn(BaseModel):
    title: str
    due: str = ""
    estimate_min: int = 30


class TaskPatch(BaseModel):
    title: str | None = None
    due: str | None = None
    status: str | None = None
    estimate_min: int | None = None


@router.get("/tasks")
def list_tasks(date_str: str | None = None, status: str | None = None):
    with db() as conn:
        sql = "SELECT * FROM tasks WHERE 1=1"
        params: list = []
        if date_str:
            sql += " AND (due=? OR due='')"
            params.append(date_str)
        if status:
            sql += " AND status=?"
            params.append(status)
        sql += " ORDER BY (due='') ASC, due ASC, id ASC LIMIT 200"
        return rows(conn, sql, params)


@router.post("/tasks")
def create_task(payload: TaskIn):
    with db() as conn:
        task_id = insert(
            conn,
            "tasks",
            {
                "title": payload.title.strip(),
                "due": payload.due.strip(),
                "estimate_min": payload.estimate_min,
                "status": "todo",
                "created_at": now_iso(),
            },
        )
    return {"id": task_id}


@router.patch("/tasks/{task_id}")
def patch_task(task_id: int, payload: TaskPatch):
    fields = {k: v for k, v in payload.model_dump().items() if v is not None}
    if not fields:
        return {"ok": True}
    if fields.get("status") == "done":
        fields["done_at"] = now_iso()
    with db() as conn:
        sets = ",".join(f"{k}=?" for k in fields)
        conn.execute(f"UPDATE tasks SET {sets} WHERE id=?", (*fields.values(), task_id))
    return {"ok": True}


@router.delete("/tasks/{task_id}")
def delete_task(task_id: int):
    with db() as conn:
        conn.execute("DELETE FROM tasks WHERE id=?", (task_id,))
    return {"ok": True}


@router.get("/today")
def today():
    today_s = today_str()
    with db() as conn:
        tasks = rows(
            conn,
            "SELECT * FROM tasks WHERE status='todo' AND (due<=? OR due='') "
            "ORDER BY (due='') ASC, due ASC, id ASC LIMIT 50",
            (today_s,),
        )
        done_today = conn.execute(
            "SELECT COUNT(*) FROM tasks WHERE status='done' AND substr(done_at,1,10)=?",
            (today_s,),
        ).fetchone()[0]
        open_total = conn.execute("SELECT COUNT(*) FROM tasks WHERE status='todo'").fetchone()[0]
        overdue = conn.execute(
            "SELECT COUNT(*) FROM tasks WHERE status='todo' AND due<>'' AND due<?",
            (today_s,),
        ).fetchone()[0]
    return {
        "date": today_s,
        "tasks": tasks,
        "done_today": done_today,
        "open_total": open_total,
        "overdue": overdue,
    }


# ---------------------------------------------------------------- notes


@router.get("/notes")
def list_notes():
    with db() as conn:
        return rows(conn, "SELECT * FROM notes ORDER BY id DESC LIMIT 100")


@router.delete("/notes/{note_id}")
def delete_note(note_id: int):
    with db() as conn:
        conn.execute("DELETE FROM notes WHERE id=?", (note_id,))
    return {"ok": True}


# ---------------------------------------------------------------- generate from message


class GenerateIn(BaseModel):
    message_id: int
    count: int = 5


def _message_content(conn, message_id: int) -> str:
    row = one(conn, "SELECT content FROM messages WHERE id=?", (message_id,))
    if not row:
        raise HTTPException(404, "消息不存在")
    if not (row.get("content") or "").strip():
        raise HTTPException(400, "这条消息没有可用的正文")
    return row["content"]


@router.post("/generate/note")
async def generate_note(payload: GenerateIn):
    with db() as conn:
        content = _message_content(conn, payload.message_id)
        cfg = load_cfg(conn)
    prompt = f"""把下面的内容整理成一页 Markdown 学习笔记。
只输出 JSON：{{"title":"标题","body":"Markdown 正文"}}
要求：有二级标题、要点列表、公式用 $...$；不要重复原话。
内容：
{content[:6000]}"""
    try:
        text, _ = await complete(cfg, [{"role": "user", "content": prompt}], temperature=0.3)
    except LLMError as exc:
        raise HTTPException(400, str(exc)) from exc
    data = extract_json(text)
    if not isinstance(data, dict) or not data.get("body"):
        raise HTTPException(400, "模型没有返回可解析的笔记，再试一次。")
    with db() as conn:
        note_id = insert(
            conn,
            "notes",
            {
                "title": str(data.get("title") or "学习笔记"),
                "body": str(data["body"]),
                "source_ref": f"msg:{payload.message_id}",
                "created_at": now_iso(),
            },
        )
    return {"id": note_id}


@router.post("/generate/task")
async def generate_task(payload: GenerateIn):
    with db() as conn:
        content = _message_content(conn, payload.message_id)
        cfg = load_cfg(conn)
    prompt = f"""根据下面的学习内容，生成 1 个可以执行的复习待办。
只输出 JSON：{{"title":"不超过 20 字","estimate_min":30}}
内容：
{content[:4000]}"""
    try:
        text, _ = await complete(cfg, [{"role": "user", "content": prompt}], temperature=0.3)
    except LLMError as exc:
        raise HTTPException(400, str(exc)) from exc
    data = extract_json(text)
    title = str((data or {}).get("title") or "").strip() or "复习这次对话的内容"
    with db() as conn:
        task_id = insert(
            conn,
            "tasks",
            {
                "title": title[:40],
                "due": today_str(),
                "estimate_min": int((data or {}).get("estimate_min") or 30),
                "status": "todo",
                "created_at": now_iso(),
            },
        )
    return {"id": task_id, "title": title}
