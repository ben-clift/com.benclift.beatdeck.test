import 'dart:math' as math;

import 'package:sidedeck/automix/genre_family.dart';
import 'package:sidedeck/debug/debug_log.dart';
import 'package:sidedeck/suggest/track_import.dart';

/// What the DJ likes: the artists and labels of the tracks they own. Those come
/// from the imported "My tracks" list and, in the full app, from the playlists
/// saved on the phone (see taste_library.dart, which plugs in through
/// [libraryReader] so this file needs no music library or audio engine). Used to put those artists first when automix
/// looks for a new track, and to try other tracks by the same artists.
class Taste {
  static Set<String> artists = {};
  static Set<String> labels = {};
  static final Map<String, String> _display = {};
  static final Map<String, String> _genre = {};

  static String norm(String a) => a.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  static bool likes(String artist) {
    final n = norm(artist);
    if (n.isEmpty) return false;
    // "Artist, Other" or "Artist & Other" counts when any name is liked.
    for (final part in n.split(RegExp(r'\s(?:and|feat|ft|vs|x)\s|,'))) {
      if (artists.contains(part.trim())) return true;
    }
    return artists.contains(n);
  }

  /// A record label that appears in your playlists.
  static bool likesLabel(String label) {
    final n = norm(label);
    return n.length >= 2 && labels.contains(n);
  }

  /// Artist or label from your playlists.
  static bool likesTrack(String artist, String label) => likes(artist) || likesLabel(label);

  /// The genre of a liked artist's tracks in your library, '' when unknown.
  static String genreOf(String artist) {
    final n = norm(artist);
    for (final part in n.split(RegExp(r'\s(?:and|feat|ft|vs|x)\s|,'))) {
      final g = _genre[part.trim()];
      if (g != null && g.isNotEmpty) return g;
    }
    return _genre[n] ?? '';
  }

  /// Up to [n] random liked artists, as they were written. With [genre],
  /// artists known to make a different kind of music are left out (a dub
  /// artist is not offered after minimal house).
  static List<String> pick(int n, {Set<String> except = const {}, String genre = ''}) {
    final all = [
      for (final a in artists)
        if (!except.contains(a) && (genre.isEmpty || genresSimilar(genre, _genre[a] ?? '')))
          _display[a] ?? a,
    ]..shuffle();
    return all.take(math.max(0, n)).toList();
  }

  static DateTime _lastRead = DateTime.fromMillisecondsSinceEpoch(0);

  /// Makes the next [refresh] read everything again (after an import).
  static void invalidate() => _lastRead = DateTime.fromMillisecondsSinceEpoch(0);

  /// What the writer of a [libraryReader] fills in.
  static Future<void> Function(TasteSink sink)? libraryReader;

  static Future<void> refresh() async {
    // Reading every playlist file again for each track is wasted work.
    if (artists.isNotEmpty && DateTime.now().difference(_lastRead).inMinutes < 10) return;
    _lastRead = DateTime.now();
    final found = <String>{};
    final foundLabels = <String>{};
    final reader = libraryReader;
    if (reader != null) {
      try {
        await reader(TasteSink(found, foundLabels, _display, _genre));
      } catch (e) {
        DebugLog.add('taste', 'could not read your playlists: $e');
      }
    }
    // Tracks imported from screenshots or pasted names count as owned too.
    try {
      for (final t in await MyTracks.instance.loadAll()) {
        final an = norm(t.artist);
        if (an.length >= 2) {
          found.add(an);
          _display.putIfAbsent(an, () => t.artist);
        }
        final ln = norm(t.label);
        if (ln.length >= 2) foundLabels.add(ln);
      }
    } catch (_) {}
    artists = found;
    labels = foundLabels;
    DebugLog.add('taste', '${found.length} artists and ${foundLabels.length} labels known');
  }
}

/// Where a [Taste.libraryReader] puts what it finds.
class TasteSink {
  TasteSink(this.artists, this.labels, this.display, this.genre);

  final Set<String> artists;
  final Set<String> labels;
  final Map<String, String> display;
  final Map<String, String> genre;
}
