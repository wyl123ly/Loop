/// 应用版本与语义版本比较（不依赖 Flutter，后端与界面共用）。
class AppVersion {
  static const current = '0.8.5';
  static const repo = 'wyl123ly/Loop';
  static const assetName = 'Loop-Desktop-win64.zip';

  static String normalize(String raw) {
    var value = raw.trim();
    if (value.startsWith('v') || value.startsWith('V')) value = value.substring(1);
    final plus = value.indexOf('+');
    if (plus >= 0) value = value.substring(0, plus);
    return value;
  }

  static List<int> _numbers(String value) {
    final clean = normalize(value).split('-').first;
    final parts = clean.split('.');
    return [
      for (var i = 0; i < 3; i++)
        i < parts.length ? (int.tryParse(parts[i]) ?? 0) : 0,
    ];
  }

  /// 返回 -1 / 0 / 1。
  static int compare(String a, String b) {
    final left = _numbers(a);
    final right = _numbers(b);
    for (var i = 0; i < 3; i++) {
      if (left[i] != right[i]) return left[i] > right[i] ? 1 : -1;
    }
    final aPre = normalize(a).contains('-');
    final bPre = normalize(b).contains('-');
    if (aPre != bPre) return aPre ? -1 : 1;
    return 0;
  }

  static bool isNewer(String candidate, [String currentVersion = current]) =>
      compare(candidate, currentVersion) > 0;
}
