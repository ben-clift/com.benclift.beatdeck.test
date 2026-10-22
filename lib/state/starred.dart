import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A starred song: names only (the file itself is deleted after it plays, so
/// playing it again fetches it again).
class StarredTrack {
  StarredTrack(this.artist, this.title, this.genre, this.bpm, this.at);

  final String artist;
  final String title;
  final String genre;
  final int bpm; // 0 when unknown
  final int at; // when it was starred (ms)

  String get key => '${artist.toLowerCase()}|${title.toLowerCase()}';

  Map<String, dynamic> toJson() => {'a': artist, 't': title, 'g': genre, 'b': bpm, 'at': at};

  static StarredTrack? fromJson(Object? j) {
    if (j is! Map || j['t'] is! String) return null;
    return StarredTrack(
      (j['a'] as String?) ?? '',
      j['t'] as String,
      (j['g'] as String?) ?? '',
      (j['b'] as num?)?.toInt() ?? 0,
      (j['at'] as num?)?.toInt() ?? 0,
    );
  }
}

class Starred extends ChangeNotifier {
  Starred._();
  static final Starred instance = Starred._();

  static const _key = 'simple_starred_v1';
  final List<StarredTrack> items = [];
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw != null) {
        for (final j in jsonDecode(raw) as List) {
          final t = StarredTrack.fromJson(j);
          if (t != null) items.add(t);
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  bool has(String artist, String title) => items.any((t) => t.key == '${artist.toLowerCase()}|${title.toLowerCase()}');

  Future<void> toggle(String artist, String title, String genre, int bpm) async {
    final k = '${artist.toLowerCase()}|${title.toLowerCase()}';
    final i = items.indexWhere((t) => t.key == k);
    if (i >= 0) {
      items.removeAt(i);
    } else {
      items.insert(0, StarredTrack(artist, title, genre, bpm, DateTime.now().millisecondsSinceEpoch));
    }
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setString(_key, jsonEncode([for (final t in items) t.toJson()]));
    } catch (_) {}
  }
}
