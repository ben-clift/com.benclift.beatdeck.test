import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/debug/debug_log.dart';

/// One track you own, read from a file name.
class ImportedTrack {
  ImportedTrack({
    this.artist = '',
    required this.title,
    this.mix = '',
    this.label = '',
    this.release = '',
    this.key = '',
    this.bpm = 0,
    this.deezer = '',
    this.checked = false,
  });

  final String artist;
  final String title;

  /// "Original Mix", "Dana Ruh Remix" and so on.
  final String mix;
  final String label;

  /// Album or compilation the file name mentions.
  final String release;

  /// Camelot key (such as 8A) when the file name has one.
  final String key;
  final double bpm;

  /// Direct Deezer page, '' when none was found.
  String deezer;

  /// True once a direct link has been looked for.
  bool checked;

  static String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  String get id => norm('$artist $title $mix');

  bool get isOriginal => mix.isEmpty || RegExp(r'^original(\s+mix)?$', caseSensitive: false).hasMatch(mix.trim());

  /// "Artist - Title (Mix) [Label]": what the review box shows. Reading it
  /// back with [TrackNameParser.parse] gives the same track.
  String get display {
    final b = StringBuffer();
    if (artist.isNotEmpty) b.write('$artist - ');
    b.write(title);
    if (mix.isNotEmpty) b.write(' ($mix)');
    if (label.isNotEmpty) b.write(' [$label]');
    return b.toString();
  }

  /// What to type into a shop's search box. The mix is kept when it is a
  /// remix, because the shop lists that version separately.
  String get linkQuery => [artist, title, if (!isOriginal) mix].where((s) => s.trim().isNotEmpty).join(' ');

  Map<String, dynamic> toJson() => {
        'a': artist,
        't': title,
        'm': mix,
        'l': label,
        'r': release,
        'k': key,
        'b': bpm,
        'd': deezer,
        'c': checked,
      };

  static ImportedTrack? fromJson(Object? j) {
    if (j is! Map || j['t'] is! String) return null;
    String s(String k) => j[k] is String ? j[k] as String : '';
    return ImportedTrack(
      artist: s('a'),
      title: j['t'] as String,
      mix: s('m'),
      label: s('l'),
      release: s('r'),
      key: s('k'),
      bpm: j['b'] is num ? (j['b'] as num).toDouble() : 0,
      deezer: s('d'),
      checked: j['c'] == true,
    );
  }
}

/// Reads file names (as Finder lists them) into tracks. Plain Dart, tested.
abstract class TrackNameParser {
  static final _ext = RegExp(r'\.(mp3|flac|wav|aiff?|m4a|ogg|opus|wma)$', caseSensitive: false);
  static final _mixWord = RegExp(r'(mix|edit|remix|rework|dub|version|extended|original|bootleg)', caseSensitive: false);

  static String _titleCase(String s) =>
      s.replaceAllMapped(RegExp(r'(^|[\s\-\(])([a-z])'), (m) => '${m[1]}${m[2]!.toUpperCase()}');

  static bool hasAudioExtension(String line) => _ext.hasMatch(line.trim());

  static bool _endsWithMix(String s) {
    final m = RegExp(r'\(([^()]+)\)\s*$').firstMatch(s.trim());
    return m != null && _mixWord.hasMatch(m.group(1)!);
  }

  /// [line] is a file name or an "Artist - Title (Mix) [Label]" line. With
  /// [requireExt] only lines ending in an audio extension count (so folder
  /// names in a screenshot are skipped). [stripNumbers] drops track numbers
  /// such as "03." or "1-02"; switch it off for lines already cleaned.
  static ImportedTrack? parse(String line, {bool requireExt = true, bool stripNumbers = true}) {
    var s = line.trim();
    if (s.isEmpty) return null;
    if (requireExt && !_ext.hasMatch(s)) return null;
    s = s.replaceFirst(_ext, '').trim();

    // "... - 8A - 128.0" from a DJ library's file naming.
    var key = '';
    var bpm = 0.0;
    final kb = RegExp(r'\s+-\s+(\d{1,2}[ABab])\s+-\s+(\d{2,3}(?:\.\d+)?)$').firstMatch(s);
    if (kb != null) {
      key = kb.group(1)!.toUpperCase();
      bpm = double.tryParse(kb.group(2)!) ?? 0;
      s = s.substring(0, kb.start).trim();
    }

    // "VA (Dots & Pearls 8)-[06]-Redshape - Ghost Story".
    var release = '';
    final va = RegExp(r'^VA\s*\((.+?)\)\s*-\s*\[?\d{1,3}\]?\s*-\s*(.+)$', caseSensitive: false).firstMatch(s);
    if (va != null) {
      release = va.group(1)!.trim();
      s = va.group(2)!.trim();
    }

    // The record label in square brackets at the end.
    var label = '';
    final lb = RegExp(r'\s*\[([^\]]+)\]\s*$').firstMatch(s);
    if (lb != null) {
      label = lb.group(1)!.trim();
      s = s.substring(0, lb.start).trim();
    }

    var artist = '';
    var title = '';

    // Names written with underscores and no spaces:
    // "04-christian_nielsen-liberate_(original_mix)".
    final scene = !s.contains(' ') && (s.contains('_') || RegExp(r'^\d{1,3}-[^-]+-[^-]+$').hasMatch(s));
    if (scene) {
      if (stripNumbers) s = s.replaceFirst(RegExp(r'^\d{1,3}-'), '');
      s = s.replaceFirst(RegExp(r'\)-[a-z]{1,4}$', caseSensitive: false), ')');
      s = _titleCase(s.replaceAll('_', ' ').replaceAll(RegExp(r'\s+'), ' ').trim());
      var d = s.indexOf(' - ');
      var skip = 3;
      if (d < 0) {
        d = s.indexOf('-');
        skip = 1;
      }
      if (d > 0) {
        artist = s.substring(0, d).trim();
        title = s.substring(d + skip).trim();
      } else {
        title = s;
      }
    } else {
      if (stripNumbers) {
        s = s.replaceFirst(RegExp(r'^(?:\d{1,3}-\d{1,2}\s+|\d{1,3}\s*[.\-]\s*|\d{1,2}\s+)'), '');
      }
      // "No Stoppin_ (Original Mix)": a lost apostrophe.
      s = s.replaceAll(RegExp(r"(?<=[A-Za-z])_(?=\s|\(|\)|$)"), "'").replaceAll('_', ' ');
      s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
      final parts = s.split(' - ');
      if (parts.length >= 3 && RegExp(r'^\d{1,2}\s+\S').hasMatch(parts.last.trim())) {
        // "Artist - Album - 03 Title": the album is kept apart from the title.
        artist = parts.first.trim();
        if (release.isEmpty) release = parts.sublist(1, parts.length - 1).join(' - ').trim();
        title = parts.last.trim().replaceFirst(RegExp(r'^\d{1,2}\s+'), '');
      } else if (parts.length == 2) {
        // "Cadenza (Edit) - Yuksek, Polo & Pan": a mix in the first part means it is the title.
        if (_endsWithMix(parts[0]) && !_endsWithMix(parts[1])) {
          title = parts[0].trim();
          artist = parts[1].trim();
        } else {
          artist = parts[0].trim();
          title = parts[1].trim();
        }
      } else if (parts.length > 2) {
        artist = parts.first.trim();
        title = parts.sublist(1).join(' - ').trim();
      } else {
        title = s;
      }
    }

    // "(Dana Ruh Remix)" or "(Original Mix)" at the end of the title.
    var mix = '';
    final mm = RegExp(r'\s*\(([^()]+)\)\s*$').firstMatch(title);
    if (mm != null && _mixWord.hasMatch(mm.group(1)!)) {
      mix = mm.group(1)!.trim();
      title = title.substring(0, mm.start).trim();
    }
    title = title.trim();
    if (title.isEmpty) return null;
    if (artist.toLowerCase() == 'va') artist = '';
    return ImportedTrack(
      artist: artist,
      title: title,
      mix: mix,
      label: label,
      release: release,
      key: key,
      bpm: bpm,
    );
  }

  /// All the tracks in a block of lines, without repeats.
  static List<ImportedTrack> parseAll(Iterable<String> lines, {bool requireExt = true, bool stripNumbers = true}) {
    final seen = <String>{};
    final out = <ImportedTrack>[];
    for (final l in lines) {
      final t = parse(l, requireExt: requireExt, stripNumbers: stripNumbers);
      if (t != null && seen.add(t.id)) out.add(t);
    }
    return out;
  }
}

/// The tracks you imported from screenshots or pasted names: what you own.
/// They count as your taste (artists and labels) so Explore hides them and
/// favours what sits near them.
class MyTracks extends ChangeNotifier {
  MyTracks._();
  static final MyTracks instance = MyTracks._();

  static const _key = 'my_tracks_v1';
  final List<ImportedTrack> tracks = [];
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw != null) {
        for (final j in jsonDecode(raw) as List) {
          final t = ImportedTrack.fromJson(j);
          if (t != null) tracks.add(t);
        }
      }
    } catch (e) {
      DebugLog.add('mytracks', 'could not read saved tracks: $e');
    }
    notifyListeners();
  }

  Future<List<ImportedTrack>> loadAll() async {
    await load();
    return tracks;
  }

  Future<void> save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, jsonEncode([for (final t in tracks) t.toJson()]));
    } catch (_) {}
    notifyListeners();
  }

  /// Adds new tracks; returns how many were not already there.
  Future<int> addAll(List<ImportedTrack> list) async {
    await load();
    final have = {for (final t in tracks) t.id};
    var n = 0;
    for (final t in list) {
      if (have.add(t.id)) {
        tracks.add(t);
        n++;
      }
    }
    await save();
    return n;
  }

  Future<void> remove(ImportedTrack t) async {
    tracks.remove(t);
    await save();
  }

  Future<void> clear() async {
    tracks.clear();
    await save();
  }
}

/// A direct page for a track on Deezer, where Deezer has it. Deezer shows
/// short previews without an account. Most underground tracks are not there,
/// so the shop search links are always offered as well.
abstract class DirectLinks {
  static const _ua = {'User-Agent': 'BeatDeck/1.0 (personal DJ app)'};

  /// Whether a Deezer result is the track we asked for.
  static bool matches(ImportedTrack t, String resultArtist, String resultTitle) {
    final rt = ImportedTrack.norm(resultTitle);
    final tt = ImportedTrack.norm(t.title);
    if (tt.isEmpty || !(rt.contains(tt) || tt.contains(rt))) return false;
    if (t.artist.isEmpty) return true;
    final ra = ImportedTrack.norm(resultArtist);
    final ta = ImportedTrack.norm(t.artist);
    if (ra.isEmpty) return false;
    return ta.contains(ra) || ra.contains(ta.split(' ').first);
  }

  static Future<String> deezer(ImportedTrack t) async {
    final first = t.artist.split(RegExp(r',|&| feat| ft| x ')).first.trim();
    final q = first.isEmpty
        ? 'track:"${t.title.replaceAll('"', '')}"'
        : 'artist:"${first.replaceAll('"', '')}" track:"${t.title.replaceAll('"', '')}"';
    final r = await http
        .get(Uri.parse('https://api.deezer.com/search?q=${Uri.encodeQueryComponent(q)}&limit=5'), headers: _ua)
        .timeout(const Duration(seconds: 12));
    if (r.statusCode != 200) throw Exception('Deezer answered ${r.statusCode}');
    final m = jsonDecode(utf8.decode(r.bodyBytes));
    if (m is! Map || m['data'] is! List) return '';
    for (final e in m['data'] as List) {
      if (e is! Map) continue;
      final title = (e['title'] ?? e['title_short'])?.toString() ?? '';
      final artist = (e['artist'] is Map ? (e['artist'] as Map)['name'] : '')?.toString() ?? '';
      final link = e['link']?.toString() ?? '';
      if (link.isNotEmpty && matches(t, artist, title)) return link;
    }
    return '';
  }
}
