import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'package:sidedeck/automix/transition_style.dart';
import 'package:sidedeck/engine/track_analyzer.dart';
import 'package:sidedeck/state/break_detect.dart';

/// What the app learned about one track by scanning it before it is ever
/// loaded: tempo, key, beat grid, the breakdowns and the first drop.
class MixInfo {
  MixInfo({
    required this.size,
    required this.mtime,
    required this.bpm,
    required this.key,
    required this.beatOffset,
    required this.duration,
    required this.breaks,
    required this.drop,
  });

  final int size;
  final int mtime;
  final double bpm;
  final int key;
  final double beatOffset;
  final double duration;
  final List<BreakSpan> breaks;
  final double? drop; // seconds into the file; null = no clear drop

  Map<String, Object?> toJson() => {
        'size': size,
        'mtime': mtime,
        'bpm': bpm,
        'key': key,
        'beatOffset': beatOffset,
        'duration': duration,
        'breaks': [for (final b in breaks) [b.start, b.end]],
        if (drop != null) 'drop': drop,
      };

  static MixInfo fromJson(Map<String, dynamic> j) => MixInfo(
        size: (j['size'] as num).toInt(),
        mtime: (j['mtime'] as num).toInt(),
        bpm: (j['bpm'] as num).toDouble(),
        key: (j['key'] as num).toInt(),
        beatOffset: (j['beatOffset'] as num).toDouble(),
        duration: (j['duration'] as num).toDouble(),
        breaks: [for (final b in (j['breaks'] as List)) BreakSpan((b[0] as num).toDouble(), (b[1] as num).toDouble())],
        drop: (j['drop'] as num?)?.toDouble(),
      );
}

/// The saved scan results, kept in one file (beatdeck_mixdata.json) next to
/// the app's databases and read by the mixer when it plans a transition.
class MixData {
  MixData._();
  static final instance = MixData._();

  final Map<String, MixInfo> _byPath = {};
  bool _loaded = false;
  int _unsaved = 0;

  Future<File> _file() async => File(p.join(await getDatabasesPath(), 'beatdeck_mixdata.json'));

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _file();
      if (await f.exists()) {
        final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        m.forEach((k, v) {
          try {
            _byPath[k] = MixInfo.fromJson(v as Map<String, dynamic>);
          } catch (_) {}
        });
      }
    } catch (_) {}
  }

  /// The saved scan for [path], or null when there is none or the file has changed.
  MixInfo? infoFor(String path) {
    final i = _byPath[path];
    if (i == null) return null;
    try {
      final st = File(path).statSync();
      if (st.size != i.size || st.modified.millisecondsSinceEpoch != i.mtime) return null;
    } catch (_) {
      return null;
    }
    return i;
  }

  bool has(String path) => infoFor(path) != null;
  int get count => _byPath.length;

  /// Works out breaks and the first drop from a fresh scan and stores them.
  Future<void> record(String path, TrackStructure s) async {
    await load();
    try {
      final st = await File(path).stat();
      final env = Float32List.fromList(s.env);
      final breaks = findBreaks(
          min: Float32List(env.length), max: env, duration: s.durationSec, bpm: s.bpm, beatOffset: s.beatOffset);
      _byPath[path] = MixInfo(
        size: st.size,
        mtime: st.modified.millisecondsSinceEpoch,
        bpm: s.bpm,
        key: s.key,
        beatOffset: s.beatOffset,
        duration: s.durationSec,
        breaks: breaks,
        drop: firstDrop(s.env, s.durationSec, s.bpm, s.beatOffset),
      );
      if (++_unsaved >= 10) await save();
    } catch (_) {}
  }

  Future<void> save() async {
    _unsaved = 0;
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode({for (final e in _byPath.entries) e.key: e.value.toJson()}));
    } catch (_) {}
  }

  Future<void> forget(String path) async {
    _byPath.remove(path);
    await save();
  }
}
