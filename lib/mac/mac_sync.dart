import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/debug/debug_log.dart';
import 'package:sidedeck/soulseek/storage_guard.dart';
import 'package:sidedeck/state/library_controller.dart';

/// Pulls the tracks from folders shared by the BeatDeck Mac script
/// (tools/beatdeck-share.py) into the library, ten at a time: each batch is
/// downloaded, added, and analysed for genre (tags) and BPM before the next.
class MacSync extends ChangeNotifier {
  MacSync._();
  static final MacSync instance = MacSync._();

  static const batchSize = 10;

  String url = '';
  String pin = '';
  int limit = 100000; // the storage limits below are what stop a run
  String stoppedFor = '';
  bool running = false;
  bool _cancel = false;
  /// While this returns true (a playlist is playing) the background sync waits.
  bool Function()? hold;
  final Set<String> _fetching = {};
  int total = 0;
  int done = 0;
  int failed = 0;
  String status = '';

  // ---- Streaming: tracks are kept as empty "stubs" (same name, size and date,
  // no disk used) and fetched from the Mac when a deck needs them. The most
  // recently used real files are kept up to your storage limit.
  DateTime? _downAt;

  /// The Mac did not answer a moment ago: its tracks are skipped for a while
  /// so a dead connection never freezes the Booth.
  bool get down => _downAt != null && DateTime.now().difference(_downAt!).inSeconds < 90;

  Set<String> _stubs = {};
  Map<String, int> _mtime = {};
  Map<String, int> _used = {};
  bool _stateLoaded = false;
  Directory? _root;

  Future<Directory> _rootDir() async {
    final r = _root;
    if (r != null) return r;
    final support = await getApplicationSupportDirectory();
    final d = Directory(p.join(support.path, 'mac'));
    await d.create(recursive: true);
    return _root = d;
  }

  Future<void> _loadState() async {
    if (_stateLoaded) return;
    _stateLoaded = true;
    final prefs = await SharedPreferences.getInstance();
    _stubs = (prefs.getStringList('mac_stub') ?? <String>[]).toSet();
    try {
      _mtime = {for (final e in (jsonDecode(prefs.getString('mac_mtime') ?? '{}') as Map).entries) '${e.key}': (e.value as num).toInt()};
      _used = {for (final e in (jsonDecode(prefs.getString('mac_used') ?? '{}') as Map).entries) '${e.key}': (e.value as num).toInt()};
    } catch (_) {}
    if (url.isEmpty) await load();
  }

  Future<void> _saveState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('mac_stub', _stubs.toList());
    await prefs.setString('mac_mtime', jsonEncode(_mtime));
    await prefs.setString('mac_used', jsonEncode(_used));
  }

  String _prefix = '';

  /// Call once at start so the library can tell Mac tracks apart.
  Future<void> init() async {
    final r = await _rootDir();
    _prefix = r.path + Platform.pathSeparator;
    await _loadState();
    notifyListeners();
    unawaited(_trim());
  }

  /// A track that came from the Mac.
  bool isMac(String path) => _prefix.isNotEmpty && path.startsWith(_prefix);

  /// A Mac track that is still on the Mac (streams when played).
  bool isStub(String path) => _stubs.contains(path);

  /// Makes sure [path] is a real file before a deck loads it: if it is a
  /// stub, it is fetched from the Mac now. Returns false if it cannot be.
  Future<bool> ensure(String path) async {
    await _loadState();
    if (!_stubs.contains(path)) {
      if (_used.containsKey(path)) {
        _used[path] = DateTime.now().millisecondsSinceEpoch;
      }
      return true;
    }
    if (down) {
      status = 'The Mac is not answering. Is the Terminal window open and the phone on the same Wi-Fi?';
      notifyListeners();
      return false;
    }
    try {
      final root = await _rootDir();
      final rel = p.split(p.relative(path, from: root.path)).join('/');
      final f = File(path);
      final want = await f.length();
      final part = File('$path.part');
      await _trim();
      DebugLog.add('mac', 'streaming from the Mac: $rel');
      await _download(rel, part);
      if (await part.length() != want) {
        await part.delete();
        throw 'the file on the Mac has changed';
      }
      await part.rename(path);
      final mt = _mtime[path];
      if (mt != null) await File(path).setLastModified(DateTime.fromMillisecondsSinceEpoch(mt));
      _stubs.remove(path);
      _used[path] = DateTime.now().millisecondsSinceEpoch;
      await _saveState();
      _downAt = null;
      unawaited(_trim());
      return true;
    } catch (e) {
      _downAt = DateTime.now();
      DebugLog.add('mac', 'could not fetch $path from the Mac: $e (Mac tracks paused for 90 s)');
      status = 'Cannot reach the Mac to play this track. Is the Terminal window still open?';
      notifyListeners();
      return false;
    }
  }

  /// Fetches a track from the Mac ahead of time (once at a time per track).
  Future<void> prefetch(String path) async {
    if (!_stubs.contains(path) || !_fetching.add(path)) return;
    try {
      await ensure(path);
    } finally {
      _fetching.remove(path);
    }
  }

  Future<void> _stub(String path) async {
    final f = File(path);
    if (!await f.exists()) return;
    final st = await f.stat();
    final mt = _mtime[path] ?? st.modified.millisecondsSinceEpoch;
    final raf = await f.open(mode: FileMode.write);
    await raf.truncate(0); // free the real data first
    await raf.truncate(st.size); // then sparse: same length, no disk used
    await raf.close();
    await f.setLastModified(DateTime.fromMillisecondsSinceEpoch(mt));
    _mtime[path] = mt;
    _stubs.add(path);
    _used.remove(path);
  }

  bool _trimming = false;

  /// Keeps real (fetched) files within your storage limit by turning the
  /// least recently used ones back into stubs.
  Future<void> _trim() async {
    if (_trimming) return;
    _trimming = true;
    try {
      await StorageGuard.load();
      final root = await _rootDir();
      final real = <String, int>{};
      await for (final e in root.list(recursive: true, followLinks: false)) {
        if (e is File && !_stubs.contains(e.path) && !e.path.endsWith('.part')) {
          real[e.path] = await e.length();
        }
      }
      var total = real.values.fold<int>(0, (a, b) => a + b);
      var cap = (StorageGuard.maxGb * 1024 * 1024 * 1024).round();
      // Also keep the phone's free space (your reserve) untouched.
      final free = StorageGuard.freeBytes(root.path);
      final reserve = (StorageGuard.reserveGb * 1024 * 1024 * 1024).round();
      if (free != null && free < reserve) cap = math.max(0, total - (reserve - free));
      final recent = DateTime.now().millisecondsSinceEpoch - 15 * 60 * 1000;
      final order = real.keys.toList()..sort((a, b) => (_used[a] ?? 0).compareTo(_used[b] ?? 0));
      for (final path in order) {
        if (total <= cap) break;
        if ((_used[path] ?? 0) > recent) continue; // probably on a deck
        total -= real[path]!;
        await _stub(path);
      }
      await _saveState();
    } catch (e) {
      DebugLog.add('mac', 'trim error: $e');
    } finally {
      _trimming = false;
    }
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    url = prefs.getString('mac_url') ?? '';
    pin = prefs.getString('mac_pin') ?? '';
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mac_url', url.trim());
    await prefs.setString('mac_pin', pin.trim());
  }

  Uri _uri(String path, [Map<String, String> q = const {}]) {
    var base = url.trim();
    if (!base.startsWith('http')) base = 'http://$base';
    base = base.replaceAll(RegExp(r'/+$'), '');
    return Uri.parse(base).replace(path: path, queryParameters: {...q, 'pin': pin.trim()});
  }

  Future<List<Map<String, dynamic>>> _index() async {
    final r = await http.get(_uri('/index')).timeout(const Duration(seconds: 60));
    if (r.statusCode == 403) throw 'Wrong code. Check the code shown on the Mac.';
    if (r.statusCode != 200) throw 'The Mac answered ${r.statusCode}.';
    return [for (final e in jsonDecode(r.body) as List) Map<String, dynamic>.from(e as Map)];
  }

  void _set(String s) {
    status = s;
    notifyListeners();
  }

  /// Checks the address and code. Returns the number of tracks the Mac shares.
  Future<int?> test() async {
    try {
      _set('Connecting…');
      final n = (await _index()).length;
      DebugLog.add('mac', 'test ok: ${_uri('/index').origin}, $n tracks');
      _set('Connected. The Mac is sharing $n tracks.');
      return n;
    } catch (e) {
      DebugLog.add('mac', 'test failed (${_uri('/index').origin}): $e');
      _set('${_friendly(e)}\n(${e.toString().split('\n').first})');
      return null;
    }
  }

  String _friendly(Object e) {
    final s = '$e';
    if (e is String) return s;
    if (s.contains('SocketException') || s.contains('TimeoutException') || s.contains('Connection')) {
      return 'Cannot reach the Mac. Same Wi-Fi? Is the Terminal window still open? Is the address right?';
    }
    return s;
  }

  void stop() {
    _cancel = true;
    _set('Stopping after this track…');
  }

  Future<void> start(LibraryController lib) async {
    if (running) return;
    running = true;
    DebugLog.add('mac', 'sync button pressed: ${url.trim()}');
    _cancel = false;
    done = 0;
    failed = 0;
    total = 0;
    notifyListeners();
    try {
      await save();
      _set('Reading the list of tracks on the Mac…');
      final index = await _index();
      final prefs = await SharedPreferences.getInstance();
      final synced = (prefs.getStringList('mac_synced') ?? <String>[]).toSet();
      final all = [for (final e in index) if (!synced.contains('${e['p']}|${e['s']}')) e];
      final todo = all.take(limit).toList();
      total = todo.length;
      if (todo.isEmpty) {
        _set('Everything on the Mac is already in BeatDeck (${index.length} tracks).');
        return;
      }
      final support = await getApplicationSupportDirectory();
      final root = Directory(p.join(support.path, 'mac'));
      await root.create(recursive: true);
      await StorageGuard.load();
      await _loadState();
      stoppedFor = '';
      DebugLog.add('mac', 'sync start: ${todo.length} new of ${index.length} tracks');
      for (var i = 0; i < todo.length && !_cancel; i += batchSize) {
        final batch = todo.sublist(i, (i + batchSize).clamp(0, todo.length));
        final got = <String>[];
        for (final e in batch) {
          if (_cancel) break;
          while (!_cancel && (hold?.call() ?? false)) {
            _set('Paused while your playlist plays…');
            await Future<void>.delayed(const Duration(seconds: 2));
          }
          // Keep the phone's free space (your Auto DJ setting) untouched.
          final free = StorageGuard.freeBytes(root.path);
          if (free != null && free - (e['s'] as num).toInt() < StorageGuard.reserveGb * 1024 * 1024 * 1024) {
            stoppedFor = 'Phone space is low (${(free / 1073741824).toStringAsFixed(1)} GB free)';
            _cancel = true;
            break;
          }
          final rel = '${e['p']}';
          final target = File(p.joinAll([root.path, ...rel.split('/').where((s) => s.isNotEmpty && s != '..')]));
          _set('Downloading ${done + 1} of $total: ${p.basename(rel)}');
          try {
            if (!(await target.exists() && await target.length() == (e['s'] as num).toInt())) {
              await target.parent.create(recursive: true);
              await _download(rel, target);
            }
            got.add(target.path);
            _mtime[target.path] = (await target.stat()).modified.millisecondsSinceEpoch;
            synced.add('$rel|${e['s']}');
          } catch (err) {
            failed++;
            DebugLog.add('mac', 'download failed: $rel ($err)');
            try {
              if (await target.exists()) await target.delete();
            } catch (_) {}
          }
          done++;
          notifyListeners();
        }
        // Add the batch, then work out genre and BPM for these ten.
        for (final path in got) {
          await lib.addFile(path);
        }
        while (!_cancel && (hold?.call() ?? false)) {
          _set('Paused while your playlist plays…');
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        _set('Analysing genre and BPM for ${got.length} tracks…');
        while (lib.analyzing) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        final need = [for (final path in got) if (lib.tracks.any((t) => t.path == path && !t.hasAnalysis)) path];
        if (need.isNotEmpty) await lib.analyzePaths(need);
        await lib.readTags();
        // Streaming: now that genre and BPM are known, empty the files. They
        // are fetched from the Mac again when a deck needs them.
        for (final path in got) {
          if (lib.tracks.any((t) => t.path == path)) await _stub(path);
        }
        await _saveState();
        await prefs.setStringList('mac_synced', synced.toList());
      }
      _set(stoppedFor.isNotEmpty
          ? 'Stopped: $stoppedFor. $done of $total done. Raise the limit in Auto DJ settings to bring more.'
          : _cancel
          ? 'Stopped. $done of $total done. Start again to carry on.'
          : 'Finished. $done tracks brought over${failed == 0 ? '' : ', $failed failed'}.');
    } catch (e) {
      _set(_friendly(e));
      DebugLog.add('mac', 'sync error: $e');
    } finally {
      running = false;
      notifyListeners();
    }
  }

  Future<void> _download(String rel, File target) async {
    final client = http.Client();
    try {
      final resp = await client.send(http.Request('GET', _uri('/file', {'p': rel}))).timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) throw 'status ${resp.statusCode}';
      final sink = target.openWrite();
      try {
        await resp.stream.timeout(const Duration(seconds: 20)).pipe(sink);
      } catch (_) {
        await sink.close().catchError((_) {});
        rethrow;
      }
    } finally {
      client.close();
    }
  }
}
