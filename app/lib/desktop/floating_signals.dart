import 'package:flutter/foundation.dart';

/// 一次截图请求（来自 Alt+A 或浮窗按钮）。
///
/// 快捷键/按钮层只投递请求，不在该层截图或上传；由当前可见的 ChatScreen
/// 在自己的守卫（active/发送中/上传中/截图进行中）通过后消费。
@immutable
class ScreenshotRequest {
  const ScreenshotRequest({required this.hideLoop, required this.nonce});

  /// true=隐藏 Loop 后截图（浮窗默认）；false=直接截图（主窗口行为）。
  final bool hideLoop;

  /// 每次请求自增，避免同一次请求被重复消费。
  final int nonce;

  @override
  String toString() => 'ScreenshotRequest(hideLoop=$hideLoop, nonce=$nonce)';
}

/// 全局截图请求信号（规格 §5.3 冻结接口）。
final ValueNotifier<ScreenshotRequest?> screenshotRequestSignal =
    ValueNotifier<ScreenshotRequest?>(null);

/// 截图覆盖/恢复进行中标记（UI 用于禁用切换/再次截图）。
final ValueNotifier<bool> captureInProgress = ValueNotifier<bool>(false);

int _requestNonce = 0;

/// 投递一次截图请求；返回请求（含本次 nonce）。
ScreenshotRequest requestScreenshot({required bool hideLoop}) {
  final request = ScreenshotRequest(hideLoop: hideLoop, nonce: ++_requestNonce);
  screenshotRequestSignal.value = request;
  return request;
}

/// 清除当前请求（消费后调用，避免重建时重复触发）。
void clearScreenshotRequest() {
  screenshotRequestSignal.value = null;
}
