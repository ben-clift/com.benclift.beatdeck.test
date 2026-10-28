import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Admin switch for Ben's own phone. Typing the code in Settings shows the
/// "Apps" buttons that open each part of BeatDeck. It only reveals buttons;
/// nothing private is protected by it (the code's hash is in the app).
class Admin {
  static const _key = 'admin_unlocked_v1';
  static const _codeHash = '4e914ee5847d91384e4eb09af8f6ae52700d3e26b1938d3688c603906d3626ef';

  static final ValueNotifier<bool> on = ValueNotifier<bool>(false);

  static bool matches(String code) =>
      sha256.convert(utf8.encode(code.trim().toLowerCase())).toString() == _codeHash;

  static Future<void> load() async {
    try {
      on.value = (await SharedPreferences.getInstance()).getBool(_key) ?? false;
    } catch (_) {}
  }

  /// True when the code was right.
  static Future<bool> unlock(String code) async {
    if (!matches(code)) return false;
    on.value = true;
    try {
      await (await SharedPreferences.getInstance()).setBool(_key, true);
    } catch (_) {}
    return true;
  }

  static Future<void> lock() async {
    on.value = false;
    try {
      await (await SharedPreferences.getInstance()).setBool(_key, false);
    } catch (_) {}
  }
}
