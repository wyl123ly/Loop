import 'dart:async';
import 'dart:ui';

import 'package:loop/desktop/answer_host/answer_protocol.dart';
import 'package:loop/desktop/answer_host/answer_window_platform.dart';
import 'package:loop/desktop/window_mode.dart';

import 'fake_answer_transport.dart';

/// 可编程的回答窗平台 fake（t2 提供，t3 可复用）。
///
/// 记录创建/配置/显示/关闭/几何调用；可注入创建失败/几何失败/外部销毁；
/// [ready] 用于模拟第二引擎上报 ready。
class FakeAnswerWindowPlatform implements AnswerWindowPlatform {
  FakeAnswerWindowPlatform({
    List<DisplayInfo>? displays,
    this.supportedValue = true,
    this.dprValue = 1.0,
  }) : displaysValue = displays ??
            <DisplayInfo>[
              const DisplayInfo(
                id: r'\\.\DISPLAY1',
                physicalBounds: Rect.fromLTWH(0, 0, 1920, 1080),
                physicalWorkArea: Rect.fromLTWH(0, 0, 1920, 1040),
                scaleFactor: 1.0,
                isPrimary: true,
              ),
            ];

  final FakeAnswerTransport transport = FakeAnswerTransport();
  List<DisplayInfo> displaysValue;
  bool supportedValue;
  double dprValue;

  final List<String> calls = [];
  final List<AnswerLaunchPayload> launchPayloads = [];
  final List<Rect> configuredBounds = [];
  final List<Rect> appliedBounds = [];

  AnswerWindowHandle? handle;
  bool alive = false;
  bool visible = false;
  bool topmost = true;
  int createCount = 0;
  int closeCount = 0;
  int showCount = 0;
  int hideCount = 0;
  int bringToTopCount = 0;
  int focusMainCount = 0;

  bool failCreate = false;
  Object? createError;
  bool failConfigure = false;
  bool failSetBounds = false;

  /// 模拟第二引擎创建耗时（T5-07 创建竞态测试）。
  Duration? createDelay;

  final StreamController<void> _windowsChanged =
      StreamController<void>.broadcast();

  @override
  bool get supported => supportedValue;

  @override
  Future<AnswerWindowHandle> create({
    required AnswerLaunchPayload payload,
  }) async {
    calls.add('create');
    createCount++;
    final delay = createDelay;
    if (delay != null) await Future<void>.delayed(delay);
    if (failCreate) {
      throw createError ?? StateError('fake create failure');
    }
    launchPayloads.add(payload);
    handle = AnswerWindowHandle(
      windowId: 'answer-$createCount',
      hwnd: 1000 + createCount,
    );
    alive = true;
    visible = false;
    return handle!;
  }

  @override
  Future<void> configure(
    AnswerWindowHandle handle, {
    required Rect physical,
    required bool topmost,
  }) async {
    calls.add('configure');
    if (failConfigure) throw StateError('fake configure failure');
    this.topmost = topmost;
    configuredBounds.add(physical);
    appliedBounds.add(physical);
  }

  @override
  Future<void> setBounds(
    AnswerWindowHandle handle,
    Rect physical, {
    bool topmost = true,
  }) async {
    calls.add('setBounds');
    if (failSetBounds) throw StateError('fake setBounds failure');
    this.topmost = topmost;
    appliedBounds.add(physical);
  }

  @override
  Future<void> showNoActivate(
    AnswerWindowHandle handle, {
    bool topmost = true,
  }) async {
    calls.add('showNoActivate');
    showCount++;
    visible = true;
    this.topmost = topmost;
  }

  @override
  Future<void> hide(AnswerWindowHandle handle) async {
    calls.add('hide');
    hideCount++;
    visible = false;
  }

  @override
  Future<void> bringToTop(AnswerWindowHandle handle) async {
    calls.add('bringToTop');
    bringToTopCount++;
  }

  @override
  Future<void> close(AnswerWindowHandle handle) async {
    calls.add('close');
    closeCount++;
    alive = false;
    visible = false;
  }

  @override
  Future<bool> isAlive(AnswerWindowHandle handle) async => alive;

  @override
  Future<List<String>> listWindowIds() async =>
      alive ? <String>[handle?.windowId ?? ''] : const <String>[];

  @override
  Stream<void> get windowsChanged => _windowsChanged.stream;

  @override
  Future<void> focusMainWindow() async {
    calls.add('focusMainWindow');
    focusMainCount++;
  }

  @override
  Future<List<DisplayInfo>> displays() async =>
      List<DisplayInfo>.of(displaysValue);

  @override
  Future<AnswerTransport> openTransport(AnswerWindowHandle handle) async {
    calls.add('openTransport');
    return transport;
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    await _windowsChanged.close();
  }

  /// 模拟第二引擎 ready。
  Future<void> ready({
    String? windowId,
    int protocol = answerProtocolVersion,
    double? dpr,
    double contentHeightLogical = 0,
    Rect? workAreaLogical,
  }) async {
    final target = handle;
    if (target == null) throw StateError('no answer window created');
    await transport.emitControl('ready', <String, Object?>{
      'protocol': protocol,
      'windowId': windowId ?? target.windowId,
      'dpr': dpr ?? dprValue,
      'workAreaLogical': encodeRect(
        workAreaLogical ?? const Rect.fromLTWH(0, 0, 1920, 1040),
      ),
      'contentHeightLogical': contentHeightLogical,
      'buildMode': 'debug',
    });
  }

  /// 模拟插件 onWindowsChanged。
  Future<void> emitWindowsChanged() async {
    _windowsChanged.add(null);
    await Future<void>.delayed(Duration.zero);
  }

  /// 模拟用户拖到新位置后上报。
  Future<void> moved(Rect physicalRect) async {
    await transport.emitControl('moved', <String, Object?>{
      'physicalRect': encodeRect(physicalRect),
    });
  }

  /// 模拟第二窗测高上报。
  Future<void> contentHeight(double heightLogical) async {
    await transport.emitControl('content_height', <String, Object?>{
      'seq': 1,
      'heightLogical': heightLogical,
    });
  }

  Future<void> control(String method) =>
      transport.emitControl(method, const <String, Object?>{});

  void resetCalls() => calls.clear();
}
