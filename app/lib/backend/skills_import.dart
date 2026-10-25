/// 教学 skill 的**安全导入管线**（t5）。
///
/// 依据 docs/subject-skills-research.md §7.3 的实测姿态实现：
/// verify 裁决 → zip-slip/zip-bomb 防护 → 后缀白名单 → 符号链接整体拒绝 →
/// frontmatter 适配（**剥离 `always:`**）→ 逐文件 sha256 清单校验 →
/// 原子替换（`pkg` / `prev`）→ `.hub-lock.json` 记账。
///
/// **安全边界**：本文件不存在任何执行 skill 内文件/脚本/命令的代码路径。
/// skill 只作为文本 playbook（SKILL.md + 资源）被读取与注入。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'db.dart';
import 'paths.dart';
import 'skills_registry.dart';
import 'subject_store.dart';

/// `.hub-lock.json` 的 schema 版本（规格 §9.6.1 / §2.3）。
const int kSkillLockSchema = 1;

/// 导入上限（比 registry 的 4MB/40MB/600 更严；research §7.3）。
class SkillImportLimits {
  const SkillImportLimits._();

  static const int maxFileBytes = 1000000; // 1 MB
  static const int maxTotalBytes = 20000000; // 20 MB
  static const int maxFiles = 500;

  /// 压缩比上限（防 zip-bomb；规格 §9.5 定为 100:1）。
  static const int maxCompressionRatio = 100;

  /// 支持文件后缀白名单（小写，含空后缀 = 无扩展名文件如 LICENSE）。
  /// 语义是"**文本资源 + 静态图示**"：允许附脚本，但 Loop **永不执行**它们。
  /// 图片/PDF 只作为资料展示（F-12）。
  static const Set<String> allowedSuffixes = <String>{
    '',
    '.md', '.markdown', '.txt', '.rst',
    '.py', '.js', '.mjs', '.ts', '.sh', '.rb', '.lua', '.r',
    '.json', '.jsonl', '.yaml', '.yml', '.toml', '.ini', '.cfg',
    '.csv', '.tsv', '.html', '.htm', '.css', '.xml', '.sql',
    '.jinja', '.j2', '.tmpl', '.template',
    // 静态图示/文档（不作为可执行内容）
    '.png', '.jpg', '.jpeg', '.webp', '.gif', '.pdf',
  };

  /// 可做**文本内容扫描**的后缀（图片/PDF 跳过）。
  static const Set<String> textScanSuffixes = <String>{
    '', '.md', '.markdown', '.txt', '.rst', '.py', '.js', '.mjs', '.ts', '.sh',
    '.rb', '.lua', '.r', '.json', '.jsonl', '.yaml', '.yml', '.toml', '.ini',
    '.cfg', '.csv', '.tsv', '.html', '.htm', '.css', '.xml', '.sql',
    '.jinja', '.j2', '.tmpl', '.template',
  };

  /// 被视为"脚本"的后缀（仅用于打标提示，不影响可安装性）。
  static const Set<String> scriptSuffixes = <String>{
    '.py', '.js', '.mjs', '.ts', '.sh', '.rb', '.lua', '.r',
  };

  /// 危险原生可执行/安装包后缀（发布侧黑名单；导入侧由白名单兜底）。
  static const Set<String> dangerousSuffixes = <String>{
    '.exe', '.dll', '.so', '.dylib', '.bin', '.msi', '.dmg', '.pkg',
    '.app', '.bat', '.cmd', '.scr', '.com', '.jar', '.apk',
  };

  static String suffixOf(String path) {
    final base = p.basename(path).toLowerCase();
    final dot = base.lastIndexOf('.');
    if (dot <= 0) return ''; // 无扩展名，或 .gitignore 这类以点开头的名字
    return base.substring(dot);
  }
}

/// 导入失败。带 HTTP 语义状态码，供 server 层直接映射。
class SkillImportError implements Exception {
  SkillImportError(this.code, this.message, {this.status = 400});

  final String code;
  final String message;
  final int status;

  Map<String, dynamic> toJson() => {
        'ok': false,
        'code': code,
        'message': message,
      };

  @override
  String toString() => 'SkillImportError($code): $message';
}

/// F-8：verify=suspicious 且用户尚未显式确认时**不是错误**，而是"需要一次
/// 显式确认"。server 层据此返回 200 + `needs_confirm:true` + `stage:'verify'`
/// （AC-04 断言 2），而不是 409。
class SkillNeedsConfirm implements Exception {
  SkillNeedsConfirm(this.verdict, this.detail);

  final SkillVerdict verdict;
  final String detail;

  @override
  String toString() => 'SkillNeedsConfirm(decision=${verdict.decision}): $detail';
}

// ===========================================================================
// 包内文本内容扫描（F-2：sha256 只能证明"和 registry 一致"，不能证明"内容无害"）
// ===========================================================================

/// 一条内容规则：命中即整包拒绝（fail-closed）。
class SkillScanRule {
  const SkillScanRule(this.id, this.label, this.pattern);

  final String id;
  final String label;
  final RegExp pattern;
}

/// 命中结果：文件 + 行号 + 片段（截断）。
class SkillScanHit {
  const SkillScanHit({
    required this.ruleId,
    required this.label,
    required this.file,
    required this.line,
    required this.snippet,
  });

  final String ruleId;
  final String label;
  final String file;
  final int line;
  final String snippet;

  Map<String, dynamic> toJson() => {
        'rule': ruleId,
        'label': label,
        'file': file,
        'line': line,
        'snippet': snippet,
      };

  String get message => '$file:$line [$label] $snippet';
}

/// 包内**文本内容**的高危模式扫描。
///
/// 设计取舍：宁可误报也不放过（fail-closed）——教学 SKILL.md 里出现
/// `curl | bash`、`/dev/tcp` 这类字面量本身就说明包不该被安装；被误伤的包
/// 由用户自行决定是否放弃（Loop 不做 override 安装）。
class SkillContentScanner {
  const SkillContentScanner._();

  /// 单文件扫描上限（超过则只扫前缀，避免超长文本拖慢导入）。
  static const int maxScanBytes = 512 * 1024;

  /// 命中片段的最大长度。
  static const int maxSnippetChars = 160;

  static final List<SkillScanRule> rules = <SkillScanRule>[
    // 1) 下载即执行（curl/wget/iwr 管道到 shell 或解释器）
    SkillScanRule(
      'download_and_exec',
      '下载即执行',
      RegExp(
        r'(?:curl|wget|Invoke-WebRequest|iwr)\b[^\n\r]{0,200}?\|\s*'
        r'(?:sudo\s+)?(?:ba|z|da)?sh\b'
        r'|(?:curl|wget)\b[^\n\r]{0,200}?\|\s*(?:python3?|node|perl|ruby)\b',
        caseSensitive: false,
      ),
    ),
    // 2) 反弹 shell（/dev/tcp 或 nc -e）
    SkillScanRule(
      'reverse_shell',
      '反弹 shell',
      RegExp(
        r'/dev/(?:tcp|udp)/'
        r'|\b(?:nc|ncat|netcat)\b[^\n\r]{0,60}\s-e\s+(?:/bin/)?(?:ba|z)?sh\b'
        r'|\bbash\s+-i\s+>&\s*/dev/(?:tcp|udp)/',
        caseSensitive: false,
      ),
    ),
    // 3) 破坏性删除
    SkillScanRule(
      'destructive_delete',
      '破坏性删除',
      RegExp(
        r'\brm\s+-[a-z]*[rf][a-z]*\s+(?:/|/\*|~|\$HOME)(?:\s|$)'
        r'|\bRemove-Item\b[^\n\r]{0,80}-Recurse[^\n\r]{0,80}-Force[^\n\r]{0,60}[A-Za-z]:\\'
        r'|\bmkfs\.(?:ext4|ext3|xfs)\b',
        caseSensitive: false,
      ),
    ),
    // 4) base64 解码后执行
    SkillScanRule(
      'base64_exec',
      'base64 解码执行',
      RegExp(
        r'\bbase64\s+(?:-d|--decode|-D)\b[^\n\r]{0,120}\|\s*(?:ba|z)?sh\b'
        r'|\bbase64\s+-d\b[^\n\r]{0,120}>\s*[^\n\r]{0,40}&&\s*(?:ba|z)?sh\b'
        r'|FromBase64String\s*\([^\n\r]{0,200}?(?:Invoke-Expression|iex)\b'
        r'|\beval\s*\(?\s*(?:atob|base64)',
        caseSensitive: false,
      ),
    ),
    // 5) 凭据/密钥读取
    SkillScanRule(
      'credential_access',
      '读取凭据/密钥',
      RegExp(
        r'(?:^|[\s/\\"])(?:id_rsa|id_ed25519|id_ecdsa)(?:[\s"]|$)'
        r'|\.aws[/\\]credentials'
        r'|\.ssh[/\\]id_'
        r'|\.git-credentials'
        r'|(?:^|[\s/\\"])\.netrc'
        r'|Login Data'
        r'|Keychain[/\\]login\.keychain',
        caseSensitive: false,
      ),
    ),
    // 6) 挖矿
    SkillScanRule(
      'crypto_mining',
      '挖矿',
      RegExp(
        r'stratum\+(?:tcp|ssl)://|\bxmrig\b|\bminerd\b|\bcryptonight\b|moneroocean',
        caseSensitive: false,
      ),
    ),
    // 7) PowerShell 编码/隐藏执行
    SkillScanRule(
      'powershell_obfuscated',
      'PowerShell 编码执行',
      RegExp(
        r'powershell(?:\.exe)?[^\n\r]{0,80}-(?:enc|encodedcommand|e)\s+[A-Za-z0-9+/=]{24,}'
        r'|-w(?:indowstyle)?\s+hidden[^\n\r]{0,80}-(?:enc|encodedcommand|e)\s'
        r'|Invoke-Expression\s*\(\s*\[System\.Convert\]::FromBase64String',
        caseSensitive: false,
      ),
    ),
    // 8) 环境变量/密钥外传
    SkillScanRule(
      'env_exfiltration',
      '环境变量外传',
      RegExp(
        r'(?:curl|wget|Invoke-WebRequest)\b[^\n\r]{0,160}'
        r'(?:printenv|\benv\b|process\.env|\$\(cat\s+\.env|\$AWS_SECRET|\$GITHUB_TOKEN)',
        caseSensitive: false,
      ),
    ),
    // 9) 本地提权/持久化（计划任务、注册表 Run、sudoers）
    SkillScanRule(
      'persistence_privesc',
      '持久化/提权',
      RegExp(
        r'\bschtasks\s+/create\b|\bcrontab\s+-e\b'
        r'|HKLM\\+SOFTWARE\\+Microsoft\\+Windows\\+CurrentVersion\\+Run'
        r'|>>?\s*/etc/sudoers\b|\bchmod\s+(?:4?777|u\+s)\b',
        caseSensitive: false,
      ),
    ),
    // 10) 静默改写 Loop 自己的数据/配置
    SkillScanRule(
      'loop_tampering',
      '改写 Loop 数据/配置',
      RegExp(
        r'data[/\\]loop\.db'
        r'|subjects[/\\][a-z0-9_]{3,40}[/\\]loop\.db'
        r'|\.hub-lock\.json\b[^\n\r]{0,60}(?:write|>|INSERT|rm|del)',
        caseSensitive: false,
      ),
    ),
  ];

  /// 扫描一组"已落 staging 的文件"，返回第一个命中（没有命中返回 null）。
  static SkillScanHit? scanFiles({
    required Map<String, String> textByRelativePath,
  }) {
    for (final entry in textByRelativePath.entries) {
      final hit = scanText(entry.key, entry.value);
      if (hit != null) return hit;
    }
    return null;
  }

  /// 扫描单段文本；[file] 仅用于回报。
  static SkillScanHit? scanText(String file, String text) {
    final limited = text.length > maxScanBytes ? text.substring(0, maxScanBytes) : text;
    final lines = limited.split('\n');
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      for (final rule in rules) {
        final match = rule.pattern.firstMatch(line);
        if (match == null) continue;
        final start = match.start;
        final end = match.end;
        final raw = line.substring(start, end).trim();
        final snippet = raw.length > maxSnippetChars
            ? '${raw.substring(0, maxSnippetChars)}…'
            : raw;
        return SkillScanHit(
          ruleId: rule.id,
          label: rule.label,
          file: file,
          line: index + 1,
          snippet: snippet,
        );
      }
    }
    return null;
  }
}

// ===========================================================================
// 严格 ZIP 读取器（自建，不依赖第三方解压行为）
// ===========================================================================

class _ZipEntry {
  _ZipEntry({
    required this.name,
    required this.flags,
    required this.method,
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localOffset,
    required this.unixMode,
  });

  final String name;
  final int flags;
  final int method;
  final int crc32;
  final int compressedSize;
  final int uncompressedSize;
  final int localOffset;
  final int? unixMode;

  bool get encrypted => (flags & 0x0001) != 0;

  /// Unix 模式位 S_IFLNK：symlink 一律整体拒绝（可指向包外内容）。
  bool get isSymlink => unixMode != null && (unixMode! & 0xF000) == 0xA000;
}

/// 只读、fail-closed 的 ZIP 解析器：支持 store(0) 与 deflate(8)。
class _ZipArchive {
  _ZipArchive._(this._bytes, this.entries);

  final Uint8List _bytes;
  final List<_ZipEntry> entries;

  static const int _sigEocd = 0x06054b50;
  static const int _sigCentral = 0x02014b50;
  static const int _sigLocal = 0x04034b50;

  static _ZipArchive parse(Uint8List bytes) {
    if (bytes.length < 22) {
      throw SkillImportError('bad_zip', '压缩包不完整');
    }
    final eocd = _findEocd(bytes);
    if (eocd < 0) {
      throw SkillImportError('bad_zip', '找不到 ZIP 结束记录（不是合法 zip）');
    }
    final total = _u16(bytes, eocd + 10);
    final cdSize = _u32(bytes, eocd + 12);
    final cdOffset = _u32(bytes, eocd + 16);

    if (total == 0xFFFF || cdOffset == 0xFFFFFFFF || cdSize == 0xFFFFFFFF) {
      throw SkillImportError('bad_zip', '不支持 ZIP64 压缩包');
    }
    if (total == 0) {
      throw SkillImportError('bad_zip', '压缩包内没有文件');
    }
    if (cdOffset + cdSize > bytes.length) {
      throw SkillImportError('bad_zip', 'ZIP 目录越界');
    }

    final entries = <_ZipEntry>[];
    var cursor = cdOffset;
    for (var i = 0; i < total; i++) {
      if (cursor + 46 > bytes.length) {
        throw SkillImportError('bad_zip', 'ZIP 目录项越界');
      }
      if (_u32(bytes, cursor) != _sigCentral) {
        throw SkillImportError('bad_zip', 'ZIP 目录项签名非法');
      }
      final versionMadeBy = _u16(bytes, cursor + 4);
      final flags = _u16(bytes, cursor + 8);
      final method = _u16(bytes, cursor + 10);
      final crc = _u32(bytes, cursor + 16);
      final compSize = _u32(bytes, cursor + 20);
      final uncompSize = _u32(bytes, cursor + 24);
      final nameLen = _u16(bytes, cursor + 28);
      final extraLen = _u16(bytes, cursor + 30);
      final commentLen = _u16(bytes, cursor + 32);
      final extAttr = _u32(bytes, cursor + 38);
      final localOffset = _u32(bytes, cursor + 42);

      if (cursor + 46 + nameLen > bytes.length) {
        throw SkillImportError('bad_zip', 'ZIP 文件名越界');
      }
      final name = _decodeName(
        bytes.sublist(cursor + 46, cursor + 46 + nameLen),
        (flags & 0x0800) != 0,
      );

      // versionMadeBy 高字节 3 = Unix，才解读 unix 权限位。
      final hostSystem = (versionMadeBy >> 8) & 0xFF;
      final unixMode = hostSystem == 3 ? (extAttr >> 16) & 0xFFFF : null;

      entries.add(_ZipEntry(
        name: name,
        flags: flags,
        method: method,
        crc32: crc,
        compressedSize: compSize,
        uncompressedSize: uncompSize,
        localOffset: localOffset,
        unixMode: unixMode,
      ));
      cursor += 46 + nameLen + extraLen + commentLen;
    }
    return _ZipArchive._(bytes, entries);
  }

  /// 读取并解压一个条目；[maxBytes] 为单文件硬上限（超出即抛）。
  Uint8List read(_ZipEntry entry, {required int maxBytes}) {
    if (entry.encrypted) {
      throw SkillImportError('bad_zip', '压缩包内含加密条目：${entry.name}');
    }
    if (entry.method != 0 && entry.method != 8) {
      throw SkillImportError(
          'bad_zip', '不支持的压缩方式（method=${entry.method}）：${entry.name}');
    }
    if (entry.uncompressedSize > maxBytes) {
      throw SkillImportError('too_large',
          '文件超出上限（${entry.uncompressedSize} > $maxBytes 字节）：${entry.name}');
    }
    if (entry.compressedSize > 0 &&
        entry.uncompressedSize / entry.compressedSize >
            SkillImportLimits.maxCompressionRatio) {
      throw SkillImportError('zip_bomb',
          '压缩比异常（${entry.uncompressedSize}/${entry.compressedSize}）：${entry.name}');
    }

    final offset = entry.localOffset;
    if (offset + 30 > _bytes.length || _u32(_bytes, offset) != _sigLocal) {
      throw SkillImportError('bad_zip', 'ZIP 本地头非法：${entry.name}');
    }
    final localNameLen = _u16(_bytes, offset + 26);
    final localExtraLen = _u16(_bytes, offset + 28);
    final dataStart = offset + 30 + localNameLen + localExtraLen;
    if (dataStart + entry.compressedSize > _bytes.length) {
      throw SkillImportError('bad_zip', 'ZIP 数据越界：${entry.name}');
    }
    final raw = Uint8List.sublistView(
        _bytes, dataStart, dataStart + entry.compressedSize);

    final Uint8List data;
    if (entry.method == 0) {
      if (entry.compressedSize != entry.uncompressedSize) {
        throw SkillImportError('bad_zip', 'STORE 条目大小不一致：${entry.name}');
      }
      if (raw.length > maxBytes) {
        throw SkillImportError('too_large', '文件超出上限：${entry.name}');
      }
      data = Uint8List.fromList(raw);
    } else {
      data = _inflate(raw, cap: maxBytes, name: entry.name);
    }

    if (data.length != entry.uncompressedSize) {
      throw SkillImportError('bad_zip',
          '解压后大小与声明不符（${data.length} != ${entry.uncompressedSize}）：${entry.name}');
    }
    if (_crc32(data) != entry.crc32) {
      throw SkillImportError('bad_zip', 'CRC 校验失败：${entry.name}');
    }
    return data;
  }

  static Uint8List _inflate(Uint8List raw, {required int cap, required String name}) {
    final builder = BytesBuilder(copy: false);
    final sink = _CappedSink(builder, cap);
    try {
      final converter = ZLibDecoder(raw: true).startChunkedConversion(sink);
      converter.add(raw);
      converter.close();
    } on _CapExceeded {
      throw SkillImportError('zip_bomb', '解压后超出上限（可能是 zip-bomb）：$name');
    } on FormatException catch (error) {
      throw SkillImportError('bad_zip', 'DEFLATE 数据损坏：$name（$error）');
    } catch (error) {
      if (error is SkillImportError) rethrow;
      throw SkillImportError('bad_zip', '解压失败：$name（$error）');
    }
    return builder.takeBytes();
  }

  static int _findEocd(Uint8List bytes) {
    final lowest = (bytes.length - 22 - 65535).clamp(0, bytes.length);
    for (var i = bytes.length - 22; i >= lowest; i--) {
      if (_u32(bytes, i) == _sigEocd) return i;
    }
    return -1;
  }

  static String _decodeName(Uint8List raw, bool utf8Flag) {
    if (utf8Flag) {
      try {
        return utf8.decode(raw);
      } catch (_) {
        return latin1.decode(raw);
      }
    }
    return latin1.decode(raw);
  }

  static int _u16(Uint8List bytes, int offset) {
    if (offset < 0 || offset + 2 > bytes.length) {
      throw SkillImportError('bad_zip', 'ZIP 结构越界');
    }
    return bytes[offset] | (bytes[offset + 1] << 8);
  }

  static int _u32(Uint8List bytes, int offset) {
    if (offset < 0 || offset + 4 > bytes.length) {
      throw SkillImportError('bad_zip', 'ZIP 结构越界');
    }
    return bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
  }
}

class _CapExceeded implements Exception {
  const _CapExceeded();
}

class _CappedSink implements Sink<List<int>> {
  _CappedSink(this._builder, this._cap);

  final BytesBuilder _builder;
  final int _cap;
  int _total = 0;

  @override
  void add(List<int> data) {
    _total += data.length;
    if (_total > _cap) {
      throw const _CapExceeded();
    }
    _builder.add(data);
  }

  @override
  void close() {}
}

// CRC32（IEEE）
final List<int> _crcTable = _buildCrcTable();

List<int> _buildCrcTable() {
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

int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

// ===========================================================================
// frontmatter
// ===========================================================================

/// SKILL.md 的 YAML frontmatter（最小解析：不引入 yaml 依赖）。
///
/// 关键职责：**剥离 `always:`**。下载来的教学 skill 绝不能因为一个字段
/// 就变成"每次对话都注入"的提示词（research §7.3）。
class SkillFrontmatter {
  SkillFrontmatter._(this._lines, this.scalars, this.tags, this.body);

  final List<String> _lines;
  final Map<String, String> scalars;
  final List<String> tags;
  final String body;

  String get name => (scalars['name'] ?? '').trim();
  String get description => (scalars['description'] ?? '').trim();
  String get version => (scalars['version'] ?? '').trim();
  String get language => (scalars['language'] ?? '').trim().toLowerCase();
  String get license => (scalars['license'] ?? '').trim();
  String get track => (scalars['track'] ?? '').trim();

  bool get hadAlways => _containsKey('always');

  bool _containsKey(String key) {
    for (final line in _lines) {
      if (_topLevelKey(line) == key) return true;
    }
    return false;
  }

  static String? _topLevelKey(String line) {
    if (line.isEmpty || line.startsWith(' ') || line.startsWith('\t')) return null;
    if (line.startsWith('-')) return null;
    final colon = line.indexOf(':');
    if (colon <= 0) return null;
    final key = line.substring(0, colon).trim();
    if (key.isEmpty) return null;
    if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(key)) return null;
    return key.toLowerCase();
  }

  /// 解析 markdown；无 frontmatter 或缺少 name/description 时抛错。
  static SkillFrontmatter parse(String markdown) {
    final normalized = markdown.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = normalized.split('\n');
    if (lines.isEmpty || lines.first.trim() != '---') {
      throw SkillImportError('bad_frontmatter', 'SKILL.md 缺少 YAML frontmatter');
    }
    var end = -1;
    for (var i = 1; i < lines.length; i++) {
      if (lines[i].trim() == '---') {
        end = i;
        break;
      }
    }
    if (end < 0) {
      throw SkillImportError('bad_frontmatter', 'SKILL.md 的 frontmatter 没有结束标记');
    }
    final inner = lines.sublist(1, end);
    final body = lines.sublist(end + 1).join('\n');

    final scalars = <String, String>{};
    final tags = <String>[];
    String? current;
    final pendingList = <String, List<String>>{};

    for (final line in inner) {
      final key = _topLevelKey(line);
      if (key != null) {
        current = key;
        final value = line.substring(line.indexOf(':') + 1).trim();
        if (value.isEmpty) continue;
        if (value.startsWith('[') && value.endsWith(']')) {
          final items = value
              .substring(1, value.length - 1)
              .split(',')
              .map((e) => e.trim().replaceAll(RegExp(r'''^["']|["']$'''), ''))
              .where((e) => e.isNotEmpty)
              .toList();
          pendingList[key] = items;
          scalars[key] = items.join(',');
        } else if (value == '|' || value == '>' || value.startsWith('|') || value.startsWith('>')) {
          scalars[key] = '';
        } else {
          scalars[key] = value.replaceAll(RegExp(r'''^["']|["']$'''), '');
        }
        continue;
      }
      final trimmed = line.trim();
      if (current != null && trimmed.startsWith('- ')) {
        final item = trimmed
            .substring(2)
            .trim()
            .replaceAll(RegExp(r'''^["']|["']$'''), '');
        if (item.isNotEmpty) {
          (pendingList[current] ??= <String>[]).add(item);
          scalars[current] = (pendingList[current] ?? const <String>[]).join(',');
        }
      }
    }

    if (pendingList['tags'] != null) tags.addAll(pendingList['tags']!);

    final frontmatter = SkillFrontmatter._(inner, scalars, tags, body);
    if (frontmatter.name.isEmpty) {
      throw SkillImportError('bad_frontmatter', 'SKILL.md 的 frontmatter 缺少 name');
    }
    if (frontmatter.description.isEmpty) {
      throw SkillImportError('bad_frontmatter', 'SKILL.md 的 frontmatter 缺少 description');
    }
    return frontmatter;
  }

  /// 重建 SKILL.md：默认剥离 `always:`（连同它的块列表/续行）。
  String rebuild({bool stripAlways = true}) {
    final kept = <String>[];
    String? skipping;
    for (final line in _lines) {
      final key = _topLevelKey(line);
      if (key != null) {
        if (stripAlways && key == 'always') {
          skipping = key;
          continue;
        }
        skipping = null;
        kept.add(line);
        continue;
      }
      if (skipping != null) continue; // 丢弃 always 的缩进续行 / 块列表
      kept.add(line);
    }
    return '---\n${kept.join('\n')}\n---\n${body.startsWith('\n') ? '' : '\n'}$body'
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trimRight();
  }

  }

// ===========================================================================
// 记账与已装模型
// ===========================================================================

/// 一个已装版本的可追溯记录（`.hub-lock.json` 的 `current`/`previous`）。
class SkillPackageRecord {
  const SkillPackageRecord({
    required this.version,
    required this.name,
    required this.description,
    required this.bundleSha256,
    required this.files,
    required this.verdictStatus,
    required this.verdictDecision,
    required this.installedAt,
    this.displayName = '',
    this.owner = '',
    this.license = '',
    this.sourceUrl = '',
    this.hasScripts = false,
    this.warnings = const [],
  });

  final String version;

  /// 身份名（F-12：与 slug 一致；frontmatter 自报名进 [displayName]）。
  final String name;

  /// frontmatter 里自报的可读名（只影响展示与注入文案）。
  final String displayName;

  final String description;

  /// 清单摘要（排序后的 `path:sha256` 行的 sha256）。
  ///
  /// 语义 = **registry 规范化重打包**的逐文件清单摘要（provenance，用于
  /// `subject_skills.sha256` 列）；[files] 则是**落盘后**的实际哈希
  /// （适配 frontmatter 后会与 registry 清单在 SKILL.md 一项上不同）。
  final String bundleSha256;
  final List<SkillManifestFile> files;
  final String verdictStatus;
  final String verdictDecision;
  final String installedAt;
  final String owner;
  final String license;
  final String sourceUrl;
  final bool hasScripts;
  final List<String> warnings;

  Map<String, dynamic> toJson() => {
        'version': version,
        'name': name,
        'display_name': displayName,
        'description': description,
        'bundle_sha256': bundleSha256,
        'files': [for (final f in files) f.toJson()],
        'verdict': {'status': verdictStatus, 'decision': verdictDecision},
        'installed_at': installedAt,
        'owner': owner,
        'license': license,
        'source_url': sourceUrl,
        'has_scripts': hasScripts,
        if (warnings.isNotEmpty) 'warnings': warnings,
      };

  static SkillPackageRecord fromJson(Map<String, dynamic> json) {
    final files = <SkillManifestFile>[];
    final rawFiles = json['files'];
    if (rawFiles is List) {
      for (final item in rawFiles) {
        if (item is! Map) continue;
        files.add(SkillManifestFile(
          path: (item['path'] ?? '').toString(),
          size: (item['size'] as num?)?.toInt() ?? 0,
          sha256: (item['sha256'] ?? '').toString(),
          contentType: (item['content_type'] ?? '').toString(),
        ));
      }
    }
    final verdict = json['verdict'];
    final verdictMap = verdict is Map ? verdict : const {};
    final warningsRaw = json['warnings'];
    return SkillPackageRecord(
      version: (json['version'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      displayName: (json['display_name'] ?? json['name'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      bundleSha256: (json['bundle_sha256'] ?? '').toString(),
      files: files,
      verdictStatus: (verdictMap['status'] ?? '').toString(),
      verdictDecision: (verdictMap['decision'] ?? '').toString(),
      installedAt: (json['installed_at'] ?? '').toString(),
      owner: (json['owner'] ?? '').toString(),
      license: (json['license'] ?? '').toString(),
      sourceUrl: (json['source_url'] ?? '').toString(),
      hasScripts: json['has_scripts'] == true,
      warnings: warningsRaw is List ? [for (final w in warningsRaw) '$w'] : const [],
    );
  }
}

/// 面向 API/UI 的已装 skill。
class InstalledSkill {
  const InstalledSkill({
    required this.slug,
    required this.record,
    required this.enabled,
    required this.pinned,
    required this.pkgDir,
    this.previous,
    this.hub = 'eduhub',
    this.dbMirrored = true,
    this.already = false,
  });

  final String slug;
  final SkillPackageRecord record;
  final bool enabled;
  final bool pinned;
  final String pkgDir;
  final SkillPackageRecord? previous;
  final String hub;
  final bool dbMirrored;

  /// F-7：本次"安装"其实是同版本重装，未做任何下载/落盘。
  final bool already;

  String get version => record.version;

  /// 身份名 = slug（F-12）；可读名见 [displayName]。
  String get name => slug.isEmpty ? record.name : slug;

  /// 展示/注入用可读名。
  String get displayName => record.displayName.isEmpty ? name : record.displayName;

  String get description => record.description;
  String get bundleSha256 => record.bundleSha256;
  bool get hasScripts => record.hasScripts;
  bool get unverified => record.verdictStatus == SkillVerdict.unknown;
  bool get suspicious => record.verdictStatus == SkillVerdict.suspicious;
  bool get hasPrevious => previous != null;

  String get owner => record.owner;
  String get license => record.license;
  String get previousVersion => previous?.version ?? '';

  /// SKILL.md 相对路径（`files_rel_path` 记账用）。
  String get skillsFilePath => record.files.isEmpty
      ? p.join(pkgDir, 'SKILL.md')
      : p.join(pkgDir, record.files.first.path);

  Map<String, dynamic> toJson() => {
        'slug': slug,
        'version': version,
        'name': name,
        'display_name': displayName,
        'description': description,
        'hub': hub,
        'enabled': enabled,
        'pinned': pinned,
        'installed': true,
        'already': already,
        'has_scripts': hasScripts,
        'unverified': unverified,
        'suspicious': suspicious,
        'verdict': {
          'status': record.verdictStatus,
          'decision': record.verdictDecision,
        },
        'sha256': bundleSha256,
        'owner': record.owner,
        'license': record.license,
        'source_url': record.sourceUrl,
        'files': record.files.length,
        'installed_at': record.installedAt,
        'has_previous': hasPrevious,
        'previous_version': previous?.version ?? '',
        'pkg_dir': pkgDir,
      };
}

// ===========================================================================
// 导入器
// ===========================================================================

/// 已装 skill 的落盘 + 记账。**每个学科一份**（依赖 `subjectKey` 作用域），
/// 因此"学科级启用"天然隔离：A 学科装的 skill 不会出现在 B 学科。
class SkillImporter {
  SkillImporter({
    required this.subjectKey,
    SkillRegistry? registry,
    Directory? rootForTests,
  })  : root = rootForTests ?? AppPaths.subjectSkillsDir(subjectKey),
        registry = registry ?? SkillRegistry.forHub(null);

  /// 学科 key（决定 `data/subjects/<key>/skills`）。
  final String subjectKey;

  /// 学科 skills 根目录。
  final Directory root;

  final SkillRegistry registry;

  Directory get _skillsRoot {
    if (!root.existsSync()) root.createSync(recursive: true);
    return root;
  }

  Directory pkgDir(String slug) => Directory(p.join(_skillsRoot.path, slug, 'pkg'));

  Directory prevDir(String slug) => Directory(p.join(_skillsRoot.path, slug, 'prev'));

  File get lockFile => File(p.join(_skillsRoot.path, '.hub-lock.json'));

  // ------------------------------------------------------------ 记账

  /// 读取 `.hub-lock.json`（磁盘权威）。
  ///
  /// F-13：落盘格式按规格 §9.6.1（`{schema, subject, skills:[…]}`）；同时兼容
  /// t5 时期的旧格式（`{version, hub, skills:{slug:{current:{…}}}}`），旧库升级
  /// 后第一次写入即自动转成新格式，不会丢记账。
  Map<String, dynamic> _readLock() {
    final file = lockFile;
    final empty = <String, dynamic>{
      'schema': kSkillLockSchema,
      'subject': subjectKey,
      'hub': registry.hub.name,
      'skills': <String, dynamic>{},
    };
    if (!file.existsSync()) return empty;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return empty;
      final map = decoded.cast<String, dynamic>();
      final raw = map['skills'];
      final skills = <String, dynamic>{};
      if (raw is List) {
        for (final item in raw) {
          if (item is! Map) continue;
          final entry = item.cast<String, dynamic>();
          final slug = (entry['slug'] ?? '').toString();
          if (slug.isEmpty) continue;
          final current = <String, dynamic>{
            'version': entry['version'] ?? '',
            'name': slug, // F-12：身份名 = slug
            'display_name': entry['name'] ?? slug, // lock 的 name 存可读名
            'description': entry['description'] ?? '',
            'bundle_sha256': entry['artifactSha256'] ?? '',
            'files': entry['files'] ?? const [],
            'verdict': entry['verdict'] ?? const {},
            'installed_at': entry['installedAt'] ?? '',
            'owner': entry['ownerHandle'] ?? '',
            'license': entry['license'] ?? '',
            'source_url': entry['sourceUrl'] ?? '',
            'has_scripts': entry['hasScripts'] == true,
            if (entry['warnings'] is List) 'warnings': entry['warnings'],
          };
          final prevVersion = entry['previousVersion'];
          final previous = <String, dynamic>{
            'version': prevVersion ?? '',
            'name': entry['name'] ?? slug,
          };
          skills[slug] = <String, dynamic>{
            'hub': entry['hub'] ?? map['hub'] ?? registry.hub.name,
            'enabled': entry['enabled'] != false,
            'pinned': entry['pinned'] == true,
            'current': current,
            if (prevVersion != null && '$prevVersion'.isNotEmpty) 'previous': previous,
          };
        }
      } else if (raw is Map) {
        for (final key in raw.keys) {
          final entry = raw[key];
          if (entry is! Map) continue;
          skills['$key'] = entry.cast<String, dynamic>();
        }
      }
      return {
        'schema': kSkillLockSchema,
        'subject': (map['subject'] ?? subjectKey).toString(),
        'hub': (map['hub'] ?? registry.hub.name).toString(),
        'updated_at': map['updated_at'],
        'skills': skills,
      };
    } catch (_) {}
    return empty;
  }

  void _writeLock(Map<String, dynamic> lock) {
    final internal = (lock['skills'] is Map)
        ? (lock['skills'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    final entries = <Map<String, dynamic>>[];
    for (final key in internal.keys) {
      final entry = internal[key];
      if (entry is! Map) continue;
      final map = entry.cast<String, dynamic>();
      final current = (map['current'] is Map)
          ? (map['current'] as Map).cast<String, dynamic>()
          : <String, dynamic>{};
      final previousVersion = (map['previous'] is Map)
          ? ((map['previous'] as Map)['version'] ?? '').toString()
          : '';
      final verdict = (current['verdict'] is Map)
          ? (current['verdict'] as Map).cast<String, dynamic>()
          : <String, dynamic>{};
      entries.add({
        'slug': key,
        'version': (current['version'] ?? '').toString(),
        'name': (current['display_name'] ?? current['name'] ?? key).toString(),
        'description': (current['description'] ?? '').toString(),
        'hub': (map['hub'] ?? lock['hub'] ?? registry.hub.name).toString(),
        'ownerHandle': (current['owner'] ?? '').toString(),
        'verdict': {
          'status': (verdict['status'] ?? '').toString(),
          'decision': (verdict['decision'] ?? '').toString(),
        },
        'artifactSha256': (current['bundle_sha256'] ?? '').toString(),
        'hasScripts': current['has_scripts'] == true,
        'enabled': map['enabled'] != false,
        'pinned': map['pinned'] == true,
        'license': (current['license'] ?? '').toString(),
        'installedAt': (current['installed_at'] ?? '').toString(),
        'previousVersion': previousVersion.isEmpty ? null : previousVersion,
        'sourceUrl': (current['source_url'] ?? '').toString(),
        'files': current['files'] ?? const [],
        if (current['warnings'] is List) 'warnings': current['warnings'],
      });
    }
    entries.sort((a, b) => '${a['slug']}'.compareTo('${b['slug']}'));
    final payload = <String, dynamic>{
      'schema': kSkillLockSchema,
      'subject': subjectKey,
      'hub': (lock['hub'] ?? registry.hub.name).toString(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'skills': entries,
    };
    final file = lockFile;
    file.parent.createSync(recursive: true);
    // 先写临时文件再 rename：避免半截 JSON 破坏记账。
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(payload));
    if (file.existsSync()) file.deleteSync();
    tmp.renameSync(file.path);
  }

  Map<String, dynamic> _entry(Map<String, dynamic> lock, String slug) {
    final skills = lock['skills'];
    if (skills is! Map) return <String, dynamic>{};
    final entry = skills[slug];
    return entry is Map ? entry.cast<String, dynamic>() : <String, dynamic>{};
  }

  // ------------------------------------------------------------ 查询

  /// 列出本学科已装 skill（**以 `.hub-lock.json` 为权威**，DB 为镜像）。
  List<InstalledSkill> list({bool includeDisabled = true}) {
    final lock = _readLock();
    final skills = lock['skills'];
    if (skills is! Map) return const [];
    final out = <InstalledSkill>[];
    for (final key in skills.keys) {
      final slug = '$key';
      final entry = _entry(lock, slug);
      final current = entry['current'];
      if (current is! Map) continue;
      final enabled = entry['enabled'] != false;
      if (!enabled && !includeDisabled) continue;
      final previous = entry['previous'];
      out.add(InstalledSkill(
        slug: slug,
        record: SkillPackageRecord.fromJson(current.cast<String, dynamic>()),
        enabled: enabled,
        pinned: entry['pinned'] == true,
        pkgDir: pkgDir(slug).path,
        previous: previous is Map
            ? SkillPackageRecord.fromJson(previous.cast<String, dynamic>())
            : null,
        hub: (entry['hub'] ?? lock['hub'] ?? 'eduhub').toString(),
      ));
    }
    out.sort((a, b) => a.slug.compareTo(b.slug));
    return out;
  }

  InstalledSkill? bySlug(String slug) {
    for (final item in list()) {
      if (item.slug == slug) return item;
    }
    return null;
  }

  /// R2-6：检查本地包是否仍然完整。返回 null 表示完整；否则返回问题描述。
  ///
  /// 短路 `already:true` 之前必须过这一关——否则磁盘上的包被人删了几个文件时，
  /// 会一直"假装已安装"而模型读不到正文。
  static String? installedIntegrityProblem(InstalledSkill skill) {
    final dir = skill.pkgDir;
    if (dir.isEmpty) return 'pkgDir 为空';
    if (!Directory(dir).existsSync()) return '包目录不存在';
    final skillMd = File(p.join(dir, 'SKILL.md'));
    if (!skillMd.existsSync()) return 'SKILL.md 缺失';
    for (final file in skill.record.files) {
      if (file.path.isEmpty) continue;
      final target = File(p.join(dir, p.joinAll(file.path.split('/'))));
      if (!target.existsSync()) return '${file.path} 缺失';
      if (file.sha256.isEmpty) continue;
      try {
        final digest = sha256.convert(target.readAsBytesSync()).toString();
        if (digest.toLowerCase() != file.sha256.toLowerCase()) {
          return '${file.path} sha256 不一致';
        }
      } catch (error) {
        return '${file.path} 读取失败：$error';
      }
    }
    return null;
  }

  InstalledSkill require(String slug) {
    final found = bySlug(slug);
    if (found == null) {
      throw SkillImportError('not_installed', '该学科没有安装这个技能：$slug', status: 404);
    }
    return found;
  }

  /// 启用中的 skill 的**纯文本** playbook（供提示词注入；不执行任何文件）。
  List<Map<String, dynamic>> enabledPlaybooks() {
    final out = <Map<String, dynamic>>[];
    for (final item in list(includeDisabled: false)) {
      final file = File(p.join(item.pkgDir, 'SKILL.md'));
      if (!file.existsSync()) continue;
      out.add({
        'slug': item.slug,
        'name': item.displayName,
        'description': item.description,
        'content': file.readAsStringSync(),
        'unverified': item.unverified,
      });
    }
    return out;
  }

  // ------------------------------------------------------------ 安装

  /// 安装（或升级）一个 skill。**只做用户显式请求的这一次**：不自动更新、
  /// 不后台拉取。任一步失败都保留旧版本。
  ///
  /// F-6：同一 `学科/slug` 的并发安装第二次进入直接 409 `install_in_progress`
  /// （staging 目录互相隔离，不会产生半写）。
  /// F-7：同版本重装幂等——在**下载前**短路，返回 `already:true`。
  /// F-8：verify 判定 suspicious 且用户未显式确认 → 抛 [SkillNeedsConfirm]，
  /// server 层返回 200 + needs_confirm + stage='verify'。
  Future<InstalledSkill> install(
    String slug, {
    String? version,
    bool allowUnverified = true,
    bool allowSuspicious = false,
  }) async {
    _assertSlug(slug);
    final lockKey = '$subjectKey/$slug';
    if (!_installing.add(lockKey)) {
      throw SkillImportError(
        'install_in_progress',
        '该技能正在安装中：$slug（同一学科同一 slug 只允许一次安装）',
        status: 409,
      );
    }
    try {
      return await _installExclusive(
        slug,
        version: version,
        allowUnverified: allowUnverified,
        allowSuspicious: allowSuspicious,
      );
    } finally {
      _installing.remove(lockKey);
    }
  }

  /// 正在安装中的 `学科/slug` 集合（F-6）。
  static final Set<String> _installing = <String>{};

  /// F-6 测试用：当前是否有安装在进行。
  static bool installingForTests(String subjectKey, String slug) =>
      _installing.contains('$subjectKey/$slug');

  /// F-9 测试用：让 `remove()` 的 rename 阶段失败（验证 500 + 零改动分支）。
  static bool trashRenameFailureForTests = false;

  Future<InstalledSkill> _installExclusive(
    String slug, {
    String? version,
    bool allowUnverified = true,
    bool allowSuspicious = false,
  }) async {
    // 1) verify 裁决（请求失败 → unknown，降级但打标）。
    final verdict = await registry.verify(slug, version: version);
    if (verdict.requiresExplicitApproval && !allowSuspicious) {
      // F-8：这不是错误响应，而是"需要用户显式确认一次"。
      throw SkillNeedsConfirm(
        verdict,
        'registry 未认可该技能包（decision=${verdict.decision}）。'
        '${verdict.detail.isEmpty ? '' : '${verdict.detail} '}'
        '如确认要安装，请显式选择"仍然安装"。',
      );
    }
    // 裁决不可得（离线/端点异常）→ 默认降级安装，但记账里会标注 unverified。
    if (verdict.isUnverified && !allowUnverified) {
      throw SkillImportError(
        'unverified',
        '无法取得 registry 的裁决（${verdict.detail.isEmpty ? '请求失败' : verdict.detail}）；'
        '当前策略不允许降级安装。',
        status: 409,
      );
    }

    // 2) 详情（拿到逐文件 sha256 清单与元数据）。
    final detail = await registry.detail(slug, version: version, files: true);
    if (!detail.hasManifest) {
      throw SkillImportError(
          'no_manifest', 'registry 未提供完整性清单，拒绝安装（无法校验逐文件 sha256）');
    }

    // F-7：同版本重装 → 幂等短路（不下载、不落盘、不改记账）。
    // R2-6：短路前必须确认磁盘上的包仍然完整（SKILL.md 存在 + 逐文件 sha256
    // 与 lock 记账一致）；不完整则**走完整安装**并记 warning `repaired`。
    final existing = bySlug(slug);
    final repairProblem =
        (existing != null && version == null && existing.version == detail.version)
            ? installedIntegrityProblem(existing)
            : null;
    if (existing != null &&
        version == null &&
        existing.version == detail.version &&
        repairProblem == null) {
      return InstalledSkill(
        slug: slug,
        record: existing.record,
        enabled: existing.enabled,
        pinned: existing.pinned,
        pkgDir: existing.pkgDir,
        previous: existing.previous,
        hub: existing.hub,
        dbMirrored: existing.dbMirrored,
        already: true,
      );
    }
    if (repairProblem != null) {
      stderr.writeln('skill $slug 本地包不完整（$repairProblem），将重新安装并记 repaired');
    }

    // 3) 下载规范化 zip。
    final package = await registry.download(slug, version: version);
    final resolvedVersion =
        package.version.isNotEmpty ? package.version : detail.version;

    // 4) 解压 + 10 项防护 + sha256 清单校验，全部在 staging 里完成。
    final staging = Directory(
        p.join(_skillsRoot.path, slug, '.staging-${DateTime.now().microsecondsSinceEpoch}'));
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    staging.createSync(recursive: true);

    SkillPackageRecord? staged;
    final warnings = <String>[];
    if (repairProblem != null) warnings.add('repaired');
    try {
      staged = _extractAndValidate(
        package.bytes,
        staging,
        slug: slug,
        version: resolvedVersion,
        detail: detail,
        verdict: verdict,
        warnings: warnings,
      );
    } catch (_) {
      _deleteQuietly(staging);
      _cleanupSlugDir(slug);
      rethrow;
    }

    // 5) 原子替换 + 记账；失败回滚到旧版本。
    final lock = _readLock();
    final backup = _entry(lock, slug);
    final previousEntry = backup.isEmpty ? null : backup['current'];
    final previousEnabled = backup['enabled'] != false;

    final swapped = _atomicSwap(slug, staging);
    try {
      lock['skills'][slug] = <String, dynamic>{
        'hub': registry.hub.name,
        'enabled': previousEnabled,
        'pinned': backup['pinned'] == true,
        'current': staged.toJson(),
        if (previousEntry is Map) 'previous': previousEntry,
      };
      _writeLock(lock);
    } catch (error) {
      // 记账失败 → 把旧版本换回去，保证"文件与记账一致"且旧版本可用。
      if (swapped) _restoreAfterFailure(slug);
      throw SkillImportError('io', '写入记账失败：$error', status: 500);
    }

    final mirrored = _mirrorToDb(
      slug: slug,
      staged: staged,
      enabled: previousEnabled,
      pinned: backup['pinned'] == true,
    );
    if (!mirrored) warnings.add('db_mirror_failed');

    return InstalledSkill(
      slug: slug,
      record: staged,
      enabled: previousEnabled,
      pinned: backup['pinned'] == true,
      pkgDir: pkgDir(slug).path,
      previous: previousEntry is Map
          ? SkillPackageRecord.fromJson(previousEntry.cast<String, dynamic>())
          : null,
      hub: registry.hub.name,
      dbMirrored: mirrored,
    );
  }

  /// 一键本地回退：把 `pkg` 与 `prev` 互换（离线可用，不联网）。
  InstalledSkill rollback(String slug) {
    _assertSlug(slug);
    require(slug); // 未安装 → 404 not_installed（比"没有上一版"更准确）
    final lock = _readLock();
    final entry = _entry(lock, slug);
    final current = entry['current'];
    final previous = entry['previous'];
    if (current is! Map || previous is! Map) {
      throw SkillImportError('no_previous', '没有可回退的上一版本：$slug', status: 409);
    }
    if (!prevDir(slug).existsSync()) {
      throw SkillImportError('no_previous', '上一版本快照已丢失：$slug', status: 409);
    }

    final currentRecord = SkillPackageRecord.fromJson(current.cast<String, dynamic>());
    final previousRecord = SkillPackageRecord.fromJson(previous.cast<String, dynamic>());

    final pkg = pkgDir(slug);
    final prev = prevDir(slug);
    final holding = Directory('${pkg.path}.swap');
    _deleteQuietly(holding);
    try {
      if (pkg.existsSync()) pkg.renameSync(holding.path);
      prev.renameSync(pkg.path);
      holding.renameSync(prev.path);
    } catch (error) {
      // 尽力恢复到交换前状态：prev 缺了就先把 pkg 挪回 prev。
      try {
        if (!prev.existsSync() && pkg.existsSync()) pkg.renameSync(prev.path);
        if (holding.existsSync()) {
          _deleteQuietly(pkg);
          holding.renameSync(pkg.path);
        }
      } catch (_) {}
      throw SkillImportError('io', '回退失败：$error', status: 500);
    }

    final enabled = entry['enabled'] != false;
    final pinned = entry['pinned'] == true;
    lock['skills'][slug] = <String, dynamic>{
      'hub': (entry['hub'] ?? lock['hub'] ?? 'eduhub').toString(),
      'enabled': enabled,
      'pinned': pinned,
      'current': previousRecord.toJson(),
      'previous': currentRecord.toJson(),
    };
    try {
      _writeLock(lock);
    } catch (error) {
      // 记账失败 → 把文件换回去，绝不留下"文件与记账不一致"的状态。
      _deleteQuietly(holding);
      try {
        pkg.renameSync(holding.path);
        prev.renameSync(pkg.path);
        holding.renameSync(prev.path);
      } catch (_) {}
      throw SkillImportError('io', '回退记账失败：$error', status: 500);
    }

    _mirrorToDb(slug: slug, staged: previousRecord, enabled: enabled, pinned: pinned);
    return InstalledSkill(
      slug: slug,
      record: previousRecord,
      enabled: enabled,
      pinned: pinned,
      pkgDir: pkg.path,
      previous: currentRecord,
      hub: (entry['hub'] ?? 'eduhub').toString(),
    );
  }

  /// 启用/停用（**学科级**：只影响本学科）。
  InstalledSkill setEnabled(String slug, bool enabled) {
    _assertSlug(slug);
    require(slug);
    final lock = _readLock();
    final entry = _entry(lock, slug);
    entry['enabled'] = enabled;
    lock['skills'][slug] = entry;
    _writeLock(lock);
    final current = entry['current'];
    final record = current is Map
        ? SkillPackageRecord.fromJson(current.cast<String, dynamic>())
        : null;
    if (record != null) {
      _mirrorToDb(
        slug: slug,
        staged: record,
        enabled: enabled,
        pinned: entry['pinned'] == true,
      );
    }
    return require(slug);
  }

  /// F-5：版本锁定开关（pinned=1 → 跳过更新检查提示，也不允许直接覆盖更新）。
  InstalledSkill setPinned(String slug, bool pinned) {
    _assertSlug(slug);
    require(slug);
    final lock = _readLock();
    final entry = _entry(lock, slug);
    entry['pinned'] = pinned;
    lock['skills'][slug] = entry;
    _writeLock(lock);
    final current = entry['current'];
    final record = current is Map
        ? SkillPackageRecord.fromJson(current.cast<String, dynamic>())
        : null;
    if (record != null) {
      _mirrorToDb(
        slug: slug,
        staged: record,
        enabled: entry['enabled'] != false,
        pinned: pinned,
      );
    }
    return require(slug);
  }

  /// 卸载：删除包目录与记账（**不动** registry，也不动其它学科）。
  ///
  /// F-9：目录删除**不得静默成功**。先原子 rename 成 `.trash-<ts>`（rename 失败
  /// = 什么都没动，抛 500，记账保持原样可重试）；rename 成功后才动记账与索引，
  /// 残余的 trash 清理结果如实回报（`dir_delete_pending`）。
  Map<String, dynamic> remove(String slug) {
    _assertSlug(slug);
    final existed = bySlug(slug) != null;
    _cleanupTrash();
    var pendingDelete = false;
    final dir = Directory(p.join(_skillsRoot.path, slug));
    if (dir.existsSync()) {
      final trash = Directory(
          p.join(_skillsRoot.path, '.trash-${DateTime.now().microsecondsSinceEpoch}'));
      try {
        if (trashRenameFailureForTests) {
          throw FileSystemException('注入的 rename 失败（测试用）', dir.path);
        }
        dir.renameSync(trash.path);
      } catch (error) {
        throw SkillImportError(
          'remove_failed',
          '技能目录被占用，卸载未生效（记账与文件都保持原样，可重试）：$error',
          status: 500,
        );
      }
      _deleteQuietly(trash);
      pendingDelete = trash.existsSync();
    }
    final lock = _readLock();
    final skills = lock['skills'];
    if (skills is Map) skills.remove(slug);
    _writeLock(lock);
    _removeDbRow(slug);
    return {
      'ok': true,
      'slug': slug,
      'removed': existed,
      'dir_delete_pending': pendingDelete,
    };
  }

  /// 清理历史遗留的 `.trash-*` 目录（best-effort，失败下次再试）。
  void _cleanupTrash() {
    final root0 = root;
    if (!root0.existsSync()) return;
    for (final entity in root0.listSync()) {
      if (entity is! Directory) continue;
      if (!p.basename(entity.path).startsWith('.trash-')) continue;
      _deleteQuietly(entity);
    }
  }

  /// F-13（AC-05 断言 7）：以 `.hub-lock.json` 为权威重建 `subject_skills` 索引。
  /// 返回是否**确实发生了重建**（索引缺失或版本不符）。
  bool rebuildIndex() {
    final lock = _readLock();
    final skills = lock['skills'];
    if (skills is! Map) return false;
    var rebuilt = false;
    for (final key in skills.keys) {
      final slug = '$key';
      final entry = _entry(lock, slug);
      final current = entry['current'];
      if (current is! Map) continue;
      final record = SkillPackageRecord.fromJson(current.cast<String, dynamic>());
      final expectedEnabled = entry['enabled'] != false;
      final expectedPinned = entry['pinned'] == true;
      final row = _dbRow(slug);
      if (row != null &&
          '${row['version']}' == record.version &&
          (row['enabled'] == 1) == expectedEnabled &&
          (row['pinned'] == 1) == expectedPinned) {
        continue;
      }
      final ok = _mirrorToDb(
        slug: slug,
        staged: record,
        enabled: expectedEnabled,
        pinned: expectedPinned,
      );
      if (ok) rebuilt = true;
    }
    return rebuilt;
  }

  /// 读索引行（诊断/重建判定用）。
  Map<String, Object?>? _dbRow(String slug) {
    try {
      final handle = SubjectStore.open(subjectKey);
      final rows = handle.rows('SELECT * FROM subject_skills WHERE slug = ?', [slug]);
      return rows.isEmpty ? null : rows.first;
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------ 内部：解压与校验

  SkillPackageRecord _extractAndValidate(
    Uint8List bytes,
    Directory staging, {
    required String slug,
    required String version,
    required SkillDetail detail,
    required SkillVerdict verdict,
    required List<String> warnings,
  }) {
    final archive = _ZipArchive.parse(bytes);

    // 文件数上限（读目录即可判定，先于任何解压）。
    if (archive.entries.length > SkillImportLimits.maxFiles) {
      throw SkillImportError('too_many_files',
          '压缩包内文件过多（${archive.entries.length} > ${SkillImportLimits.maxFiles}）');
    }

    // F-12：先规范化一遍路径，识别"单层壳目录"（zip 里所有文件都在同一个顶层
    // 目录下且根层没有 SKILL.md）→ 拍平，避免把壳目录当包根。
    final normalized = <String, String>{};
    final topSegments = <String>{};
    var rootHasSkillMd = false;
    for (final entry in archive.entries) {
      if (entry.name.endsWith('/') || entry.isSymlink) continue;
      final safeRel = _safeRelativePath(entry.name);
      if (safeRel == null || safeRel == '.') continue;
      normalized[entry.name] = safeRel;
      if (safeRel == 'SKILL.md') rootHasSkillMd = true;
      topSegments.add(safeRel.split('/').first);
    }
    final shell = (!rootHasSkillMd && topSegments.length == 1) ? topSegments.first : '';
    String flatten(String rel) =>
        (shell.isNotEmpty && rel.startsWith('$shell/')) ? rel.substring(shell.length + 1) : rel;

    // 逐文件 sha256 清单也要按同样的规则拍平比对，否则"壳目录"包必然误报不一致。
    final manifest = <String, SkillManifestFile>{
      for (final file in detail.files)
        flatten(file.path): SkillManifestFile(
          path: flatten(file.path),
          size: file.size,
          sha256: file.sha256,
          contentType: file.contentType,
        ),
    };
    if (shell.isNotEmpty && detail.files.every((file) => file.path.startsWith('$shell/'))) {
      warnings.add('flattened_shell_dir');
    }

    final written = <String, SkillManifestFile>{};
    var totalBytes = 0;
    var hasScripts = false;

    for (final entry in archive.entries) {
      // 符号链接：整体拒绝（链接可指向包外内容）。
      if (entry.isSymlink) {
        throw SkillImportError('symlink', '压缩包含符号链接，已整体拒绝：${entry.name}');
      }
      if (entry.name.endsWith('/')) continue; // 目录项

      final safeRaw = _safeRelativePath(entry.name);
      if (safeRaw == null) {
        // dotfile / __MACOSX：按生态惯例静默跳过（不落盘）。
        continue;
      }
      if (safeRaw == '.') continue;
      // 拍平单层壳目录（F-12）。
      final safeRel = (shell.isNotEmpty && safeRaw.startsWith('$shell/'))
          ? safeRaw.substring(shell.length + 1)
          : safeRaw;
      if (safeRel.isEmpty) continue;

      final suffix = SkillImportLimits.suffixOf(safeRel);
      if (!SkillImportLimits.allowedSuffixes.contains(suffix)) {
        throw SkillImportError('suffix_not_allowed',
            '文件类型不在白名单内：$safeRel（$suffix）');
      }
      if (SkillImportLimits.scriptSuffixes.contains(suffix)) hasScripts = true;

      final data = archive.read(entry, maxBytes: SkillImportLimits.maxFileBytes);
      totalBytes += data.length;
      if (totalBytes > SkillImportLimits.maxTotalBytes) {
        throw SkillImportError('too_large',
            '解压总量超出上限（>${SkillImportLimits.maxTotalBytes ~/ 1000000}MB）');
      }

      final target = File(p.join(staging.path, p.joinAll(safeRel.split('/'))));
      target.parent.createSync(recursive: true);
      target.writeAsBytesSync(data, flush: true);

      written[safeRel] = SkillManifestFile(
        path: safeRel,
        size: data.length,
        sha256: sha256.convert(data).toString(),
        contentType: entry.name.endsWith('.md') ? 'text/markdown' : '',
      );
    }

    if (written.isEmpty) {
      throw SkillImportError('bad_zip', '压缩包内没有可安装的文件');
    }
    if (!written.containsKey('SKILL.md')) {
      throw SkillImportError('bad_frontmatter', '包根级缺少 SKILL.md');
    }

    // ---- 逐文件 sha256 清单校验（任何不匹配即拒绝）----
    final missing = <String>[];
    final mismatched = <String>[];
    for (final entry in manifest.entries) {
      final actual = written[entry.key];
      if (actual == null) {
        missing.add(entry.key);
        continue;
      }
      if (actual.sha256.toLowerCase() != entry.value.sha256.toLowerCase()) {
        mismatched.add(entry.key);
      }
    }
    final extra = written.keys.where((key) => !manifest.containsKey(key)).toList();
    if (missing.isNotEmpty || mismatched.isNotEmpty || extra.isNotEmpty) {
      final parts = <String>[];
      if (mismatched.isNotEmpty) parts.add('sha256 不一致：${mismatched.take(3).join(', ')}');
      if (missing.isNotEmpty) parts.add('清单内文件缺失：${missing.take(3).join(', ')}');
      if (extra.isNotEmpty) parts.add('包内多出未登记文件：${extra.take(3).join(', ')}');
      throw SkillImportError('sha256_mismatch', '完整性校验不通过（${parts.join('；')}）');
    }

    // ---- F-2：包内文本内容扫描（sha256 只证明"与 registry 清单一致"）----
    final scanHit = _scanStagedContent(staging, written.keys);
    if (scanHit != null) {
      throw SkillImportError(
        'content_blocked',
        '包内文本命中高危模式，已整包拒绝：${scanHit.message}',
        status: 400,
      );
    }

    // ---- frontmatter 适配：剥离 always: ----
    final skillMd = File(p.join(staging.path, 'SKILL.md'));
    final original = skillMd.readAsStringSync();
    final frontmatter = SkillFrontmatter.parse(original);
    // F-12：`name` 强制为 slug（slug 是目录/记账/索引的唯一键，前端与注入
    // 都按 slug 取；frontmatter 里自报的名字不参与身份判定）。
    final declaredName = frontmatter.name.trim();
    final effectiveName = declaredName == slug ? declaredName : slug;
    if (declaredName.isNotEmpty && declaredName != slug) {
      warnings.add('name_forced_to_slug');
    }
    final stripped = frontmatter.hadAlways;
    final adapted = stripped ? frontmatter.rebuild(stripAlways: true) : original;
    if (stripped) {
      skillMd.writeAsStringSync(adapted, flush: true);
      warnings.add('stripped_always');
      // 记账里的 `files` 描述的是**磁盘上的实际内容**，所以适配后要重算
      // SKILL.md 的哈希；registry 原始清单的摘要另存为 bundleSha256。
      final adaptedBytes = utf8.encode(adapted);
      written['SKILL.md'] = SkillManifestFile(
        path: 'SKILL.md',
        size: adaptedBytes.length,
        sha256: sha256.convert(adaptedBytes).toString(),
        contentType: 'text/markdown',
      );
    }

    // bundleSha256 = **registry 规范化重打包**的清单摘要（provenance）。
    final registryDigest = _bundleDigest(manifest.values.toList());
    return SkillPackageRecord(
      version: version,
      name: effectiveName,
      displayName: declaredName.isEmpty ? effectiveName : declaredName,
      description: frontmatter.description,
      bundleSha256: registryDigest,
      files: written.values.toList()
        ..sort((a, b) => a.path.compareTo(b.path)),
      verdictStatus: verdict.status,
      verdictDecision: verdict.decision,
      installedAt: DateTime.now().toUtc().toIso8601String(),
      owner: detail.owner,
      license: detail.license,
      sourceUrl: registry.hub.skillWebUrl(slug),
      hasScripts: hasScripts,
      warnings: warnings,
    );
  }

  /// 规范化相对路径。返回 `null` 表示应静默跳过（dotfile / `__MACOSX`）。
  /// 返回 `'.'` 表示目录自身。
  static String? _safeRelativePath(String raw) {
    if (raw.isEmpty) {
      throw SkillImportError('zip_slip', '压缩包内含空文件名');
    }
    if (raw.contains('\u0000')) {
      throw SkillImportError('zip_slip', '压缩包内含非法字符：$raw');
    }
    var name = raw.replaceAll('\\', '/');
    if (name.startsWith('/') || name.startsWith('//')) {
      throw SkillImportError('zip_slip', '压缩包含绝对路径，已拒绝：$raw');
    }
    if (RegExp(r'^[A-Za-z]:').hasMatch(name)) {
      throw SkillImportError('zip_slip', '压缩包含盘符路径，已拒绝：$raw');
    }
    final parts = <String>[];
    for (final segment in name.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        throw SkillImportError('zip_slip', '压缩包含路径穿越（..），已拒绝：$raw');
      }
      parts.add(segment);
    }
    if (parts.isEmpty) return '.';
    if (parts.first == '__MACOSX') return null;
    if (parts.any((segment) => segment.startsWith('.'))) return null;
    return parts.join('/');
  }

  static String _bundleDigest(Iterable<SkillManifestFile> files) {
    final lines = files.map((f) => '${f.path}:${f.sha256}').toList()..sort();
    return sha256.convert(utf8.encode(lines.join('\n'))).toString();
  }

  /// F-2：扫描 staging 里的**文本**文件（图片/PDF 跳过）找高危模式。
  static SkillScanHit? _scanStagedContent(Directory staging, Iterable<String> relativePaths) {
    final texts = <String, String>{};
    for (final rel in relativePaths) {
      if (!SkillImportLimits.textScanSuffixes.contains(SkillImportLimits.suffixOf(rel))) {
        continue;
      }
      final file = File(p.join(staging.path, p.joinAll(rel.split('/'))));
      if (!file.existsSync()) continue;
      try {
        texts[rel] = file.readAsStringSync();
      } catch (_) {
        // 非 UTF-8 的"文本"文件：跳过内容扫描（后缀/大小/CRC 仍然校验过）。
      }
    }
    return SkillContentScanner.scanFiles(textByRelativePath: texts);
  }

  static void _assertSlug(String slug) {
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]{0,127}$').hasMatch(slug)) {
      throw SkillImportError('invalid_slug', '非法 slug：$slug');
    }
  }

  // ------------------------------------------------------------ 内部：原子替换

  /// 把 `pkg` 换成 [staging]，旧版本挪到 `prev`。返回旧包是否被移动过，
  /// 供失败时判定是否需要换回。
  bool _atomicSwap(String slug, Directory staging) {
    final pkg = pkgDir(slug);
    final prev = prevDir(slug);
    pkg.parent.createSync(recursive: true);

    // 清掉更早的 prev（只保留最近一版，够一键回退）。
    _deleteQuietly(prev);

    var pkgSwapped = false;
    try {
      if (pkg.existsSync()) {
        pkg.renameSync(prev.path);
        pkgSwapped = true;
      }
      staging.renameSync(pkg.path);
    } catch (error) {
      // 失败：把旧版本换回原位，绝不留下半截状态。
      _restoreAfterFailure(slug);
      _deleteQuietly(staging);
      throw SkillImportError('io', '写入技能包失败：$error', status: 500);
    }
    return pkgSwapped;
  }

  /// 失败恢复：把 `prev` 换回 `pkg`（旧版本必须**逐字节**保留）。
  void _restoreAfterFailure(String slug) {
    final pkg = pkgDir(slug);
    final prev = prevDir(slug);
    try {
      if (pkg.existsSync()) _deleteQuietly(pkg);
      if (prev.existsSync()) prev.renameSync(pkg.path);
    } catch (_) {
      // 恢复尽力而为；调用方会抛出原始错误。
    }
  }

  /// 导入失败后清掉空的 `<slug>/` 外壳，避免在数据目录里留下痕迹。
  void _cleanupSlugDir(String slug) {
    try {
      final dir = Directory(p.join(_skillsRoot.path, slug));
      if (dir.existsSync() && dir.listSync().isEmpty) dir.deleteSync();
    } catch (_) {}
  }

  static void _deleteQuietly(FileSystemEntity entity) {
    try {
      if (entity is Directory) {
        if (entity.existsSync()) entity.deleteSync(recursive: true);
      } else if (entity is File) {
        if (entity.existsSync()) entity.deleteSync();
      }
    } catch (_) {}
  }

  // ------------------------------------------------------------ 内部：DB 镜像

  /// 把记账镜像进本学科库的 `subject_skills`（t3 已建好表）。
  /// **失败不致命**：锁文件才是权威，镜像只是给 SQL/UI 用的查询面。
  bool _mirrorToDb({
    required String slug,
    required SkillPackageRecord staged,
    required bool enabled,
    required bool pinned,
  }) {
    try {
      return SkillsDbMirror.upsert(
        subjectKey: subjectKey,
        slug: slug,
        hub: registry.hub.name,
        record: staged,
        enabled: enabled,
        pinned: pinned,
        filesRelPath: pkgDir(slug).path,
      );
    } catch (_) {
      return false;
    }
  }

  void _removeDbRow(String slug) {
    try {
      SkillsDbMirror.remove(subjectKey: subjectKey, slug: slug);
    } catch (_) {}
  }

  void close() => registry.close();
}

// ===========================================================================
// subject_skills 镜像（t3 已建表；锁文件才是权威）
// ===========================================================================

/// 把已装 skill 记录镜像进**本学科库**的 `subject_skills` 表。
///
/// 为什么要镜像：`.hub-lock.json` 是记账与回退的权威来源，但 UI/后续的
/// 提示词拼装更习惯用 SQL。镜像失败不影响安装结果（只记一条 warning）。
class SkillsDbMirror {
  const SkillsDbMirror._();

  static bool upsert({
    required String subjectKey,
    required String slug,
    required String hub,
    required SkillPackageRecord record,
    required bool enabled,
    required bool pinned,
    required String filesRelPath,
  }) {
    final database = SubjectStore.open(subjectKey).database;
    final now = Db.nowIso();
    final skillMd = _readSkillMd(filesRelPath);
    final relPath = _relativeToData(filesRelPath);

    // 一个 slug 只保留一行（最新版本）；旧版本目录仍以 `prev` 快照存在。
    database.execute(
      'DELETE FROM subject_skills WHERE slug = ? AND version <> ?',
      [slug, record.version],
    );
    database.execute(
      '''
      INSERT INTO subject_skills(
        slug, version, name, display_name, description, hub, source_url, sha256,
        files_rel_path, skill_md, enabled, pinned, installed_at, updated_at
      ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(slug, version) DO UPDATE SET
        name=excluded.name, display_name=excluded.display_name,
        description=excluded.description, hub=excluded.hub,
        source_url=excluded.source_url, sha256=excluded.sha256,
        files_rel_path=excluded.files_rel_path, skill_md=excluded.skill_md,
        enabled=excluded.enabled, pinned=excluded.pinned,
        installed_at=excluded.installed_at, updated_at=excluded.updated_at
      ''',
      [
        slug,
        record.version,
        slug, // F-12：身份名 = slug
        record.displayName.isEmpty ? slug : record.displayName,
        record.description,
        hub,
        record.sourceUrl,
        record.bundleSha256,
        relPath,
        skillMd,
        enabled ? 1 : 0,
        pinned ? 1 : 0,
        record.installedAt.isEmpty ? now : record.installedAt,
        now,
      ],
    );
    return true;
  }

  static void remove({required String subjectKey, required String slug}) {
    final database = SubjectStore.open(subjectKey).database;
    database.execute('DELETE FROM subject_skills WHERE slug = ?', [slug]);
  }

  static String _readSkillMd(String pkgDir) {
    try {
      final file = File(p.join(pkgDir, 'SKILL.md'));
      if (file.existsSync()) return file.readAsStringSync();
    } catch (_) {}
    return '';
  }

  static String _relativeToData(String absolute) {
    try {
      if (AppPaths.ready) return AppPaths.relativeToData(absolute);
    } catch (_) {}
    return absolute;
  }
}