import 'dart:io';
import 'package:sidedeck/theme/ph.dart';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/state/ratings.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

/// Pick tracks from what the library is showing now (so a genre filter or
/// "Most played" sort narrows the list) and send them to Google Drive.
Future<void> showExportSheet(BuildContext context, List<LibraryTrack> shown) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ExportSheet(shown: shown),
  );
}

class _ExportSheet extends StatefulWidget {
  const _ExportSheet({required this.shown});
  final List<LibraryTrack> shown;

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  late final Set<String> _sel = {for (final t in widget.shown) t.path};
  bool _busy = false;

  // Filters: favourites only, genre, and a tempo range.
  bool _favOnly = false;
  String? _genre; // null = any; '' = no genre set
  late final double _bpmLo = _bounds().$1;
  late final double _bpmHi = _bounds().$2;
  late RangeValues _bpm = RangeValues(_bpmLo, _bpmHi);

  (double, double) _bounds() {
    final b = [for (final t in widget.shown) if (t.hasAnalysis) t.bpm!];
    if (b.isEmpty) return (60, 200);
    b.sort();
    return (b.first.floorToDouble(), b.last.ceilToDouble());
  }

  bool get _bpmActive => _bpm.start > _bpmLo || _bpm.end < _bpmHi;

  List<String> get _genres {
    final c = <String, int>{};
    for (final t in widget.shown) {
      final g = t.genre.trim();
      if (g.isNotEmpty) c[g] = (c[g] ?? 0) + 1;
    }
    final l = c.keys.toList()..sort((a, b) => c[b]!.compareTo(c[a]!));
    return l.take(30).toList();
  }

  List<LibraryTrack> get _visible => [
        for (final t in widget.shown)
          if ((!_favOnly || Ratings.instance.starsOf(t.path) > 0) &&
              (_genre == null ||
                  (_genre == '' ? t.genre.trim().isEmpty : t.genre.trim().toLowerCase() == _genre!.toLowerCase())) &&
              (!_bpmActive || (t.hasAnalysis && t.bpm! >= _bpm.start && t.bpm! <= _bpm.end)))
            t
      ];

  /// Changing a filter selects exactly the tracks that match.
  void _refilter() {
    _sel
      ..clear()
      ..addAll(_visible.map((t) => t.path));
  }

  @override
  void initState() {
    super.initState();
    Ratings.instance.load().then((_) {
      if (mounted) setState(() {});
    });
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

  Widget _filters() {
    final genres = _genres;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 96),
            child: SingleChildScrollView(
              child: Wrap(
            spacing: 6,
            runSpacing: 0,
            children: [
              FilterChip(
                label: const Text('Favourites'),
                selected: _favOnly,
                onSelected: (v) => setState(() {
                  _favOnly = v;
                  _refilter();
                }),
              ),
              for (final g in genres)
                FilterChip(
                  label: Text(g),
                  selected: _genre == g,
                  onSelected: (v) => setState(() {
                    _genre = v ? g : null;
                    _refilter();
                  }),
                ),
              FilterChip(
                label: const Text('No genre'),
                selected: _genre == '',
                onSelected: (v) => setState(() {
                  _genre = v ? '' : null;
                  _refilter();
                }),
              ),
            ],
          ),
            ),
          ),
          Row(
            children: [
              Text('BPM ${_bpm.start.round()} to ${_bpm.end.round()}',
                  style: const TextStyle(fontSize: 12, color: SideDeckTheme.muted)),
              Expanded(
                child: RangeSlider(
                  values: _bpm,
                  min: _bpmLo,
                  max: _bpmHi <= _bpmLo ? _bpmLo + 1 : _bpmHi,
                  onChanged: (v) => setState(() {
                    _bpm = v;
                    _refilter();
                  }),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height * 0.8;
    return SizedBox(
      height: h,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text('Send to Google Drive',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
                TextButton(
                  onPressed: () => setState(_refilter),
                  child: const Text('All'),
                ),
                TextButton(onPressed: () => setState(_sel.clear), child: const Text('None')),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Use the filters to pick what to send. Tracks with no tempo yet are left out when you move the BPM slider.',
                style: TextStyle(fontSize: 12, color: SideDeckTheme.muted),
              ),
            ),
          ),
          _filters(),
          Expanded(
            child: ListView.builder(
              itemCount: _visible.length,
              itemBuilder: (_, i) {
                final t = _visible[i];
                return CheckboxListTile(
                  dense: true,
                  value: _sel.contains(t.path),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _sel.add(t.path);
                    } else {
                      _sel.remove(t.path);
                    }
                  }),
                  title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(t.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: (_visible.every((t) => !_sel.contains(t.path)) || _busy) ? null : _send,
                icon: const Icon(Ph.cloudUploadOutlined),
                label: Text(_busy ? 'Opening…' : 'Send ${_visible.where((t) => _sel.contains(t.path)).length} to Google Drive'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
