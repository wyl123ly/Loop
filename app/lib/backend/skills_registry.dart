/// 教学 skill registry 适配器（t5）。
///
/// 设计约束（验收 + docs/subject-skills-research.md §4/§7.4）：
/// - **hub 由后端白名单固定**：只有 [SkillHubAllowlist] 里登记的 hub 能被访问，
///   前端**不能**传入任意 registry URL（防 SSRF）；HTTP 层只暴露 `eduhub`。
/// - **禁跟随任意外部重定向**：只允许跳到同一 hub 白名单主机，且最多 2 跳。
/// - **进程内 Dart**：不调用 eduhub CLI / npm / Python sidecar。
/// - 只读消费：搜索/目录/详情/verify/下载，全部免登录（无需 token）。
///
/// 字段适配依据实测（research §4.4/§4.5/§4.7）：
/// - 列表响应可能是 `{results|skills|items: [...]}` 三种形状之一；
/// - `skill.tags` 是 dist-tags map（**不是**话题标签），话题标签在 `skill.keywords`；
/// - 完整性清单在 `?files=true` 的 `files[]`（path/size/sha256/contentType）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// 一个 hub 的静态描述。
class SkillHub {
  const SkillHub({
    required this.name,
    required this.label,
    required this.baseUrl,
    required this.webUrl,
    required this.allowedHosts,
    this.allowInsecure = false,
  });

  final String name;
  final String label;

  /// 形如 `https://eduhub.deeptutor.info/api/v1`（无尾斜杠）。
  final String baseUrl;

  /// 站点来源，用于 "在 EduHub 查看" 外链。
  final String webUrl;

  /// 允许访问/重定向的主机白名单（小写）。
  final Set<String> allowedHosts;

  /// 是否允许非 TLS（仅用于测试内嵌 hub；正式 hub 恒为 false）。
  final bool allowInsecure;

  bool allowsHost(String host) => allowedHosts.contains(host.toLowerCase());

  String skillWebUrl(String slug) => '$webUrl/skills/${Uri.encodeComponent(slug)}';

  /// 测试/自托管构造：主机白名单收敛为该 baseUrl 自身。
  factory SkillHub.forBaseUrl(
    String baseUrl, {
    String name = 'eduhub',
    String label = 'EduHub (test)',
    String? webUrl,
  }) {
    final uri = Uri.parse(baseUrl);
    if (uri.host.isEmpty || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw ArgumentError('非法 hub baseUrl：$baseUrl');
    }
    final normalized = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return SkillHub(
      name: name,
      label: label,
      baseUrl: normalized,
      webUrl: webUrl ?? '${uri.scheme}://${uri.authority}',
      allowedHosts: {uri.host},
      allowInsecure: uri.scheme != 'https',
    );
  }
}

/// 后端 hub 白名单：**唯一**的 registry 入口。
class SkillHubAllowlist {
  const SkillHubAllowlist._();

  static const String defaultHub = 'eduhub';

  static const Map<String, SkillHub> hubs = <String, SkillHub>{
    'eduhub': SkillHub(
      name: 'eduhub',
      label: 'EduHub',
      baseUrl: 'https://eduhub.deeptutor.info/api/v1',
      webUrl: 'https://eduhub.deeptutor.info',
      allowedHosts: <String>{'eduhub.deeptutor.info'},
    ),
  };

  /// 解析 hub 名；未知/非法一律拒绝（不降级到默认，避免静默指向他处）。
  static SkillHub resolve(String? hub) {
    final key = (hub ?? defaultHub).trim().toLowerCase();
    final found = hubs[key];
    if (found == null) {
      throw SkillRegistryError('blocked', '不支持的 registry：$hub（仅允许 ${hubs.keys.join(' / ')}）');
    }
    // 测试专用：把白名单 hub 指向本地假 hub（仅 FLUTTER_TEST 进程生效），
    // 让 F-5/F-6/F-7/F-8 的 HTTP 级用例能真实走 server 的 skills 处理器。
    final override = baseUrlOverrideForTests;
    if (override != null && override.isNotEmpty && _isTestProcess) {
      return SkillHub.forBaseUrl(override, name: key, label: '${found.label} (test)');
    }
    return found;
  }

  /// HTTP 级测试注入点（生产恒为 null）。
  static String? baseUrlOverrideForTests;

  static bool get _isTestProcess => Platform.environment['FLUTTER_TEST'] == 'true';

  /// 白名单 hub 的 baseUrl 列表（F-18：设置页只读展示，与实际白名单一致）。
  static List<String> get hubUrls => [for (final hub in hubs.values) hub.baseUrl];

  static bool contains(String hub) => hubs.containsKey(hub.trim().toLowerCase());
}

/// registry 访问失败。`code == 'offline'` 表示网络不可达（可降级）。
class SkillRegistryError implements Exception {
  SkillRegistryError(this.code, this.message, {this.status = 0});

  /// `offline` | `not_found` | `bad_response` | `blocked` | `too_large` | `http`
  final String code;
  final String message;
  final int status;

  bool get offline => code == 'offline';

  Map<String, dynamic> toJson() => {
        'ok': false,
        'code': code,
        'offline': offline,
        'message': message,
        if (status != 0) 'status': status,
      };

  @override
  String toString() => 'SkillRegistryError($code): $message';
}

/// verify 三态裁决（research §4.3 实测语义）。
///
/// ⚠️ **这不是安全保证**：抽象扫描只覆盖已知高危模式，置信度通常为 low，
/// 且包**没有签名**（`signature.status = unsigned`）。UI 不得表述为"安全"。
class SkillVerdict {
  const SkillVerdict({
    required this.status,
    this.decision = '',
    this.detail = '',
    this.summary = '',
    this.confidence = '',
    this.signature = '',
  });

  static const String ok = 'ok';
  static const String suspicious = 'suspicious';
  static const String unknown = 'unknown';

  final String status;
  final String decision;
  final String detail;

  /// registry 自述摘要（如实展示，不改写）。
  final String summary;
  final String confidence;
  final String signature;

  /// `ok=true` → 可直接安装。
  bool get canInstallDirectly => status == ok;

  /// `ok=false` → 默认拒绝，需用户显式"仍然安装"。
  bool get requiresExplicitApproval => status == suspicious;

  /// 请求失败 → 可降级安装，但必须标注"未验证"。
  bool get isUnverified => status == unknown;

  bool get canInstallWithApproval => canInstallDirectly || isUnverified;

  Map<String, dynamic> toJson() => {
        'status': status,
        'decision': decision,
        'detail': detail,
        'summary': summary,
        'confidence': confidence,
        'signature': signature,
        'can_install_directly': canInstallDirectly,
        'requires_explicit_approval': requiresExplicitApproval,
        'unverified': isUnverified,
      };

  @override
  String toString() => 'SkillVerdict($status/$decision)';

  /// 从 `/skills/{slug}/verify` 响应构造。
  ///
  /// 判定规则（与 DeepTutor 实测实现一致，**fail-closed**）：
  /// - `ok` 严格等于 `true` → [ok]；
  /// - `ok` 为其它值（含缺失/类型异常）→ [suspicious]（默认拒装）；
  /// - 请求本身失败 → 由调用方给出 [unknown]，不走本方法。
  static SkillVerdict fromVerifyPayload(Map<String, dynamic> payload) {
    final decision = (payload['decision'] ?? '').toString();
    final security = payload['security'];
    final securityMap = security is Map ? security : const {};
    final signature = payload['signature'];
    final signatureMap = signature is Map ? signature : const {};
    final summary = (securityMap['summary'] ?? '').toString();
    final confidence = (securityMap['confidence'] ?? '').toString();
    final signatureStatus = (signatureMap['status'] ?? '').toString();

    if (payload['ok'] == true) {
      return SkillVerdict(
        status: ok,
        decision: decision.isEmpty ? 'ok' : decision,
        detail: (securityMap['status'] ?? '').toString(),
        summary: summary,
        confidence: confidence,
        signature: signatureStatus,
      );
    }
    return SkillVerdict(
      status: suspicious,
      decision: decision.isEmpty ? 'flagged' : decision,
      detail: summary.isEmpty ? 'registry 未认可该包' : summary,
      summary: summary,
      confidence: confidence,
      signature: signatureStatus,
    );
  }

  /// 请求失败时的降级裁决。
  static SkillVerdict unavailable(String reason) =>
      SkillVerdict(status: unknown, decision: 'unavailable', detail: reason);

  /// registry 无 verdict 端点/响应不可解析时的降级裁决。
  static SkillVerdict unreadable(String reason) =>
      SkillVerdict(status: unknown, decision: 'unreadable', detail: reason);
}

/// 搜索结果/目录条目。
class SkillListing {
  const SkillListing({
    required this.slug,
    required this.name,
    this.summary = '',
    this.version = '',
    this.owner = '',
    this.ownerUrl = '',
    this.downloads = 0,
    this.stars = 0,
    this.updatedAt = 0,
    this.webUrl = '',
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

  Map<String, dynamic> toJson() => {
        'slug': slug,
        'name': name,
        'summary': summary,
        'version': version,
        'owner': owner,
        'owner_url': ownerUrl,
        'downloads': downloads,
        'stars': stars,
        'updated_at': updatedAt,
        'web_url': webUrl,
      };
}

/// `?files=true` 的逐文件完整性清单条目。
class SkillManifestFile {
  const SkillManifestFile({
    required this.path,
    required this.size,
    required this.sha256,
    this.contentType = '',
  });

  final String path;
  final int size;
  final String sha256;
  final String contentType;

  Map<String, dynamic> toJson() =>
      {'path': path, 'size': size, 'sha256': sha256, 'content_type': contentType};
}

/// 详情（含 SKILL.md 正文与完整性清单）。
class SkillDetail extends SkillListing {
  const SkillDetail({
    required super.slug,
    required super.name,
    super.summary,
    super.version,
    super.owner,
    super.ownerUrl,
    super.downloads,
    super.stars,
    super.updatedAt,
    super.webUrl,
    this.content = '',
    this.tags = const [],
    this.license = '',
    this.changelog = '',
    this.versions = const [],
    this.distTags = const {},
    this.files = const [],
  });

  /// SKILL.md 全文（EduHub 的 `skill.description`）。
  final String content;

  /// 话题关键词（来自 `skill.keywords`，**不是** dist-tags）。
  final List<String> tags;
  final String license;
  final String changelog;
  final List<String> versions;
  final Map<String, String> distTags;
  final List<SkillManifestFile> files;

  bool get hasManifest => files.isNotEmpty;

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'content': content,
        'tags': tags,
        'license': license,
        'changelog': changelog,
        'versions': versions,
        'dist_tags': distTags,
        'files': [for (final f in files) f.toJson()],
      };
}

/// 下载到的规范化 zip。
class SkillPackage {
  const SkillPackage({
    required this.bytes,
    required this.version,
    required this.slug,
  });

  final Uint8List bytes;
  final String version;
  final String slug;

  int get length => bytes.length;
}

/// ClawHub 协议 registry 的只读客户端。
class SkillRegistry {
  SkillRegistry({
    SkillHub? hub,
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
    this.downloadTimeout = const Duration(seconds: 45),
    SkillHub? hubForTests,
  })  : _hub = hubForTests ?? hub ?? SkillHubAllowlist.resolve(null),
        _client = client ?? http.Client();

  /// 正式入口：白名单 hub（默认 eduhub）。
  factory SkillRegistry.forHub(
    String? hubName, {
    http.Client? client,
    Duration timeout = const Duration(seconds: 10),
    Duration downloadTimeout = const Duration(seconds: 45),
  }) {
    return SkillRegistry(
      hub: SkillHubAllowlist.resolve(hubName),
      client: client,
      timeout: timeout,
      downloadTimeout: downloadTimeout,
    );
  }

  /// 测试/自托管专用：指向一个显式 baseUrl（HTTP 层**不会**暴露此构造）。
  factory SkillRegistry.forBaseUrlForTests(
    String baseUrl, {
    http.Client? client,
    Duration timeout = const Duration(seconds: 10),
    Duration downloadTimeout = const Duration(seconds: 45),
  }) {
    return SkillRegistry(
      hubForTests: SkillHub.forBaseUrl(baseUrl),
      client: client,
      timeout: timeout,
      downloadTimeout: downloadTimeout,
    );
  }

  /// 语言只暴露 zh/en：文档声称 `ja`/`other` 可发布，但实测 CLI 会拒绝，
  /// 因此 Loop 侧不接受（research §3.4）。
  static const List<String> languages = <String>['zh', 'en'];

  static bool isSupportedLanguage(String? language) {
    final value = (language ?? '').trim().toLowerCase();
    return languages.contains(value);
  }

  static const int _maxRedirects = 2;
  static const int _maxJsonBytes = 8 * 1024 * 1024;

  /// registry 单包硬上限 40MB（research §3.5）；下载后再按导入上限收紧。
  static const int maxArtifactBytes = 40 * 1024 * 1024;

  final SkillHub _hub;
  final http.Client _client;
  final Duration timeout;
  final Duration downloadTimeout;

  SkillHub get hub => _hub;

  void close() => _client.close();

  // ------------------------------------------------------------ 公开方法

  /// 关键词搜索（`/search`）。空 query 走目录（`/skills`）。
  Future<List<SkillListing>> search(String query, {int limit = 25}) {
    final q = query.trim();
    if (q.isEmpty) return catalog(limit: limit);
    return _listing(
      '/search',
      query: {'q': q, 'limit': '${limit.clamp(1, 100)}'},
    );
  }

  /// 目录浏览（`/skills`）——"已安装"之外的探索入口，仅用户主动进入时调用。
  Future<List<SkillListing>> catalog({int limit = 50}) => _listing(
        '/skills',
        query: {'limit': '${limit.clamp(1, 100)}'},
      );

  /// 详情；默认带 `files=true` 以取得逐文件 sha256 清单。
  Future<SkillDetail> detail(
    String slug, {
    String? version,
    bool files = true,
  }) async {
    _assertSlug(slug);
    final payload = await _getJson(
      '/skills/${Uri.encodeComponent(slug)}',
      query: {
        if (version != null && version.isNotEmpty) 'version': version,
        if (files) 'files': 'true',
      },
    );
    final skill = payload['skill'];
    final skillMap = skill is Map ? skill.cast<String, dynamic>() : payload;

    final owner = _ownerOf(payload, skillMap);
    final latest = payload['latestVersion'];
    final latestMap = latest is Map ? latest.cast<String, dynamic>() : const {};
    final distRaw = payload['distTags'];
    final distTags = <String, String>{};
    if (distRaw is Map) {
      distRaw.forEach((key, value) => distTags['$key'] = '$value');
    }

    // 字段陷阱：`skill.tags` 是 dist-tags map；话题标签在 `skill.keywords`。
    final keywords = skillMap['keywords'];
    final tags = keywords is List
        ? [for (final item in keywords) '$item'.trim()].where((e) => e.isNotEmpty).toList()
        : const <String>[];

    final versions = <String>[];
    final versionsRaw = payload['versions'];
    if (versionsRaw is List) {
      for (final item in versionsRaw) {
        final text = '$item'.trim();
        if (text.isNotEmpty) versions.add(text);
      }
    }

    final filesList = <SkillManifestFile>[];
    final filesRaw = payload['files'];
    if (filesRaw is List) {
      for (final item in filesRaw) {
        if (item is! Map) continue;
        final path = (item['path'] ?? '').toString();
        final sha = (item['sha256'] ?? '').toString().toLowerCase();
        if (path.isEmpty || sha.isEmpty) continue;
        filesList.add(SkillManifestFile(
          path: path,
          size: (item['size'] as num?)?.toInt() ?? 0,
          sha256: sha,
          contentType: (item['contentType'] ?? '').toString(),
        ));
      }
    }

    final effectiveVersion = distTags['latest'] ??
        (latestMap['version'] ?? '').toString().trim();

    return SkillDetail(
      slug: (skillMap['slug'] ?? slug).toString(),
      name: (skillMap['displayName'] ?? skillMap['name'] ?? slug).toString(),
      summary: (skillMap['summary'] ?? skillMap['description'] ?? '').toString(),
      version: effectiveVersion.isEmpty
          ? (skillMap['version'] ?? '').toString()
          : effectiveVersion,
      owner: owner.$1,
      ownerUrl: owner.$2,
      downloads: _intOf(skillMap, 'stats', 'downloads'),
      stars: _intOf(skillMap, 'stats', 'stars'),
      updatedAt: (skillMap['updatedAt'] as num?)?.toInt() ?? 0,
      webUrl: _hub.skillWebUrl(slug),
      content: (skillMap['description'] ?? '').toString(),
      tags: tags,
      license: (latestMap['license'] ?? '').toString(),
      changelog: (latestMap['changelog'] ?? '').toString(),
      versions: versions,
      distTags: distTags,
      files: filesList,
    );
  }

  /// 安全裁决。**请求失败 → unknown（降级）**，绝不抛出。
  Future<SkillVerdict> verify(String slug, {String? version}) async {
    _assertSlug(slug);
    try {
      final payload = await _getJson(
        '/skills/${Uri.encodeComponent(slug)}/verify',
        query: {
          if (version != null && version.isNotEmpty) 'version': version,
          if (version == null || version.isEmpty) 'tag': 'latest',
        },
      );
      return SkillVerdict.fromVerifyPayload(payload);
    } on SkillRegistryError catch (error) {
      if (error.offline) return SkillVerdict.unavailable(error.message);
      if (error.code == 'not_found') {
        return SkillVerdict.unreadable('registry 没有该包的裁决记录');
      }
      return SkillVerdict.unreadable(error.message);
    } catch (error) {
      return SkillVerdict.unreadable('$error');
    }
  }

  /// 下载规范化 zip（`/download`）。
  Future<SkillPackage> download(String slug, {String? version}) async {
    _assertSlug(slug);
    final response = await _send(
      '/download',
      query: {
        'slug': slug,
        if (version != null && version.isNotEmpty) 'version': version,
        if (version == null || version.isEmpty) 'tag': 'latest',
      },
      timeout: downloadTimeout,
      accept: 'application/zip',
    );
    if (response.statusCode == 404) {
      throw SkillRegistryError('not_found', 'registry 上没有这个技能包：$slug',
          status: 404);
    }
    if (response.statusCode == 409) {
      throw SkillRegistryError(
          'bad_response', '该 slug 存在歧义，需要指定发布者（ownerHandle）', status: 409);
    }
    if (response.statusCode >= 400) {
      throw SkillRegistryError('http', '下载失败（HTTP ${response.statusCode}）',
          status: response.statusCode);
    }
    final bytes = response.bodyBytes;
    if (bytes.isEmpty) {
      throw SkillRegistryError('bad_response', 'registry 返回了空包');
    }
    if (bytes.length > maxArtifactBytes) {
      throw SkillRegistryError('too_large',
          '技能包超出 registry 上限（${(bytes.length / 1024 / 1024).toStringAsFixed(1)}MB > 40MB）');
    }
    final resolved = await _resolveVersion(slug, version);
    return SkillPackage(bytes: bytes, version: resolved, slug: slug);
  }

  // ------------------------------------------------------------ 内部

  Future<String> _resolveVersion(String slug, String? version) async {
    if (version != null && version.isNotEmpty) return version;
    try {
      final payload = await _getJson('/skills/${Uri.encodeComponent(slug)}');
      final dist = payload['distTags'];
      if (dist is Map && dist['latest'] != null) return '${dist['latest']}';
      final latest = payload['latestVersion'];
      if (latest is Map && latest['version'] != null) return '${latest['version']}';
      final skill = payload['skill'];
      if (skill is Map && skill['version'] != null) return '${skill['version']}';
    } catch (_) {}
    return '';
  }

  (String, String) _ownerOf(Map<String, dynamic> payload, Map<String, dynamic> skill) {
    final owner = payload['owner'] ?? skill['owner'];
    if (owner is Map) {
      final handle = (owner['handle'] ?? owner['displayName'] ?? '').toString();
      final url = (owner['htmlUrl'] ?? '').toString();
      if (handle.isNotEmpty) return (handle, url);
    }
    final handle = (skill['ownerHandle'] ?? payload['ownerHandle'] ?? '').toString();
    return (handle, '');
  }

  int _intOf(Map<String, dynamic> source, String mapKey, String field) {
    final map = source[mapKey];
    if (map is Map) return (map[field] as num?)?.toInt() ?? 0;
    return 0;
  }

  void _assertSlug(String slug) {
    if (!isValidSlug(slug)) {
      throw SkillRegistryError('bad_response', '非法 slug：$slug');
    }
  }

  /// slug 白名单形状（与 registry/CLI 一致）：`^[a-z0-9][a-z0-9._-]{0,127}$`。
  static bool isValidSlug(String slug) =>
      RegExp(r'^[a-z0-9][a-z0-9._-]{0,127}$').hasMatch(slug);

  Future<List<SkillListing>> _listing(
    String path, {
    required Map<String, String> query,
  }) async {
    final payload = await _getJson(path, query: query);
    final rows = _rowsOf(payload);
    final out = <SkillListing>[];
    for (final row in rows) {
      final slug = (row['slug'] ?? '').toString().trim();
      if (slug.isEmpty) continue;
      final owner = row['owner'];
      final ownerMap = owner is Map ? owner : const {};
      final stats = row['stats'];
      final statsMap = stats is Map ? stats : const {};
      out.add(SkillListing(
        slug: slug,
        name: (row['displayName'] ?? row['name'] ?? slug).toString(),
        summary: (row['summary'] ?? row['description'] ?? '').toString(),
        version: (row['version'] ?? '').toString(),
        owner: (ownerMap['handle'] ?? row['ownerHandle'] ?? '').toString(),
        ownerUrl: (ownerMap['htmlUrl'] ?? '').toString(),
        downloads: (statsMap['downloads'] as num?)?.toInt() ?? 0,
        stars: (statsMap['stars'] as num?)?.toInt() ?? 0,
        updatedAt: (row['updatedAt'] as num?)?.toInt() ?? 0,
        webUrl: _hub.skillWebUrl(slug),
      ));
    }
    return out;
  }

  /// 兼容三种列表形状：`{results}`（EduHub search）/ `{skills}`（EduHub 目录）
  /// / `{items,nextCursor}`（ClawHub）。
  List<Map<String, dynamic>> _rowsOf(Map<String, dynamic> payload) {
    for (final key in const ['results', 'skills', 'items']) {
      final value = payload[key];
      if (value is List) {
        return [
          for (final item in value)
            if (item is Map) item.cast<String, dynamic>(),
        ];
      }
    }
    return const [];
  }

  Future<Map<String, dynamic>> _getJson(
    String path, {
    Map<String, String>? query,
  }) async {
    final response = await _send(path, query: query, timeout: timeout);
    if (response.statusCode == 404) {
      throw SkillRegistryError('not_found', 'registry 上没有这个资源：$path', status: 404);
    }
    if (response.statusCode >= 400) {
      throw SkillRegistryError(
          'http', 'registry 返回 HTTP ${response.statusCode}', status: response.statusCode);
    }
    if (response.bodyBytes.length > _maxJsonBytes) {
      throw SkillRegistryError('too_large', 'registry 响应过大');
    }
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map) return decoded.cast<String, dynamic>();
      if (decoded is List) return {'items': decoded};
      throw const FormatException('unexpected payload');
    } on SkillRegistryError {
      rethrow;
    } catch (error) {
      throw SkillRegistryError('bad_response', 'registry 响应不是合法 JSON：$error');
    }
  }

  /// 发起 GET，**手动**处理重定向：只允许跳到白名单主机，最多 2 跳。
  Future<http.Response> _send(
    String path, {
    Map<String, String>? query,
    required Duration timeout,
    String accept = 'application/json',
  }) async {
    var uri = Uri.parse('${_hub.baseUrl}$path');
    if (query != null && query.isNotEmpty) {
      uri = uri.replace(queryParameters: query);
    }
    var hops = 0;
    while (true) {
      final request = http.Request('GET', uri)
        ..followRedirects = false;
      request.headers['Accept'] = accept;
      request.headers['User-Agent'] = 'Loop/0.8 subject-skills';

      final http.StreamedResponse streamed;
      try {
        streamed = await _client.send(request).timeout(timeout);
      } on TimeoutException {
        throw SkillRegistryError('offline', '连接 $path 超时（${timeout.inSeconds}s）');
      } catch (error) {
        throw SkillRegistryError('offline', '无法连接 registry：$error');
      }

      final body = await _readCapped(streamed, maxArtifactBytes);
      final response = http.Response.bytes(
        body,
        streamed.statusCode,
        headers: streamed.headers,
        request: request,
      );

      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers['location'];
        if (location == null || location.isEmpty) {
          throw SkillRegistryError('bad_response', 'registry 返回了没有 Location 的重定向');
        }
        final target = uri.resolve(location);
        if (hops >= _maxRedirects) {
          throw SkillRegistryError('blocked', '重定向次数过多，已拒绝（防 SSRF）');
        }
        if (!_hub.allowsHost(target.host)) {
          throw SkillRegistryError(
              'blocked', '拒绝跟随到非白名单主机的重定向：${target.host}');
        }
        if (!_hub.allowInsecure && target.scheme != 'https') {
          throw SkillRegistryError('blocked', '拒绝跟随到非 HTTPS 的重定向：$target');
        }
        uri = target;
        hops++;
        continue;
      }
      return response;
    }
  }

  Future<Uint8List> _readCapped(http.StreamedResponse streamed, int cap) async {
    final declared = streamed.contentLength;
    if (declared != null && declared > cap) {
      throw SkillRegistryError(
          'too_large', 'registry 响应超出上限（${(declared / 1024 / 1024).toStringAsFixed(1)}MB）');
    }
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in streamed.stream) {
      total += chunk.length;
      if (total > cap) {
        throw SkillRegistryError('too_large', 'registry 响应超出上限（>${cap ~/ 1024 ~/ 1024}MB）');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}