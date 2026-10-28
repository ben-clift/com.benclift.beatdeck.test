import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// The photos shown over the MilkDrop picture. Each one is a small JPEG copy
/// (about 900 pixels on the long side) kept in the app's own folder, so the
/// originals are never touched and the picture page stays light.
class MilkdropPhotos extends ChangeNotifier {
  MilkdropPhotos._();
  static final MilkdropPhotos instance = MilkdropPhotos._();

  static const maxPhotos = 200;

  List<File> files = [];

  /// Bumped whenever the list changes, so the picture pages know to reload.
  int version = 0;
  bool _loaded = false;

  Future<Directory> _dir() async {
    final d = Directory('${(await getApplicationDocumentsDirectory()).path}/visual_photos');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final d = await _dir();
      final l = (await d.list().toList()).whereType<File>().where((f) => f.path.endsWith('.jpg')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      files = l;
      version++;
      notifyListeners();
    } catch (_) {}
  }

  /// Saves already-shrunk JPEG bytes. Returns how many were kept (up to [maxPhotos] in all).
  Future<int> addBytes(List<Uint8List> list) async {
    await load();
    var added = 0;
    try {
      final d = await _dir();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      for (var i = 0; i < list.length && files.length < maxPhotos; i++) {
        final f = File('${d.path}/p${stamp}_${i.toString().padLeft(3, '0')}.jpg');
        await f.writeAsBytes(list[i], flush: true);
        files.add(f);
        added++;
      }
    } catch (_) {}
    if (added > 0) {
      version++;
      notifyListeners();
    }
    return added;
  }

  Future<void> clear() async {
    for (final f in files) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    files = [];
    version++;
    notifyListeners();
  }
}
