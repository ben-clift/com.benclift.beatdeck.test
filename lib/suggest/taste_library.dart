import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/debug/debug_log.dart';
import 'package:sidedeck/engine/tags.dart';
import 'package:sidedeck/soulseek/slsk_setup.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/state/playlist_store.dart';
import 'package:sidedeck/suggest/taste.dart';

/// Reads the artists and labels in your saved playlists (or most played
/// tracks) for [Taste]. Only the full app uses this; the standalone finder has
/// no music library and never imports it.
abstract class TasteLibrary {
  /// The reader to set as [Taste.libraryReader].
  static Future<void> Function(TasteSink) reader(LibraryController lib) => (sink) => _read(lib, sink);

  /// Plugs [lib] into [Taste] and refreshes it.
  static Future<void> refresh(LibraryController lib) {
    Taste.libraryReader = reader(lib);
    return Taste.refresh();
  }

  /// A label from a file name such as "name-[perl 015]-1999" gives "perl".
  static String _labelFromName(String name) {
    final m = RegExp(r'[\[\(]([a-z][a-z0-9 &.\x27]*?)[\s_-]*\d{1,4}[a-z]?[\]\)]', caseSensitive: false)
        .firstMatch(name);
    return m == null ? '' : m.group(1)!.trim();
  }

  static Future<void> _read(LibraryController lib, TasteSink sink) async {
    final prefs = await SharedPreferences.getInstance();
    final store = PlaylistStore.decode(prefs.getString('local_playlists'));
    final byPath = {for (final t in lib.tracks) t.path: t};
    // Labels read from tags are kept (path to label) so files are read once.
    Map<String, dynamic> cache = {};
    try {
      cache = jsonDecode(prefs.getString('taste_labels_v1') ?? '{}') as Map<String, dynamic>;
    } catch (_) {}
    var reads = 0;
    var total = 0;
    // Your playlists (the "Backup tracks" shelf is music you are bored of).
    final sources = <String>[
      for (final pl in store.playlists)
        if (pl.name != 'Backup tracks') ...pl.paths,
    ];
    total = sources.length;
    // Nothing saved: the tracks you play most stand in for your taste.
    if (sources.isEmpty) {
      final dj = SlskSetup.dj;
      if (dj != null) {
        final top = [for (final t in lib.tracks) if (dj.playCountOf(t.path) >= 2) t.path];
        sources.addAll(top);
        DebugLog.add('taste', 'no playlist tracks, using ${top.length} most played tracks instead');
      }
    }
    for (final path in sources) {
      {
        var artist = byPath[path]?.artist ?? '';
        if (artist.trim().isEmpty) {
          final name = path.split(RegExp(r'[\\/]')).last.replaceFirst(RegExp(r'\.[^.]+$'), '');
          final dash = name.indexOf(' - ');
          if (dash > 0) {
            artist = name.substring(0, dash);
          } else {
            // "baby ford & zip (glidin' along)-[perl 061]" gives "baby ford & zip".
            final cut = RegExp(r'\s*[\(\[]|\s-|-\[').firstMatch(name);
            if (cut != null && cut.start > 1) artist = name.substring(0, cut.start);
          }
        }
        artist = artist.replaceFirst(RegExp(r'^\d+[\.\s-]+'), '');
        if (Taste.norm(artist) == 'va' || Taste.norm(artist) == 'various artists') continue;
        final n = Taste.norm(artist);
        if (n.length < 2) continue;
        sink.artists.add(n);
        sink.display[n] = artist.trim();
        final tg = byPath[path]?.genre ?? '';
        if (tg.isNotEmpty) sink.genre[n] = tg;
        // The record label: from the tags, else from the file name.
        var label = cache[path] as String?;
        if (label == null && reads < 150) {
          reads++;
          try {
            label = (await readTrackTags(path)).label;
          } catch (_) {
            label = '';
          }
          if (label.isEmpty) label = _labelFromName(path.split(RegExp(r'[\\/]')).last);
          cache[path] = label;
        }
        final ln = Taste.norm(label ?? '');
        if (ln.length >= 2) sink.labels.add(ln);
      }
    }
    DebugLog.add('taste',
        '${store.playlists.length} playlists, $total tracks in them, ${sink.artists.length} artists and ${sink.labels.length} labels read');
    try {
      await prefs.setString('taste_labels_v1', jsonEncode(cache));
    } catch (_) {}
  }
}
