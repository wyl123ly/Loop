class Conversation {
  final int id;
  final String title;
  final String preview;
  final int messages;
  final String updatedAt;

  Conversation({
    required this.id,
    required this.title,
    required this.preview,
    required this.messages,
    required this.updatedAt,
  });

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
        id: json['id'] as int,
        title: (json['title'] ?? '新对话') as String,
        preview: (json['preview'] ?? '') as String,
        messages: (json['messages'] ?? 0) as int,
        updatedAt: (json['updated_at'] ?? '') as String,
      );
}

class ToolStep {
  final String name;
  final String status;
  final String detail;

  ToolStep({required this.name, required this.status, this.detail = ''});

  factory ToolStep.fromJson(Map<String, dynamic> json) => ToolStep(
        name: (json['name'] ?? '') as String,
        status: (json['status'] ?? '') as String,
        detail: (json['detail'] ?? '') as String,
      );

  String get label {
    switch (name) {
      case 'search_materials':
        return '检索资料';
      case 'create_tasks':
        return '创建待办';
      case 'create_note':
        return '保存笔记';
      case 'plan_exam':
        return '排学习计划';
      case 'update_plan':
        return '更新计划';
      case 'list_tasks':
        return '查看待办';
      case 'list_materials':
        return '查看资料';
      case 'get_today':
        return '今日统计';
      case 'update_task':
        return '修改待办';
      case 'reschedule_tasks':
        return '改期待办';
      case 'list_notes':
        return '查看笔记';
      case 'read_note':
        return '读取笔记';
      case 'update_note':
        return '修改笔记';
      case 'fs_list':
        return '列目录';
      case 'fs_read':
        return '读文件';
      case 'fs_write':
        return '写文件';
      case 'fs_mkdir':
        return '建目录';
      case 'fs_move':
        return '移动文件';
      case 'fs_delete':
        return '删除文件';
      case 'shell_run':
        return '执行命令';
      default:
        return name;
    }
  }
}

class RefItem {
  final String name;
  final int page;

  RefItem({required this.name, required this.page});

  factory RefItem.fromJson(Map<String, dynamic> json) =>
      RefItem(name: (json['name'] ?? '') as String, page: (json['page'] ?? 0) as int);
}

class PlanItem {
  final String id;
  final String title;
  final String status;

  const PlanItem({required this.id, required this.title, this.status = 'pending'});

  factory PlanItem.fromJson(Map<String, dynamic> json) => PlanItem(
        id: (json['id'] ?? '').toString(),
        title: (json['title'] ?? '').toString(),
        status: (json['status'] ?? 'pending').toString(),
      );

  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'status': status};
}

class Message {
  int? id;
  final String role;
  String content;
  List<ToolStep> steps;
  List<RefItem> refs;
  List<PlanItem> plan;
  int tokensIn;
  int tokensOut;
  double cost;

  Message({
    this.id,
    required this.role,
    this.content = '',
    List<ToolStep>? steps,
    List<RefItem>? refs,
    List<PlanItem>? plan,
    this.tokensIn = 0,
    this.tokensOut = 0,
    this.cost = 0,
  })  : steps = steps ?? [],
        refs = refs ?? [],
        plan = plan ?? [];

  bool get isUser => role == 'user';

  factory Message.fromJson(Map<String, dynamic> json) {
    final steps = (json['steps'] as List? ?? [])
        .whereType<Map>()
        .map((e) => ToolStep.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final plan = (json['plan'] as List? ?? [])
        .whereType<Map>()
        .map((e) => PlanItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final refs = (json['refs'] as List? ?? [])
        .whereType<Map>()
        .map((e) => RefItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return Message(
      id: json['id'] as int?,
      role: (json['role'] ?? 'assistant') as String,
      content: (json['content'] ?? '') as String,
      steps: steps,
      refs: refs,
      plan: plan,
      tokensIn: (json['tokens_in'] ?? 0) as int,
      tokensOut: (json['tokens_out'] ?? 0) as int,
    );
  }
}

class TaskItem {
  final int id;
  final String title;
  final String due;
  final String status;
  final int estimateMin;

  TaskItem({
    required this.id,
    required this.title,
    required this.due,
    required this.status,
    required this.estimateMin,
  });

  bool get done => status == 'done';

  factory TaskItem.fromJson(Map<String, dynamic> json) => TaskItem(
        id: json['id'] as int,
        title: (json['title'] ?? '') as String,
        due: (json['due'] ?? '') as String,
        status: (json['status'] ?? 'todo') as String,
        estimateMin: (json['estimate_min'] ?? 30) as int,
      );
}

class MaterialItem {
  final int id;
  final String name;
  final String kind;
  final String status;
  final int pages;
  final int chars;
  final int folderId;
  final String sourcePath;
  final String relativePath;

  MaterialItem({
    required this.id,
    required this.name,
    required this.kind,
    required this.status,
    required this.pages,
    required this.chars,
    this.folderId = 0,
    this.sourcePath = '',
    this.relativePath = '',
  });

  factory MaterialItem.fromJson(Map<String, dynamic> json) => MaterialItem(
        id: json['id'] as int,
        name: (json['name'] ?? '') as String,
        kind: (json['kind'] ?? '') as String,
        status: (json['status'] ?? '') as String,
        pages: (json['pages'] ?? 0) as int,
        chars: (json['chars'] ?? 0) as int,
        folderId: (json['folder_id'] ?? 0) as int,
        sourcePath: (json['source_path'] ?? '') as String,
        relativePath: (json['relative_path'] ?? '') as String,
      );
}

class MaterialFolder {
  final int id;
  final String name;
  final String rootPath;
  final int fileCount;
  final String lastScanAt;

  MaterialFolder({
    required this.id,
    required this.name,
    required this.rootPath,
    required this.fileCount,
    required this.lastScanAt,
  });

  factory MaterialFolder.fromJson(Map<String, dynamic> json) => MaterialFolder(
        id: json['id'] as int,
        name: (json['name'] ?? '') as String,
        rootPath: (json['root_path'] ?? '') as String,
        fileCount: (json['file_count'] ?? 0) as int,
        lastScanAt: (json['last_scan_at'] ?? '') as String,
      );
}

class TodayData {
  final String date;
  final List<TaskItem> tasks;
  final int doneToday;
  final int openTotal;
  final int overdue;

  TodayData({
    required this.date,
    required this.tasks,
    required this.doneToday,
    required this.openTotal,
    required this.overdue,
  });

  factory TodayData.fromJson(Map<String, dynamic> json) => TodayData(
        date: (json['date'] ?? '') as String,
        tasks: (json['tasks'] as List? ?? [])
            .whereType<Map>()
            .map((e) => TaskItem.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        doneToday: (json['done_today'] ?? 0) as int,
        openTotal: (json['open_total'] ?? 0) as int,
        overdue: (json['overdue'] ?? 0) as int,
      );
}

class CustomMode {
  final String id;
  final String name;
  final String prompt;
  final String thinking;

  const CustomMode({
    required this.id,
    required this.name,
    required this.prompt,
    this.thinking = 'medium',
  });

  factory CustomMode.fromJson(Map<String, dynamic> json) => CustomMode(
        id: (json['id'] ?? 'custom').toString(),
        name: (json['name'] ?? '自定义模式').toString(),
        prompt: (json['prompt'] ?? '').toString(),
        thinking: (json['thinking'] ?? 'medium').toString(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'prompt': prompt,
        'thinking': thinking,
      };
}

class SettingsData {
  final String apiKeyMasked;
  final bool hasKey;
  final String baseUrl;
  final String model;
  final String reasonModel;
  final String theme;
  final String customModes;
  final bool autoCheckUpdates;

  SettingsData({
    required this.apiKeyMasked,
    required this.hasKey,
    required this.baseUrl,
    required this.model,
    required this.reasonModel,
    this.theme = 'system',
    this.customModes = '[]',
    this.autoCheckUpdates = true,
  });

  factory SettingsData.fromJson(Map<String, dynamic> json) => SettingsData(
        apiKeyMasked: (json['api_key'] ?? '') as String,
        hasKey: (json['has_key'] ?? false) as bool,
        baseUrl: (json['base_url'] ?? '') as String,
        model: (json['model'] ?? 'deepseek-flash') as String,
        reasonModel: (json['reason_model'] ?? 'deepseek-v4-pro') as String,
        theme: (json['theme'] ?? 'system') as String,
        customModes: (json['custom_modes'] ?? '[]') as String,
        autoCheckUpdates: (json['auto_check_updates'] ?? true) as bool,
      );
}

class AgentSettingsData {
  final String workspacePath;
  final bool shell;
  final bool browser;
  final bool mcp;
  final bool background;

  const AgentSettingsData({
    required this.workspacePath,
    required this.shell,
    required this.browser,
    required this.mcp,
    required this.background,
  });

  factory AgentSettingsData.fromJson(Map<String, dynamic> json) => AgentSettingsData(
        workspacePath: (json['workspace_path'] ?? '') as String,
        shell: (json['shell'] ?? true) as bool,
        browser: (json['browser'] ?? true) as bool,
        mcp: (json['mcp'] ?? true) as bool,
        background: (json['background'] ?? false) as bool,
      );
}

class McpServerItem {
  final int id;
  final String name;
  final String transport;
  final String command;
  final String args;
  final String env;
  final String workingDirectory;
  final String url;
  final bool enabled;

  const McpServerItem({
    required this.id,
    required this.name,
    required this.transport,
    required this.command,
    required this.args,
    required this.env,
    required this.workingDirectory,
    required this.url,
    required this.enabled,
  });

  factory McpServerItem.fromJson(Map<String, dynamic> json) => McpServerItem(
        id: json['id'] as int,
        name: (json['name'] ?? '') as String,
        transport: (json['transport'] ?? 'stdio') as String,
        command: (json['command'] ?? '') as String,
        args: (json['args'] ?? '[]') as String,
        env: (json['env'] ?? '{}') as String,
        workingDirectory: (json['working_directory'] ?? '') as String,
        url: (json['url'] ?? '') as String,
        enabled: (json['enabled'] ?? 0) == 1,
      );
}

class AgentJob {
  final int id;
  final String title;
  final String prompt;
  final String scheduleKind;
  final String scheduleValue;
  final String nextRun;
  final String lastRun;
  final bool enabled;
  final String lastStatus;

  const AgentJob({
    required this.id,
    required this.title,
    required this.prompt,
    required this.scheduleKind,
    required this.scheduleValue,
    required this.nextRun,
    required this.lastRun,
    required this.enabled,
    required this.lastStatus,
  });

  factory AgentJob.fromJson(Map<String, dynamic> json) => AgentJob(
        id: json['id'] as int,
        title: (json['title'] ?? '') as String,
        prompt: (json['prompt'] ?? '') as String,
        scheduleKind: (json['schedule_kind'] ?? 'interval') as String,
        scheduleValue: (json['schedule_value'] ?? '60') as String,
        nextRun: (json['next_run'] ?? '') as String,
        lastRun: (json['last_run'] ?? '') as String,
        enabled: (json['enabled'] ?? 0) == 1,
        lastStatus: (json['last_status'] ?? '') as String,
      );
}

class AuditItem {
  final int id;
  final String tool;
  final String args;
  final String result;
  final String approval;
  final int durationMs;
  final String createdAt;

  const AuditItem({
    required this.id,
    required this.tool,
    required this.args,
    required this.result,
    required this.approval,
    required this.durationMs,
    required this.createdAt,
  });

  factory AuditItem.fromJson(Map<String, dynamic> json) => AuditItem(
        id: json['id'] as int,
        tool: (json['tool'] ?? '') as String,
        args: (json['args'] ?? '') as String,
        result: (json['result'] ?? '') as String,
        approval: (json['approval'] ?? '') as String,
        durationMs: (json['duration_ms'] ?? 0) as int,
        createdAt: (json['created_at'] ?? '') as String,
      );
}

class NoteItem {
  final int id;
  final String title;
  final String body;
  final String sourceRef;
  final String createdAt;

  NoteItem({
    required this.id,
    required this.title,
    required this.body,
    required this.sourceRef,
    required this.createdAt,
  });

  factory NoteItem.fromJson(Map<String, dynamic> json) => NoteItem(
        id: json['id'] as int,
        title: (json['title'] ?? '未命名笔记') as String,
        body: (json['body'] ?? '') as String,
        sourceRef: (json['source_ref'] ?? '') as String,
        createdAt: (json['created_at'] ?? '') as String,
      );
}
