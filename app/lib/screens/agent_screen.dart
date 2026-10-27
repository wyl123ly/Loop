import 'package:flutter/material.dart';

import '../desktop/autostart.dart';
import '../models.dart';
import '../state.dart';
import '../theme.dart';

class AgentScreen extends StatefulWidget {
  const AgentScreen({super.key, required this.active});

  final bool active;

  @override
  State<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends State<AgentScreen> {
  int _tab = 0;
  bool _loading = true;
  AgentSettingsData? _settings;
  List<McpServerItem> _servers = [];
  List<AuditItem> _audits = [];
  List<AgentJob> _jobs = [];
  bool _autostart = false;
  final TextEditingController _workspace = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant AgentScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _load();
  }

  @override
  void dispose() {
    _workspace.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final settings = await appState.api.agentSettings();
      final servers = await appState.api.mcpServers();
      final audits = await appState.api.audits();
      final jobs = await appState.api.jobs();
      final autostart = await isAutostartEnabled();
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _workspace.text = settings.workspacePath;
        _servers = servers;
        _audits = audits;
        _jobs = jobs;
        _autostart = autostart;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack(error.toString(), isError: true);
    }
  }

  Future<void> _save({
    bool? shell,
    bool? browser,
    bool? mcp,
    bool? background,
    String? workspace,
    String? approval,
  }) async {
    try {
      await appState.api.saveAgentSettings(
        workspacePath: workspace,
        shell: shell,
        browser: browser,
        mcp: mcp,
        background: background,
        approval: approval,
      );
      await _load();
      if (mounted) _snack('设置已保存');
    } catch (error) {
      if (mounted) _snack(error.toString(), isError: true);
    }
  }

  void _snack(String text, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text, style: TextStyle(color: isError ? pal.onPrimaryBtn : pal.toastFg)),
      backgroundColor: isError ? pal.dangerInk : pal.toastBg,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 78,
          padding: const EdgeInsets.fromLTRB(32, 20, 32, 8),
          child: Row(
            children: [
              Text('代理',
                  style: TextStyle(
                      fontSize: LoopType.display, fontWeight: FontWeight.w700, color: pal.ink, letterSpacing: -0.5)),
              const SizedBox(width: 10),
              Text('本地能力 · MCP · 审计',
                  style: TextStyle(fontSize: LoopType.secondary, color: pal.muted)),
              const Spacer(),
              IconButton(
                tooltip: '刷新',
                onPressed: _loading ? null : _load,
                icon: Icon(Icons.refresh_rounded, size: 18, color: pal.muted),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 4, 32, 12),
          child: Row(
            children: [
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('权限')),
                  ButtonSegment(value: 1, label: Text('MCP')),
                  ButtonSegment(value: 2, label: Text('审计')),
                  ButtonSegment(value: 3, label: Text('后台')),
                ],
                selected: {_tab},
                showSelectedIcon: false,
                onSelectionChanged: (value) => setState(() => _tab = value.first),
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading && _settings == null
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2.4))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(32, 4, 32, 48),
                  children: [
                    if (_tab == 0) _permissionsTab(),
                    if (_tab == 1) _mcpTab(),
                    if (_tab == 2) _auditTab(),
                    if (_tab == 3) _jobsTab(),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _permissionsTab() {
    final s = _settings;
    if (s == null) {
      // 后端不可达/加载失败时的降级态：避免 `_settings!` 崩溃（也让真实六页
      // 在无后端的 widget 测试中可被布局/溢出扫描）。正常加载后不会出现。
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: panelDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('代理设置暂不可用',
                style: TextStyle(fontSize: LoopType.reading, fontWeight: FontWeight.w600, color: pal.ink)),
            const SizedBox(height: 6),
            Text('连不上本地服务或加载失败，请稍后重试。',
                style: TextStyle(fontSize: LoopType.caption, color: pal.muted)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: panelDecoration(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('工作区',
                  style: TextStyle(fontSize: LoopType.reading, fontWeight: FontWeight.w600, color: pal.ink)),
              const SizedBox(height: 4),
              Text('Agent 只能读写这个目录。Shell 的工作目录也限制在这里。',
                  style: TextStyle(fontSize: LoopType.caption, color: pal.muted)),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _workspace,
                      decoration: const InputDecoration(hintText: r'例如 C:\Users\你\LoopWorkspace'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: () => _save(workspace: _workspace.text.trim()),
                    child: const Text('保存'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => appState.api.openWorkspace(),
                    child: const Text('打开'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: panelDecoration(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('能力开关',
                  style: TextStyle(fontSize: LoopType.reading, fontWeight: FontWeight.w600, color: pal.ink)),
              const SizedBox(height: 4),
              Text('关闭后 Agent 无法调用对应工具；所有危险操作仍会逐次审批。',
                  style: TextStyle(fontSize: LoopType.caption, color: pal.muted)),
              const SizedBox(height: 10),
              _switchRow('Shell', '在工作区内执行 PowerShell', s.shell,
                  (value) => _save(shell: value)),
              _switchRow('浏览器', '用本地 Edge 打开/读取/点击网页', s.browser,
                  (value) => _save(browser: value)),
              _switchRow('MCP', '调用你添加的 MCP 服务器工具', s.mcp,
                  (value) => _save(mcp: value)),
              _switchRow('后台任务', '允许定时任务在应用运行期间后台执行', s.background,
                  (value) => _save(background: value)),
              _switchRow('开机自启', '登录 Windows 后在托盘启动，便于后台任务', _autostart,
                  (value) async {
                await setAutostart(value);
                if (mounted) setState(() => _autostart = value);
              }),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: panelDecoration(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('审批策略',
                  style: TextStyle(fontSize: LoopType.reading, fontWeight: FontWeight.w600, color: pal.ink)),
              const SizedBox(height: 4),
              Text(
                switch (s.approval) {
                  'all' => '全部自动批准：文件、Shell、浏览器、MCP 都不再弹确认，风险最高。',
                  'files' => '自动批准工作区内文件操作；Shell、浏览器、MCP 仍逐次确认。',
                  _ => '所有危险操作逐次确认（默认）。',
                },
                style: TextStyle(fontSize: LoopType.caption, color: pal.muted),
              ),
              const SizedBox(height: 10),
              SegmentedButton<String>(
                key: const Key('agent-approval'),
                segments: const [
                  ButtonSegment(value: 'manual', label: Text('逐次确认')),
                  ButtonSegment(value: 'files', label: Text('自动批准文件')),
                  ButtonSegment(value: 'all', label: Text('全部自动')),
                ],
                selected: {s.approval},
                onSelectionChanged: (value) => _save(approval: value.first),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: panelDecoration(),
          child: Row(
            children: [
              Icon(Icons.shield_outlined, size: 18, color: pal.warningInk),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '安全说明：Shell 不是内核级沙箱；文件访问限制在工作区；所有命令/写入/浏览器/MCP 调用都会写审计记录。默认逐次确认，选择自动批准时请自行承担风险。',
                  style: TextStyle(fontSize: LoopType.caption, height: 1.6, color: pal.muted),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _switchRow(String title, String subtitle, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: LoopType.body, color: pal.ink)),
                Text(subtitle, style: TextStyle(fontSize: LoopType.caption, color: pal.muted)),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _mcpTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('MCP 服务器',
                style: TextStyle(fontSize: LoopType.reading, fontWeight: FontWeight.w600, color: pal.ink)),
            const Spacer(),
            FilledButton.icon(
              onPressed: _showMcpDialog,
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('添加服务器'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text('stdio 命令或 Streamable HTTP 地址；工具默认每次调用都需审批。',
            style: TextStyle(fontSize: LoopType.caption, color: pal.muted)),
        const SizedBox(height: 12),
        if (_servers.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: panelDecoration(),
            child: Text('还没有 MCP 服务器。可以添加本地 stdio 服务或远程 HTTP 服务。',
                style: TextStyle(fontSize: LoopType.secondary, color: pal.muted)),
          ),
        for (final server in _servers)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            decoration: panelDecoration(radius: LoopRadius.card),
            child: Row(
              children: [
                Icon(server.transport == 'http' ? Icons.cloud_outlined : Icons.terminal_rounded,
                    size: 18, color: pal.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(server.name,
                          style: TextStyle(
                              fontSize: LoopType.body, fontWeight: FontWeight.w600, color: pal.ink)),
                      Text(
                        server.transport == 'http'
                            ? server.url
                            : '${server.command} ${server.args}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: LoopType.caption, color: pal.muted),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => _testMcp(server),
                  child: const Text('测试'),
                ),
                TextButton(
                  onPressed: () => _deleteMcp(server),
                  child: const Text('删除'),
                ),
                Switch(
                  value: server.enabled,
                  onChanged: (value) async {
                    await appState.api.setMcpEnabled(server.id, value);
                    await _load();
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _testMcp(McpServerItem server) async {
    try {
      final result = await appState.api.testMcpServer(server.id);
      if (!mounted) return;
      if (result['ok'] == true) {
        final tools = (result['tools'] as List? ?? []).join(', ');
        _snack('连接成功：${tools.isEmpty ? '无工具' : tools}');
      } else {
        _snack('连接失败：${result['error'] ?? ''}', isError: true);
      }
    } catch (error) {
      _snack(error.toString(), isError: true);
    }
  }

  Future<void> _deleteMcp(McpServerItem server) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除 MCP 服务器'),
        content: Text('删除「${server.name}」？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await appState.api.deleteMcpServer(server.id);
    await _load();
  }

  Future<void> _showMcpDialog() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => const _McpDialog(),
    );
    if (result == null) return;
    try {
      await appState.api.addMcpServer(
        name: result['name']!,
        transport: result['transport']!,
        command: result['command'] ?? '',
        workingDirectory: result['working_directory'] ?? '',
        args: result['args'] ?? '[]',
        url: result['url'] ?? '',
        env: result['env'] ?? '{}',
      );
      await _load();
      _snack('已添加 MCP 服务器');
    } catch (error) {
      _snack(error.toString(), isError: true);
    }
  }

  Widget _jobsTab() {
    final enabled = _settings?.background ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('定时任务',
                style: TextStyle(fontSize: LoopType.reading, fontWeight: FontWeight.w600, color: pal.ink)),
            const Spacer(),
            FilledButton.icon(
              onPressed: _showJobDialog,
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('新建任务'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          enabled
              ? '应用运行期间每 30 秒检查一次，任务串行执行；危险工具不会在后台启用。'
              : '后台任务已关闭。请在上方「权限 → 后台任务」打开。',
          style: TextStyle(fontSize: LoopType.caption, color: pal.muted),
        ),
        const SizedBox(height: 12),
        if (_jobs.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: panelDecoration(),
            child: Text('还没有定时任务。', style: TextStyle(fontSize: LoopType.secondary, color: pal.muted)),
          ),
        for (final job in _jobs)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            decoration: panelDecoration(radius: LoopRadius.card),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.schedule_rounded, size: 16, color: pal.accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(job.title,
                          style: TextStyle(
                              fontSize: LoopType.body, fontWeight: FontWeight.w600, color: pal.ink)),
                    ),
                    Switch(
                      value: job.enabled,
                      onChanged: (value) async {
                        await appState.api.setJobEnabled(job.id, value);
                        await _load();
                      },
                    ),
                  ],
                ),
                Text(
                  job.scheduleKind == 'daily'
                      ? '每天 ${job.scheduleValue}'
                      : '每 ${job.scheduleValue} 分钟',
                  style: TextStyle(fontSize: LoopType.caption, color: pal.muted),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    TextButton(
                      onPressed: () async {
                        await appState.api.runJob(job.id);
                        _snack('已触发运行');
                      },
                      child: const Text('立即运行'),
                    ),
                    TextButton(
                      onPressed: () async {
                        await appState.api.deleteJob(job.id);
                        await _load();
                      },
                      child: const Text('删除'),
                    ),
                    const Spacer(),
                    Text(
                      job.lastStatus.isEmpty ? '未运行' : job.lastStatus,
                      style: TextStyle(fontSize: LoopType.micro, color: pal.muted),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _showJobDialog() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => const _JobDialog(),
    );
    if (result == null) return;
    try {
      await appState.api.addJob(
        title: result['title']!,
        prompt: result['prompt']!,
        scheduleKind: result['kind']!,
        scheduleValue: result['value']!,
      );
      await _load();
      _snack('已创建定时任务');
    } catch (error) {
      _snack(error.toString(), isError: true);
    }
  }

  Widget _auditTab() {
    if (_audits.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: panelDecoration(),
        child: Text('还没有工具调用记录。', style: TextStyle(fontSize: LoopType.secondary, color: pal.muted)),
      );
    }
    return Column(
      children: [
        for (final item in _audits)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            decoration: panelDecoration(radius: LoopRadius.control),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  item.approval == 'rejected'
                      ? Icons.block_rounded
                      : item.approval == 'approved'
                          ? Icons.verified_user_outlined
                          : Icons.bolt_rounded,
                  size: 16,
                  color: item.approval == 'rejected' ? pal.danger : pal.accent,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(item.tool,
                              style: TextStyle(
                                  fontSize: LoopType.secondary, fontWeight: FontWeight.w600, color: pal.ink)),
                          const SizedBox(width: 8),
                          Text('${item.durationMs}ms',
                              style: TextStyle(fontSize: LoopType.micro, color: pal.muted)),
                          const Spacer(),
                          Text(item.createdAt.length > 16 ? item.createdAt.substring(11, 16) : '',
                              style: TextStyle(fontSize: LoopType.micro, color: pal.muted)),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(item.result,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: LoopType.caption, color: pal.muted)),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _McpDialog extends StatefulWidget {
  const _McpDialog();

  @override
  State<_McpDialog> createState() => _McpDialogState();
}

class _McpDialogState extends State<_McpDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _command = TextEditingController();
  final TextEditingController _args = TextEditingController(text: '[]');
  final TextEditingController _url = TextEditingController();
  final TextEditingController _cwd = TextEditingController();
  String _transport = 'stdio';

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    _args.dispose();
    _url.dispose();
    _cwd.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, {
      'name': name,
      'transport': _transport,
      'command': _command.text.trim(),
      'args': _args.text.trim().isEmpty ? '[]' : _args.text.trim(),
      'url': _url.text.trim(),
      'working_directory': _cwd.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加 MCP 服务器'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              const SizedBox(height: 10),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'stdio', label: Text('stdio')),
                  ButtonSegment(value: 'http', label: Text('Streamable HTTP')),
                ],
                selected: {_transport},
                showSelectedIcon: false,
                onSelectionChanged: (value) => setState(() => _transport = value.first),
              ),
              const SizedBox(height: 10),
              if (_transport == 'stdio') ...[
                TextField(
                  controller: _command,
                  decoration: const InputDecoration(
                    labelText: '命令',
                    hintText: r'例如 C:\Python312\python.exe',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _cwd,
                  decoration: const InputDecoration(
                    labelText: '工作目录（可空）',
                    hintText: r'C:\path\to\server',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _args,
                  decoration: const InputDecoration(
                    labelText: '参数（JSON 数组）',
                    hintText: r'["path\to\server.py"]',
                  ),
                ),
              ] else
                TextField(
                  controller: _url,
                  decoration: const InputDecoration(
                    labelText: 'URL',
                    hintText: 'https://example.com/mcp',
                  ),
                ),
              const SizedBox(height: 8),
              Text('stdio 服务器会以子进程方式运行；只添加你信任的程序。',
                  style: TextStyle(fontSize: LoopType.caption, color: pal.muted)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _save, child: const Text('添加')),
      ],
    );
  }
}


class _JobDialog extends StatefulWidget {
  const _JobDialog();

  @override
  State<_JobDialog> createState() => _JobDialogState();
}

class _JobDialogState extends State<_JobDialog> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _prompt = TextEditingController();
  final TextEditingController _value = TextEditingController(text: '60');
  String _kind = 'interval';

  @override
  void dispose() {
    _title.dispose();
    _prompt.dispose();
    _value.dispose();
    super.dispose();
  }

  void _save() {
    final title = _title.text.trim();
    final prompt = _prompt.text.trim();
    final value = _value.text.trim();
    if (title.isEmpty || prompt.isEmpty || value.isEmpty) return;
    Navigator.pop(context, {
      'title': title,
      'prompt': prompt,
      'kind': _kind,
      'value': value,
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建定时任务'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _title,
                autofocus: true,
                decoration: const InputDecoration(labelText: '任务名称'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _prompt,
                maxLines: 4,
                minLines: 3,
                decoration: const InputDecoration(
                  labelText: '任务内容',
                  hintText: '例如：总结今天的资料，生成明天要复习的 3 个待办',
                ),
              ),
              const SizedBox(height: 10),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'interval', label: Text('每隔 N 分钟')),
                  ButtonSegment(value: 'daily', label: Text('每天')),
                ],
                selected: {_kind},
                showSelectedIcon: false,
                onSelectionChanged: (value) => setState(() {
                  _kind = value.first;
                  _value.text = _kind == 'daily' ? '08:00' : '60';
                }),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _value,
                decoration: InputDecoration(
                  labelText: _kind == 'daily' ? '时间 HH:mm' : '间隔分钟',
                ),
              ),
              const SizedBox(height: 8),
              Text('后台任务只会使用资料/任务/笔记等安全工具，不会执行 Shell、浏览器或 MCP。',
                  style: TextStyle(fontSize: LoopType.caption, color: pal.muted)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _save, child: const Text('创建')),
      ],
    );
  }
}
