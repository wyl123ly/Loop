import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:loop/backend/paths.dart';
import 'package:loop/backend/server.dart';
import 'package:loop/backend/skills_import.dart';
import 'package:loop/backend/skills_registry.dart';
import 'package:loop/backend/subject_store.dart';

/// 教学技能导入器功能测试（t5；规格 docs/subject-feature-spec.md §9，
/// 实测结论见 docs/subject-skills-research.md）。
///
/// 纪律：
/// - 全部使用**隔离数据目录**（`SubjectStore.initTempForTests`），并在
///   S0/S99 断言正式 `data/loop.db` 的指纹完全不变；
/// - registry 用**本地假 hub**（真实 HTTP + 真实 zip），不访问公网；
/// - 用例编号 SK1..SK16。

// ===========================================================================
// 测试夹具：ZIP 构造器 + 本地假 hub
// ===========================================================================

void _u16(BytesBuilder b, int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);

void _u32(BytesBuilder b, int v) =>
    b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);

List<int> _crcTable() {
  final table = List<int>.filled(256, 0);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
    }
    table[i] = c;
  }
  return table;
}

final List<int> _crc = _crcTable();

int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc = _crc[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// 一个 zip 条目。
class _Entry {
  _Entry(this.name, this.data);

  final String name;
  final List<int> data;
}

List<int> _buildZip(List<_Entry> entries) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  var offset = 0;

  for (final entry in entries) {
    final nameBytes = utf8.encode(entry.name);
    final payload = ZLibEncoder(raw: true, level: 9).convert(entry.data);
    final declared = entry.data.length;
    final crc = _crc32(entry.data);
    const flags = 0x0800; // UTF-8 名字

    final local = BytesBuilder();
    _u32(local, 0x04034b50);
    _u16(local, 20);
    _u16(local, flags);
    _u16(local, 8);
    _u16(local, 0);
    _u16(local, 0);
    _u32(local, crc);
    _u32(local, payload.length);
    _u32(local, declared);
    _u16(local, nameBytes.length);
    _u16(local, 0);
    local.add(nameBytes);
    out.add(local.takeBytes());
    out.add(payload);

    _u32(central, 0x02014b50);
    _u16(central, 0x031E); // made by unix 3.0
    _u16(central, 20);
    _u16(central, flags);
    _u16(central, 8);
    _u16(central, 0);
    _u16(central, 0);
    _u32(central, crc);
    _u32(central, payload.length);
    _u32(central, declared);
    _u16(central, nameBytes.length);
    _u16(central, 0);
    _u16(central, 0);
    _u16(central, 0);
    _u16(central, 0);
    _u32(central, (0x81A4 & 0xFFFF) << 16);
    _u32(central, offset);
    central.add(nameBytes);

    offset += 30 + nameBytes.length + payload.length;
  }

  final centralBytes = central.takeBytes();
  final eocd = BytesBuilder();
  _u32(eocd, 0x06054b50);
  _u16(eocd, 0);
  _u16(eocd, 0);
  _u16(eocd, entries.length);
  _u16(eocd, entries.length);
  _u32(eocd, centralBytes.length);
  _u32(eocd, offset);
  _u16(eocd, 0);
  out.add(centralBytes);
  out.add(eocd.takeBytes());
  return out.takeBytes();
}

/// 假 hub 上的一个技能包。
class _FakePackage {
  _FakePackage({
    required this.slug,
    required this.files,
    this.name = '',
    this.verdict,
  });

  final String slug;
  final Map<String, List<int>> files;
  final String name;

  /// 当前版本；测试可直接改它来模拟"发布了新版本"。
  String version = '1.0.0';

  final String description = '演示技能：用于测试安装管线。';
  final String license = 'MIT-0';
  final List<String> keywords = const ['tutor'];

  /// 自定义 verify 响应；null 表示 `ok:true, decision:pass`。
  Map<String, dynamic>? verdict;

  List<int> get zipBytes =>
      _buildZip([for (final e in files.entries) _Entry(e.key, e.value)]);

  List<Map<String, dynamic>> get manifest => [
        for (final e in files.entries)
          {
            'path': e.key,
            'size': e.value.length,
            'sha256': sha256.convert(e.value).toString(),
            'contentType': e.key.endsWith('.md') ? 'text/markdown' : '',
          },
      ];

  String get skillMd => utf8.decode(files['SKILL.md'] ?? const []);

  Map<String, dynamic> listing() => {
        'slug': slug,
        'displayName': name.isEmpty ? slug : name,
        'summary': description,
        'version': version,
        'updatedAt': 0,
        'stats': {'downloads': 7, 'stars': 2},
        'ownerHandle': 'tester',
        'owner': {'handle': 'tester', 'htmlUrl': 'https://example.invalid/tester'},
      };

  Map<String, dynamic> detail({required bool filesRequested}) => {
        'skill': {
          'slug': slug,
          'displayName': name.isEmpty ? slug : name,
          'summary': description,
          'description': skillMd,
          // 陷阱复现：tags 是 dist-tags map，不是话题标签。
          'tags': {'latest': version},
          'keywords': keywords,
          'stats': {'downloads': 7, 'stars': 2, 'versions': 1},
          'createdAt': 0,
          'updatedAt': 0,
        },
        'latestVersion': {'version': version, 'changelog': 'x', 'license': license},
        'metadata': {'setup': [], 'os': null, 'systems': null},
        'owner': {'handle': 'tester', 'displayName': 'Tester', 'htmlUrl': 'https://example.invalid/tester'},
        'versions': [version],
        'distTags': {'latest': version},
        if (filesRequested) 'files': manifest,
      };

  Map<String, dynamic> verifyPayload() =>
      verdict ??
      {
        'schema': 'clawhub.skill.verify.v1',
        'ok': true,
        'decision': 'pass',
        'reasons': [],
        'slug': slug,
        'version': version,
        'security': {
          'status': 'clean',
          'passed': true,
          'confidence': 'low',
          'summary': 'Static scan found no high-signal malicious patterns. '
              'Not a full malware scan.',
          'model': 'eduhub-static-scan',
        },
        'signature': {'status': 'unsigned'},
      };
}

/// 本地假 registry：真实 HTTP + 真实 zip，但不碰公网。
class _FakeHub {
  _FakeHub._(this._server, this.baseUrl);

  final HttpServer _server;
  final String baseUrl;

  final List<_FakePackage> packages = [];

  /// 列表响应形状：`results`（EduHub search）/ `skills`（EduHub 目录）/ `items`（ClawHub）。
  String listShape = 'results';

  /// 非空时 `/search` 返回 302。
  String? redirectTo;

  /// 记录收到的请求路径，用于断言"没有静默拉取"。
  final List<String> requests = [];

  static Future<_FakeHub> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final hub = _FakeHub._(server, 'http://127.0.0.1:${server.port}/api/v1');
    server.listen(hub._handle, onError: (Object _) {});
    return hub;
  }

  _FakePackage add(_FakePackage package) {
    packages.add(package);
    return package;
  }

  _FakePackage bySlug(String slug, [String? version]) => packages.firstWhere(
        (item) => item.slug == slug && (version == null || item.version == version),
      );

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    final query = request.uri.queryParameters;
    requests.add(request.uri.toString());

    Future<void> json(Object data, [int status = 200]) async {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(data));
      await request.response.close();
    }

    if (segments.length < 2) return json({'detail': 'not found'}, 404);

    final last = segments.last;

    if (last == 'search' || (last == 'skills' && segments.length == 3)) {
      if (redirectTo != null) {
        request.response.statusCode = 302;
        request.response.headers.set('location', redirectTo!);
        await request.response.close();
        return;
      }
      return json({listShape: [for (final item in packages) item.listing()]});
    }

    if (last == 'verify') {
      final slug = segments[segments.length - 2];
      final pkg = bySlug(slug, query['version']);
      return json(pkg.verifyPayload());
    }

    if (last == 'download') {
      final pkg = bySlug(query['slug']!, query['version']);
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType('application', 'zip');
      request.response.add(pkg.zipBytes);
      await request.response.close();
      return;
    }

    if (segments.length >= 4 && segments[2] == 'skills') {
      final pkg = bySlug(segments[3], query['version']);
      return json(pkg.detail(filesRequested: query['files'] == 'true'));
    }

    return json({'detail': 'not found'}, 404);
  }
}

// ===========================================================================
// 工具
// ===========================================================================

String _skillMd({
  String name = 'loop-subject-tutor',
  String description = 'Tutor inside one Loop subject. Use when the learner asks to be taught.',
  String extra = '',
}) =>
    '---\n'
    'name: $name\n'
    'description: $description\n'
    'track: academics\n'
    'language: zh\n'
    'version: 1.0.0\n'
    '$extra'
    '---\n'
    '\n'
    '# Loop 学科助教\n'
    '\n'
    '## 工作循环\n'
    '1. 先检索学科资料库。\n'
    '2. 命中则引用原文出处。\n';

Map<String, List<int>> _packageFiles({
  String name = 'loop-subject-tutor',
  String description = 'Tutor inside one Loop subject. Use when the learner asks to be taught.',
  String extra = '',
  String referenceText = '# 检索策略\n\n1. 先学科内，后通用。\n',
  String? skillMdOverride,
}) =>
    {
      'SKILL.md': utf8.encode(skillMdOverride ?? _skillMd(name: name, description: description, extra: extra)),
      'references/retrieval-policy.md': utf8.encode(referenceText),
    };

Directory _tempDir() => Directory.systemTemp.createTempSync('loop-skill-test-');

void _deleteQuietly(Directory dir) {
  try {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  } catch (_) {}
}

File? _realLoopDb() {
  for (final candidate in [Directory.current, Directory.current.parent]) {
    final file = File(p.join(candidate.path, 'data', 'loop.db'));
    if (file.existsSync()) return file;
  }
  return null;
}

String? _fingerprint(File? file) {
  if (file == null) return null;
  final stat = file.statSync();
  return '${stat.modified.millisecondsSinceEpoch}|${stat.size}|'
      '${sha256.convert(file.readAsBytesSync())}';
}

void main() {
  late Directory dataDir;
  late _FakeHub hub;
  String? realDbBefore;

  setUpAll(() {
    realDbBefore = _fingerprint(_realLoopDb());
  });

  tearDownAll(() {
    expect(_fingerprint(_realLoopDb()), realDbBefore,
        reason: 'S99：技能测试不得触碰正式 data/loop.db');
  });

  setUp(() async {
    dataDir = _tempDir();
    SubjectStore.initTempForTests(dataDir);
    hub = await _FakeHub.start();
  });

  tearDown(() async {
    await hub.close();
    SubjectStore.closeAll();
    SubjectStore.resetForTests();
    _deleteQuietly(dataDir);
  });

  SkillRegistry registryFor(_FakeHub fake) =>
      SkillRegistry.forBaseUrlForTests(fake.baseUrl);

  SkillImporter importerFor(SkillRegistry registry, {String? key}) => SkillImporter(
        subjectKey: key ?? AppPaths.defaultSubjectKey,
        registry: registry,
      );

  // -------------------------------------------------------------- SK0/SK1

  test('SK0 隔离：数据目录指向临时目录，正式库指纹不变', () {
    expect(AppPaths.data.path, dataDir.path);
    expect(File(p.join(dataDir.path, 'loop.db')).existsSync(), isTrue);
    expect(_fingerprint(_realLoopDb()), realDbBefore);
  });

  test('SK1 初始状态：没有已装技能，策略声明不自动安装/不自动更新', () async {
    final importer = importerFor(registryFor(hub));
    final installed = importer.list();
    expect(installed, isEmpty);
    expect(File(p.join(importer.root.path, '.hub-lock.json')).existsSync(), isFalse);
  });

  // -------------------------------------------------------------- 浏览

  test('SK2 搜索归一化 EduHub results 形状，并带 web_url', () async {
    hub.add(_FakePackage(slug: 'socratic-tutor', files: _packageFiles()));
    final registry = registryFor(hub);
    final results = await registry.search('socratic');
    expect(results, hasLength(1));
    expect(results.first.slug, 'socratic-tutor');
    expect(results.first.version, '1.0.0');
    expect(results.first.owner, 'tester');
    expect(results.first.webUrl, contains('/skills/socratic-tutor'));
  });

  test('SK3 兼容三种列表形状：results / skills / items', () async {
    hub.add(_FakePackage(slug: 'a-skill', files: _packageFiles()));
    final registry = registryFor(hub);
    for (final shape in ['results', 'skills', 'items']) {
      hub.listShape = shape;
      final results = await registry.search('x');
      expect(results.map((e) => e.slug), contains('a-skill'), reason: 'shape=$shape');
    }
    // 空 query 走目录端点
    final catalog = await registry.catalog();
    expect(catalog, hasLength(1));
  });

  test('SK4 详情：话题标签取 keywords（不是 dist-tags map），并解析 sha256 清单', () async {
    final pkg = hub.add(_FakePackage(slug: 'socratic-tutor', files: _packageFiles()));
    final registry = registryFor(hub);
    final detail = await registry.detail('socratic-tutor');
    expect(detail.tags, ['tutor']);
    expect(detail.distTags['latest'], '1.0.0');
    expect(detail.license, 'MIT-0');
    expect(detail.hasManifest, isTrue);
    expect(detail.files.map((f) => f.path), contains('SKILL.md'));
    final skillFile = detail.files.firstWhere((f) => f.path == 'SKILL.md');
    expect(skillFile.sha256,
        sha256.convert(pkg.files['SKILL.md']!).toString());
  });

  // -------------------------------------------------------------- 安装

  test('SK5 显式安装成功：落盘 + .hub-lock.json 记账 + subject_skills 镜像', () async {
    hub.add(_FakePackage(slug: 'socratic-tutor', name: 'Socratic Tutor', files: _packageFiles()));
    final importer = importerFor(registryFor(hub));
    final installed = await importer.install('socratic-tutor');

    expect(installed.slug, 'socratic-tutor');
    expect(installed.version, '1.0.0');
    expect(installed.enabled, isTrue);
    expect(installed.unverified, isFalse);
    expect(installed.hasScripts, isFalse);
    expect(installed.license, 'MIT-0');

    // 文件真的落盘了，且 SKILL.md 可读
    final skillMd = File(p.join(installed.pkgDir, 'SKILL.md'));
    final reference = File(p.join(installed.pkgDir, 'references', 'retrieval-policy.md'));
    expect(skillMd.existsSync(), isTrue);
    expect(reference.existsSync(), isTrue);
    expect(skillMd.readAsStringSync(), contains('Loop 学科助教'));

    // 记账文件（权威来源；F-13 起按规格 §9.6.1 的数组形状落盘）
    final lock = File(p.join(importer.root.path, '.hub-lock.json'));
    expect(lock.existsSync(), isTrue);
    final lockJson = jsonDecode(lock.readAsStringSync()) as Map<String, dynamic>;
    expect(lockJson['schema'], 1);
    expect(lockJson['subject'], AppPaths.defaultSubjectKey);
    final skills = (lockJson['skills'] as List).cast<Map>();
    final entry = skills.firstWhere((item) => item['slug'] == 'socratic-tutor');
    expect(entry['version'], '1.0.0');
    expect(entry['artifactSha256'], isNotEmpty);
    expect(entry['enabled'], isTrue);
    expect(entry['pinned'], isFalse);
    expect(entry['previousVersion'], isNull);
    expect((entry['files'] as List), isNotEmpty);

    // DB 镜像（给 SQL/UI 用）
    final rows = SubjectStore.open(AppPaths.defaultSubjectKey)
        .database
        .select('SELECT slug, version, enabled, files_rel_path FROM subject_skills');
    expect(rows, hasLength(1));
    expect(rows.first['slug'], 'socratic-tutor');
    expect(rows.first['enabled'], 1);

    // 已装列表可读
    expect(importer.list().single.slug, 'socratic-tutor');
  });

  test('SK6 升级：旧版本进 previous，可一键回退（离线可用）', () async {
    final pkg = hub.add(_FakePackage(slug: 'socratic-tutor', files: _packageFiles()));
    final importer = importerFor(registryFor(hub));
    await importer.install('socratic-tutor');
    final v1Bytes = File(p.join(importer.pkgDir('socratic-tutor').path, 'SKILL.md'))
        .readAsBytesSync();

    // 发布 v1.1.0 并升级
    pkg.version = '1.1.0';
    pkg.files
      ..clear()
      ..addAll(_packageFiles(referenceText: '# 检索策略 v2\n\n1. 先学科内。\n'));
    final upgraded = await importer.install('socratic-tutor');
    expect(upgraded.version, '1.1.0');
    expect(upgraded.hasPrevious, isTrue);
    expect(upgraded.previousVersion, '1.0.0');

    // 关掉 hub 证明回退是纯本地的
    await hub.close();

    final rolled = importer.rollback('socratic-tutor');
    expect(rolled.version, '1.0.0');
    expect(rolled.hasPrevious, isTrue);
    expect(rolled.previousVersion, '1.1.0');
    expect(
      File(p.join(importer.pkgDir('socratic-tutor').path, 'SKILL.md')).readAsBytesSync(),
      v1Bytes,
      reason: '回退后必须是 v1 的原始字节',
    );
  });

  test('SK6b 回退无上一版时明确报 409，不做破坏性操作', () async {
    hub.add(_FakePackage(slug: 'socratic-tutor', files: _packageFiles()));
    final importer = importerFor(registryFor(hub));
    await importer.install('socratic-tutor');
    expect(
      () => importer.rollback('socratic-tutor'),
      throwsA(isA<SkillImportError>()
          .having((e) => e.code, 'code', 'no_previous')
          .having((e) => e.status, 'status', 409)),
    );
  });

  // -------------------------------------------------------------- 学科级启用

  test('SK7 启用/停用只影响本学科；另一学科互不可见', () async {
    hub.add(_FakePackage(slug: 'socratic-tutor', files: _packageFiles()));
    final registry = registryFor(hub);

    final other = SubjectStore.create(name: '另一个学科');
    final alpha = importerFor(registry, key: AppPaths.defaultSubjectKey);
    final beta = importerFor(registry, key: other.key);

    await alpha.install('socratic-tutor');
    expect(alpha.list(), hasLength(1));
    expect(beta.list(), isEmpty, reason: 'A 学科装的技能不得出现在 B 学科');

    // 停用只影响本学科
    final disabled = alpha.setEnabled('socratic-tutor', false);
    expect(disabled.enabled, isFalse);
    expect(alpha.list(includeDisabled: false), isEmpty);
    expect(alpha.list(includeDisabled: true), hasLength(1));

    // 不同学科各自启用
    await beta.install('socratic-tutor');
    expect(beta.list().single.enabled, isTrue);
    expect(alpha.list().single.enabled, isFalse);

    // 每个学科各自落盘
    expect(alpha.pkgDir('socratic-tutor').path,
        isNot(beta.pkgDir('socratic-tutor').path));
  });

  test('SK8 停用后不进入 playbook 列表；启用后恢复（纯文本，绝不执行）', () async {
    hub.add(_FakePackage(slug: 'socratic-tutor', files: _packageFiles()));
    final importer = importerFor(registryFor(hub));
    await importer.install('socratic-tutor');

    expect(importer.enabledPlaybooks(), hasLength(1));
    expect(importer.enabledPlaybooks().single['content'], contains('Loop 学科助教'));

    importer.setEnabled('socratic-tutor', false);
    expect(importer.enabledPlaybooks(), isEmpty);

    importer.setEnabled('socratic-tutor', true);
    expect(importer.enabledPlaybooks(), hasLength(1));
  });

  test('SK9 卸载：删除包目录与记账，且不影响其它 slug', () async {
    hub.add(_FakePackage(slug: 'socratic-tutor', files: _packageFiles()));
    hub.add(_FakePackage(slug: 'unblock-reading', files: _packageFiles(name: 'unblock-reading')));
    final importer = importerFor(registryFor(hub));
    await importer.install('socratic-tutor');
    await importer.install('unblock-reading');

    final result = importer.remove('socratic-tutor');
    expect(result['ok'], isTrue);
    expect(importer.list().map((e) => e.slug), ['unblock-reading']);
    expect(Directory(p.join(importer.root.path, 'socratic-tutor')).existsSync(), isFalse);
    final rows = SubjectStore.open(AppPaths.defaultSubjectKey)
        .database
        .select('SELECT slug FROM subject_skills');
    expect(rows.map((r) => r['slug']), ['unblock-reading']);
  });

  test('SK10 卸载不存在的技能不抛错（幂等）', () async {
    final importer = importerFor(registryFor(hub));
    final result = importer.remove('never-installed');
    expect(result['removed'], isFalse);
    expect(importer.list(), isEmpty);
  });

  // -------------------------------------------------------------- 离线降级

  test('SK11 离线：已装技能全部可用；搜索/校验优雅降级为 offline', () async {
    hub.add(_FakePackage(slug: 'socratic-tutor', files: _packageFiles()));
    final importer = importerFor(registryFor(hub));
    await importer.install('socratic-tutor');

    // 指向一个必然拒绝连接的端口 = 离线
    final offlineRegistry = SkillRegistry.forBaseUrlForTests('http://127.0.0.1:1/api/v1');
    final offlineImporter = SkillImporter(
      subjectKey: AppPaths.defaultSubjectKey,
      registry: offlineRegistry,
      rootForTests: importer.root,
    );

    // 已装列表纯本地 → 仍然可用
    expect(offlineImporter.list().single.slug, 'socratic-tutor');
    expect(offlineImporter.enabledPlaybooks(), hasLength(1));

    // 搜索 → offline 错误（可被 UI 展示为"当前离线"）
    await expectLater(
      offlineRegistry.search('anything'),
      throwsA(isA<SkillRegistryError>()
          .having((e) => e.code, 'code', 'offline')
          .having((e) => e.offline, 'offline', isTrue)),
    );

    // verify 不抛错，降级为 unknown
    final verdict = await offlineRegistry.verify('socratic-tutor');
    expect(verdict.status, SkillVerdict.unknown);
    expect(verdict.isUnverified, isTrue);
  });

  test('SK11b 离线时下载不可达 → 安装明确失败，且不留下半个包', () async {
    hub.add(_FakePackage(slug: 'socratic-tutor', files: _packageFiles()));
    final offlineRegistry = SkillRegistry.forBaseUrlForTests('http://127.0.0.1:1/api/v1');
    final importer = SkillImporter(
      subjectKey: AppPaths.defaultSubjectKey,
      registry: offlineRegistry,
      rootForTests: AppPaths.subjectSkillsDir(AppPaths.defaultSubjectKey),
    );
    // 下载不可达 → 明确失败，且不留下半个包
    await expectLater(
      importer.install('socratic-tutor'),
      throwsA(isA<SkillRegistryError>()),
    );
    expect(importer.list(), isEmpty);
  });

  // -------------------------------------------------------------- verify 三态

  test('SK12 verify 三态：ok=true→ok；ok=false→suspicious；请求失败→unknown', () async {
    final okPkg = hub.add(_FakePackage(slug: 'clean-skill', files: _packageFiles()));
    final flagged = hub.add(_FakePackage(
      slug: 'flagged-skill',
      files: _packageFiles(name: 'flagged-skill'),
      verdict: {
        'ok': false,
        'decision': 'review',
        'security': {'status': 'review', 'confidence': 'low', 'summary': '命中高危模式'},
        'signature': {'status': 'unsigned'},
      },
    ));
    final registry = registryFor(hub);

    final ok = await registry.verify(okPkg.slug);
    expect(ok.status, SkillVerdict.ok);
    expect(ok.canInstallDirectly, isTrue);
    expect(ok.requiresExplicitApproval, isFalse);
    // 措辞：不得声称是安全扫描
    expect(ok.summary, contains('Not a full malware scan'));
    expect(ok.signature, 'unsigned');

    final bad = await registry.verify(flagged.slug);
    expect(bad.status, SkillVerdict.suspicious);
    expect(bad.requiresExplicitApproval, isTrue);
    expect(bad.canInstallDirectly, isFalse);

    final offline = await SkillRegistry.forBaseUrlForTests('http://127.0.0.1:1/api/v1')
        .verify('whatever');
    expect(offline.status, SkillVerdict.unknown);
    expect(offline.isUnverified, isTrue);
  });

  test('SK13 未认可的包默认拒绝安装；显式"仍然安装"才写入，且记账保留 suspicious', () async {
    hub.add(_FakePackage(
      slug: 'flagged-skill',
      files: _packageFiles(name: 'flagged-skill'),
      verdict: {
        'ok': false,
        'decision': 'review',
        'security': {'summary': '命中高危模式'},
        'signature': {'status': 'unsigned'},
      },
    ));
    final importer = importerFor(registryFor(hub));

    // F-8：suspicious 不再抛 4xx 错误，而是抛"需要显式确认"（server 层 → 200 +
    // needs_confirm + stage='verify'，符合 AC-04 断言 2）。
    await expectLater(
      importer.install('flagged-skill'),
      throwsA(isA<SkillNeedsConfirm>()
          .having((e) => e.verdict.decision, 'decision', 'review')),
    );
    expect(importer.list(), isEmpty, reason: '拒绝时不得留下任何文件');

    final installed = await importer.install('flagged-skill', allowSuspicious: true);
    expect(installed.suspicious, isTrue);
    expect(installed.enabled, isTrue);
  });

  test('SK14 语言只暴露 zh / en（不接受实测被 CLI 拒绝的 ja/other）', () async {
    expect(SkillRegistry.languages, ['zh', 'en']);
    expect(SkillRegistry.isSupportedLanguage('zh'), isTrue);
    expect(SkillRegistry.isSupportedLanguage('en'), isTrue);
    expect(SkillRegistry.isSupportedLanguage('ja'), isFalse);
    expect(SkillRegistry.isSupportedLanguage('other'), isFalse);
    expect(SkillRegistry.isSupportedLanguage(''), isFalse);
  });

  // -------------------------------------------------------------- 不自动安装

  test('SK15 安装是显式动作：浏览/校验不会写盘，也不会拉包', () async {
    hub.add(_FakePackage(slug: 'socratic-tutor', files: _packageFiles()));
    final registry = registryFor(hub);
    final importer = importerFor(registry);

    await registry.search('x');
    await registry.detail('socratic-tutor');
    await registry.verify('socratic-tutor');

    expect(hub.requests.any((u) => u.contains('/download')), isFalse,
        reason: '浏览/校验阶段绝不应该下载包');
    expect(importer.list(), isEmpty);
    expect(Directory(p.join(importer.root.path, 'socratic-tutor')).existsSync(), isFalse);
  });

  // -------------------------------------------------------------- HTTP 层

  group('HTTP /api/skills（不触网的路径）', () {
    late int port;

    setUp(() async {
      port = await Backend.startForTests(dataDir);
    });

    tearDown(() async {
      await Backend.stopForTests();
    });

    Future<(int, Map<String, dynamic>)> call(
      String method,
      String path, {
      Object? body,
    }) async {
      final client = HttpClient();
      final request = await client.openUrl(
          method, Uri.parse('http://127.0.0.1:$port$path'));
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final text = await utf8.decoder.bind(response).join();
      client.close(force: true);
      return (
        response.statusCode,
        text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>,
      );
    }

    test('SK16 GET /api/skills 返回「已安装」视图、白名单与策略声明', () async {
      final (status, data) = await call('GET', '/api/skills');
      expect(status, 200);
      expect(data['ok'], isTrue);
      expect(data['installed'], isEmpty);
      expect(data['hub'], 'eduhub');
      expect(data['policy']['hub_allowlist'], ['eduhub']);
      expect(data['policy']['auto_update'], isFalse);
      expect(data['policy']['auto_install'], isFalse);
      // 关键：不得把 verify 描述成安全保证
      expect(data['policy']['verify_is_security_guarantee'], isFalse);
      expect(data['policy']['verify_note'], contains('不代表'));
      expect(data['policy']['languages'], ['zh', 'en']);
      expect(data['policy']['limits']['max_file_bytes'], 1000000);
      expect(data['subject_key'], isNotEmpty);
    });

    test('SK17 hub 白名单：伪造 hub 参数被 400 拒绝（防 SSRF）', () async {
      for (final path in [
        '/api/skills/catalog?hub=evil.example',
        '/api/skills/catalog?hub=http://169.254.169.254/',
        '/api/skills/detail?hub=clawhub&slug=whatever',
      ]) {
        final (status, data) = await call('GET', path);
        expect(status, 400, reason: path);
        expect(data['ok'], isFalse);
        expect(data['code'], 'blocked');
      }
    });

    test('SK18 语言过滤：ja/other 被 400 拒绝', () async {
      for (final language in ['ja', 'other', 'fr']) {
        final (status, data) =
            await call('GET', '/api/skills/catalog?language=$language');
        expect(status, 400, reason: language);
        expect(data['code'], 'unsupported_language');
      }
    });

    test('SK19 非法 slug / 缺 slug 被 400 拒绝', () async {
      final (s1, d1) = await call('GET', '/api/skills/detail?slug=../etc/passwd');
      expect(s1, 400);
      expect(d1['code'], 'invalid_slug');

      final (s2, d2) = await call('GET', '/api/skills/detail');
      expect(s2, 400);
      expect(d2['code'], 'invalid_slug');

      final (s3, d3) = await call('POST', '/api/skills/install', body: {'slug': 'UPPER CASE'});
      expect(s3, 400);
      expect(d3['code'], 'invalid_slug');
    });

    test('SK20 enable/disable/rollback/delete 走本学科作用域并写入 subject_key', () async {
      final (s1, d1) = await call('POST', '/api/skills/ghost/enable');
      expect(s1, 404);
      expect(d1['code'], 'not_installed');

      final (s2, d2) = await call('POST', '/api/skills/ghost/rollback');
      expect(s2, 404);

      // F-5：DELETE 必须带 confirm（缺参 → 400；带 confirm → 删除语义不变）。
      final (s3Missing, d3Missing) = await call('DELETE', '/api/skills/ghost');
      expect(s3Missing, 400);
      expect(d3Missing['code'], 'confirm_required');

      final (s3, d3) = await call('DELETE', '/api/skills/ghost?confirm=ghost');
      expect(s3, 200);
      expect(d3['removed'], isFalse);
      expect(d3['subject_key'], isNotEmpty);

      final (s4, _) = await call('POST', '/api/skills/ghost/bogus');
      expect(s4, 404);
    });

    test('SK21 已归档学科的写操作被 409 拒绝（读仍可用）', () async {
      final record = SubjectStore.create(name: '待归档学科');
      SubjectStore.archive(record.id);

      final (s1, d1) = await call(
          'POST', '/api/skills/install?subject=${record.key}', body: {'slug': 'x-skill'});
      expect(s1, 409);
      expect(d1['detail'], contains('归档'));

      final (s2, d2) = await call('GET', '/api/skills?subject=${record.key}');
      expect(s2, 200);
      expect(d2['subject_key'], record.key);
    });

    test('SK22 请求未知学科不回退到他科（404）', () async {
      final (status, data) = await call('GET', '/api/skills?subject=nope_missing');
      expect(status, 404);
      expect(data['detail'], contains('学科不存在'));
    });
  });
}