import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'api.dart';
import 'ui_theme.dart';
import 'models.dart';

/// 侧栏「新对话」被点击时 +1，聊天页监听后真正开一个新会话。
final ValueNotifier<int> newChatSignal = ValueNotifier<int>(0);

/// 历史对话被点击时写入会话 id，聊天页监听后加载。
final ValueNotifier<int?> openConversationSignal = ValueNotifier<int?>(null);

/// 最近对话被删除时写入会话 id，聊天页监听后清空/切换。
final ValueNotifier<int?> deletedConversationSignal = ValueNotifier<int?>(null);

/// 当前学科切换时写入新 key，各页监听后按新学科重新取数（§12）。
final ValueNotifier<String?> subjectChangedSignal = ValueNotifier<String?>(null);

class AppState extends ChangeNotifier {
  AppState({LoopApi? api}) : api = api ?? LoopApi();

  /// 可注入假实现用于 widget/单元测试；生产环境使用默认 [LoopApi]。
  final LoopApi api;

  List<Conversation> conversations = [];
  int? currentConversationId;
  SettingsData? settings;
  bool ready = false;
  String? bootstrapError;
  ThemeMode themeMode = ThemeMode.system;
  List<CustomMode> customModes = [];

  /// 只在主题/外观变化时 +1：MaterialApp 只监听它，不再被会话、学科等
  /// 高频通知带着重建整棵树（主题切换卡顿的主因之一）。
  final ValueNotifier<int> appearanceRevision = ValueNotifier<int>(0);

  /// 启动状态（splash → Shell / 错误页）变化时 +1。
  final ValueNotifier<int> bootRevision = ValueNotifier<int>(0);

  /// 学科列表（含归档与否由后端决定；默认只含未归档）。
  List<Subject> subjects = [];

  /// 当前学科；未加载时回退到 [settings.activeSubject] 或默认学科 key。
  Subject? activeSubject;

  /// 当前学科 key（无学科信息时回退 `default`）。
  String get activeKey => activeSubject?.key ?? settings?.activeSubject ?? 'default';

  Future<void> bootstrap() async {
    for (var attempt = 0; attempt < 40; attempt++) {
      try {
        settings = await api.settings();
        final override = themeOverride();
        if (override == null) {
          themeMode = switch (settings!.theme) {
            'light' => ThemeMode.light,
            'dark' => ThemeMode.dark,
            _ => ThemeMode.system,
          };
        }
        try {
          final raw = jsonDecode(settings!.customModes);
          if (raw is List) {
            customModes = raw
                .whereType<Map>()
                .map((item) => CustomMode.fromJson(Map<String, dynamic>.from(item)))
                .toList();
          }
        } catch (_) {
          customModes = [];
        }
        bootstrapError = null;
        appearanceRevision.value++;
        break;
      } catch (error) {
        bootstrapError = error.toString();
        // 桌面端 sidecar 启动需要几秒，这里轮询等它
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    // 先学科（决定各页作用域），再按当前学科取会话（§12 bootstrap 顺序）。
    await loadSubjects();
    await refreshConversations();
    ready = true;
    bootRevision.value++;
    notifyListeners();
  }

  /// 拉取学科列表与当前学科；失败时保留旧值（不阻塞启动）。
  Future<void> loadSubjects() async {
    try {
      subjects = await api.subjects(includeArchived: true);
      activeSubject = await api.activeSubject();
      // 后续请求显式带 `subject=`，避免切换期间的取数落在旧学科。
      api.subjectScope = activeSubject?.key;
      notifyListeners();
    } catch (_) {}
  }

  /// 切换学科：写后端 + 通知 + 触发 [subjectChangedSignal]，并刷新会话列表。
  Future<bool> switchSubject(String key) async {
    if (key.isEmpty || key == activeKey) return true;
    try {
      activeSubject = await api.setActiveSubject(key);
      api.subjectScope = activeSubject?.key ?? key;
      subjectChangedSignal.value = activeSubject?.key ?? key;
      currentConversationId = null;
      conversations = [];
      notifyListeners();
      await refreshConversations();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 新建学科并切换过去（默认学科之外的用户学科）。
  Future<Subject?> createSubject({
    required String name,
    String goal = '',
    String examDate = '',
    int dailyMinutes = 0,
    String icon = '',
    String color = '',
    String level = '',
  }) async {
    try {
      final created = await api.createSubject(
        name: name,
        goal: goal,
        examDate: examDate,
        dailyMinutes: dailyMinutes,
        icon: icon,
        color: color,
        level: level,
      );
      await loadSubjects();
      await switchSubject(created.key);
      return created;
    } catch (_) {
      return null;
    }
  }

  /// 学科内数据变化后按当前学科重新取数（会话/资料/待办片各自刷新）。
  Future<void> refreshSubjectScoped() async {
    await refreshConversations();
  }

  Future<void> refreshConversations() async {
    try {
      conversations = await api.conversations();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> refreshSettings() async {
    try {
      settings = await api.settings();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> deleteConversation(int id) async {
    try {
      await api.deleteConversation(id);
    } catch (_) {}
    conversations.removeWhere((item) => item.id == id);
    if (currentConversationId == id) {
      currentConversationId = conversations.isEmpty ? null : conversations.first.id;
    }
    notifyListeners();
    deletedConversationSignal.value = id;
    await refreshConversations();
  }

  void setCurrentConversation(int? id) {
    if (currentConversationId == id) return;
    currentConversationId = id;
    notifyListeners();
  }

  Conversation? conversationById(int? id) {
    if (id == null) return null;
    for (final item in conversations) {
      if (item.id == id) return item;
    }
    return null;
  }

  Future<void> saveCustomModes(List<CustomMode> modes) async {
    customModes = modes;
    notifyListeners();
    try {
      await api.saveSettings(customModes: jsonEncode(modes.map((m) => m.toJson()).toList()));
    } catch (_) {}
  }

  Future<void> setSidebarCollapsed(bool value) async {
    final current = settings;
    settings = _copySettings(current, sidebarCollapsed: value);
    notifyListeners();
    try {
      await api.saveSettings(sidebarCollapsed: value);
    } catch (_) {}
  }

  Future<void> setAutoCheckUpdates(bool value) async {
    final current = settings;
    settings = _copySettings(current, autoCheckUpdates: value);
    notifyListeners();
    try {
      await api.saveSettings(autoCheckUpdates: value);
    } catch (_) {}
  }

  /// 读全局“流式输出”开关；设置尚未加载时按默认 [true] 处理。
  bool get streamOutput => settings?.streamOutput ?? true;

  /// 立即切换开关并持久化；保存失败时回滚旧值并返回 false，由设置页提示。
  Future<bool> setStreamOutput(bool value) async {
    final current = settings;
    if (current == null) return false;
    if (current.streamOutput == value) return true;
    settings = _copySettings(current, streamOutput: value);
    notifyListeners();
    try {
      await api.saveSettings(streamOutput: value);
      return true;
    } catch (_) {
      settings = current;
      notifyListeners();
      return false;
    }
  }

  /// 复制 [SettingsData] 的全部字段后再改指定项，避免侧栏/更新开关把
  /// `streamOutput` 等新字段重置成默认值。
  SettingsData _copySettings(
    SettingsData? current, {
    bool? autoCheckUpdates,
    bool? sidebarCollapsed,
    bool? streamOutput,
  }) {
    return SettingsData(
      apiKeyMasked: current?.apiKeyMasked ?? '',
      hasKey: current?.hasKey ?? false,
      baseUrl: current?.baseUrl ?? '',
      model: current?.model ?? 'deepseek-flash',
      reasonModel: current?.reasonModel ?? 'deepseek-v4-pro',
      activeProvider: current?.activeProvider ?? 'deepseek',
      providersJson: current?.providersJson ?? '[]',
      theme: current?.theme ?? 'system',
      customModes: current?.customModes ?? '[]',
      autoCheckUpdates: autoCheckUpdates ?? current?.autoCheckUpdates ?? true,
      sidebarCollapsed: sidebarCollapsed ?? current?.sidebarCollapsed ?? false,
      streamOutput: streamOutput ?? current?.streamOutput ?? true,
      activeSubject: current?.activeSubject ?? 'default',
      crossSubjectSearch: current?.crossSubjectSearch ?? false,
    );
  }

  Future<void> setTheme(ThemeMode mode) async {
    if (themeMode == mode) return;
    themeMode = mode;
    // 先让界面立即换色；持久化放到后台，不阻塞这一帧。
    appearanceRevision.value++;
    notifyListeners();
    try {
      await api.saveSettings(
        theme: switch (mode) { ThemeMode.light => 'light', ThemeMode.dark => 'dark', _ => 'system' },
      );
    } catch (_) {}
  }

  /// 系统深浅色变化：只有跟随系统时才需要重刷界面。
  void notifySystemBrightnessChanged() {
    if (themeMode != ThemeMode.system) return;
    appearanceRevision.value++;
    notifyListeners();
  }

  void newChat() => newChatSignal.value++;

  void openConversation(int id) => openConversationSignal.value = id;
}

final AppState appState = AppState();
