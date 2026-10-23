"""分块 + 中文 bigram + SQLite FTS5 检索。

为什么用 bigram：SQLite FTS5 默认分词不切中文，把中文按二字切好后，
"特征值" -> "特征 征值"，查询同样切分，BM25 就能正常工作，零依赖。
"""
from __future__ import annotations

import re
import sqlite3

_CJK = re.compile(r"[\u4e00-\u9fff]+")
_WORD = re.compile(r"[A-Za-z][A-Za-z0-9_+\-]{1,}")


def tokenize(text: str, limit: int = 300) -> list[str]:
    out: list[str] = []
    for run in _CJK.findall(text or ""):
        if len(run) == 1:
            out.append(run)
        else:
            out.extend(run[i : i + 2] for i in range(len(run) - 1))
    out.extend(w.lower() for w in _WORD.findall(text or ""))
    seen: set[str] = set()
    result: list[str] = []
    for token in out:
        if token not in seen:
            seen.add(token)
            result.append(token)
    return result[:limit]


def chunk_pages(pages: list[str], size: int = 800, overlap: int = 100) -> list[tuple[int, str]]:
    chunks: list[tuple[int, str]] = []
    for page_no, page in enumerate(pages, start=1):
        text = re.sub(r"\s+", " ", page or "").strip()
        if not text:
            continue
        start = 0
        length = len(text)
        while start < length:
            end = min(length, start + size)
            if end < length:
                floor = start + max(200, size // 2)
                for sep in ("。", "！", "？", "；", ". ", "，", ",", " "):
                    pos = text.rfind(sep, floor, end)
                    if pos != -1:
                        end = pos + len(sep)
                        break
            piece = text[start:end].strip()
            if len(piece) >= 4:
                chunks.append((page_no, piece))
            if end >= length:
                break
            start = max(end - overlap, start + 1)
    return chunks


def index_material(conn: sqlite3.Connection, material_id: int, pages: list[str]) -> int:
    remove_material_index(conn, material_id)
    count = 0
    for page_no, text in chunk_pages(pages):
        cur = conn.execute(
            "INSERT INTO chunks(material_id, page, text) VALUES(?,?,?)",
            (material_id, page_no, text),
        )
        chunk_id = int(cur.lastrowid)
        conn.execute(
            "INSERT INTO chunks_fts(chunk_id, tokens) VALUES(?,?)",
            (chunk_id, " ".join(tokenize(text))),
        )
        count += 1
    return count


def remove_material_index(conn: sqlite3.Connection, material_id: int) -> None:
    ids = [r[0] for r in conn.execute("SELECT id FROM chunks WHERE material_id=?", (material_id,))]
    for chunk_id in ids:
        rowids = [r[0] for r in conn.execute("SELECT rowid FROM chunks_fts WHERE chunk_id=?", (chunk_id,))]
        for rowid in rowids:
            conn.execute("DELETE FROM chunks_fts WHERE rowid=?", (rowid,))
        conn.execute("DELETE FROM chunks WHERE id=?", (chunk_id,))


def search(conn: sqlite3.Connection, query: str, limit: int = 5) -> list[dict]:
    tokens = tokenize(query)
    if not tokens:
        return []
    match = " OR ".join(f'"{t}"' for t in tokens[:24])
    sql = """
        SELECT c.id, c.material_id, c.page, c.text, m.name AS material_name,
               bm25(chunks_fts) AS score
        FROM chunks_fts
        JOIN chunks c ON c.id = chunks_fts.chunk_id
        JOIN materials m ON m.id = c.material_id
        WHERE chunks_fts MATCH ?
        ORDER BY score LIMIT ?
    """
    try:
        return [dict(r) for r in conn.execute(sql, (match, limit)).fetchall()]
    except sqlite3.OperationalError:
        return []


def format_snippets(hits: list[dict], budget: int = 2400) -> tuple[str, list[dict]]:
    """把命中片段拼成给模型的上下文，同时返回引用列表给前端。"""
    parts: list[str] = []
    refs: list[dict] = []
    used = 0
    for hit in hits:
        text = (hit.get("text") or "").strip()
        if not text:
            continue
        block = f"[{hit['material_name']} p.{hit['page']}]\n{text}"
        if used + len(block) > budget:
            break
        used += len(block)
        parts.append(block)
        refs.append(
            {
                "material_id": hit["material_id"],
                "name": hit["material_name"],
                "page": hit["page"],
                "snippet": text[:160],
            }
        )
    return "\n\n".join(parts), refs
