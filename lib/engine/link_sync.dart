import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../debug/debug_log.dart';
import '../state/dj_controller.dart';
import 'link_logic.dart';

/// Ableton Link tempo sync. OFF by default; while off nothing runs and the app
/// behaves exactly as before. Switch it on in Settings.
///
/// What it does: shares tempo with Ableton Live and other Link apps on the same
/// Wi-Fi. The master deck (or the playing deck when there is no master) follows
/// the session tempo, and moving that deck's tempo moves the session.
/// Not yet: beat phase alignment, start/stop sync.
class LinkSync extends ChangeNotifier {
  LinkSync._();
  static final LinkSync instance = LinkSync._();

  static const _prefKey = 'link_sync_v1';
  static const _mc = MethodChannel('sidedeck/audio');

  DjController? _dj;
  Timer? _timer;
  DynamicLibrary? _lib;
  int Function(int)? _enable;
  int Function()? _peers;
  double Function()? _tempo;
  void Function(double)? _setTempo;

  bool enabled = false;
  int peers = 0;
  double tempo = 0;
  String status = 'Off';

  double _lastLink = 0;
  double _lastDeck = 0;

  /// Call once after the controller exists. Restores the saved choice.
  Future<void> attach(DjController dj) async {
    _dj = dj;
    try {
      final on = (await SharedPreferences.getInstance()).getBool(_prefKey) ?? false;
      if (on) await setEnabled(true, save: false);
    } catch (e) {
      DebugLog.add('link', 'could not restore Link setting: $e');
    }
  }

  bool _bind() {
    if (_enable != null) return true;
    try {
      final lib = Platform.isAndroid
          ? DynamicLibrary.open('libdj_engine.so')
          : DynamicLibrary.process();
      _lib = lib;
      _enable = lib.lookupFunction<Int32 Function(Int32), int Function(int)>('link_enable');
      _peers = lib.lookupFunction<Int32 Function(), int Function()>('link_peers');
      _tempo = lib.lookupFunction<Double Function(), double Function()>('link_tempo');
      _setTempo = lib.lookupFunction<Void Function(Double), void Function(double)>('link_set_tempo');
      return true;
    } catch (e) {
      DebugLog.add('link', 'Link is not in this build: $e');
      return false;
    }
  }

  Future<void> setEnabled(bool on, {bool save = true}) async {
    if (on) {
      if (!_bind()) {
        status = 'Not available in this build';
        enabled = false;
        notifyListeners();
        return;
      }
      try {
        await _mc.invokeMethod('linkMulticast', {'on': true});
      } catch (e) {
        DebugLog.add('link', 'multicast lock failed: $e');
      }
      final ok = _enable!(1) == 1;
      enabled = ok;
      status = ok ? 'On, looking for other apps' : 'Could not start';
      _lastLink = 0;
      _lastDeck = 0;
      _timer?.cancel();
      if (ok) {
        _timer = Timer.periodic(const Duration(milliseconds: 250), (_) => _poll());
      }
    } else {
      _timer?.cancel();
      _timer = null;
      try {
        _enable?.call(0);
        await _mc.invokeMethod('linkMulticast', {'on': false});
      } catch (_) {}
      enabled = false;
      peers = 0;
      tempo = 0;
      status = 'Off';
    }
    if (save) {
      try {
        await (await SharedPreferences.getInstance()).setBool(_prefKey, enabled);
      } catch (_) {}
    }
    notifyListeners();
  }

  /// The deck whose tempo is shared: the master, else the first playing deck.
  int _leader(DjController dj) {
    final m = dj.masterDeck;
    if (m >= 0 && dj.deck(m).loaded) return m;
    for (var i = 0; i < DjController.deckCount; i++) {
      final d = dj.deck(i);
      if (d.loaded && d.playing) return i;
    }
    return -1;
  }

  void _poll() {
    final dj = _dj;
    if (!enabled || dj == null) return;
    try {
      final link = _tempo!();
      final n = _peers!();
      final changed = n != peers || (link - tempo).abs() > 0.005;
      peers = n;
      tempo = link;
      status = n > 0 ? 'Connected to $n other app${n == 1 ? '' : 's'}' : 'On, no other apps yet';

      final i = _leader(dj);
      final d = i >= 0 ? dj.deck(i) : null;
      final deckBpm = (d != null && d.bpm > 0) ? d.bpm * d.rate : 0.0;
      final decision = decideLink(
        linkBpm: link,
        deckBpm: deckBpm,
        lastLink: _lastLink,
        lastDeck: _lastDeck,
        peers: n,
      );
      var deckNow = deckBpm;
      switch (decision.action) {
        case LinkAction.applyToDeck:
          final r = fitRate(decision.bpm, d!.bpm);
          if (r != null) {
            dj.setRate(i, r);
            deckNow = d.bpm * d.rate;
            DebugLog.add('link', 'deck ${i + 1} follows Link at ${decision.bpm.toStringAsFixed(1)} BPM');
          }
        case LinkAction.publish:
          _setTempo!(decision.bpm);
          DebugLog.add('link', 'sent ${decision.bpm.toStringAsFixed(1)} BPM to Link');
        case LinkAction.none:
          break;
      }
      _lastLink = decision.action == LinkAction.publish ? decision.bpm : link;
      _lastDeck = deckNow;
      if (changed || decision.action != LinkAction.none) notifyListeners();
    } catch (e) {
      DebugLog.add('link', 'poll failed: $e');
    }
  }
}
