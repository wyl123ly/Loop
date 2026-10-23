import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'paths.dart';

/// SQLite 数据层（进程内，同步访问）。表结构与 Python 版保持一致，旧库可直接打开。
class Db {
  static late final Database db;
  static bool _ready = false;

  static void init() {
    if (_ready) return;
    db = sqlite3.open(AppPaths.dbPath);
    db.execute('PRAGMA journal_mode=WAL');
    _migrate();
    db.execute("UPDATE agent_runs SET status='error' WHERE status='running'");
    _ready = true;
  }

  static void _migrate() {
    db.execute('''
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
      CREATE TABLE IF NOT EXISTS material_folders(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        root_path TEXT UNIQUE,
        name TEXT,
        created_at TEXT NOT NULL,
        last_scan_at TEXT DEFAULT ''
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
      DROP TABLE IF EXISTS cards;
      DROP TABLE IF EXISTS reviews;
      DROP TABLE IF EXISTS subjects;
      CREATE TABLE IF NOT EXISTS agent_runs(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id INTEGER NOT NULL,
        status TEXT DEFAULT 'running',
        cancel_requested INTEGER DEFAULT 0,
        tool_calls INTEGER DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS mcp_servers(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        transport TEXT DEFAULT 'stdio',
        command TEXT DEFAULT '',
        args TEXT DEFAULT '[]',
        env TEXT DEFAULT '{}',
        working_directory TEXT DEFAULT '',
        url TEXT DEFAULT '',
        enabled INTEGER DEFAULT 0,
        trust_mode TEXT DEFAULT 'ask',
        created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS agent_jobs(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        prompt TEXT NOT NULL,
        mode TEXT DEFAULT 'answer',
        mode_prompt TEXT DEFAULT '',
        schedule_kind TEXT DEFAULT 'interval',
        schedule_value TEXT DEFAULT '60',
        next_run TEXT DEFAULT '',
        last_run TEXT DEFAULT '',
        enabled INTEGER DEFAULT 0,
        tool_scope TEXT DEFAULT '[]',
        budget_tokens INTEGER DEFAULT 60000,
        timeout_sec INTEGER DEFAULT 180,
        last_status TEXT DEFAULT '',
        created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS agent_audit(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        run_id INTEGER,
        job_id INTEGER,
        tool TEXT,
        args TEXT,
        result TEXT,
        risk TEXT,
        approval TEXT,
        duration_ms INTEGER,
        created_at TEXT NOT NULL
      );
    ''');
    try {
      db.execute("ALTER TABLE messages ADD COLUMN plan TEXT DEFAULT '[]'");
    } catch (_) {}
    try {
      db.execute("ALTER TABLE mcp_servers ADD COLUMN working_directory TEXT DEFAULT ''");
    } catch (_) {}
    for (final sql in [
      "ALTER TABLE materials ADD COLUMN folder_id INTEGER DEFAULT 0",
      "ALTER TABLE materials ADD COLUMN source_path TEXT DEFAULT ''",
      "ALTER TABLE materials ADD COLUMN source_mtime INTEGER DEFAULT 0",
      "ALTER TABLE materials ADD COLUMN source_size INTEGER DEFAULT 0",
      "ALTER TABLE materials ADD COLUMN relative_path TEXT DEFAULT ''",
    ]) {
      try {
        db.execute(sql);
      } catch (_) {}
    }

    for (final entry in _defaults.entries) {
      db.execute(
        'INSERT OR IGNORE INTO settings(key, value) VALUES(?, ?)',
        [entry.key, entry.value],
      );
    }
  }

  static const _defaults = {
    'api_key': '',
    'base_url': 'https://api.deepseek.com',
    'model': 'deepseek-flash',
    'reason_model': 'deepseek-v4-pro',
    'theme': 'system',
    'auto_check_updates': 'true',
    'custom_modes': '[]',
    'workspace_path': '',
    'agent_shell': 'true',
    'agent_browser': 'true',
    'agent_mcp': 'true',
    'agent_background': 'false',
  };

  static List<Map<String, Object?>> rows(String sql, [List<Object?> params = const []]) {
    return db.select(sql, params).map((row) => Map<String, Object?>.from(row)).toList();
  }

  static Map<String, Object?>? one(String sql, [List<Object?> params = const []]) {
    final result = db.select(sql, params);
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first);
  }

  static Object? scalar(String sql, [List<Object?> params = const []]) {
    final result = db.select(sql, params);
    if (result.isEmpty) return null;
    return result.first.values.first;
  }

  static int insert(String table, Map<String, Object?> values) {
    final keys = values.keys.toList();
    final sql =
        'INSERT INTO $table (${keys.join(',')}) VALUES (${List.filled(keys.length, '?').join(',')})';
    final stmt = db.prepare(sql);
    try {
      stmt.execute(keys.map((k) => values[k]).toList());
      return db.lastInsertRowId;
    } finally {
      stmt.close();
    }
  }

  static void run(String sql, [List<Object?> params = const []]) {
    db.execute(sql, params);
  }

  static String setting(String key, [String fallback = '']) {
    final value = scalar('SELECT value FROM settings WHERE key=?', [key]);
    if (value == null) return fallback;
    final text = value.toString();
    return text.isEmpty ? fallback : text;
  }

  static void setSetting(String key, String value) {
    db.execute(
      'INSERT INTO settings(key, value) VALUES(?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value=excluded.value',
      [key, value],
    );
  }

  static String nowIso() {
    final now = DateTime.now();
    final offset = now.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    String two(int v) => v.toString().padLeft(2, '0');
    final hours = two(offset.inHours.abs());
    final minutes = two(offset.inMinutes.abs() % 60);
    return '${now.year}-${two(now.month)}-${two(now.day)}T'
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}$sign$hours:$minutes';
  }

  static String today() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}';
  }

  static String encode(Object? value) => jsonEncode(value);

  static List<Map<String, Object?>> parseList(Object? raw) {
    if (raw == null) return [];
    try {
      final data = jsonDecode(raw.toString());
      if (data is List) {
        return data.whereType<Map>().map((e) => Map<String, Object?>.from(e)).toList();
      }
    } catch (_) {}
    return [];
  }
}
