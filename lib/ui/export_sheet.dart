import 'dart:io';
import 'package:sidedeck/theme/ph.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/state/ratings.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

/// Pick tracks (filter by genre, BPM or favourites, and listen to a 30 second
/// snip from one minute in) and send them to Google Drive.
Future<void> showExportSheet(BuildContext context, List<LibraryTrack> shown, {LibraryController? lib}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ExportSheet(shown: shown, lib: lib),
  ).whenComplete(() => const MethodChannel('beatdeck/preview').invokeMethod<void>('stop').catchError((_) {}));
}

class _ExportSheet extends StatefulWidget {
  const _ExportSheet({required this.shown, this.lib});
  final List<LibraryTrack> shown;
  final LibraryController? lib;

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  static const _ch = MethodChannel('beatdeck/preview');
  static const _noTag = 'No genre tag';

  late final Set<String> _sel = {for (final t in widget.shown) t.path};
  bool _busy = false;
  bool _favOnly = false;
  final Set<String> _genreSel = {}; // empty = every genre
  Map<String, String> _liveGenre = {};
  late final double _bpmLo;
  late final double _bpmHi;
  late RangeValues _bpm;
  String? _playing;

  @override
  void initState() {
    super.initState();
    final bpms = [for (final t in widget.shown) if (t.hasAnalysis) t.bpm!];
    _bpmLo = bpms.isEmpty ? 60 : bpms.reduce((a, b) => a < b ? a : b).floorToDouble();
    _bpmHi = bpms.isEmpty ? 200 : (bpms.reduce((a, b) => a > b ? a : b).ceilToDouble().clamp(_bpmLo + 1, 400)).toDouble();
    _bpm = RangeValues(_bpmLo, _bpmHi);
    Ratings.instance.load().then((_) {
      if (mounted) setState(() {});
    });
    // Genres are read from the files' tags in the background; pick them up as they arrive.
    final lib = widget.lib;
    if (lib != null) {
      lib.addListener(_refreshGenres);
      _refreshGenres();
      lib.readTags();
    }
  }

  void _refreshGenres() {
    final lib = widget.lib;
    if (lib == null || !mounted) return;
    _liveGenre = {for (final t in lib.tracks) if (t.genre.trim().isNotEmpty) t.path: t.genre.trim()};
    setState(() {});
  }

  @override
  void dispose() {
    widget.lib?.removeListener(_refreshGenres);
    super.dispose();
  }

  String _genreOf(LibraryTrack t) {
    final g = (_liveGenre[t.path] ?? t.genre).trim();
    return g.isEmpty ? _noTag : g;
  }

  /// Genre name -> how many of these tracks have it (biggest first).
  List<MapEntry<String, int>> get _genreCounts {
    final m = <String, int>{};
    for (final t in widget.shown) {
      m[_genreOf(t)] = (m[_genreOf(t)] ?? 0) + 1;
    }
    final l = m.entries.toList()
      ..sort((a, b) => a.key == _noTag ? 1 : (b.key == _noTag ? -1 : b.value.compareTo(a.value)));
    return l;
  }

  Future<void> _pickGenres() async {
    final counts = _genreCounts;
    final pick = {..._genreSel};
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Genres'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final e in counts)
                  CheckboxListTile(
                    dense: true,
                    value: pick.contains(e.key),
                    title: Text('${e.key} (${e.value})'),
                    onChanged: (v) => setD(() {
                      if (v == true) {
                        pick.add(e.key);
                      } else {
                        pick.remove(e.key);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => setD(pick.clear), child: const Text('Clear')),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
          ],
        ),
      ),
    );
    if (!mounted) return;
    setState(() {
      _genreSel
        ..clear()
        ..addAll(pick);
      _filtersChanged();
    });
  }

  List<LibraryTrack> get _visible {
    final bpmFiltered = _bpm.start > _bpmLo || _bpm.end < _bpmHi;
    return [
      for (final t in widget.shown)
        if ((_genreSel.isEmpty || _genreSel.contains(_genreOf(t))) &&
            (!_favOnly || Ratings.instance.starsOf(t.path) > 0) &&
            (!bpmFiltered || (t.hasAnalysis && t.bpm! >= _bpm.start && t.bpm! <= _bpm.end)))
          t,
    ];
  }

  void _filtersChanged() {
    // Selecting follows the filter: what you can see is what gets ticked.
    _sel
      ..clear()
      ..addAll(_visible.map((t) => t.path));
  }

  Future<void> _togglePlay(LibraryTrack t) async {
    try {
      if (_playing == t.path) {
        await _ch.invokeMethod<void>('stop');
        setState(() => _playing = null);
      } else {
        // 30 seconds from one minute in (earlier for short tracks).
        final dur = t.durationMs;
        final start = dur > 100000 ? 60000 : (dur > 40000 ? dur - 35000 : 0);
        await _ch.invokeMethod<void>('play', {'path': t.path, 'startMs': start, 'lenMs': 30000});
        setState(() => _playing = t.path);
        Future.delayed(const Duration(seconds: 31), () {
          if (mounted && _playing == t.path) setState(() => _playing = null);
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not play that file.')));
      }
    }
  }

  Future<void> _send() async {
    final files = [
      for (final t in _visible)
        if (_sel.contains(t.path) && File(t.path).existsSync()) XFile(t.path),
    ];
    if (files.isEmpty) return;
    setState(() => _busy = true);
    try {
      // Opens the phone's share sheet: choose Drive (Save to Drive) there.
      await SharePlus.instance.share(ShareParams(files: files, subject: 'BeatDeck tracks'));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not share: $e')));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height * 0.85;
    final vis = _visible;
    final nSel = vis.where((t) => _sel.contains(t.path)).length;
    return SizedBox(
      height: h,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Row(
              children: [
                const Expanded(
                  child: Text('Send to Google Drive',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
                TextButton(
                  onPressed: () => setState(() => _sel
                    ..clear()
                    ..addAll(vis.map((t) => t.path))),
                  child: const Text('All'),
                ),
                TextButton(onPressed: () => setState(_sel.clear), child: const Text('None')),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickGenres,
                    icon: const Icon(Icons.library_music_outlined, size: 18),
                    label: Text(
                      _genreSel.isEmpty
                          ? 'All genres (${_genreCounts.length})'
                          : (_genreSel.length == 1 ? _genreSel.first : '${_genreSel.length} genres selected'),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                const Icon(Icons.star, size: 18),
                Switch(
                  value: _favOnly,
                  onChanged: (v) => setState(() {
                    _favOnly = v;
                    _filtersChanged();
                  }),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text('BPM ${_bpm.start.round()} – ${_bpm.end.round()}',
                    style: TextStyle(fontSize: 12, color: SideDeckTheme.muted)),
                Expanded(
                  child: RangeSlider(
                    values: _bpm,
                    min: _bpmLo,
                    max: _bpmHi,
                    onChanged: (v) => setState(() {
                      _bpm = v;
                      _filtersChanged();
                    }),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${vis.length} tracks shown. Tap play to hear 30 seconds from one minute in.',
                style: TextStyle(fontSize: 12, color: SideDeckTheme.muted),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: vis.length,
              itemBuilder: (_, i) {
                final t = vis[i];
                final on = _playing == t.path;
                final fav = Ratings.instance.starsOf(t.path) > 0;
                return ListTile(
                  dense: true,
                  leading: IconButton(
                    icon: Icon(on ? Icons.stop_circle_outlined : Icons.play_circle_outline, size: 30),
                    onPressed: () => _togglePlay(t),
                  ),
                  title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    [
                      if (t.artist.isNotEmpty) t.artist,
                      if (t.hasAnalysis) '${t.bpm!.round()} BPM',
                      if (_genreOf(t) != _noTag) _genreOf(t),
                    ].join('  ·  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (fav) const Icon(Icons.star, size: 16),
                      Checkbox(
                        value: _sel.contains(t.path),
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _sel.add(t.path);
                          } else {
                            _sel.remove(t.path);
                          }
                        }),
                      ),
                    ],
                  ),
                  onTap: () => setState(() {
                    if (!_sel.add(t.path)) _sel.remove(t.path);
                  }),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: (nSel == 0 || _busy) ? null : _send,
                icon: const Icon(Ph.cloudUploadOutlined),
                label: Text(_busy ? 'Opening…' : 'Send $nSel to Google Drive'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
