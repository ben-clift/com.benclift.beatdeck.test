import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Simple mode (the default in the friends build): one screen, pick a vibe,
/// tap Start. Pro mode is the full BeatDeck.
class AppMode {
  static final ValueNotifier<bool> simple = ValueNotifier<bool>(true);

  static Future<void> load() async {
    try {
      simple.value = (await SharedPreferences.getInstance()).getBool('simple_mode_v1') ?? true;
    } catch (_) {}
    applyOrientation();
  }

  static Future<void> set(bool v) async {
    simple.value = v;
    applyOrientation();
    try {
      await (await SharedPreferences.getInstance()).setBool('simple_mode_v1', v);
    } catch (_) {}
  }

  static void applyOrientation() {
    SystemChrome.setPreferredOrientations(simple.value
        ? DeviceOrientation.values
        : const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  }
}
