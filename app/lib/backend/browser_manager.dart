import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:puppeteer/puppeteer.dart';

import 'db.dart';
import 'agent_tools.dart';

/// 本地 Edge + Puppeteer 会话。仅允许 http(s)，禁止内网/本机地址。
class BrowserManager {
  static Browser? _browser;
  static Page? _page;

  static String? _edgePath() {
    final candidates = [
      r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
      r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
      r'C:\Program Files\Google\Chrome\Application\chrome.exe',
      r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  static Future<Page> _ensurePage() async {
    if (_page != null && _browser != null) return _page!;
    if (Db.setting('agent_browser', 'true') == 'false') {
      throw const ToolFailure('浏览器能力已在设置中关闭');
    }
    final edge = _edgePath();
    if (edge == null) throw const ToolFailure('未找到 Edge/Chrome，无法启动浏览器');
    final dir = Directory(p.join(workspacePath, '.browser-profile'))
      ..createSync(recursive: true);
    _browser = await puppeteer.launch(
      executablePath: edge,
      headless: true,
      userDataDir: dir.path,
      args: ['--no-first-run', '--no-default-browser-check', '--disable-gpu', '--disable-extensions'],
    );
    _page = await _browser!.newPage();
    await _page!.setViewport(DeviceViewport(width: 1280, height: 900));
    return _page!;
  }

  static void _validateUrl(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      throw const ToolFailure('只允许 http/https 网址');
    }
    final host = uri.host.toLowerCase();
    if (host == 'localhost' || host == '127.0.0.1' || host == '::1' || host.endsWith('.local')) {
      throw const ToolFailure('禁止访问本机/内网地址');
    }
    final parts = host.split('.').map(int.tryParse).toList();
    if (parts.length == 4 && parts.every((e) => e != null)) {
      final [a, b, c, d] = parts.cast<int>();
      final private = a == 10 ||
          (a == 172 && b >= 16 && b <= 31) ||
          (a == 192 && b == 168) ||
          (a == 169 && b == 254) ||
          a == 127;
      if (private) throw const ToolFailure('禁止访问本机/内网地址');
    }
  }

  static Future<Map<String, Object?>> _readPage() async {
    final page = await _ensurePage();
    final data = await page.evaluate<dynamic>('''() => ({
      title: document.title,
      url: location.href,
      text: (document.body?.innerText || '').slice(0, 12000),
      links: Array.from(document.querySelectorAll('a')).slice(0, 30).map(a => ({text: (a.innerText || '').trim().slice(0, 60), href: a.href}))
    })''');
    final map = (data as Map).cast<String, dynamic>();
    return {
      'title': map['title'] ?? '',
      'url': map['url'] ?? '',
      'text': map['text'] ?? '',
      'links': map['links'] ?? [],
    };
  }

  static Future<ToolResult> open(String url) async {
    _validateUrl(url);
    final page = await _ensurePage();
    await page.goto(url, wait: Until.networkIdle);
    final info = await _readPage();
    return ToolResult('已打开 ${info['title']}', {'ok': true, 'page': info});
  }

  static Future<ToolResult> read() async {
    final info = await _readPage();
    return ToolResult('已读取网页 ${info['title']}', {'ok': true, 'page': info});
  }

  static Future<ToolResult> click(String selector) async {
    if (selector.trim().isEmpty) throw const ToolFailure('selector 不能为空');
    final page = await _ensurePage();
    await page.click(selector);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final info = await _readPage();
    return ToolResult('已点击 $selector', {'ok': true, 'page': info});
  }

  static Future<ToolResult> type(String selector, String text) async {
    if (selector.trim().isEmpty) throw const ToolFailure('selector 不能为空');
    final page = await _ensurePage();
    await page.type(selector, text);
    return ToolResult('已输入 $selector', {'ok': true});
  }

  static Future<ToolResult> screenshot() async {
    final page = await _ensurePage();
    final bytes = await page.screenshot();
    final dir = Directory(p.join(workspacePath, 'screenshots'))..createSync(recursive: true);
    final file = File(p.join(dir.path, 'browser-${DateTime.now().millisecondsSinceEpoch}.png'));
    file.writeAsBytesSync(bytes);
    return ToolResult('已截图 ${p.basename(file.path)}', {
      'ok': true,
      'path': p.relative(file.path, from: workspacePath),
      'bytes': bytes.length,
    });
  }

  static Future<ToolResult> back() async {
    final page = await _ensurePage();
    await page.goBack();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final info = await _readPage();
    return ToolResult('已返回上一页', {'ok': true, 'page': info});
  }

  static Future<void> close() async {
    await _browser?.close();
    _browser = null;
    _page = null;
  }
}
