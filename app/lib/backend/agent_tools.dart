import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models.dart';
import 'browser_manager.dart';
import 'mcp_manager.dart';
import 'agent_run.dart';
import 'db.dart';
import 'retrieval.dart';

/// 工具执行结果：detail 给 UI，payload 回填模型。
class ToolResult {
  const ToolResult(this.detail, this.payload);
  final String detail;
  final Map<String, Object?> payload;
}

class ToolContext {
  ToolContext({
    required this.conversationId,
    required this.run,
    required this.plan,
    required this.refs,
  });

  final int conversationId;
  final AgentRun run;
  final PlanState plan;
  final List<Map<String, Object?>> refs;
}

class PlanState {
  List<PlanItem> items = [];

  bool completeActiveWrite() {
    final writeWords = RegExp(r'写|保存|创建|修改|生成|笔记|文件|任务|更新|整理');
    var changed = false;
    final next = <PlanItem>[];
    for (final item in items) {
      if (item.status == 'in_progress' && writeWords.hasMatch(item.title)) {
        changed = true;
        next.add(PlanItem(id: item.id, title: item.title, status: 'done'));
      } else {
        next.add(item);
      }
    }
    if (changed) items = next;
    return changed;
  }

  bool finalizeIncomplete() {
    var changed = false;
    final next = <PlanItem>[];
    for (final item in items) {
      if (item.status == 'in_progress') {
        changed = true;
        next.add(PlanItem(id: item.id, title: item.title, status: 'done'));
      } else if (item.status == 'pending') {
        changed = true;
        next.add(PlanItem(id: item.id, title: item.title, status: 'skipped'));
      } else {
        next.add(item);
      }
    }
    if (changed) items = next;
    return changed;
  }

  void apply(Object? raw) {
    if (raw is! List) throw const ToolFailure('plan items 必须是数组');
    final next = <PlanItem>[];
    for (var i = 0; i < raw.length && i < 8; i++) {
      final item = raw[i];
      if (item is! Map) continue;
      final title = (item['title'] ?? '').toString().trim();
      if (title.isEmpty) continue;
      var status = (item['status'] ?? 'pending').toString();
      if (!const {'pending', 'in_progress', 'done', 'skipped', 'failed'}.contains(status)) {
        status = 'pending';
      }
      next.add(PlanItem(
        id: (item['id'] ?? '${i + 1}').toString(),
        title: title.length > 120 ? title.substring(0, 120) : title,
        status: status,
      ));
    }
    if (next.isEmpty) throw const ToolFailure('plan 至少需要一项');
    items = next;
  }

  List<Map<String, Object?>> toJson() => items.map((e) => e.toJson()).toList();
}

class ToolFailure implements Exception {
  const ToolFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

const approvalTools = {
  'fs_write',
  'fs_move',
  'fs_delete',
  'shell_run',
  'browser_open',
  'browser_click',
  'browser_type',
};

bool requiresApproval(String name) => approvalTools.contains(name) || name.startsWith('mcp__');

Map<String, dynamic> _fn(
  String name,
  String description,
  Map<String, dynamic> properties, [
  List<String> required = const [],
]) =>
    {
      'type': 'function',
      'function': {
        'name': name,
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': properties,
          'required': required,
        },
      },
    };

Map<String, dynamic> _str(String description) => {'type': 'string', 'description': description};
Map<String, dynamic> _int(String description) => {'type': 'integer', 'description': description};

List<Map<String, dynamic>> get toolDefinitions => [
      _fn('update_plan', '维护当前任务的执行计划。复杂任务（需要两步以上操作）先调用它；每完成一步更新状态。', {
        'items': {
          'type': 'array',
          'description': '1-8 项计划，按顺序',
          'items': {
            'type': 'object',
            'properties': {
              'id': _str('稳定 id，如 1、2'),
              'title': _str('一步能完成的具体动作'),
              'status': {
                'type': 'string',
                'enum': ['pending', 'in_progress', 'done', 'skipped', 'failed'],
              },
            },
            'required': ['title'],
          },
        },
      }, ['items']),
      _fn('search_materials', '在用户上传的资料里检索原文，返回带页码的片段。回答依赖资料时先用。', {
        'query': _str('检索关键词，2-8 个字'),
      }, ['query']),
      _fn('list_materials', '列出用户上传的资料（id、名称、类型、页数）。', {}),
      _fn('list_tasks', '查看待办，可按状态或日期过滤。', {
        'status': _str('todo / done，可空'),
        'date': _str('YYYY-MM-DD，可空'),
      }),
      _fn('get_today', '获取今天的日期与任务统计。', {}),
      _fn('create_tasks', '创建学习待办。', {
        'tasks': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'title': _str('待办标题'),
              'due': _str('YYYY-MM-DD，可空'),
              'estimate_min': _int('预计分钟'),
            },
            'required': ['title'],
          },
        },
      }, ['tasks']),
      _fn('update_task', '修改一个待办的标题/日期/预计时长/状态。', {
        'id': _int('待办 id'),
        'title': _str('新标题，可空'),
        'due': _str('YYYY-MM-DD，可空'),
        'estimate_min': _int('预计分钟，可空'),
        'status': _str('todo / done'),
      }, ['id']),
      _fn('reschedule_tasks', '批量修改待办日期。', {
        'ids': {
          'type': 'array',
          'items': {'type': 'integer'},
        },
        'due': _str('YYYY-MM-DD'),
      }, ['ids', 'due']),
      _fn('list_notes', '列出最近的笔记。', {'limit': _int('数量，默认 20')}),
      _fn('read_note', '读取一篇笔记的正文。仅在确实需要正文时读取，不要用来反复确认刚写入的笔记。', {'id': _int('笔记 id')}, ['id']),
      _fn('create_note', '保存一篇 Markdown 学习笔记。成功返回 note_id 即表示已写入，不要重复创建或反复回读确认。', {
        'title': _str('标题'),
        'body': _str('Markdown 正文'),
      }, ['title', 'body']),
      _fn('update_note', '修改已有笔记的标题/正文。', {
        'id': _int('笔记 id'),
        'title': _str('新标题，可空'),
        'body': _str('新正文，可空'),
      }, ['id']),
      _fn('fs_list', '列出工作区目录内容。', {'path': _str('相对工作区路径，默认根目录')}),
      _fn('fs_read', '读取工作区内的文本文件。', {'path': _str('相对工作区路径')}, ['path']),
      _fn('fs_write', '写入工作区文件（需要用户审批）。', {
        'path': _str('相对工作区路径'),
        'content': _str('文本内容'),
        'mode': _str('create / overwrite / append，默认 overwrite'),
      }, ['path', 'content']),
      _fn('fs_mkdir', '在工作区创建目录。', {'path': _str('相对工作区路径')}, ['path']),
      _fn('fs_move', '移动/重命名工作区文件或目录（需要审批）。', {
        'src': _str('源路径'),
        'dst': _str('目标路径'),
      }, ['src', 'dst']),
      _fn('fs_delete', '删除工作区内的文件或空目录（需要审批）。', {'path': _str('相对工作区路径')}, ['path']),
      _fn('shell_run', '在工作区执行 PowerShell 命令（需要用户审批）。', {
        'command': _str('完整命令'),
        'cwd': _str('相对工作区目录，可空'),
        'timeout_sec': _int('超时秒数，5-60'),
      }, ['command']),
      _fn('browser_open', '用本地 Edge 打开网页（需要审批）。只允许 http/https 公网地址。', {
        'url': _str('完整 URL'),
      }, ['url']),
      _fn('browser_read', '读取当前网页的标题、正文和链接。', {}),
      _fn('browser_click', '点击网页元素（CSS selector，需要审批）。', {'selector': _str('CSS selector')}, ['selector']),
      _fn('browser_type', '在网页输入框中输入文字（需要审批）。', {
        'selector': _str('CSS selector'),
        'text': _str('要输入的文字'),
      }, ['selector', 'text']),
      _fn('browser_screenshot', '截取当前网页到工作区 screenshots 目录。', {}),
      _fn('browser_back', '返回浏览器上一页。', {}),
      _fn('browser_close', '关闭浏览器会话。', {}),
      _fn('delegate_task', '把只读研究/分析/审阅子任务委派给子 Agent，返回摘要。主 Agent 负责写操作。', {
        'role': {
          'type': 'string',
          'enum': ['researcher', 'planner', 'reviewer', 'analyst'],
          'description': '子 Agent 角色',
        },
        'objective': _str('子任务目标'),
        'context': _str('必要的上下文，可空'),
      }, ['role', 'objective']),
    ];

Future<List<Map<String, dynamic>>> allToolDefinitions() async {
  return [...toolDefinitions, ...await McpManager.definitions()];
}

String get workspacePath {
  final custom = Db.setting('workspace_path');
  final base = custom.isNotEmpty
      ? custom
      : p.join(Platform.environment['USERPROFILE'] ?? Directory.current.path, 'LoopWorkspace');
  final dir = Directory(base);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return p.normalize(dir.absolute.path);
}

String _jail(String raw) {
  final root = workspacePath;
  final input = raw.trim();
  final target = p.normalize(p.isAbsolute(input) ? input : p.join(root, input));
  var canonical = target;
  try {
    final parent = Directory(p.dirname(target));
    if (parent.existsSync()) {
      canonical = p.normalize(p.join(parent.resolveSymbolicLinksSync(), p.basename(target)));
    }
  } catch (_) {}
  final r = root.toLowerCase();
  final t = canonical.toLowerCase();
  if (t != r && !t.startsWith('$r${Platform.pathSeparator}')) {
    throw const ToolFailure('路径超出工作区，已拒绝');
  }
  return canonical;
}

String _relative(String path) {
  final rel = p.relative(path, from: workspacePath);
  return rel == '.' ? '' : rel;
}

String _clip(String text, [int max = 6000]) =>
    text.length > max ? '${text.substring(0, max)}\n…（已截断）' : text;

String _normalizeDate(Object? raw) {
  final value = (raw ?? '').toString().trim();
  if (value.isEmpty) return '';
  try {
    return DateTime.parse(value.substring(0, 10)).toIso8601String().substring(0, 10);
  } catch (_) {
    return '';
  }
}

ToolResult _ok(String detail, [Map<String, Object?> payload = const {'ok': true}]) =>
    ToolResult(detail, payload);

ToolResult _err(String message) => ToolResult(message, {'ok': false, 'error': message});

Future<ToolResult> executeTool(String name, Map<String, dynamic> args, ToolContext ctx) async {
  try {
    switch (name) {
      case 'update_plan':
        ctx.plan.apply(args['items']);
        return _ok('计划更新为 ${ctx.plan.items.length} 步', {
          'ok': true,
          'plan': ctx.plan.toJson(),
        });

      case 'search_materials':
        final query = (args['query'] ?? '').toString().trim();
        if (query.isEmpty) return _err('query 不能为空');
        final hits = search(query);
        final (contextText, refs) = formatSnippets(hits);
        ctx.refs.addAll(refs);
        if (contextText.isEmpty) return _ok('没有检索到相关资料', {'ok': true, 'context': '', 'hits': 0});
        return _ok('命中 ${refs.length} 段资料', {
          'ok': true,
          'context': contextText,
          'hits': refs.length,
        });

      case 'list_materials':
        final rows = Db.rows('SELECT id,name,kind,pages,chars FROM materials ORDER BY id DESC LIMIT 50');
        return _ok('共 ${rows.length} 份资料', {'ok': true, 'materials': rows});

      case 'list_tasks':
        var sql = 'SELECT * FROM tasks WHERE 1=1';
        final params = <Object?>[];
        final status = (args['status'] ?? '').toString();
        final date = (args['date'] ?? '').toString();
        if (status == 'todo' || status == 'done') {
          sql += ' AND status=?';
          params.add(status);
        }
        if (date.isNotEmpty) {
          sql += ' AND due=?';
          params.add(_normalizeDate(date));
        }
        sql += ' ORDER BY (due=\'\') ASC, due ASC, id ASC LIMIT 50';
        final rows = Db.rows(sql, params);
        return _ok('共 ${rows.length} 条待办', {'ok': true, 'tasks': rows});

      case 'get_today':
        final today = Db.today();
        return _ok('今天是 $today', {
          'ok': true,
          'date': today,
          'done_today': Db.scalar("SELECT COUNT(*) FROM tasks WHERE status='done' AND substr(done_at,1,10)=?", [today]) ?? 0,
          'open_total': Db.scalar("SELECT COUNT(*) FROM tasks WHERE status='todo'") ?? 0,
          'overdue': Db.scalar("SELECT COUNT(*) FROM tasks WHERE status='todo' AND due<>'' AND due<?", [today]) ?? 0,
        });

      case 'create_tasks':
        final created = <int>[];
        final now = Db.nowIso();
        for (final raw in ((args['tasks'] as List?) ?? const []).take(10)) {
          if (raw is! Map) continue;
          final title = (raw['title'] ?? '').toString().trim();
          if (title.isEmpty) continue;
          created.add(Db.insert('tasks', {
            'title': _clip(title, 200),
            'due': _normalizeDate(raw['due']),
            'estimate_min': ((raw['estimate_min'] as num?)?.toInt() ?? 30).clamp(5, 480),
            'status': 'todo',
            'created_at': now,
          }));
        }
        return _ok('新增 ${created.length} 个待办', {'ok': true, 'created': created.length, 'ids': created});

      case 'update_task':
        final id = (args['id'] as num?)?.toInt();
        if (id == null) return _err('缺少 id');
        final current = Db.one('SELECT * FROM tasks WHERE id=?', [id]);
        if (current == null) return _err('待办不存在：$id');
        final fields = <String, Object?>{};
        final title = (args['title'] ?? '').toString().trim();
        if (title.isNotEmpty) fields['title'] = _clip(title, 200);
        if (args['due'] != null) fields['due'] = _normalizeDate(args['due']);
        if (args['estimate_min'] != null) {
          fields['estimate_min'] = ((args['estimate_min'] as num).toInt()).clamp(5, 480);
        }
        final status = (args['status'] ?? '').toString();
        if (status == 'done') {
          fields['status'] = 'done';
          fields['done_at'] = Db.nowIso();
        } else if (status == 'todo') {
          fields['status'] = 'todo';
          fields['done_at'] = '';
        }
        if (fields.isEmpty) return _err('没有可修改的字段');
        final sets = fields.keys.map((k) => '$k=?').join(',');
        Db.run('UPDATE tasks SET $sets WHERE id=?', [...fields.values, id]);
        return _ok('已更新待办 $id', {
          'ok': true,
          'task': Db.one('SELECT * FROM tasks WHERE id=?', [id]),
        });

      case 'reschedule_tasks':
        final due = _normalizeDate(args['due']);
        if (due.isEmpty) return _err('due 需要 YYYY-MM-DD');
        final ids = ((args['ids'] as List?) ?? const [])
            .map((e) => (e as num?)?.toInt())
            .whereType<int>()
            .take(50)
            .toList();
        var changed = 0;
        for (final id in ids) {
          if (Db.one('SELECT id FROM tasks WHERE id=?', [id]) == null) continue;
          Db.run('UPDATE tasks SET due=? WHERE id=?', [due, id]);
          changed++;
        }
        return _ok('已改期 $changed 条到 $due', {'ok': true, 'changed': changed, 'due': due});

      case 'list_notes':
        final limit = ((args['limit'] as num?)?.toInt() ?? 20).clamp(1, 50);
        final rows = Db.rows('SELECT id,title,created_at FROM notes ORDER BY id DESC LIMIT ?', [limit]);
        return _ok('共 ${rows.length} 篇笔记', {'ok': true, 'notes': rows});

      case 'read_note':
        final id = (args['id'] as num?)?.toInt();
        final row = Db.one('SELECT * FROM notes WHERE id=?', [id]);
        if (row == null) return _err('笔记不存在');
        row['body'] = _clip((row['body'] ?? '').toString());
        return _ok('已读取笔记', {'ok': true, 'note': row});

      case 'create_note':
        final title = (args['title'] ?? '学习笔记').toString().trim();
        final body = (args['body'] ?? '').toString().trim();
        if (body.isEmpty) return _err('笔记正文为空');
        final noteId = Db.insert('notes', {
          'title': _clip(title, 200),
          'body': body.length > 20000 ? body.substring(0, 20000) : body,
          'source_ref': 'conv:${ctx.conversationId}',
          'created_at': Db.nowIso(),
        });
        return _ok('已保存笔记《$title》（id=$noteId，已提交，无需重复创建或回读）', {
          'ok': true,
          'note_id': noteId,
          'title': title,
          'committed': true,
          'do_not_repeat': true,
          'message': '笔记已写入数据库。直接汇报完成，不要再次 create_note 或 read_note 验证。',
        });

      case 'update_note':
        final id = (args['id'] as num?)?.toInt();
        final row = Db.one('SELECT id FROM notes WHERE id=?', [id]);
        if (row == null) return _err('笔记不存在');
        final fields = <String, Object?>{};
        final title = (args['title'] ?? '').toString().trim();
        final body = (args['body'] ?? '').toString().trim();
        if (title.isNotEmpty) fields['title'] = _clip(title, 200);
        if (body.isNotEmpty) fields['body'] = body.length > 20000 ? body.substring(0, 20000) : body;
        if (fields.isEmpty) return _err('没有可修改的字段');
        final sets = fields.keys.map((k) => '$k=?').join(',');
        Db.run('UPDATE notes SET $sets WHERE id=?', [...fields.values, id]);
        return _ok('已更新笔记 $id（已提交，无需重复读取确认）', {
          'ok': true,
          'note_id': id,
          'committed': true,
          'do_not_repeat': true,
        });

      case 'fs_list':
        final path = _jail((args['path'] ?? '').toString());
        final dir = Directory(path);
        if (!dir.existsSync()) return _err('目录不存在');
        final entries = <Map<String, Object?>>[];
        for (final entity in dir.listSync(followLinks: false).take(200)) {
          final stat = entity.statSync();
          entries.add({
            'name': p.basename(entity.path),
            'type': entity is Directory ? 'dir' : 'file',
            'size': stat.size,
          });
        }
        return _ok('列出 ${entries.length} 项', {
          'ok': true,
          'path': _relative(path),
          'entries': entries,
        });

      case 'fs_read':
        final path = _jail((args['path'] ?? '').toString());
        final file = File(path);
        if (!file.existsSync()) return _err('文件不存在');
        if (file.lengthSync() > 2 * 1024 * 1024) return _err('文件超过 2MB，拒绝读取');
        final bytes = file.readAsBytesSync();
        if (bytes.take(4096).contains(0)) return _err('二进制文件无法读取');
        return _ok('已读取 ${_relative(path)}', {
          'ok': true,
          'path': _relative(path),
          'content': _clip(utf8.decode(bytes, allowMalformed: true)),
        });

      case 'fs_write':
        final path = _jail((args['path'] ?? '').toString());
        final content = (args['content'] ?? '').toString();
        if (content.length > 1024 * 1024) return _err('内容超过 1MB，拒绝写入');
        final mode = (args['mode'] ?? 'overwrite').toString();
        final file = File(path);
        file.parent.createSync(recursive: true);
        if (mode == 'append') {
          file.writeAsStringSync(content, mode: FileMode.append, flush: true);
        } else {
          final temp = File('$path.tmp-${DateTime.now().microsecondsSinceEpoch}');
          temp.writeAsStringSync(content, flush: true);
          temp.renameSync(path);
        }
        return _ok('已写入 ${_relative(path)}（${content.length} 字）', {
          'ok': true,
          'path': _relative(path),
          'chars': content.length,
        });

      case 'fs_mkdir':
        final path = _jail((args['path'] ?? '').toString());
        Directory(path).createSync(recursive: true);
        return _ok('已创建目录 ${_relative(path)}', {'ok': true, 'path': _relative(path)});

      case 'fs_move':
        final src = _jail((args['src'] ?? '').toString());
        final dst = _jail((args['dst'] ?? '').toString());
        final type = FileSystemEntity.typeSync(src);
        if (type == FileSystemEntityType.notFound) return _err('源不存在');
        if (FileSystemEntity.typeSync(dst) != FileSystemEntityType.notFound) return _err('目标已存在');
        Directory(p.dirname(dst)).createSync(recursive: true);
        if (type == FileSystemEntityType.directory) {
          Directory(src).renameSync(dst);
        } else {
          File(src).renameSync(dst);
        }
        return _ok('已移动 ${_relative(src)} → ${_relative(dst)}', {
          'ok': true,
          'from': _relative(src),
          'to': _relative(dst),
        });

      case 'fs_delete':
        final path = _jail((args['path'] ?? '').toString());
        final type = FileSystemEntity.typeSync(path);
        if (type == FileSystemEntityType.notFound) return _err('路径不存在');
        if (type == FileSystemEntityType.directory) {
          final dir = Directory(path);
          if (dir.listSync().isNotEmpty) return _err('目录非空，拒绝递归删除');
          dir.deleteSync();
        } else {
          File(path).deleteSync();
        }
        return _ok('已删除 ${_relative(path)}', {'ok': true, 'deleted': _relative(path)});

      case 'shell_run':
        if (Db.setting('agent_shell', 'true') == 'false') return _err('Shell 能力已在设置中关闭');
        final command = (args['command'] ?? '').toString().trim();
        if (command.isEmpty) return _err('命令为空');
        final cwd = _jail((args['cwd'] ?? '').toString());
        if (FileSystemEntity.typeSync(cwd) != FileSystemEntityType.directory) {
          return _err('cwd 不是目录');
        }
        final timeout = ((args['timeout_sec'] as num?)?.toInt() ?? 60).clamp(5, 60);
        final proc = await Process.start(
          'powershell.exe',
          ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', command],
          workingDirectory: cwd,
        );
        final stdoutBuffer = StringBuffer();
        final stderrBuffer = StringBuffer();
        final subOut = proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen((chunk) {
          if (stdoutBuffer.length < 200 * 1024) stdoutBuffer.write(chunk);
        });
        final subErr = proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen((chunk) {
          if (stderrBuffer.length < 200 * 1024) stderrBuffer.write(chunk);
        });
        int exitCode;
        try {
          exitCode = await proc.exitCode.timeout(Duration(seconds: timeout));
        } on TimeoutException {
          Process.killPid(proc.pid);
          unawaited(Process.run('taskkill', ['/PID', '${proc.pid}', '/T', '/F']));
          exitCode = -1;
        }
        await subOut.cancel();
        await subErr.cancel();
        return _ok('命令退出码 $exitCode', {
          'ok': exitCode == 0,
          'exit_code': exitCode,
          'stdout': _clip(stdoutBuffer.toString()),
          'stderr': _clip(stderrBuffer.toString()),
        });

      case 'browser_open':
        return await BrowserManager.open((args['url'] ?? '').toString());
      case 'browser_read':
        return await BrowserManager.read();
      case 'browser_click':
        return await BrowserManager.click((args['selector'] ?? '').toString());
      case 'browser_type':
        return await BrowserManager.type(
          (args['selector'] ?? '').toString(),
          (args['text'] ?? '').toString(),
        );
      case 'browser_screenshot':
        return await BrowserManager.screenshot();
      case 'browser_back':
        return await BrowserManager.back();
      case 'browser_close':
        await BrowserManager.close();
        return _ok('浏览器已关闭');

      default:
        if (name.startsWith('mcp__')) return await McpManager.call(name, args);
        return _err('未知工具：$name');
    }
  } on ToolFailure catch (error) {
    return _err(error.message);
  } catch (error) {
    return _err('执行失败：$error');
  }
}
