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

class AppState extends ChangeNotifier {
  final LoopApi api = LoopApi();

  List<Conversation> conversations = [];
  int? currentConversationId;
  SettingsData? settings;
  bool ready = false;
  String? bootstrapError;
  ThemeMode themeMode = ThemeMode.system;
  List<CustomMode> customModes = [];

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
        break;
      } catch (error) {
        bootstrapError = error.toString();
        // 桌面端 sidecar 启动需要几秒，这里轮询等它
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    ready = true;
    notifyListeners();
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
    settings = SettingsData(
      apiKeyMasked: current?.apiKeyMasked ?? '',
      hasKey: current?.hasKey ?? false,
      baseUrl: current?.baseUrl ?? '',
      model: current?.model ?? 'deepseek-flash',
      reasonModel: current?.reasonModel ?? 'deepseek-v4-pro',
      theme: current?.theme ?? 'dark',
      customModes: current?.customModes ?? '[]',
      autoCheckUpdates: current?.autoCheckUpdates ?? true,
      sidebarCollapsed: value,
    );
    notifyListeners();
    try {
      await api.saveSettings(sidebarCollapsed: value);
    } catch (_) {}
  }

  Future<void> setAutoCheckUpdates(bool value) async {
    settings = SettingsData(
      apiKeyMasked: settings?.apiKeyMasked ?? '',
      hasKey: settings?.hasKey ?? false,
      baseUrl: settings?.baseUrl ?? '',
      model: settings?.model ?? 'deepseek-flash',
      reasonModel: settings?.reasonModel ?? 'deepseek-v4-pro',
      theme: settings?.theme ?? 'dark',
      customModes: settings?.customModes ?? '[]',
      autoCheckUpdates: value,
      sidebarCollapsed: settings?.sidebarCollapsed ?? false,
    );
    notifyListeners();
    try {
      await api.saveSettings(autoCheckUpdates: value);
    } catch (_) {}
  }

  Future<void> setTheme(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    try {
      await api.saveSettings(
        theme: switch (mode) { ThemeMode.light => 'light', ThemeMode.dark => 'dark', _ => 'system' },
      );
    } catch (_) {}
  }

  void newChat() => newChatSignal.value++;

  void openConversation(int id) => openConversationSignal.value = id;
}

final AppState appState = AppState();
