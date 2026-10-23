"""Agent：通用问答 + 工具循环 + 流式事件。

事件类型（与前端约定）：
  {"event": "step",  "data": {"name","status","detail"}}
  {"event": "delta", "data": {"text"}}
  {"event": "done",  "data": {...}}
  {"event": "error", "data": {"message"}}
"""
from __future__ import annotations

import base64
import json
from datetime import date, timedelta
from pathlib import Path
from typing import AsyncIterator

from db import dump, get_setting, insert, now_iso, one, rows
from llm import LLMError, estimate_cost, stream_chat
from retrieval import format_snippets, search

SYSTEM_TEMPLATE = """你是「回路」的学习助手，服务一名中国大学生。你的知识面覆盖 AI/计算机、数学（线性代数、微积分、概率）、英语，以及任何他正在学的科目。

今天：{today}

回答规则：
1. 用中文，先给结论，再给推导/解释；公式用 $...$，独立成行用 $$...$$。
2. 如果检索到了资料，优先按资料回答，引用格式：[资料名 p.页码]；资料里没有依据时，明确说"以下来自模型常识"。
3. 数学与计算类结论必须可验证；不确定就说不确定，不要编造步骤。
4. 结尾给 1 道自测题（题目 + "答案："各一行）。
5. 用户要求"记下来 / 安排计划"时，调用工具（create_note / create_tasks / plan_exam），不要只在正文里描述。
6. 回答长度适中，别写套话。
{mode}

你可以调用工具来查资料、记笔记、建待办。工具结果会回填给你，请基于结果继续回答。"""

MODE_HINT = {
    "answer": "模式：答疑。直接讲清楚，必要时补一个例子。",
    "socratic": "模式：苏格拉底。先反问一句确认他卡在哪，再给提示，最后给完整解答；答案放在最后。",
    "read": "模式：精读。按段落/页码讲资料，逐段解释。",
}

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "search_materials",
            "description": "在用户上传的资料（PDF/讲义/笔记）里检索原文片段，返回带页码的上下文。回答依赖资料时先调用它。",
            "parameters": {
                "type": "object",
                "properties": {"query": {"type": "string", "description": "检索关键词，2-8 个字"}},
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_tasks",
            "description": "创建学习待办（今天或某天要做的事）。",
            "parameters": {
                "type": "object",
                "properties": {
                    "tasks": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "title": {"type": "string"},
                                "due": {"type": "string", "description": "YYYY-MM-DD，可空"},
                                "estimate_min": {"type": "integer"},
                            },
                            "required": ["title"],
                        },
                    }
                },
                "required": ["tasks"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_note",
            "description": "把当前讲解整理成一页 Markdown 笔记存下来。",
            "parameters": {
                "type": "object",
                "properties": {
                    "title": {"type": "string"},
                    "body": {"type": "string", "description": "Markdown 正文"},
                },
                "required": ["title", "body"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "plan_exam",
            "description": "按考试日期倒排学习计划，自动生成每天的任务。",
            "parameters": {
                "type": "object",
                "properties": {
                    "exam_date": {"type": "string", "description": "YYYY-MM-DD"},
                    "daily_minutes": {"type": "integer"},
                    "topics": {"type": "array", "items": {"type": "string"}},
                },
                "required": ["exam_date"],
            },
        },
    },
]


def load_cfg(conn) -> dict:
    return {
        "api_key": get_setting(conn, "api_key"),
        "base_url": get_setting(conn, "base_url", "https://api.deepseek.com"),
        "model": get_setting(conn, "model", "deepseek-flash"),
    }


def _system_prompt(mode: str) -> str:
    return SYSTEM_TEMPLATE.format(today=date.today().isoformat(), mode=MODE_HINT.get(mode, MODE_HINT["answer"]))


def _load_images(conn, attachments: list[str]) -> list[dict]:
    images: list[dict] = []
    for ref in attachments or []:
        if not ref.startswith("img_"):
            continue
        try:
            upload_id = int(ref[4:])
        except ValueError:
            continue
        row = one(conn, "SELECT * FROM uploads WHERE id=?", (upload_id,))
        if not row:
            continue
        path = Path(row["path"])
        if not path.exists() or path.stat().st_size > 12 * 1024 * 1024:
            continue
        mime = row.get("mime") or "image/png"
        images.append(
            {
                "mime": mime,
                "b64": base64.b64encode(path.read_bytes()).decode("ascii"),
            }
        )
    return images


def _attachment_excerpts(conn, attachments: list[str]) -> str:
    parts: list[str] = []
    for ref in attachments or []:
        if not ref.startswith("mat_"):
            continue
        try:
            material_id = int(ref[4:])
        except ValueError:
            continue
        mat = one(conn, "SELECT * FROM materials WHERE id=?", (material_id,))
        if not mat:
            continue
        chunks = rows(
            conn,
            "SELECT page, text FROM chunks WHERE material_id=? ORDER BY id LIMIT 3",
            (material_id,),
        )
        body = "\n".join(f"(p.{c['page']}) {c['text']}" for c in chunks)
        parts.append(f"《{mat['name']}》节选：\n{body[:1800]}")
    return "\n\n".join(parts)


def _user_message(text: str, images: list[dict], excerpts: str) -> dict:
    blocks = []
    if excerpts:
        blocks.append("【我附上的资料】\n" + excerpts)
    blocks.append(text)
    content_text = "\n\n".join(blocks).strip()
    if not images:
        return {"role": "user", "content": content_text}
    parts: list[dict] = [{"type": "text", "text": content_text}]
    for img in images[:4]:
        parts.append(
            {"type": "image_url", "image_url": {"url": f"data:{img['mime']};base64,{img['b64']}"}}
        )
    return {"role": "user", "content": parts}


def _normalize_date(value: str) -> str:
    value = (value or "").strip()
    if not value:
        return ""
    try:
        return date.fromisoformat(value[:10]).isoformat()
    except ValueError:
        return ""


def execute_tool(conn, name: str, args: dict, ctx: dict) -> tuple[str, dict]:
    now = now_iso()

    if name == "search_materials":
        query = str(args.get("query") or "").strip()
        hits = search(conn, query, limit=5) if query else []
        text, refs = format_snippets(hits)
        ctx["refs"].extend(refs)
        if not text:
            return "没有检索到相关资料", {"ok": True, "context": "", "hits": 0}
        return f"命中 {len(refs)} 段资料", {"ok": True, "context": text, "hits": len(refs)}

    if name == "create_tasks":
        created = []
        for task in (args.get("tasks") or [])[:10]:
            title = str(task.get("title") or "").strip()
            if not title:
                continue
            created.append(
                insert(
                    conn,
                    "tasks",
                    {
                        "title": title,
                        "due": _normalize_date(task.get("due")),
                        "estimate_min": int(task.get("estimate_min") or 30),
                        "status": "todo",
                        "created_at": now,
                    },
                )
            )
        return f"新增 {len(created)} 个待办", {"ok": True, "created": len(created), "ids": created}

    if name == "create_note":
        title = str(args.get("title") or "学习笔记").strip()
        body = str(args.get("body") or "").strip()
        if not body:
            return "笔记内容为空，未保存", {"ok": False}
        note_id = insert(
            conn,
            "notes",
            {
                "title": title,
                "body": body,
                "source_ref": f"conv:{ctx.get('conversation_id')}",
                "created_at": now,
            },
        )
        return f"已保存笔记《{title}》", {"ok": True, "note_id": note_id}

    if name == "plan_exam":
        exam = _normalize_date(str(args.get("exam_date") or ""))
        daily = max(15, min(240, int(args.get("daily_minutes") or 60)))
        topics = [str(t).strip() for t in (args.get("topics") or []) if str(t).strip()][:20]
        start = date.today()
        try:
            end = date.fromisoformat(exam)
        except ValueError:
            end = start + timedelta(days=14)
        days = max(1, min(60, (end - start).days + 1))
        if not topics:
            topics = ["过一遍知识点", "做一套题", "整理错题"]
        created = []
        for i in range(days):
            day = start + timedelta(days=i)
            topic = topics[i % len(topics)]
            created.append(
                insert(
                    conn,
                    "tasks",
                    {
                        "title": f"复习：{topic}",
                        "due": day.isoformat(),
                        "estimate_min": daily,
                        "status": "todo",
                        "created_at": now,
                    },
                )
            )
        return f"已排 {len(created)} 天计划", {"ok": True, "created": len(created), "days": days}

    return f"未知工具：{name}", {"ok": False, "error": "unknown_tool"}


async def run_agent(
    conn,
    conversation_id: int,
    user_message_id: int,
    user_text: str,
    attachments: list[str],
    mode: str = "answer",
) -> AsyncIterator[dict]:
    cfg = load_cfg(conn)
    history = rows(
        conn,
        "SELECT role, content FROM messages WHERE conversation_id=? AND id<? "
        "AND role IN ('user','assistant') ORDER BY id DESC LIMIT 8",
        (conversation_id, user_message_id),
    )
    messages: list[dict] = [{"role": "system", "content": _system_prompt(mode)}]
    for item in reversed(history):
        if item["content"]:
            messages.append({"role": item["role"], "content": item["content"]})

    images = _load_images(conn, attachments)
    excerpts = _attachment_excerpts(conn, attachments)
    messages.append(_user_message(user_text, images, excerpts))

    ctx = {"conversation_id": conversation_id, "refs": []}
    steps: list[dict] = []
    full_text = ""
    usage_in = 0
    usage_out = 0
    error_message = ""

    for _round in range(4):
        pending: dict[int, dict] = {}
        round_text = ""
        try:
            async for chunk in stream_chat(cfg, messages, TOOLS):
                usage = chunk.get("usage") or {}
                if usage:
                    usage_in += int(usage.get("prompt_tokens") or 0)
                    usage_out += int(usage.get("completion_tokens") or 0)
                choices = chunk.get("choices") or []
                if not choices:
                    continue
                delta = choices[0].get("delta") or {}
                text = delta.get("content")
                if text:
                    round_text += text
                    full_text += text
                    yield {"event": "delta", "data": {"text": text}}
                for call in delta.get("tool_calls") or []:
                    index = int(call.get("index") or 0)
                    slot = pending.setdefault(index, {"id": "", "name": "", "arguments": ""})
                    if call.get("id"):
                        slot["id"] = call["id"]
                    fn = call.get("function") or {}
                    if fn.get("name"):
                        slot["name"] = fn["name"]
                    if fn.get("arguments"):
                        slot["arguments"] += fn["arguments"]
        except LLMError as exc:
            error_message = str(exc)
            break

        if not pending:
            break

        tool_calls_payload = []
        for index in sorted(pending):
            call = pending[index]
            call_id = call["id"] or f"call_{index}"
            tool_calls_payload.append(
                {
                    "id": call_id,
                    "type": "function",
                    "function": {"name": call["name"], "arguments": call["arguments"] or "{}"},
                }
            )
        messages.append(
            {"role": "assistant", "content": round_text or "", "tool_calls": tool_calls_payload}
        )

        for index in sorted(pending):
            call = pending[index]
            call_id = call["id"] or f"call_{index}"
            try:
                args = json.loads(call["arguments"] or "{}")
            except json.JSONDecodeError:
                args = {}
            yield {"event": "step", "data": {"name": call["name"], "status": "running"}}
            try:
                detail, payload = execute_tool(conn, call["name"], args, ctx)
            except Exception as exc:  # 工具失败不能中断整轮对话
                detail, payload = f"执行失败：{exc}", {"ok": False, "error": str(exc)}
            conn.commit()  # 写入立即落库，客户端断开也不丢
            steps.append({"name": call["name"], "status": "done", "detail": detail})
            yield {
                "event": "step",
                "data": {"name": call["name"], "status": "done", "detail": detail},
            }
            messages.append(
                {
                    "role": "tool",
                    "tool_call_id": call_id,
                    "content": json.dumps(payload, ensure_ascii=False),
                }
            )

    if error_message and not full_text:
        yield {"event": "error", "data": {"message": error_message}}
        return

    # 引用去重：同一资料同一页只留一条
    refs_out = []
    seen_refs = set()
    for ref in ctx["refs"]:
        key = (ref.get("material_id"), ref.get("page"))
        if key in seen_refs:
            continue
        seen_refs.add(key)
        refs_out.append(ref)

    cost = estimate_cost(cfg["model"], usage_in, usage_out)
    message_id = insert(
        conn,
        "messages",
        {
            "conversation_id": conversation_id,
            "role": "assistant",
            "content": full_text,
            "steps": dump(steps),
            "refs": dump(refs_out),
            "model": cfg["model"],
            "tokens_in": usage_in,
            "tokens_out": usage_out,
            "created_at": now_iso(),
        },
    )
    insert(
        conn,
        "usage",
        {
            "ts": now_iso(),
            "model": cfg["model"],
            "tokens_in": usage_in,
            "tokens_out": usage_out,
            "cost": cost,
        },
    )
    yield {
        "event": "done",
        "data": {
            "message_id": message_id,
            "tokens_in": usage_in,
            "tokens_out": usage_out,
            "cost": cost,
            "steps": steps,
            "refs": refs_out,
            "error": error_message,
        },
    }
