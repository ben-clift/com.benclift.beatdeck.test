import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/debug/debug_log.dart';
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
  bool running = false;
  bool _cancel = false;
  int total = 0;
  int done = 0;
  int failed = 0;
  String status = '';

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
      _set('Connected. The Mac is sharing $n tracks.');
      return n;
    } catch (e) {
      _set(_friendly(e));
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
      final todo = [for (final e in index) if (!synced.contains('${e['p']}|${e['s']}')) e];
      total = todo.length;
      if (todo.isEmpty) {
        _set('Everything on the Mac is already in BeatDeck (${index.length} tracks).');
        return;
      }
      final support = await getApplicationSupportDirectory();
      final root = Directory(p.join(support.path, 'mac'));
      await root.create(recursive: true);
      DebugLog.add('mac', 'sync start: ${todo.length} new of ${index.length} tracks');
      for (var i = 0; i < todo.length && !_cancel; i += batchSize) {
        final batch = todo.sublist(i, (i + batchSize).clamp(0, todo.length));
        final got = <String>[];
        for (final e in batch) {
          if (_cancel) break;
          final rel = '${e['p']}';
          final target = File(p.joinAll([root.path, ...rel.split('/').where((s) => s.isNotEmpty && s != '..')]));
          _set('Downloading ${done + 1} of $total: ${p.basename(rel)}');
          try {
            if (!(await target.exists() && await target.length() == (e['s'] as num).toInt())) {
              await target.parent.create(recursive: true);
              await _download(rel, target);
            }
            got.add(target.path);
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
        _set('Analysing genre and BPM for ${got.length} tracks…');
        while (lib.analyzing) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        final need = [for (final path in got) if (lib.tracks.any((t) => t.path == path && !t.hasAnalysis)) path];
        if (need.isNotEmpty) await lib.analyzePaths(need);
        await lib.readTags();
        await prefs.setStringList('mac_synced', synced.toList());
      }
      _set(_cancel
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
      final resp = await client.send(http.Request('GET', _uri('/file', {'p': rel}))).timeout(const Duration(seconds: 60));
      if (resp.statusCode != 200) throw 'status ${resp.statusCode}';
      final sink = target.openWrite();
      try {
        await resp.stream.timeout(const Duration(seconds: 60)).pipe(sink);
      } catch (_) {
        await sink.close().catchError((_) {});
        rethrow;
      }
    } finally {
      client.close();
    }
  }
}
