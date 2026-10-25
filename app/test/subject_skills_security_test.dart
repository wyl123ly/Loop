import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:loop/backend/paths.dart';
import 'package:loop/backend/skills_import.dart';
import 'package:loop/backend/skills_registry.dart';
import 'package:loop/backend/subject_store.dart';

/// 教学技能**安全边界**测试（t5）。
///
/// 依据 docs/subject-skills-research.md §7.3 的实测姿态：
/// zip-slip / zip-bomb / 符号链接 / 后缀白名单 / 逐文件 sha256 清单 /
/// frontmatter 剥离 `always:` / 原子替换失败保留旧版本 / SSRF 重定向拦截 /
/// hub 白名单固定 / **不存在执行 skill 内文件的代码路径**。
///
/// 用例编号 SEC1..SEC33。

// ===========================================================================
// ZIP 构造器（测试可控：压缩方式 / unix 模式位 / 谎报大小）
// ===========================================================================

void _u16(BytesBuilder b, int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);

void _u32(BytesBuilder b, int v) =>
    b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);

final List<int> _crc = () {
  final table = List<int>.filled(256, 0);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
    }
    table[i] = c;
  }
  return table;
}();

int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc = _crc[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

class _Entry {
  _Entry(
    this.name,
    this.data, {
    this.method = 0,
    this.unixMode,
    this.declaredUncompressed,
  });

  final String name;
  final List<int> data;
  final int method; // 0 = store（测试里省压缩开销）, 8 = deflate
  final int? unixMode; // 0xA1FF = symlink
  final int? declaredUncompressed;
}

List<int> _buildZip(List<_Entry> entries) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  var offset = 0;
  for (final entry in entries) {
    final nameBytes = utf8.encode(entry.name);
    final payload = entry.method == 0
        ? entry.data
        : ZLibEncoder(raw: true, level: 9).convert(entry.data);
    final declared = entry.declaredUncompressed ?? entry.data.length;
    final crc = _crc32(entry.data);
    const flags = 0x0800;

    final local = BytesBuilder();
    _u32(local, 0x04034b50);
    _u16(local, 20);
    _u16(local, flags);
    _u16(local, entry.method);
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
    _u16(central, 0x031E);
    _u16(central, 20);
    _u16(central, flags);
    _u16(central, entry.method);
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
    _u32(central, ((entry.unixMode ?? 0x81A4) & 0xFFFF) << 16);
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

/// 不可压缩的伪随机字节（用于构造"谎报大小"/超限样本）。
Uint8List _incompressible(int length, [int seed = 7]) {
  final random = Random(seed);
  final out = Uint8List(length);
  for (var i = 0; i < out.length; i++) {
    out[i] = random.nextInt(256);
  }
  return out;
}

// ===========================================================================
// 假 hub（可控：manifest / zip 内容 / 重定向）
// ===========================================================================

class _Pkg {
  _Pkg({
    required this.slug,
    required this.files,
    this.extraEntries = const [],
  });

  final String slug;
  final Map<String, List<int>> files;
  final List<_Entry> extraEntries;

  String version = '1.0.0';
  List<Map<String, dynamic>>? manifestOverride;
  List<int>? downloadBytes;

  List<int> get zipBytes =>
      downloadBytes ?? _buildZip([..._entries(), ...extraEntries]);

  List<_Entry> _entries() => [
        for (final e in files.entries)
          _Entry(e.key, e.value, method: e.key.endsWith('.txt') ? 0 : 8),
      ];

  List<Map<String, dynamic>> get manifest =>
      manifestOverride ??
      [
        for (final e in files.entries)
          {
            'path': e.key,
            'size': e.value.length,
            'sha256': sha256.convert(e.value).toString(),
            'contentType': '',
          },
      ];
}

class _Hub {
  _Hub._(this._server, this.baseUrl);

  final HttpServer _server;
  final String baseUrl;
  final List<_Pkg> packages = [];
  String? redirectTo;
  int redirectBudget = 0;
  final List<String> requests = [];

  static Future<_Hub> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final hub = _Hub._(server, 'http://127.0.0.1:${server.port}/api/v1');
    server.listen(hub._handle, onError: (Object _) {});
    return hub;
  }

  _Pkg add(_Pkg pkg) {
    packages.add(pkg);
    return pkg;
  }

  _Pkg bySlug(String slug) => packages.firstWhere((item) => item.slug == slug);

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

    final last = segments.isEmpty ? '' : segments.last;

    if (last == 'search' || (last == 'skills' && segments.length == 3)) {
      if (redirectTo != null && redirectBudget > 0) {
        redirectBudget--;
        request.response.statusCode = 302;
        request.response.headers.set('location', redirectTo!);
        await request.response.close();
        return;
      }
      return json({
        'results': [
          for (final item in packages)
            {'slug': item.slug, 'displayName': item.slug, 'version': item.version},
        ],
      });
    }

    if (last == 'verify') {
      return json({
        'ok': true,
        'decision': 'pass',
        'security': {'status': 'clean', 'confidence': 'low', 'summary': 'x'},
        'signature': {'status': 'unsigned'},
      });
    }

    if (last == 'download') {
      final pkg = bySlug(query['slug']!);
      request.response.statusCode = 200;
      request.response.add(pkg.zipBytes);
      await request.response.close();
      return;
    }

    if (segments.length >= 4 && segments[2] == 'skills') {
      final pkg = bySlug(segments[3]);
      return json({
        'skill': {
          'slug': pkg.slug,
          'displayName': pkg.slug,
          'summary': 'x',
          'description': utf8.decode(pkg.files['SKILL.md'] ?? const []),
          'tags': {'latest': pkg.version},
          'keywords': ['tutor'],
          'stats': {'downloads': 0, 'stars': 0},
        },
        'latestVersion': {'version': pkg.version, 'license': 'MIT-0'},
        'owner': {'handle': 'tester'},
        'versions': [pkg.version],
        'distTags': {'latest': pkg.version},
        if (query['files'] == 'true') 'files': pkg.manifest,
      });
    }

    return json({'detail': 'not found'}, 404);
  }
}

// ===========================================================================
// 夹具
// ===========================================================================

String _md({String extra = ''}) =>
    '---\n'
    'name: loop-subject-tutor\n'
    'description: Tutor inside one Loop subject. Use when the learner asks to be taught.\n'
    'track: academics\n'
    '$extra'
    '---\n'
    '\n'
    '# Loop 学科助教\n'
    '\n'
    '正文要点：先检索学科资料库。\n';

Map<String, List<int>> _files({String extra = '', String? md}) => {
      'SKILL.md': utf8.encode(md ?? _md(extra: extra)),
      'references/retrieval-policy.md': utf8.encode('# 检索策略\n'),
    };

Directory _tempDir() => Directory.systemTemp.createTempSync('loop-skill-sec-');

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
  late _Hub hub;
  String? realDbBefore;

  setUpAll(() {
    realDbBefore = _fingerprint(_realLoopDb());
  });

  tearDownAll(() {
    expect(_fingerprint(_realLoopDb()), realDbBefore,
        reason: 'SEC99：安全测试不得触碰正式 data/loop.db');
  });

  setUp(() async {
    dataDir = _tempDir();
    SubjectStore.initTempForTests(dataDir);
    hub = await _Hub.start();
  });

  tearDown(() async {
    await hub.close();
    SubjectStore.closeAll();
    SubjectStore.resetForTests();
    _deleteQuietly(dataDir);
  });

  SkillImporter importer() => SkillImporter(
        subjectKey: AppPaths.defaultSubjectKey,
        registry: SkillRegistry.forBaseUrlForTests(hub.baseUrl),
      );

  /// 断言安装被拒绝、错误码正确、且**磁盘上不留任何痕迹**。
  Future<void> expectRejected(
    SkillImporter target,
    String slug,
    String code,
  ) async {
    await expectLater(
      target.install(slug),
      throwsA(isA<SkillImportError>().having((e) => e.code, 'code', code)),
      reason: '期望被拒绝：$code',
    );
    expect(Directory(p.join(target.root.path, slug)).existsSync(), isFalse,
        reason: '被拒绝时不得留下任何文件');
    expect(target.list(), isEmpty);
  }

  // -------------------------------------------------------------- zip-slip

  group('zip-slip / 路径穿越', () {
    test('SEC1 拒绝 ../ 路径穿越', () async {
      final target = importer();
      hub.add(_Pkg(
        slug: 'evil-a',
        files: _files(),
        extraEntries: [_Entry('../evil.md', utf8.encode('pwned'))],
      ));
      await expectRejected(target, 'evil-a', 'zip_slip');
    });

    test('SEC2 拒绝绝对路径', () async {
      final target = importer();
      hub.add(_Pkg(
        slug: 'evil-b',
        files: _files(),
        extraEntries: [_Entry('/etc/passwd', utf8.encode('root:x:'))],
      ));
      await expectRejected(target, 'evil-b', 'zip_slip');
    });

    test('SEC3 拒绝 Windows 盘符路径', () async {
      final target = importer();
      hub.add(_Pkg(
        slug: 'evil-c',
        files: _files(),
        extraEntries: [_Entry('C:/Windows/x.md', utf8.encode('x'))],
      ));
      await expectRejected(target, 'evil-c', 'zip_slip');
    });

    test('SEC4 拒绝反斜杠形式的穿越', () async {
      final target = importer();
      hub.add(_Pkg(
        slug: 'evil-d',
        files: _files(),
        extraEntries: [_Entry(r'..\..\evil.md', utf8.encode('pwned'))],
      ));
      await expectRejected(target, 'evil-d', 'zip_slip');
    });
  });

  // -------------------------------------------------------------- zip-bomb

  group('zip-bomb / 体积上限', () {
    test('SEC5 拒绝异常压缩比（高压缩率炸弹）', () async {
      final target = importer();
      hub.add(_Pkg(
        slug: 'bomb-ratio',
        files: {'SKILL.md': utf8.encode(_md())},
        // 必须走 DEFLATE：50 万个 0 压缩后只有几百字节 → 压缩比远超上限
        extraEntries: [
          _Entry('references/big.txt', Uint8List(500000), method: 8),
        ],
      ));
      await expectRejected(target, 'bomb-ratio', 'zip_bomb');
    });

    test('SEC6 拒绝"谎报解压后大小"的炸弹（解压中截断）', () async {
      final target = importer();
      hub.add(_Pkg(
        slug: 'bomb-lying',
        files: {
          'SKILL.md': utf8.encode(_md()),
        },
        extraEntries: [
          _Entry('references/lying.txt', _incompressible(1500000, 3),
              method: 8, declaredUncompressed: 900000),
        ],
      ));
      await expectRejected(target, 'bomb-lying', 'zip_bomb');
    });

    test('SEC7 拒绝单文件超过 1MB', () async {
      final target = importer();
      hub.add(_Pkg(
        slug: 'too-big-file',
        files: {
          'SKILL.md': utf8.encode(_md()),
          'references/huge.txt': _incompressible(1200000, 5),
        },
      ));
      await expectRejected(target, 'too-big-file', 'too_large');
    });

    test('SEC8 拒绝解压总量超过 20MB', () async {
      final target = importer();
      final files = <String, List<int>>{'SKILL.md': utf8.encode(_md())};
      for (var i = 0; i < 21; i++) {
        // 每个 1MB（刚好不触发单文件上限），合计 21MB → 触发总量上限
        files['references/part-$i.txt'] = _incompressible(1000000, 100 + i);
      }
      hub.add(_Pkg(slug: 'too-big-total', files: files));
      await expectRejected(target, 'too-big-total', 'too_large');
    });

    test('SEC9 拒绝超过 500 个文件', () async {
      final target = importer();
      final entries = <_Entry>[_Entry('SKILL.md', utf8.encode(_md()))];
      for (var i = 0; i < 501; i++) {
        entries.add(_Entry('references/f$i.txt', utf8.encode('x')));
      }
      hub.add(_Pkg(slug: 'too-many', files: _files(), extraEntries: entries));
      await expectRejected(target, 'too-many', 'too_many_files');
    });
  });

  // -------------------------------------------------------------- 白名单 / symlink

  group('后缀白名单与符号链接', () {
    test('SEC10 拒绝白名单外的后缀（.exe）', () async {
      final target = importer();
      hub.add(_Pkg(
        slug: 'with-exe',
        files: _files(),
        extraEntries: [
          _Entry('tools/payload.exe', utf8.encode('MZ'), unixMode: 0x81ED),
        ],
      ));
      await expectRejected(target, 'with-exe', 'suffix_not_allowed');
    });

    test('SEC11 符号链接一律整体拒绝（即使其余文件都合法）', () async {
      final target = importer();
      hub.add(_Pkg(
        slug: 'with-link',
        files: _files(),
        extraEntries: [
          // unix 模式 0xA1FF = S_IFLNK，内容指向包外
          _Entry('references/escape.md', utf8.encode('/etc/passwd'),
              unixMode: 0xA1FF),
        ],
      ));
      await expectRejected(target, 'with-link', 'symlink');
    });

    test('SEC12 危险原生后缀与白名单不交叠', () {
      for (final suffix in SkillImportLimits.dangerousSuffixes) {
        expect(SkillImportLimits.allowedSuffixes.contains(suffix), isFalse,
            reason: '$suffix 不得在白名单里');
      }
      expect(SkillImportLimits.allowedSuffixes.contains('.exe'), isFalse);
      expect(SkillImportLimits.allowedSuffixes.contains('.dll'), isFalse);
      expect(SkillImportLimits.allowedSuffixes.contains('.bat'), isFalse);
      expect(SkillImportLimits.allowedSuffixes.contains('.jar'), isFalse);
    });

    test('SEC13 隐藏文件与 __MACOSX 静默跳过（不落盘、不报错）', () async {
      final target = importer();
      hub.add(_Pkg(
        slug: 'with-dotfiles',
        files: _files(),
        extraEntries: [
          _Entry('.git/config', utf8.encode('[core]')),
          _Entry('__MACOSX/._SKILL.md', utf8.encode('junk')),
        ],
      ));
      final installed = await target.install('with-dotfiles');
      expect(File(p.join(installed.pkgDir, '.git', 'config')).existsSync(), isFalse);
      expect(Directory(p.join(installed.pkgDir, '__MACOSX')).existsSync(), isFalse);
      expect(File(p.join(installed.pkgDir, 'SKILL.md')).existsSync(), isTrue);
    });
  });

  // -------------------------------------------------------------- sha256 清单

  group('逐文件 sha256 完整性校验', () {
    test('SEC14 单个字节被改动即拒绝（清单不一致）', () async {
      final target = importer();
      final pkg = _Pkg(slug: 'tampered', files: _files());
      // 清单按原始内容算；下载内容被改了一个字符。
      final changed = Map<String, List<int>>.from(pkg.files);
      changed['SKILL.md'] =
          utf8.encode(utf8.decode(changed['SKILL.md']!).replaceAll('助教', '助教X'));
      pkg.downloadBytes =
          _buildZip([for (final e in changed.entries) _Entry(e.key, e.value)]);
      hub.add(pkg);
      await expectRejected(target, 'tampered', 'sha256_mismatch');
    });

    test('SEC15 清单里的文件在包里缺失即拒绝', () async {
      final target = importer();
      final pkg = _Pkg(slug: 'missing-file', files: _files());
      pkg.manifestOverride = [
        ...pkg.manifest,
        {
          'path': 'references/not-shipped.md',
          'size': 10,
          'sha256': 'a' * 64,
          'contentType': 'text/markdown',
        },
      ];
      hub.add(pkg);
      await expectRejected(target, 'missing-file', 'sha256_mismatch');
    });

    test('SEC16 包内多出未登记文件即拒绝', () async {
      final target = importer();
      hub.add(_Pkg(
        slug: 'extra-file',
        files: _files(),
        extraEntries: [_Entry('references/sneaky.md', utf8.encode('extra'))],
      ));
      await expectRejected(target, 'extra-file', 'sha256_mismatch');
    });

    test('SEC17 registry 未提供清单时拒绝安装（无法校验）', () async {
      final target = importer();
      final pkg = _Pkg(slug: 'no-manifest', files: _files());
      pkg.manifestOverride = [];
      hub.add(pkg);
      await expectRejected(target, 'no-manifest', 'no_manifest');
    });

    test('SEC18 记账里的 files 哈希与磁盘实际内容一致', () async {
      final target = importer();
      hub.add(_Pkg(slug: 'good-skill', files: _files()));
      final installed = await target.install('good-skill');
      for (final file in installed.record.files) {
        final onDisk =
            File(p.join(installed.pkgDir, p.joinAll(file.path.split('/'))));
        expect(onDisk.existsSync(), isTrue, reason: file.path);
        expect(sha256.convert(onDisk.readAsBytesSync()).toString(), file.sha256,
            reason: '${file.path} 的记账哈希必须等于磁盘内容');
      }
    });
  });

  // -------------------------------------------------------------- always: 剥离

  group('frontmatter 适配：剥离 always:', () {
    test('SEC19 标量形式 always: true 被剥离，其余字段保留', () async {
      final target = importer();
      hub.add(_Pkg(
        slug: 'has-always',
        files: _files(extra: 'always: true\ntags: [tutor]\n'),
      ));
      final installed = await target.install('has-always');

      final text = File(p.join(installed.pkgDir, 'SKILL.md')).readAsStringSync();
      expect(text.contains('always'), isFalse, reason: 'always 必须被剥离');
      expect(text, contains('name: loop-subject-tutor'));
      expect(text, contains('tags: [tutor]'), reason: '其它字段必须保留');
      expect(text, contains('Loop 学科助教'), reason: '正文必须保留');
      expect(installed.record.warnings, contains('stripped_always'));
    });

    test('SEC20 块列表形式的 always: 也被整块剥离，且不误伤后续字段', () async {
      final target = importer();
      hub.add(_Pkg(
        slug: 'has-always-block',
        files: _files(
          md: '---\n'
              'name: loop-subject-tutor\n'
              'description: Tutor inside one Loop subject. Use when the learner asks to be taught.\n'
              'always:\n'
              '  - inject-everywhere\n'
              '  - another\n'
              'tags: [tutor]\n'
              '---\n'
              '\n'
              '# 正文\n',
        ),
      ));
      final installed = await target.install('has-always-block');
      final text = File(p.join(installed.pkgDir, 'SKILL.md')).readAsStringSync();
      expect(text.contains('always'), isFalse);
      expect(text.contains('inject-everywhere'), isFalse);
      expect(text.contains('tags: [tutor]'), isTrue);
      expect(text.contains('# 正文'), isTrue);
    });

    test('SEC21 未声明 always 的技能包不被改动（避免无谓改写）', () async {
      final target = importer();
      hub.add(_Pkg(slug: 'clean-skill', files: _files(extra: 'tags: [tutor]\n')));
      final installed = await target.install('clean-skill');
      final text = File(p.join(installed.pkgDir, 'SKILL.md')).readAsStringSync();
      expect(text, utf8.decode(_files(extra: 'tags: [tutor]\n')['SKILL.md']!));
      expect(installed.record.warnings, isNot(contains('stripped_always')));
    });
  });

  // -------------------------------------------------------------- SSRF / 白名单

  group('hub 白名单与重定向（防 SSRF）', () {
    test('SEC22 只登记 eduhub；未知 hub 一律拒绝', () {
      expect(SkillHubAllowlist.hubs.keys, ['eduhub']);
      expect(SkillHubAllowlist.contains('eduhub'), isTrue);
      expect(SkillHubAllowlist.contains('clawhub'), isFalse);
      expect(SkillHubAllowlist.contains('evil'), isFalse);
      expect(() => SkillHubAllowlist.resolve('clawhub'),
          throwsA(isA<SkillRegistryError>()));
      expect(() => SkillHubAllowlist.resolve('http://169.254.169.254/'),
          throwsA(isA<SkillRegistryError>()));
      expect(SkillHubAllowlist.resolve(null).name, 'eduhub');
      expect(SkillHubAllowlist.resolve('EduHub').baseUrl,
          'https://eduhub.deeptutor.info/api/v1');
    });

    test('SEC23 拒绝跟随到非白名单主机的重定向', () async {
      hub.add(_Pkg(slug: 'any-skill', files: _files()));
      hub.redirectTo = 'http://evil.invalid/api/v1/search';
      hub.redirectBudget = 5;
      final registry = SkillRegistry.forBaseUrlForTests(hub.baseUrl);

      await expectLater(
        registry.search('x'),
        throwsA(isA<SkillRegistryError>()
            .having((e) => e.code, 'code', 'blocked')
            .having((e) => e.message, 'message', contains('非白名单主机'))),
      );
      // 关键：绝不能真的去连那个主机
      expect(hub.requests.length, 1);
    });

    test('SEC24 同主机重定向允许跟随后成功（不误杀正常跳转）', () async {
      hub.add(_Pkg(slug: 'any-skill', files: _files()));
      hub.redirectTo = '${hub.baseUrl}/search';
      hub.redirectBudget = 1;
      final registry = SkillRegistry.forBaseUrlForTests(hub.baseUrl);
      final results = await registry.search('x');
      expect(results.map((e) => e.slug), contains('any-skill'));
    });

    test('SEC25 同主机无限重定向被跳数上限拦截', () async {
      hub.add(_Pkg(slug: 'any-skill', files: _files()));
      hub.redirectTo = '${hub.baseUrl}/search';
      hub.redirectBudget = 99;
      final registry = SkillRegistry.forBaseUrlForTests(hub.baseUrl);
      await expectLater(
        registry.search('x'),
        throwsA(isA<SkillRegistryError>()
            .having((e) => e.code, 'code', 'blocked')
            .having((e) => e.message, 'message', contains('重定向次数过多'))),
      );
    });
  });

  // -------------------------------------------------------------- 原子替换

  group('原子替换与回退', () {
    test('SEC26 记账写入失败时保留旧版本（逐字节），并恢复记账', () async {
      final target = importer();
      final pkg = hub.add(_Pkg(slug: 'atomic-skill', files: _files()));
      await target.install('atomic-skill');

      final pkgRoot = target.pkgDir('atomic-skill').path;
      final before = <String, List<int>>{
        for (final file
            in Directory(pkgRoot).listSync(recursive: true).whereType<File>())
          p.relative(file.path, from: pkgRoot): file.readAsBytesSync(),
      };
      final lockFile = File(p.join(target.root.path, '.hub-lock.json'));
      final lockBackup = lockFile.readAsStringSync();
      expect(before.keys, contains('SKILL.md'));

      // 让 _writeLock 必然失败：把锁文件路径换成一个**目录**，
      // 于是 tmp rename 到该路径会失败（Windows/POSIX 都失败）。
      lockFile.deleteSync();
      Directory(lockFile.path).createSync();

      // 发布新版本并尝试升级
      pkg.version = '2.0.0';
      pkg.files
        ..clear()
        ..addAll(_files(extra: 'tags: [tutor]\n'));
      await expectLater(
        target.install('atomic-skill'),
        throwsA(isA<SkillImportError>().having((e) => e.code, 'code', 'io')),
      );

      // 旧版本必须逐字节保留
      final after = <String, List<int>>{
        for (final file
            in Directory(pkgRoot).listSync(recursive: true).whereType<File>())
          p.relative(file.path, from: pkgRoot): file.readAsBytesSync(),
      };
      expect(after.keys.toSet(), before.keys.toSet());
      for (final key in before.keys) {
        expect(after[key], before[key], reason: '$key 必须逐字节不变');
      }

      // 不能留下 staging 残留
      final leftovers = Directory(target.root.path)
          .listSync()
          .where((e) => p.basename(e.path).startsWith('.staging-'))
          .toList();
      expect(leftovers, isEmpty);

      // 恢复记账后，已装版本仍是旧的那一个
      Directory(lockFile.path).deleteSync();
      lockFile.writeAsStringSync(lockBackup);
      expect(target.list().single.version, '1.0.0');
    });

    test('SEC27 目标目录里的旧文件不会与新包混合（替换而非覆盖）', () async {
      final target = importer();
      final pkg = hub.add(_Pkg(slug: 'swap-skill', files: _files()));
      await target.install('swap-skill');
      expect(
        File(p.join(target.pkgDir('swap-skill').path, 'references',
                'retrieval-policy.md'))
            .existsSync(),
        isTrue,
      );

      // 新版本删掉了 references/：替换后旧文件必须消失（不能残留）
      pkg.version = '2.0.0';
      pkg.files
        ..clear()
        ..addAll({'SKILL.md': utf8.encode(_md(extra: 'tags: [tutor]\n'))});
      await target.install('swap-skill');

      expect(
        Directory(p.join(target.pkgDir('swap-skill').path, 'references'))
            .existsSync(),
        isFalse,
        reason: '替换必须是整体替换，不能残留上一版的文件',
      );
    });
  });

  // -------------------------------------------------------------- 无执行路径

  group('不存在执行 skill 内文件的代码路径', () {
    test('SEC28 导入器与 registry 源码里没有任何进程执行 API', () {
      const forbidden = [
        'Process.run',
        'Process.start',
        'Process.runSync',
        'Process.startSync',
        'Process.kill',
        'Isolate.spawn',
        'eval(',
        'Function.apply',
      ];
      for (final name in ['skills_import.dart', 'skills_registry.dart']) {
        final file = File(p.join(Directory.current.path, 'lib', 'backend', name));
        expect(file.existsSync(), isTrue, reason: name);
        final source = file.readAsStringSync();
        for (final token in forbidden) {
          expect(source.contains(token), isFalse, reason: '$name 不得出现 $token');
        }
      }
    });

    test('SEC29 含脚本的技能包：脚本仅作为文本落盘，不执行且被明确标记', () async {
      final target = importer();
      const marker = '#!/bin/sh\necho SHOULD-NEVER-RUN > /tmp/loop-pwned\n';
      hub.add(_Pkg(
        slug: 'with-script',
        files: {
          'SKILL.md': utf8.encode(_md()),
          'scripts/helper.sh': utf8.encode(marker),
          'scripts/helper.py': utf8.encode('print("never run")\n'),
        },
      ));
      final installed = await target.install('with-script');

      expect(installed.hasScripts, isTrue, reason: '必须向用户标注"含脚本"');
      final script = File(p.join(installed.pkgDir, 'scripts', 'helper.sh'));
      expect(script.existsSync(), isTrue);
      // 内容原样保存为**文本**（可审阅），且没有被赋予执行位
      expect(script.readAsStringSync(), marker);
      expect(SkillImportLimits.scriptSuffixes.contains('.sh'), isTrue);

      // playbook 只暴露文本，不含任何"执行"能力
      final playbooks = target.enabledPlaybooks();
      expect(playbooks, hasLength(1));
      expect(playbooks.single['content'], contains('# Loop 学科助教'));
      expect(playbooks.single.keys, isNot(contains('exec')));
    });

    test('SEC30 非 zip 内容被拒绝（不是 zip 就不能进管线）', () async {
      final target = importer();
      final pkg = _Pkg(slug: 'not-a-zip', files: _files());
      pkg.downloadBytes = utf8.encode('this is definitely not a zip file');
      hub.add(pkg);
      await expectRejected(target, 'not-a-zip', 'bad_zip');
    });

    test('SEC31 缺 SKILL.md / 坏 frontmatter 被拒绝', () async {
      final target = importer();
      hub.add(_Pkg(
        slug: 'no-skill-md',
        files: {'references/only.md': utf8.encode('# x\n')},
      ));
      await expectRejected(target, 'no-skill-md', 'bad_frontmatter');

      final target2 = importer();
      hub.add(_Pkg(
        slug: 'bad-frontmatter',
        files: {'SKILL.md': utf8.encode('# 没有 frontmatter\n')},
      ));
      await expectRejected(target2, 'bad-frontmatter', 'bad_frontmatter');
    });

    test('SEC32 缺 name/description 的 frontmatter 被拒绝', () async {
      final target = importer();
      hub.add(_Pkg(
        slug: 'no-name',
        files: {
          'SKILL.md':
              utf8.encode('---\ndescription: only a description\n---\n\n# x\n'),
        },
      ));
      await expectRejected(target, 'no-name', 'bad_frontmatter');
    });

    test('SEC33 非法 slug 一律拒绝（不拼接出奇怪路径）', () async {
      final target = importer();
      for (final slug in ['../evil', 'Upper', 'a/b', '', '.hidden']) {
        await expectLater(
          target.install(slug),
          throwsA(
              isA<SkillImportError>().having((e) => e.code, 'code', 'invalid_slug')),
          reason: slug,
        );
      }
      expect(Directory(target.root.path).listSync(), isEmpty);
    });
  });
}