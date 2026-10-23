"""SQLite 数据层：建表、连接、小工具。"""
from __future__ import annotations

import json
import os
import sqlite3
from contextlib import contextmanager
from datetime import date, datetime
from pathlib import Path
from typing import Any, Iterable

ROOT = Path(__file__).resolve().parent.parent
DATA = Path(os.environ.get("LOOP_DATA_DIR") or (ROOT / "data"))
FILES = DATA / "files"
DB_PATH = DATA / "loop.db"

SCHEMA = """
CREATE TABLE IF NOT EXISTS conversations(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT DEFAULT '新对话',
  mode TEXT DEFAULT 'answer',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS messages(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  conversation_id INTEGER NOT NULL,
  role TEXT NOT NULL,
  content TEXT NOT NULL DEFAULT '',
  steps TEXT DEFAULT '[]',
  refs TEXT DEFAULT '[]',
  model TEXT DEFAULT '',
  tokens_in INTEGER DEFAULT 0,
  tokens_out INTEGER DEFAULT 0,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conversation_id, id);

CREATE TABLE IF NOT EXISTS materials(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  kind TEXT NOT NULL,
  path TEXT DEFAULT '',
  status TEXT DEFAULT 'ready',
  pages INTEGER DEFAULT 0,
  chars INTEGER DEFAULT 0,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS uploads(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT,
  path TEXT,
  mime TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS chunks(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  material_id INTEGER NOT NULL,
  page INTEGER DEFAULT 0,
  text TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_chunks_mat ON chunks(material_id);

CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(chunk_id UNINDEXED, tokens);

CREATE TABLE IF NOT EXISTS tasks(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  due TEXT DEFAULT '',
  estimate_min INTEGER DEFAULT 30,
  status TEXT DEFAULT 'todo',
  created_at TEXT NOT NULL,
  done_at TEXT DEFAULT ''
);

CREATE TABLE IF NOT EXISTS notes(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  source_ref TEXT DEFAULT '',
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS settings(
  key TEXT PRIMARY KEY,
  value TEXT
);

CREATE TABLE IF NOT EXISTS usage(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT NOT NULL,
  model TEXT,
  tokens_in INTEGER DEFAULT 0,
  tokens_out INTEGER DEFAULT 0,
  cost REAL DEFAULT 0
);
"""

# v0.2 起取消「复习 / 卡片 / 科目」，旧库启动时顺手清掉
OBSOLETE_TABLES = ("cards", "reviews", "subjects")

DEFAULT_SETTINGS = {
    "api_key": "",
    "base_url": "https://api.deepseek.com",
    "model": "deepseek-flash",
    "reason_model": "deepseek-v4-pro",
}


def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def today_str() -> str:
    return date.today().isoformat()


@contextmanager
def db():
    DATA.mkdir(parents=True, exist_ok=True)
    FILES.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=20)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def init_db() -> None:
    with db() as conn:
        conn.executescript(SCHEMA)
        for table in OBSOLETE_TABLES:
            conn.execute(f"DROP TABLE IF EXISTS {table}")
        for k, v in DEFAULT_SETTINGS.items():
            conn.execute("INSERT OR IGNORE INTO settings(key, value) VALUES(?,?)", (k, v))


def rows(conn: sqlite3.Connection, sql: str, params: Iterable[Any] = ()) -> list[dict]:
    return [dict(r) for r in conn.execute(sql, tuple(params)).fetchall()]


def one(conn: sqlite3.Connection, sql: str, params: Iterable[Any] = ()) -> dict | None:
    r = conn.execute(sql, tuple(params)).fetchone()
    return dict(r) if r else None


def insert(conn: sqlite3.Connection, table: str, data: dict) -> int:
    keys = list(data.keys())
    sql = f"INSERT INTO {table} ({','.join(keys)}) VALUES ({','.join('?' * len(keys))})"
    cur = conn.execute(sql, [data[k] for k in keys])
    return int(cur.lastrowid)


def get_setting(conn: sqlite3.Connection, key: str, default: str = "") -> str:
    r = conn.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
    return r[0] if r and r[0] is not None else default


def set_setting(conn: sqlite3.Connection, key: str, value: str) -> None:
    conn.execute(
        "INSERT INTO settings(key, value) VALUES(?,?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (key, value),
    )


def dump(obj: Any) -> str:
    return json.dumps(obj, ensure_ascii=False)
