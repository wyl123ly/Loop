import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';

import 'agent_tools.dart';
import 'db.dart';

class McpToolInfo {
  const McpToolInfo(this.serverId, this.serverName, this.name, this.description, this.schema);
  final int serverId;
  final String serverName;
  final String name;
  final String description;
  final Map<String, dynamic> schema;

  String get qualifiedName => 'mcp__${serverId}__$name';
}

class _Connection {
  _Connection(this.client, this.tools);
  final McpClient client;
  final List<Tool> tools;
}

class McpManager {
  static final Map<int, _Connection> _connections = {};

  static List<Map<String, Object?>> servers() =>
      Db.rows('SELECT * FROM mcp_servers ORDER BY id');

  static Future<_Connection> _connect(Map<String, Object?> row) async {
    final id = (row['id'] as num).toInt();
    final cached = _connections[id];
    if (cached != null) return cached;
    final transport = (row['transport'] ?? 'stdio').toString();
    final client = McpClient(
      const Implementation(name: 'loop-agent', version: '1.0.0'),
      options: const McpClientOptions(protocol: McpProtocol.legacy),
    );
    if (transport == 'http') {
      final url = (row['url'] ?? '').toString();
      if (url.isEmpty) throw const ToolFailure('MCP HTTP 服务器缺少 URL');
      await client.connect(StreamableHttpClientTransport(Uri.parse(url)));
    } else {
      final command = (row['command'] ?? '').toString();
      if (command.isEmpty) throw const ToolFailure('MCP stdio 服务器缺少命令');
      final args = ((jsonDecode((row['args'] ?? '[]').toString()) as List?) ?? const [])
          .map((e) => e.toString())
          .toList();
      final envRaw = (jsonDecode((row['env'] ?? '{}').toString()) as Map?) ?? const {};
      final env = envRaw.map((key, value) => MapEntry(key.toString(), value.toString()));
      await client.connect(StdioClientTransport(StdioServerParameters(
        command: command,
        args: args,
        environment: env.isEmpty ? null : env,
        workingDirectory: (row['working_directory'] ?? '').toString().isEmpty
            ? null
            : row['working_directory'].toString(),
        stderrMode: ProcessStartMode.normal,
      )));
    }
    final listed = await client.listTools();
    final connection = _Connection(client, listed.tools);
    _connections[id] = connection;
    return connection;
  }

  static Future<List<McpToolInfo>> tools() async {
    final result = <McpToolInfo>[];
    for (final row in servers()) {
      if ((row['enabled'] as num?)?.toInt() != 1) continue;
      try {
        final connection = await _connect(row).timeout(const Duration(seconds: 15));
        final serverId = (row['id'] as num).toInt();
        final serverName = (row['name'] ?? 'MCP').toString();
        for (final tool in connection.tools) {
          Map<String, dynamic> schema;
          try {
            schema = tool.inputSchema.toJson();
          } catch (_) {
            schema = {'type': 'object', 'properties': <String, dynamic>{}};
          }
          result.add(McpToolInfo(
            serverId,
            serverName,
            tool.name,
            (tool.description ?? '').toString(),
            schema,
          ));
        }
      } catch (error) {
        stderr.writeln('MCP server ${row['name']} failed: $error');
      }
    }
    return result;
  }

  static Future<List<Map<String, dynamic>>> definitions() async {
    if (Db.setting('agent_mcp', 'true') == 'false') return [];
    final list = await tools();
    return [
      for (final tool in list)
        {
          'type': 'function',
          'function': {
            'name': tool.qualifiedName,
            'description': '[${tool.serverName}] ${tool.description.isEmpty ? tool.name : tool.description}',
            'parameters': tool.schema,
          },
        },
    ];
  }

  static Future<ToolResult> call(String qualifiedName, Map<String, dynamic> args) async {
    if (Db.setting('agent_mcp', 'true') == 'false') {
      return const ToolResult('MCP 能力已在设置中关闭', {'ok': false, 'error': 'MCP disabled'});
    }
    final match = RegExp(r'^mcp__(\d+)__(.+)$').firstMatch(qualifiedName);
    if (match == null) return const ToolResult('无效 MCP 工具名', {'ok': false, 'error': 'bad name'});
    final serverId = int.parse(match.group(1)!);
    final toolName = match.group(2)!;
    final row = Db.one('SELECT * FROM mcp_servers WHERE id=?', [serverId]);
    if (row == null || (row['enabled'] as num?)?.toInt() != 1) {
      return const ToolResult('MCP 服务器未启用', {'ok': false, 'error': 'server disabled'});
    }
    try {
      final connection = await _connect(row).timeout(const Duration(seconds: 20));
      final result = await connection.client
          .callTool(CallToolRequest(name: toolName, arguments: args))
          .timeout(const Duration(seconds: 30));
      final raw = jsonEncode(result.toJson());
      final clipped = raw.length > 6000 ? '${raw.substring(0, 6000)}…' : raw;
      return ToolResult('MCP $toolName 返回 ${raw.length} 字', {
        'ok': true,
        'server_id': serverId,
        'tool': toolName,
        'result': clipped,
      });
    } catch (error) {
      return ToolResult('MCP 调用失败：$error', {'ok': false, 'error': '$error'});
    }
  }

  static Future<Map<String, Object?>> test(Map<String, Object?> row) async {
    final id = (row['id'] as num?)?.toInt() ?? 0;
    if (id > 0) await closeServer(id);
    try {
      final connection = await _connect(row).timeout(const Duration(seconds: 20));
      return {
        'ok': true,
        'tools': connection.tools.map((tool) => tool.name).toList(),
      };
    } catch (error) {
      return {'ok': false, 'error': '$error'};
    }
  }

  static Future<void> closeServer(int id) async {
    final connection = _connections.remove(id);
    try {
      await connection?.client.close();
    } catch (_) {}
  }

  static Future<void> closeAll() async {
    for (final id in _connections.keys.toList()) {
      await closeServer(id);
    }
  }
}
