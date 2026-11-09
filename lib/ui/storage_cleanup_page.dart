import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sidedeck/soulseek/slsk_setup.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/state/ratings.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

/// Frees phone storage by deleting downloaded tracks that break the rules:
/// house music only, 120 to 140 BPM. Shows exactly what would go first, keeps
/// starred tracks, and only looks at the downloads folder.
class StorageCleanupPage extends StatefulWidget {
  const StorageCleanupPage({super.key, required this.library});
  final LibraryController library;

  @override
  State<StorageCleanupPage> createState() => _StorageCleanupPageState();
}

class _Item {
  _Item(this.track, this.reason, this.bytes);
  final LibraryTrack track;
  final String reason;
  final int bytes;
}

class _StorageCleanupPageState extends State<StorageCleanupPage> {
  static const _lo = 120.0;
  static const _hi = 140.0;

  List<_Item> _items = [];
  final Set<String> _off = {}; // ticked off = kept
  int _unknown = 0;
  int _starred = 0;
  int _kept = 0;
  bool _busy = true;
  String _note = 'Reading tags…';

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _busy = true;
      _note = 'Reading genres and tempos…';
    });
    final lib = widget.library;
    await Ratings.instance.load();
    await lib.readTags();
    final dir = SlskSetup.dirFor(lib);
    final out = <_Item>[];
    var unknown = 0, starred = 0, kept = 0;
    for (final t in lib.tracks) {
      if (dir.isEmpty || !t.path.startsWith(dir)) continue; // only the downloads folder
      if (Ratings.instance.starsOf(t.path) > 0) {
        starred++;
        continue;
      }
      final g = t.genre.trim().toLowerCase();
      String? reason;
      if (t.hasAnalysis && (t.bpm! < _lo || t.bpm! > _hi)) {
        reason = '${t.bpm!.round()} BPM (outside 120–140)';
      } else if (g.isNotEmpty && !g.contains('house')) {
        reason = 'Not house (${t.genre.trim()})';
      }
      if (reason != null) {
        var n = 0;
        try {
          n = File(t.path).lengthSync();
        } catch (_) {}
        out.add(_Item(t, reason, n));
      } else if (g.isEmpty && !t.hasAnalysis) {
        unknown++;
      } else {
        kept++;
      }
    }
    out.sort((a, b) => b.bytes.compareTo(a.bytes));
    if (!mounted) return;
    setState(() {
      _items = out;
      _unknown = unknown;
      _starred = starred;
      _kept = kept;
      _busy = false;
      _note = '';
    });
  }

  Future<void> _analyse() async {
    setState(() {
      _busy = true;
      _note = 'Working out tempos… this can take a while.';
    });
    await widget.library.analyzeAll();
    await _scan();
  }

  String _mb(int b) => b >= 1073741824 ? '${(b / 1073741824).toStringAsFixed(2)} GB' : '${(b / 1048576).toStringAsFixed(0)} MB';

  List<_Item> get _toDelete => [for (final i in _items) if (!_off.contains(i.track.path)) i];

  Future<void> _delete() async {
    final list = _toDelete;
    if (list.isEmpty) return;
    final total = list.fold<int>(0, (a, i) => a + i.bytes);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${list.length} tracks?'),
        content: Text('This removes them from your phone for good and frees about ${_mb(total)}. It cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _note = 'Deleting…';
    });
    final n = await widget.library.deleteTracks([for (final i in list) i.track]);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Deleted $n tracks, freed about ${_mb(total)}.')));
    await _scan();
  }

  @override
  Widget build(BuildContext context) {
    final del = _toDelete;
    final total = del.fold<int>(0, (a, i) => a + i.bytes);
    return Scaffold(
      appBar: AppBar(title: const Text('Free up space')),
      body: _busy
          ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const CircularProgressIndicator(), const SizedBox(height: 12), Text(_note)]))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    'Rules: house music only, 120 to 140 BPM. Only the downloads folder is checked, and starred tracks are always kept.\n'
                    '${_items.length} tracks break the rules (${_mb(_items.fold<int>(0, (a, i) => a + i.bytes))}). '
                    '$_kept fit the rules, $_starred starred kept, $_unknown have no genre or tempo yet so are kept.',
                    style: TextStyle(fontSize: 12, color: SideDeckTheme.muted),
                  ),
                ),
                if (widget.library.unanalyzedCount > 0)
                  TextButton(onPressed: _analyse, child: Text('Work out tempo for ${widget.library.unanalyzedCount} tracks first')),
                Expanded(
                  child: ListView.builder(
                    itemCount: _items.length,
                    itemBuilder: (_, i) {
                      final it = _items[i];
                      return CheckboxListTile(
                        dense: true,
                        value: !_off.contains(it.track.path),
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _off.remove(it.track.path);
                          } else {
                            _off.add(it.track.path);
                          }
                        }),
                        title: Text(it.track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${it.reason}  ·  ${_mb(it.bytes)}'),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: del.isEmpty ? null : _delete,
                      icon: const Icon(Icons.delete_outline),
                      label: Text('Delete ${del.length} ticked (${_mb(total)})'),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
