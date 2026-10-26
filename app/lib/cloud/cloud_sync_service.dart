import 'dart:convert';
import 'dart:typed_data';

import 'package:supabase/supabase.dart';

/// 方案 B 的 Supabase 客户端封装。
///
/// 只使用 anon/publishable key；service_role 绝不能进入客户端。
/// 当前阶段提供配置、连接测试、登录、设备注册；快照上传/恢复在后续阶段接入。
class CloudSyncService {
  CloudSyncService();

  /// 进程内单例；设置页、快照、退出同步共用同一个会话。
  static final CloudSyncService instance = CloudSyncService();

  SupabaseClient? _client;
  String? _deviceId;

  bool get configured => _client != null;
  bool get signedIn => _client?.auth.currentUser != null;
  String? get userId => _client?.auth.currentUser?.id;
  String? get userEmail => _client?.auth.currentUser?.email;
  String? get deviceId => _deviceId;
  String? get refreshToken => _client?.auth.currentSession?.refreshToken;

  SupabaseClient get client {
    final value = _client;
    if (value == null) {
      throw StateError('还没有配置 Supabase URL/Key');
    }
    return value;
  }

  void configure({required String url, required String key}) {
    final normalizedUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
    final normalizedKey = key.trim();
    if (normalizedUrl.isEmpty || normalizedKey.isEmpty) {
      throw ArgumentError('Supabase URL 和 Key 不能为空');
    }
    final parsed = Uri.tryParse(normalizedUrl);
    if (parsed == null || parsed.scheme != 'https' || parsed.host.isEmpty) {
      throw ArgumentError('Supabase URL 必须是 https://xxx.supabase.co');
    }
    if (normalizedKey.toLowerCase().contains('service_role')) {
      throw ArgumentError('不能用 service_role key，请用 anon/publishable key');
    }
    _client = SupabaseClient(normalizedUrl, normalizedKey);
  }

  /// 登录后探测 Storage 写入/读取/删除权限，提前发现 bucket 策略 403。
  Future<void> probeStorage() async {
    final user = client.auth.currentUser;
    if (user == null) throw StateError('请先登录');
    final bucket = client.storage.from('loop-snapshots');
    final path = '${user.id}/.probe-${DateTime.now().millisecondsSinceEpoch}.txt';
    await bucket.uploadBinary(
      path,
      Uint8List.fromList(utf8.encode('loop-probe')),
      fileOptions: const FileOptions(upsert: true, contentType: 'text/plain'),
    );
    try {
      final data = await bucket.download(path);
      if (utf8.decode(data) != 'loop-probe') {
        throw StateError('Storage 探测内容不一致');
      }
    } finally {
      await bucket.remove([path]);
    }
  }

  /// 只读探测：能访问 profiles 表即说明 URL/Key/Data API 正常。
  /// 未登录时 anon 被 RLS 限制为 0 行，但不会 404。
  Future<void> testConnection() async {
    await client.from('profiles').select('id').limit(1);
  }

  Future<User> signIn({
    required String email,
    required String password,
  }) async {
    final response = await client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
    final user = response.user;
    if (user == null) {
      throw StateError('登录失败：没有返回用户');
    }
    return user;
  }

  Future<void> restoreSession(String refreshToken) async {
    if (refreshToken.trim().isEmpty) return;
    await client.auth.setSession(refreshToken.trim());
  }

  Future<void> signOut() async {
    await client.auth.signOut();
  }

  /// 注册/更新当前设备；id 由客户端持久化，同一台设备复用。
  Future<void> registerDevice({
    required String deviceId,
    required String deviceName,
  }) async {
    final user = client.auth.currentUser;
    if (user == null) {
      throw StateError('请先登录');
    }
    _deviceId = deviceId;
    await client.from('devices').upsert({
      'id': deviceId,
      'user_id': user.id,
      'name': deviceName.trim().isEmpty ? 'Windows PC' : deviceName.trim(),
      'platform': 'windows',
      'last_seen_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// 读取云端最新快照元数据；当前阶段只用于状态展示。
  Future<Map<String, dynamic>?> latestSnapshot() async {
    final rows = await client
        .from('snapshots')
        .select()
        .eq('status', 'ready')
        .order('created_at', ascending: false)
        .limit(1);
    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(rows.first as Map);
  }
}
