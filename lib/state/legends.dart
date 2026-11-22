import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/state/playlist_controller.dart';
import 'package:sidedeck/state/playlist_store.dart';

/// "Legends": tracks you want to keep for good. They live in a playlist called
/// Legends (play it from the library or Auto DJ) and are never deleted: not
/// when a downloaded track is played, not to free space, not by any clean-up.
class Legends extends ChangeNotifier {
  Legends._();
  static final Legends instance = Legends._();

  static const name = 'Legends';
  static const _prefsKey = 'local_playlists';
  Set<String> _paths = {};
  bool _loaded = false;

  int get count => _paths.length;
  bool has(String path) => _paths.contains(path);
  Set<String> get all => _paths;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    await _refresh();
  }

  Future<void> _refresh() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final store = PlaylistStore.decode(prefs.getString(_prefsKey));
      _paths = {for (final p in store.playlists) if (p.name == name) ...p.paths};
    } catch (_) {}
    notifyListeners();
  }

  Future<void> add(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final store = PlaylistStore.decode(prefs.getString(_prefsKey));
    var pl = store.playlists.where((p) => p.name == name).firstOrNull;
    pl ??= store.create(name);
    store.add(pl.id, path);
    await prefs.setString(_prefsKey, store.encode());
    await PlaylistController.reloadAll();
    await _refresh();
  }

  Future<void> remove(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final store = PlaylistStore.decode(prefs.getString(_prefsKey));
    final pl = store.playlists.where((p) => p.name == name).firstOrNull;
    if (pl != null) {
      var i = pl.paths.indexOf(path);
      while (i >= 0) {
        store.removeAt(pl.id, i);
        i = pl.paths.indexOf(path);
      }
      await prefs.setString(_prefsKey, store.encode());
      await PlaylistController.reloadAll();
    }
    await _refresh();
  }

  Future<void> toggle(String path) => has(path) ? remove(path) : add(path);
}
