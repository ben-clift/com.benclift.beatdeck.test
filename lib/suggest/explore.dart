import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/debug/debug_log.dart';
import 'package:sidedeck/suggest/discover.dart';
import 'package:sidedeck/suggest/taste.dart';

/// Reading of MusicBrainz answers. Plain Dart (no network) so it can be tested.
abstract class ExploreParse {
  /// MusicBrainz's placeholders for "many artists" and "no label".
  static const variousArtists = '89ad4ac3-39f7-470e-963a-56509c546377';
  static const noLabel = '157afde4-4bf5-4039-8ad2-5a15acc85176';

  static String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  static dynamic _json(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  /// The search result whose name is exactly [wanted] (ignoring case and
  /// punctuation). A near match is not taken: a wrong artist would send the
  /// whole walk the wrong way.
  static ({String id, String name})? exactMatch(String body, String listKey, String wanted) {
    final m = _json(body);
    if (m is! Map) return null;
    final list = m[listKey];
    if (list is! List) return null;
    final w = norm(wanted);
    if (w.isEmpty) return null;
    for (final e in list) {
      if (e is! Map) continue;
      final id = e['id'];
      final name = e['name'];
      if (id is String && name is String && norm(name) == w) return (id: id, name: name);
    }
    return null;
  }

  /// Labels on a list of releases, with how many releases each appears on.
  static List<({String id, String name, int n})> labelsOf(String body) {
    final m = _json(body);
    final counts = <String, ({String name, int n})>{};
    if (m is Map && m['releases'] is List) {
      for (final r in m['releases'] as List) {
        if (r is! Map || r['label-info'] is! List) continue;
        final seen = <String>{};
        for (final li in r['label-info'] as List) {
          final l = li is Map ? li['label'] : null;
          if (l is! Map) continue;
          final id = l['id'];
          final name = l['name'];
          if (id is! String || name is! String || id == noLabel || !seen.add(id)) continue;
          counts[id] = (name: name, n: (counts[id]?.n ?? 0) + 1);
        }
      }
    }
    return [for (final e in counts.entries) (id: e.key, name: e.value.name, n: e.value.n)]
      ..sort((a, b) => b.n.compareTo(a.n));
  }

  /// Artists credited on a list of releases, with how many releases each is on.
  static List<({String id, String name, int n})> artistsOf(String body) {
    final m = _json(body);
    final counts = <String, ({String name, int n})>{};
    if (m is Map && m['releases'] is List) {
      for (final r in m['releases'] as List) {
        if (r is! Map || r['artist-credit'] is! List) continue;
        final seen = <String>{};
        for (final c in r['artist-credit'] as List) {
          final a = c is Map ? c['artist'] : null;
          if (a is! Map) continue;
          final id = a['id'];
          final name = a['name'];
          if (id is! String || name is! String || id == variousArtists || !seen.add(id)) continue;
          counts[id] = (name: name, n: (counts[id]?.n ?? 0) + 1);
        }
      }
    }
    return [for (final e in counts.entries) (id: e.key, name: e.value.name, n: e.value.n)]
      ..sort((a, b) => b.n.compareTo(a.n));
  }

  /// Names of related artists from a Deezer "related" answer.
  static List<String> deezerNames(String body) {
    final m = _json(body);
    if (m is! Map || m['data'] is! List) return const [];
    return [
      for (final e in m['data'] as List)
        if (e is Map && e['name'] is String) e['name'] as String,
    ];
  }

  /// "Listen" and "buy" web pages for a search text. These are search pages on
  /// each site, opened in the phone's browser: nothing plays inside the app.
  static Map<String, String> links(String text) {
    final q = Uri.encodeQueryComponent(text);
    return {
      'YouTube': 'https://www.youtube.com/results?search_query=$q',
      'Bandcamp': 'https://bandcamp.com/search?q=$q',
      'Traxsource': 'https://www.traxsource.com/search?term=$q',
      'Beatport': 'https://www.beatport.com/search?q=$q',
      'Hardwax': 'https://hardwax.com/?search=$q',
    };
  }

  /// Resident Advisor artist page: letters and digits only, as RA writes them.
  static String raArtistUrl(String artist) =>
      'https://ra.co/dj/${artist.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '')}';
}

/// One artist or label found by the walk.
class ExploreHit {
  ExploreHit(this.kind, this.name, [this.mbid = '']);

  /// 'artist' or 'label'.
  final String kind;
  final String name;

  /// MusicBrainz id when known.
  String mbid;
  double score = 0;

  /// The artists or labels that led here.
  final Set<String> via = {};
  int hop = 1;
  bool owned = false;
  bool genreMatch = false;

  String get key => '$kind:${ExploreParse.norm(name)}';
}

class ExploreTrack {
  ExploreTrack(this.artist, this.title, this.bpm);
  final String artist;
  final String title;

  /// 0 when Deezer has no tempo for the track.
  final double bpm;
}

/// Walks outward from an artist, a label or a genre: artist to the labels they
/// release on, label to the artists on it, artist to similar artists. Each hop
/// widens the list. Things already in your playlists are marked, labels you own
/// raise the artists on them, and anything you said "not for me" to is skipped.
///
/// MusicBrainz asks for one request a second and a named app, so the walk is
/// paced, capped, and every answer is kept on the phone for a week.
class Explore extends ChangeNotifier {
  static const _maxAge = Duration(days: 7);
  static const _ua = {'User-Agent': 'BeatDeck/1.0 (personal DJ app)', 'Accept': 'application/json'};
  static const maxRequests = 30;

  bool busy = false;
  String status = '';
  final List<ExploreHit> hits = [];
  final Set<String> _dismissed = {};
  bool _loaded = false;
  int _requests = 0;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  int _run = 0;

  Future<void> loadDismissed() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      _dismissed.addAll(p.getStringList('explore_dismissed_v1') ?? const <String>[]);
    } catch (_) {}
  }

  int get dismissedCount => _dismissed.length;

  Future<void> dismiss(ExploreHit h) async {
    _dismissed.add(h.key);
    hits.removeWhere((x) => x.key == h.key);
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList('explore_dismissed_v1', _dismissed.toList());
    } catch (_) {}
  }

  Future<void> forgetDismissed() async {
    _dismissed.clear();
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove('explore_dismissed_v1');
    } catch (_) {}
    notifyListeners();
  }

  void cancel() {
    _run++;
    busy = false;
    status = 'Stopped.';
    notifyListeners();
  }

  // ---- network, paced and cached -------------------------------------------

  /// Keeps a small parsed result (never the whole answer) for a week.
  Future<dynamic> _cached(String cacheKey, Future<Object> Function() fetch) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('exp_$cacheKey');
    if (raw != null) {
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        final at = DateTime.fromMillisecondsSinceEpoch(m['t'] as int);
        if (DateTime.now().difference(at) < _maxAge) return m['v'];
      } catch (_) {}
    }
    final v = await fetch();
    try {
      await p.setString('exp_$cacheKey', jsonEncode({'t': DateTime.now().millisecondsSinceEpoch, 'v': v}));
    } catch (_) {}
    return v;
  }

  /// One MusicBrainz request, at least 1.1 s after the last one.
  Future<String> _mb(String path, Map<String, String> query) async {
    if (_requests >= maxRequests) throw StateError('request limit');
    final wait = const Duration(milliseconds: 1100) - DateTime.now().difference(_last);
    if (!wait.isNegative) await Future<void>.delayed(wait);
    _last = DateTime.now();
    _requests++;
    final r = await http
        .get(Uri.https('musicbrainz.org', '/ws/2/$path', {...query, 'fmt': 'json'}), headers: _ua)
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw Exception('MusicBrainz answered ${r.statusCode}');
    return utf8.decode(r.bodyBytes);
  }

  Future<String> _deezer(String path) async {
    final r = await http.get(Uri.parse('https://api.deezer.com/$path'), headers: _ua).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('Deezer answered ${r.statusCode}');
    return utf8.decode(r.bodyBytes);
  }

  Future<String> _resolve(String kind, String name) async {
    final v = await _cached('id_${kind}_${ExploreParse.norm(name)}', () async {
      final body = await _mb(kind, {'query': '$kind:"${name.replaceAll('"', '')}"', 'limit': '8'});
      return ExploreParse.exactMatch(body, kind == 'artist' ? 'artists' : 'labels', name)?.id ?? '';
    });
    return v is String ? v : '';
  }

  // ---- the walk -------------------------------------------------------------

  List<({String id, String name, int n})> _triples(dynamic v) => [
        if (v is List)
          for (final e in v)
            if (e is List && e.length == 3) (id: e[0].toString(), name: e[1].toString(), n: (e[2] as num).toInt()),
      ];

  /// What one artist or label leads to.
  Future<List<({String kind, String name, String id, double w, String via})>> _expand(ExploreHit n) async {
    final out = <({String kind, String name, String id, double w, String via})>[];
    if (n.mbid.isEmpty) n.mbid = await _resolve(n.kind, n.name);
    if (n.kind == 'artist') {
      if (n.mbid.isNotEmpty) {
        final v = await _cached('rel_a_${n.mbid}', () async {
          final body = await _mb('release', {'artist': n.mbid, 'inc': 'labels', 'limit': '100'});
          return [for (final l in ExploreParse.labelsOf(body).take(8)) [l.id, l.name, l.n]];
        });
        for (final l in _triples(v)) {
          out.add((kind: 'label', name: l.name, id: l.id, w: 1.0 + (l.n > 5 ? 5 : l.n) * 0.1, via: n.name));
        }
      }
      try {
        final names = await _cached('dz_sim_${ExploreParse.norm(n.name)}', () async {
          final s = jsonDecode(await _deezer('search/artist?q=${Uri.encodeQueryComponent(n.name)}&limit=1')) as Map;
          final data = s['data'];
          if (data is! List || data.isEmpty || (data.first as Map)['id'] == null) return <String>[];
          final id = (data.first as Map)['id'];
          return ExploreParse.deezerNames(await _deezer('artist/$id/related?limit=12'));
        });
        if (names is List) {
          for (final name in names) {
            out.add((kind: 'artist', name: name.toString(), id: '', w: 0.8, via: n.name));
          }
        }
      } catch (e) {
        DebugLog.add('explore', 'Deezer similar for ${n.name}: $e');
      }
    } else if (n.mbid.isNotEmpty) {
      final v = await _cached('rel_l_${n.mbid}', () async {
        final body = await _mb('release', {'label': n.mbid, 'inc': 'artist-credits', 'limit': '100'});
        return [for (final a in ExploreParse.artistsOf(body).take(40)) [a.id, a.name, a.n]];
      });
      final ownedLabel = Taste.likesLabel(n.name);
      for (final a in _triples(v)) {
        out.add((kind: 'artist', name: a.name, id: a.id, w: 1.0 + (a.n > 5 ? 5 : a.n) * 0.1 + (ownedLabel ? 1.5 : 0), via: n.name));
      }
    }
    return out;
  }

  /// [kind] is 'artist', 'label' or 'genre'. [hops] 1 to 3.
  Future<void> run({
    required String kind,
    required String name,
    int hops = 1,
    String genre = '',
    bool hideOwned = true,
  }) async {
    final me = ++_run;
    await loadDismissed();
    busy = true;
    hits.clear();
    _requests = 0;
    status = 'Looking up $name…';
    notifyListeners();
    final found = <String, ExploreHit>{};
    final seed = ExploreHit(kind == 'genre' ? 'artist' : kind, name);
    try {
      // The genre list: used to start from a genre, or to lift matches.
      final genreArtists = <String>[];
      final g = kind == 'genre' ? name : genre;
      if (g.trim().isNotEmpty) {
        status = 'Reading the $g lists…';
        notifyListeners();
        final seen = <String>{};
        for (final s in [...await Discover.bandcamp(g), ...await Discover.discogs(g)]) {
          if (seen.add(ExploreParse.norm(s.artist))) genreArtists.add(s.artist);
        }
        if (me != _run) return;
      }
      final genreNames = {for (final a in genreArtists) ExploreParse.norm(a)};

      void add(String kindOf, String nameOf, String id, double w, String via, int hop) {
        final key = '$kindOf:${ExploreParse.norm(nameOf)}';
        if (_dismissed.contains(key) || ExploreParse.norm(nameOf) == ExploreParse.norm(seed.name)) return;
        final h = found.putIfAbsent(key, () => ExploreHit(kindOf, nameOf, id)..hop = hop);
        h.score += w / hop;
        h.via.add(via);
        if (hop < h.hop) h.hop = hop;
        if (h.mbid.isEmpty) h.mbid = id;
      }

      var frontier = <ExploreHit>[];
      if (kind == 'genre') {
        for (final a in genreArtists) {
          add('artist', a, '', 1.0, name, 1);
        }
        frontier = found.values.toList()
          // Artists you already know lead to labels that suit you, so go there first.
          ..sort((a, b) => (Taste.likes(b.name) ? 1 : 0) - (Taste.likes(a.name) ? 1 : 0));
      } else {
        frontier = [seed];
      }

      var level = kind == 'genre' ? 2 : 1;
      var stoppedAtLimit = false;
      while (level <= hops && frontier.isNotEmpty && me == _run) {
        if (kind != 'genre' || level > 2) frontier.sort((a, b) => b.score.compareTo(a.score));
        final next = <ExploreHit>[];
        for (final node in frontier.take(kind == 'genre' ? 4 : (level == 1 ? 1 : 5))) {
          if (me != _run) return;
          status = 'Hop $level: ${node.name}… ($_requests/$maxRequests requests)';
          notifyListeners();
          try {
            final before = found.keys.toSet();
            for (final e in await _expand(node)) {
              add(e.kind, e.name, e.id, e.w, e.via, level);
            }
            for (final k in found.keys) {
              if (!before.contains(k)) next.add(found[k]!);
            }
          } on StateError {
            stoppedAtLimit = true;
            break;
          } catch (e) {
            DebugLog.add('explore', 'could not expand ${node.name}: $e');
          }
        }
        if (stoppedAtLimit) break;
        frontier = next;
        level++;
      }

      for (final h in found.values) {
        h.owned = h.kind == 'artist' ? Taste.likes(h.name) : Taste.likesLabel(h.name);
        h.genreMatch = h.kind == 'artist' && genreNames.contains(ExploreParse.norm(h.name));
        if (h.genreMatch) h.score += 3;
        if (h.owned && h.kind == 'label') h.score += 1;
      }
      final list = found.values.where((h) => !(hideOwned && h.owned)).toList()
        ..sort((a, b) => b.score.compareTo(a.score));
      hits
        ..clear()
        ..addAll(list.take(80));
      status = hits.isEmpty
          ? 'Nothing found. Check the spelling, or try another start.'
          : '${hits.length} found${stoppedAtLimit ? ' (stopped at the $maxRequests request limit)' : ''}.';
      DebugLog.add('explore', '$kind "$name" hops $hops: ${hits.length} results, $_requests requests');
    } catch (e) {
      status = 'Could not finish: $e';
      DebugLog.add('explore', 'failed: $e');
    } finally {
      if (me == _run) {
        busy = false;
        notifyListeners();
      }
    }
  }

  /// Top tracks of an artist from Deezer, with tempo where Deezer has one.
  Future<List<ExploreTrack>> topTracks(String artist) async {
    final out = <ExploreTrack>[];
    try {
      final s = jsonDecode(await _deezer('search/artist?q=${Uri.encodeQueryComponent(artist)}&limit=1')) as Map;
      final data = s['data'];
      if (data is! List || data.isEmpty) return out;
      final id = (data.first as Map)['id'];
      final top = jsonDecode(await _deezer('artist/$id/top?limit=8')) as Map;
      for (final t in (top['data'] as List? ?? const [])) {
        if (t is! Map) continue;
        final title = (t['title_short'] ?? t['title'])?.toString() ?? '';
        if (title.isEmpty) continue;
        var bpm = 0.0;
        try {
          final tr = jsonDecode(await _deezer('track/${t['id']}')) as Map;
          final b = tr['bpm'];
          if (b is num) bpm = b.toDouble();
        } catch (_) {}
        out.add(ExploreTrack(artist, title, bpm));
      }
    } catch (e) {
      DebugLog.add('explore', 'top tracks of $artist: $e');
    }
    return out;
  }
}
