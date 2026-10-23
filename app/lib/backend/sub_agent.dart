import 'dart:convert';

import 'agent_run.dart';
import 'agent_tools.dart';
import 'llm.dart';

const _roles = {
  'researcher': '你是研究助手。用资料检索/列表工具收集证据，输出简短结论与引用来源；只读，不写文件、不建任务。',
  'planner': '你是规划助手。查看现有任务与资料，给出可执行的步骤建议；只读。',
  'reviewer': '你是审阅助手。检查目标与已有内容，指出遗漏、矛盾与风险；只读。',
  'analyst': '你是分析助手。基于给定目标与上下文做推理，给出结构化结论；只读。',
};

const _allowedTools = {
  'researcher': {'search_materials', 'list_materials', 'list_tasks', 'get_today'},
  'planner': {'list_tasks', 'get_today', 'list_materials'},
  'reviewer': {'search_materials', 'list_materials', 'list_notes', 'read_note', 'list_tasks'},
  'analyst': {'search_materials', 'list_materials', 'get_today', 'list_tasks'},
};

/// 只读子 Agent：独立上下文，最多 2 次工具调用，返回摘要。
Future<Map<String, Object?>> runSubAgent({
  required String role,
  required String objective,
  required String context,
  required AgentRun run,
}) async {
  final allowed = _allowedTools[role] ?? _allowedTools['analyst']!;
  final messages = <Map<String, dynamic>>[
    {'role': 'system', 'content': _roles[role] ?? _roles['analyst']!},
    {
      'role': 'user',
      'content': '$objective\n\n可用上下文：\n${context.length > 3000 ? context.substring(0, 3000) : context}',
    },
  ];
  final schemas = toolDefinitions
      .where((item) => allowed.contains(item['function']['name']))
      .toList();
  final ctx = ToolContext(
    conversationId: 0,
    run: run,
    plan: PlanState(),
    refs: [],
  );
  var summary = '';
  try {
    for (var round = 0; round < 3; round++) {
      final pending = <int, Map<String, dynamic>>{};
      await for (final chunk in streamChat(
        config: LlmConfig.fromDb(),
        messages: messages,
        tools: schemas,
        temperature: 0.4,
      )) {
        final choices = chunk['choices'] as List? ?? [];
        if (choices.isEmpty) continue;
        final delta = (choices.first as Map)['delta'] as Map?;
        if (delta == null) continue;
        final text = delta['content'];
        if (text is String && text.isNotEmpty) summary += text;
        for (final raw in (delta['tool_calls'] as List? ?? [])) {
          if (raw is! Map) continue;
          final index = (raw['index'] as num?)?.toInt() ?? 0;
          final slot = pending.putIfAbsent(index, () => {'id': '', 'name': '', 'arguments': ''});
          if (raw['id'] != null) slot['id'] = raw['id'];
          final fn = raw['function'];
          if (fn is Map) {
            if (fn['name'] != null) slot['name'] = fn['name'];
            if (fn['arguments'] != null) {
              slot['arguments'] = (slot['arguments'] as String) + fn['arguments'].toString();
            }
          }
        }
      }
      if (pending.isEmpty) break;
      final calls = <Map<String, dynamic>>[];
      for (final entry in pending.entries) {
        calls.add({
          'id': (entry.value['id'] as String).isEmpty ? 'call_${entry.key}' : entry.value['id'],
          'type': 'function',
          'function': {
            'name': entry.value['name'],
            'arguments': (entry.value['arguments'] as String).isEmpty
                ? '{}'
                : entry.value['arguments'],
          },
        });
      }
      messages.add({'role': 'assistant', 'content': summary, 'tool_calls': calls});
      for (final call in calls) {
        final fn = call['function'] as Map;
        final name = fn['name'] as String;
        if (!allowed.contains(name)) continue;
        Map<String, dynamic> args;
        try {
          args = (jsonDecode(fn['arguments'] as String) as Map).cast<String, dynamic>();
        } catch (_) {
          args = {};
        }
        final result = await executeTool(name, args, ctx);
        messages.add({
          'role': 'tool',
          'tool_call_id': call['id'],
          'content': jsonEncode(result.payload),
        });
      }
    }
  } catch (error) {
    return {
      'detail': '子 Agent 失败：$error',
      'payload': {'ok': false, 'error': '$error'},
      'agent': {'role': role, 'objective': objective, 'summary': '失败：$error'},
    };
  }
  final finalText = summary.trim().isEmpty ? '（无输出）' : summary.trim();
  return {
    'detail': '$role 完成：${finalText.length > 120 ? finalText.substring(0, 120) : finalText}',
    'payload': {
      'ok': true,
      'role': role,
      'summary': finalText.length > 3000 ? finalText.substring(0, 3000) : finalText,
    },
    'agent': {
      'role': role,
      'objective': objective.length > 80 ? objective.substring(0, 80) : objective,
      'summary': finalText.length > 200 ? finalText.substring(0, 200) : finalText,
    },
  };
}
