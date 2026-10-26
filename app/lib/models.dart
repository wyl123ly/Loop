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

class AttachmentItem {
  const AttachmentItem({required this.id, required this.name, required this.isImage});

  final String id;
  final String name;
  final bool isImage;

  factory AttachmentItem.fromJson(Map<String, dynamic> json) => AttachmentItem(
        id: (json['id'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        isImage: json['is_image'] == true,
      );
}

class Message {
  int? id;
  final String role;
  String content;
  List<ToolStep> steps;
  List<RefItem> refs;
  List<PlanItem> plan;
  List<AttachmentItem> attachments;
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
    List<AttachmentItem>? attachments,
    this.tokensIn = 0,
    this.tokensOut = 0,
    this.cost = 0,
  })  : steps = steps ?? [],
        refs = refs ?? [],
        plan = plan ?? [],
        attachments = attachments ?? [];

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
    final attachments = (json['attachments'] as List? ?? [])
        .whereType<Map>()
        .map((e) => AttachmentItem.fromJson(Map<String, dynamic>.from(e)))
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
      attachments: attachments,
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
  final String activeProvider;
  final String providersJson;
  final String theme;
  final String customModes;
  final bool autoCheckUpdates;
  final bool sidebarCollapsed;

  /// 正文是否逐字显示。关闭后仍走同一条流式协议，只是等整段回答结束后
  /// 一次性收到 `delta`；默认 true 保持既有体验。
  final bool streamOutput;

  /// 当前学科 key（`settings.active_subject`，§4.2）；后端启动后一定是合法值。
  final String activeSubject;

  /// 跨学科兜底检索开关（默认关闭，§7.2）。
  final bool crossSubjectSearch;

  /// 教学技能 hub URL（F-18：**只读**，恒等于后端白名单值）。
  final String skillHubUrl;

  /// 迁移后一次性提示是否已看过（F-11）。
  final bool subjectMigrationNoticeSeen;

  SettingsData({
    required this.apiKeyMasked,
    required this.hasKey,
    required this.baseUrl,
    required this.model,
    required this.reasonModel,
    this.activeProvider = 'deepseek',
    this.providersJson = '[]',
    this.theme = 'system',
    this.customModes = '[]',
    this.autoCheckUpdates = true,
    this.sidebarCollapsed = false,
    this.streamOutput = true,
    this.activeSubject = 'default',
    this.crossSubjectSearch = false,
    this.skillHubUrl = 'https://eduhub.deeptutor.info/api/v1',
    this.subjectMigrationNoticeSeen = false,
  });

  factory SettingsData.fromJson(Map<String, dynamic> json) => SettingsData(
        apiKeyMasked: (json['api_key'] ?? '') as String,
        hasKey: (json['has_key'] ?? false) as bool,
        baseUrl: (json['base_url'] ?? '') as String,
        model: (json['model'] ?? 'deepseek-flash') as String,
        reasonModel: (json['reason_model'] ?? 'deepseek-v4-pro') as String,
        activeProvider: (json['active_provider'] ?? 'deepseek') as String,
        providersJson: (json['providers'] ?? '[]') as String,
        theme: (json['theme'] ?? 'system') as String,
        customModes: (json['custom_modes'] ?? '[]') as String,
        autoCheckUpdates: (json['auto_check_updates'] ?? true) as bool,
        sidebarCollapsed: (json['sidebar_collapsed'] ?? false) as bool,
        streamOutput: (json['stream_output'] ?? true) as bool,
        activeSubject: (json['active_subject'] ?? 'default') as String,
        crossSubjectSearch: (json['cross_subject_search'] ?? false) as bool,
        skillHubUrl: (json['skill_hub_url'] ??
                'https://eduhub.deeptutor.info/api/v1') as String,
        subjectMigrationNoticeSeen:
            (json['subject_migration_notice_seen'] ?? false) as bool,
      );
}

/// F-11：设置页「数据与迁移」的视图模型（迁移状态 + 一次性提示标记）。
class MigrationOverview {
  const MigrationOverview({
    required this.applied,
    required this.pending,
    required this.running,
    required this.lastError,
    required this.report,
    required this.noticeSeen,
  });

  final List<Map<String, dynamic>> applied;
  final List<String> pending;
  final bool running;
  final String lastError;
  final Map<String, dynamic> report;
  final bool noticeSeen;

  bool get needsMigration => pending.isNotEmpty;
  bool get failed => report['result'] == 'failed' || lastError.isNotEmpty;

  /// 本次迁移的文件搬迁摘要（失败/残留会如实显示）。
  String get countsLabel {
    final counts = report['counts'];
    if (counts is! Map) return '';
    final parts = <String>[];
    for (final key in ['conversations', 'messages', 'materials', 'uploads', 'chunks']) {
      final value = counts[key];
      if (value == null) continue;
      parts.add('$key=$value');
    }
    return parts.join(' · ');
  }

  String get filesLabel {
    final moved = (report['files_moved'] as num?)?.toInt() ?? 0;
    if (report.isEmpty) return '';
    final failed = (report['files_failed'] as num?)?.toInt() ?? 0;
    final leftover = (report['files_leftover'] as num?)?.toInt() ?? 0;
    final missing = (report['files_missing'] as num?)?.toInt() ?? 0;
    return '文件 $moved 搬迁成功'
        '${failed > 0 ? '，$failed 失败' : ''}'
        '${leftover > 0 ? '，$leftover 旧副本残留' : ''}'
        '${missing > 0 ? '，$missing 源文件缺失' : ''}';
  }

  List<Map<String, dynamic>> get fileErrors {
    final errors = report['file_errors'];
    if (errors is! List) return const [];
    return [for (final item in errors) if (item is Map) Map<String, dynamic>.from(item)];
  }

  String get appliedAt {
    for (final item in applied) {
      if ('${item['id']}' == 'v0.8.0-subjects') {
        return '${item['applied_at'] ?? ''}';
      }
    }
    return applied.isEmpty ? '' : '${applied.first['applied_at'] ?? ''}';
  }

  factory MigrationOverview.fromJson(Map<String, dynamic> status, SettingsData settings) =>
      MigrationOverview(
        applied: [
          for (final item in (status['applied'] as List? ?? []))
            if (item is Map) Map<String, dynamic>.from(item),
        ],
        pending: [for (final item in (status['pending'] as List? ?? [])) '$item'],
        running: status['running'] == true,
        lastError: (status['last_error'] ?? '').toString(),
        report: (status['report'] is Map)
            ? Map<String, dynamic>.from(status['report'] as Map)
            : const {},
        noticeSeen: settings.subjectMigrationNoticeSeen,
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

/// 学科（全局注册表 `subjects` 的一行，见规格 §3.1/§11.2）。
class Subject {
  final int id;
  final String key;
  final String name;
  final String description;
  final String icon;
  final String color;
  final String goal;
  final String examDate;
  final int dailyMinutes;
  final String level;
  final String status;
  final bool isDefault;
  final int sortOrder;
  final String integrity;
  final String lastOpenedAt;
  final String createdAt;
  final String archivedAt;
  final Map<String, dynamic> counts;

  const Subject({
    required this.id,
    required this.key,
    required this.name,
    this.description = '',
    this.icon = '',
    this.color = '',
    this.goal = '',
    this.examDate = '',
    this.dailyMinutes = 0,
    this.level = '',
    this.status = 'active',
    this.isDefault = false,
    this.sortOrder = 0,
    this.integrity = 'ok',
    this.lastOpenedAt = '',
    this.createdAt = '',
    this.archivedAt = '',
    this.counts = const {},
  });

  bool get archived => status == 'archived';

  factory Subject.fromJson(Map<String, dynamic> json) => Subject(
        id: (json['id'] as num?)?.toInt() ?? 0,
        key: (json['key'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        description: (json['description'] ?? '').toString(),
        icon: (json['icon'] ?? '').toString(),
        color: (json['color'] ?? '').toString(),
        goal: (json['goal'] ?? '').toString(),
        examDate: (json['exam_date'] ?? '').toString(),
        dailyMinutes: (json['daily_minutes'] as num?)?.toInt() ?? 0,
        level: (json['level'] ?? '').toString(),
        status: (json['status'] ?? 'active').toString(),
        isDefault: (json['is_default'] as num?)?.toInt() == 1,
        sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
        integrity: (json['integrity'] ?? 'ok').toString(),
        lastOpenedAt: (json['last_opened_at'] ?? '').toString(),
        createdAt: (json['created_at'] ?? '').toString(),
        archivedAt: (json['archived_at'] ?? '').toString(),
        counts: json['counts'] is Map
            ? Map<String, dynamic>.from(json['counts'] as Map)
            : const {},
      );
}

/// 学科内一个可追踪的掌握单元（§8.1）。
class TopicItem {
  final int id;
  final String name;
  final String status;
  final double mastery;
  final double confidence;
  final int evidenceCount;
  final String lastStudiedAt;
  final String nextReviewAt;

  const TopicItem({
    required this.id,
    required this.name,
    this.status = 'learning',
    this.mastery = 0,
    this.confidence = 0,
    this.evidenceCount = 0,
    this.lastStudiedAt = '',
    this.nextReviewAt = '',
  });

  factory TopicItem.fromJson(Map<String, dynamic> json) => TopicItem(
        id: (json['id'] as num?)?.toInt() ?? 0,
        name: (json['name'] ?? '').toString(),
        status: (json['status'] ?? 'learning').toString(),
        mastery: (json['mastery'] as num?)?.toDouble() ?? 0,
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
        evidenceCount: (json['evidence_count'] as num?)?.toInt() ?? 0,
        lastStudiedAt: (json['last_studied_at'] ?? '').toString(),
        nextReviewAt: (json['next_review_at'] ?? '').toString(),
      );
}

/// 每日学习量（`progress_daily`）。
class ProgressDailyPoint {
  final String day;
  final int minutes;
  final int events;
  final int mastered;
  final int reviewDue;

  const ProgressDailyPoint({
    required this.day,
    this.minutes = 0,
    this.events = 0,
    this.mastered = 0,
    this.reviewDue = 0,
  });

  factory ProgressDailyPoint.fromJson(Map<String, dynamic> json) => ProgressDailyPoint(
        day: (json['day'] ?? '').toString(),
        minutes: (json['minutes'] as num?)?.toInt() ?? 0,
        events: (json['events'] as num?)?.toInt() ?? 0,
        mastered: (json['mastered'] as num?)?.toInt() ?? 0,
        reviewDue: (json['review_due'] as num?)?.toInt() ?? 0,
      );
}

/// 学科进度视图（画像 / 汇总 / 知识点 / 每日），接口形状见 §11.4。
class SubjectProgress {
  final Map<String, dynamic> profile;
  final Map<String, dynamic> summary;
  final List<TopicItem> topics;
  final List<ProgressDailyPoint> daily;

  const SubjectProgress({
    this.profile = const {},
    this.summary = const {},
    this.topics = const [],
    this.daily = const [],
  });

  factory SubjectProgress.fromJson(Map<String, dynamic> json) => SubjectProgress(
        profile: json['profile'] is Map
            ? Map<String, dynamic>.from(json['profile'] as Map)
            : const {},
        summary: json['summary'] is Map
            ? Map<String, dynamic>.from(json['summary'] as Map)
            : const {},
        topics: (json['topics'] as List? ?? [])
            .whereType<Map>()
            .map((e) => TopicItem.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        daily: (json['daily'] as List? ?? [])
            .whereType<Map>()
            .map((e) => ProgressDailyPoint.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

// ===========================================================================
// 教学技能（t5；规格 §9，实测结论见 docs/subject-skills-research.md）
// ===========================================================================

/// verify 三态裁决的展示模型。
///
/// ⚠️ [label] 的措辞刻意保守：registry 的静态扫描**不是**恶意软件扫描，
/// 技能包也**没有签名**，所以任何情况下都不显示"安全"。
class SkillVerdictInfo {
  const SkillVerdictInfo({
    this.status = 'unknown',
    this.decision = '',
    this.detail = '',
    this.summary = '',
    this.confidence = '',
    this.signature = '',
    this.canInstallDirectly = false,
    this.requiresExplicitApproval = false,
    this.unverified = true,
  });

  final String status;
  final String decision;
  final String detail;
  final String summary;
  final String confidence;
  final String signature;
  final bool canInstallDirectly;
  final bool requiresExplicitApproval;
  final bool unverified;

  factory SkillVerdictInfo.fromJson(Map<String, dynamic> json) => SkillVerdictInfo(
        status: (json['status'] ?? 'unknown').toString(),
        decision: (json['decision'] ?? '').toString(),
        detail: (json['detail'] ?? '').toString(),
        summary: (json['summary'] ?? '').toString(),
        confidence: (json['confidence'] ?? '').toString(),
        signature: (json['signature'] ?? '').toString(),
        canInstallDirectly: json['can_install_directly'] == true,
        requiresExplicitApproval: json['requires_explicit_approval'] == true,
        unverified: json['unverified'] != false,
      );

  /// 面向用户的短标签（中性、不承诺安全）。
  String get label {
    switch (status) {
      case 'ok':
        return '未被规则命中';
      case 'suspicious':
        return 'registry 未认可';
      default:
        return '未验证';
    }
  }

  /// 详细说明（用于 tooltip / 详情页）。
  String get explanation {
    switch (status) {
      case 'ok':
        return 'registry 的静态扫描没有命中已知高危模式（只覆盖已知模式，且包没有签名，不代表安全）。';
      case 'suspicious':
        return detail.isEmpty ? 'registry 将该技能包标记为可疑，默认拒绝安装。' : detail;
      default:
        return detail.isEmpty ? '本次没有取得 registry 的裁决结果，安装后会被标注为"未验证"。' : detail;
    }
  }
}

/// 本学科已安装的一个教学技能。
class InstalledSkillInfo {
  const InstalledSkillInfo({
    required this.slug,
    this.version = '',
    this.name = '',
    this.description = '',
    this.hub = 'eduhub',
    this.enabled = true,
    this.pinned = false,
    this.hasScripts = false,
    this.sha256 = '',
    this.owner = '',
    this.license = '',
    this.sourceUrl = '',
    this.files = 0,
    this.installedAt = '',
    this.hasPrevious = false,
    this.previousVersion = '',
    this.pkgDir = '',
    this.verdict = const SkillVerdictInfo(),
  });

  final String slug;
  final String version;
  final String name;
  final String description;
  final String hub;
  final bool enabled;
  final bool pinned;

  /// 包内含脚本文件（**仅作为文本资源存在，Loop 永不执行**）。
  final bool hasScripts;
  final String sha256;
  final String owner;
  final String license;
  final String sourceUrl;
  final int files;
  final String installedAt;
  final bool hasPrevious;
  final String previousVersion;
  final String pkgDir;
  final SkillVerdictInfo verdict;

  factory InstalledSkillInfo.fromJson(Map<String, dynamic> json) => InstalledSkillInfo(
        slug: (json['slug'] ?? '').toString(),
        version: (json['version'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        description: (json['description'] ?? '').toString(),
        hub: (json['hub'] ?? 'eduhub').toString(),
        enabled: json['enabled'] != false,
        pinned: json['pinned'] == true,
        hasScripts: json['has_scripts'] == true,
        sha256: (json['sha256'] ?? '').toString(),
        owner: (json['owner'] ?? '').toString(),
        license: (json['license'] ?? '').toString(),
        sourceUrl: (json['source_url'] ?? '').toString(),
        files: (json['files'] as num?)?.toInt() ?? 0,
        installedAt: (json['installed_at'] ?? '').toString(),
        hasPrevious: json['has_previous'] == true,
        previousVersion: (json['previous_version'] ?? '').toString(),
        pkgDir: (json['pkg_dir'] ?? '').toString(),
        verdict: json['verdict'] is Map
            ? SkillVerdictInfo.fromJson(Map<String, dynamic>.from(json['verdict'] as Map))
            : const SkillVerdictInfo(),
      );

  bool get unverified => verdict.status == 'unknown';
  bool get suspicious => verdict.status == 'suspicious';
  bool get canRollback => hasPrevious;

  /// 展示名（缺 name 时回退 slug）。
  String get displayName => name.isEmpty ? slug : name;

  String get licenseLabel => license.isEmpty ? '未声明许可' : license;
}

/// registry 目录/搜索条目。
class HubSkillInfo {
  const HubSkillInfo({
    required this.slug,
    this.name = '',
    this.summary = '',
    this.version = '',
    this.owner = '',
    this.ownerUrl = '',
    this.downloads = 0,
    this.stars = 0,
    this.updatedAt = 0,
    this.webUrl = '',
    this.installed = false,
  });

  final String slug;
  final String name;
  final String summary;
  final String version;
  final String owner;
  final String ownerUrl;
  final int downloads;
  final int stars;
  final int updatedAt;
  final String webUrl;

  /// 本学科是否已装（后端在 catalog 里回填）。
  final bool installed;

  factory HubSkillInfo.fromJson(Map<String, dynamic> json) => HubSkillInfo(
        slug: (json['slug'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        summary: (json['summary'] ?? '').toString(),
        version: (json['version'] ?? '').toString(),
        owner: (json['owner'] ?? '').toString(),
        ownerUrl: (json['owner_url'] ?? '').toString(),
        downloads: (json['downloads'] as num?)?.toInt() ?? 0,
        stars: (json['stars'] as num?)?.toInt() ?? 0,
        updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
        webUrl: (json['web_url'] ?? '').toString(),
        installed: json['installed'] == true,
      );

  String get displayName => name.isEmpty ? slug : name;
}

/// hub 的浏览结果。
class SkillCatalogData {
  const SkillCatalogData({
    this.hub = 'eduhub',
    this.webUrl = '',
    this.query = '',
    this.languages = const ['zh', 'en'],
    this.skills = const [],
  });

  final String hub;
  final String webUrl;
  final String query;
  final List<String> languages;
  final List<HubSkillInfo> skills;

  factory SkillCatalogData.fromJson(Map<String, dynamic> json) {
    final installed = <String>{
      for (final item in (json['installed_slugs'] as List? ?? [])) '$item',
    };
    return SkillCatalogData(
      hub: (json['hub'] ?? 'eduhub').toString(),
      webUrl: (json['web_url'] ?? '').toString(),
      query: (json['query'] ?? '').toString(),
      languages: (json['languages'] as List? ?? ['zh', 'en'])
          .map((e) => '$e')
          .toList(),
      skills: (json['skills'] as List? ?? [])
          .whereType<Map>()
          .map((e) => HubSkillInfo.fromJson(Map<String, dynamic>.from(e)))
          .map((item) => HubSkillInfo(
                slug: item.slug,
                name: item.name,
                summary: item.summary,
                version: item.version,
                owner: item.owner,
                ownerUrl: item.ownerUrl,
                downloads: item.downloads,
                stars: item.stars,
                updatedAt: item.updatedAt,
                webUrl: item.webUrl,
                installed: installed.contains(item.slug),
              ))
          .toList(),
    );
  }
}

/// 后端的技能策略声明（UI 据此正确措辞，避免夸大安全性）。
class SkillPolicyInfo {
  const SkillPolicyInfo({
    this.hubAllowlist = const ['eduhub'],
    this.languages = const ['zh', 'en'],
    this.autoUpdate = false,
    this.autoInstall = false,
    this.verifyIsSecurityGuarantee = false,
    this.verifyNote = '',
    this.maxFileBytes = 1000000,
    this.maxTotalBytes = 20000000,
    this.maxFiles = 500,
  });

  final List<String> hubAllowlist;
  final List<String> languages;
  final bool autoUpdate;
  final bool autoInstall;
  final bool verifyIsSecurityGuarantee;
  final String verifyNote;
  final int maxFileBytes;
  final int maxTotalBytes;
  final int maxFiles;

  factory SkillPolicyInfo.fromJson(Map<String, dynamic> json) {
    final limits = json['limits'] is Map
        ? Map<String, dynamic>.from(json['limits'] as Map)
        : const <String, dynamic>{};
    return SkillPolicyInfo(
      hubAllowlist: (json['hub_allowlist'] as List? ?? ['eduhub']).map((e) => '$e').toList(),
      languages: (json['languages'] as List? ?? ['zh', 'en']).map((e) => '$e').toList(),
      autoUpdate: json['auto_update'] == true,
      autoInstall: json['auto_install'] == true,
      verifyIsSecurityGuarantee: json['verify_is_security_guarantee'] == true,
      verifyNote: (json['verify_note'] ?? '').toString(),
      maxFileBytes: (limits['max_file_bytes'] as num?)?.toInt() ?? 1000000,
      maxTotalBytes: (limits['max_total_bytes'] as num?)?.toInt() ?? 20000000,
      maxFiles: (limits['max_files'] as num?)?.toInt() ?? 500,
    );
  }
}

/// `GET /api/skills` 的完整载荷（「已安装」优先视图）。
class SkillLibraryData {
  const SkillLibraryData({
    this.subjectKey = '',
    this.hub = 'eduhub',
    this.hubLabel = 'EduHub',
    this.webUrl = '',
    this.installed = const [],
    this.policy = const SkillPolicyInfo(),
  });

  final String subjectKey;
  final String hub;
  final String hubLabel;
  final String webUrl;
  final List<InstalledSkillInfo> installed;
  final SkillPolicyInfo policy;

  factory SkillLibraryData.fromJson(Map<String, dynamic> json) => SkillLibraryData(
        subjectKey: (json['subject_key'] ?? '').toString(),
        hub: (json['hub'] ?? 'eduhub').toString(),
        hubLabel: (json['hub_label'] ?? 'EduHub').toString(),
        webUrl: (json['web_url'] ?? '').toString(),
        installed: (json['installed'] as List? ?? [])
            .whereType<Map>()
            .map((e) => InstalledSkillInfo.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        policy: json['policy'] is Map
            ? SkillPolicyInfo.fromJson(Map<String, dynamic>.from(json['policy'] as Map))
            : const SkillPolicyInfo(),
      );

  int get enabledCount => installed.where((item) => item.enabled).length;
}
