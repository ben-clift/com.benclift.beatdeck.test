import 'package:shared_preferences/shared_preferences.dart';

/// The friends test build stops working [days] days after it was built.
/// The build time is stamped in by the build ([BUILD_EPOCH]); a build without
/// it never expires. Winding the phone's clock back does not help: the latest
/// time the app has ever seen is remembered.
class Expiry {
  static const int _built = int.fromEnvironment('BUILD_EPOCH', defaultValue: 0);
  static const int days = 30;

  static DateTime? get builtAt => _built == 0 ? null : DateTime.fromMillisecondsSinceEpoch(_built * 1000);
  static DateTime? get expiresAt => builtAt?.add(const Duration(days: days));

  static Future<DateTime> _now() async {
    var now = DateTime.now();
    try {
      final p = await SharedPreferences.getInstance();
      final seen = p.getInt('expiry_last_seen') ?? 0;
      if (seen > now.millisecondsSinceEpoch) {
        now = DateTime.fromMillisecondsSinceEpoch(seen);
      } else {
        await p.setInt('expiry_last_seen', now.millisecondsSinceEpoch);
      }
    } catch (_) {}
    return now;
  }

  static Future<bool> expired() async {
    final e = expiresAt;
    if (e == null) return false;
    return (await _now()).isAfter(e);
  }

  /// "2 days left", "5 hours left", or null for a build that never expires.
  static Future<String?> remaining() async {
    final e = expiresAt;
    if (e == null) return null;
    final left = e.difference(await _now());
    if (left.isNegative) return 'Expired';
    if (left.inHours >= 48) return '${left.inDays} days left';
    if (left.inHours >= 1) return '${left.inHours} hours left';
    return '${left.inMinutes} minutes left';
  }
}
