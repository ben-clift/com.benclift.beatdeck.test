import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sidedeck/soulseek/slsk_setup.dart';
import 'package:sidedeck/soulseek/soulseek_client.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';
import 'package:sidedeck/ui/soulseek_page.dart';

/// Type an artist and a track, search the Soulseek network for every version
/// (remixes, edits, VIPs, dubs, bootlegs...), tick the ones you want and get them.
class RemixFinderPage extends StatefulWidget {
  const RemixFinderPage({super.key, required this.library});
  final LibraryController library;

  @override
  State<RemixFinderPage> createState() => _RemixFinderPageState();
}

class _Version {
  _Version(this.key, this.label);
  final String key;
  final String label;
  final List<SlskResult> sources = [];

  SlskResult get best {
    final l = [...sources]..sort((a, b) => _score(b).compareTo(_score(a)));
    return l.first;
  }

  static int _score(SlskResult r) {
    final lossless = const {'flac', 'wav', 'aiff', 'aif', 'alac'}.contains(r.ext);
    final q = lossless ? 400 : (r.bitrate >= 320 ? 300 : r.bitrate.clamp(0, 256));
    return (r.freeSlot ? 1000 : 0) + q + (r.speed ~/ 100000).clamp(0, 50) - r.queue.clamp(0, 200);
  }
}

class _RemixFinderPageState extends State<RemixFinderPage> {
  final _artist = TextEditingController();
  final _track = TextEditingController();
  static const _types = ['Remix', 'Edit', 'VIP', 'Dub', 'Bootleg', 'Rework', 'Extended', 'Original', 'Other'];

  final Map<String, _Version> _versions = {};
  final Set<String> _picked = {};
  String _type = 'All';
  bool _goodOnly = false;
  bool _busy = false;
  String _status = '';

  @override
  void dispose() {
    _artist.dispose();
    _track.dispose();
    super.dispose();
  }

  static String _typeOf(SlskResult r) {
    final s = '${r.fileName} ${r.folder}'.toLowerCase();
    bool has(String p) => RegExp(p).hasMatch(s);
    if (has(r'instrumental|acapella|a cappella')) return 'Other';
    if (has(r'\bvip\b')) return 'VIP';
    if (has(r'bootleg|mashup')) return 'Bootleg';
    if (has(r'rework|re-work|\bflip\b')) return 'Rework';
    if (has(r'remix|\brmx\b')) return 'Remix';
    if (has(r'\bdub\b')) return 'Dub';
    if (has(r'\bedit\b')) return 'Edit';
    if (has(r'extended|club mix')) return 'Extended';
    if (has(r'original mix|original')) return 'Original';
    return 'Other';
  }

  static String _norm(String file) {
    var s = file.toLowerCase();
    final dot = s.lastIndexOf('.');
    if (dot > 0) s = s.substring(0, dot);
    s = s.replaceFirst(RegExp(r'^\s*(cd\d+[-_ ]*)?\d{1,3}\s*[-_. ]+'), '');
    s = s.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
    return s;
  }

  Future<void> _search() async {
    final a = _artist.text.trim();
    final t = _track.text.trim();
    if (t.isEmpty) return;
    if (!soulseek.online) {
      setState(() => _status = 'Not signed in to Soulseek yet.');
      return;
    }
    SlskSetup.wire(widget.library);
    setState(() {
      _busy = true;
      _versions.clear();
      _picked.clear();
      _type = 'All';
      _status = 'Searching…';
    });
    final base = '$a $t'.trim();
    final queries = [base, '$base remix', '$base edit', '$base vip', '$base dub'];
    final words = _norm(t).split(' ').where((w) => w.length > 2).toList();
    for (var i = 0; i < queries.length && mounted; i++) {
      setState(() => _status = 'Searching ${i + 1} of ${queries.length}: ${queries[i]}');
      soulseek.search(queries[i]);
      await Future<void>.delayed(const Duration(seconds: 9));
      for (final r in List<SlskResult>.of(soulseek.results)) {
        final key = _norm(r.fileName);
        if (words.isNotEmpty && !words.every(key.contains)) continue; // wrong song
        final v = _versions.putIfAbsent(key, () => _Version(key, _typeOf(r)));
        if (!v.sources.any((s) => s.user == r.user && s.path == r.path)) v.sources.add(r);
      }
      if (mounted) setState(() {});
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _status = _versions.isEmpty
            ? 'Nothing found. Check the spelling, or try just the track name.'
            : '${_versions.length} versions found.';
      });
    }
  }

  bool _isGood(_Version v) {
    final r = v.best;
    return const {'flac', 'wav', 'aiff', 'aif', 'alac'}.contains(r.ext) || r.bitrate >= 256;
  }

  List<_Version> get _shown {
    final l = [
      for (final v in _versions.values)
        if ((_type == 'All' || v.label == _type) && (!_goodOnly || _isGood(v))) v,
    ]..sort((a, b) {
        final c = b.sources.length.compareTo(a.sources.length);
        return c != 0 ? c : _Version._score(b.best).compareTo(_Version._score(a.best));
      });
    return l;
  }

  void _get() {
    var n = 0;
    for (final v in _versions.values) {
      if (_picked.contains(v.key)) {
        soulseek.download(v.best);
        n++;
      }
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Getting $n ${n == 1 ? 'version' : 'versions'}. They join your library when finished.')));
    setState(_picked.clear);
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final counts = <String, int>{for (final v in _versions.values) v.label: 0};
    for (final v in _versions.values) {
      counts[v.label] = (counts[v.label] ?? 0) + 1;
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Find remixes')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              children: [
                TextField(
                  controller: _artist,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(labelText: 'Artist'),
                ),
                TextField(
                  controller: _track,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _busy ? null : _search(),
                  decoration: const InputDecoration(labelText: 'Track'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _search,
                        icon: const Icon(Icons.search),
                        label: Text(_busy ? 'Searching…' : 'Find all versions'),
                      ),
                    ),
                    if (!soulseek.online) ...[
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: () async {
                          await Navigator.of(context).push(MaterialPageRoute<void>(
                              builder: (_) => SoulseekPage(library: widget.library)));
                          if (mounted) setState(() {});
                        },
                        child: const Text('Sign in'),
                      ),
                    ],
                  ],
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(_status, style: TextStyle(fontSize: 12, color: SideDeckTheme.muted)),
                  ),
                ),
              ],
            ),
          ),
          if (_versions.isNotEmpty) ...[
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final t in ['All', ..._types])
                    if (t == 'All' || (counts[t] ?? 0) > 0)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(t == 'All' ? 'All (${_versions.length})' : '$t (${counts[t]})'),
                          selected: _type == t,
                          onSelected: (_) => setState(() => _type = t),
                        ),
                      ),
                ],
              ),
            ),
            SwitchListTile(
              dense: true,
              title: const Text('Good quality only (256+ kbps or lossless)'),
              value: _goodOnly,
              onChanged: (v) => setState(() => _goodOnly = v),
            ),
          ],
          Expanded(
            child: ListView.builder(
              itemCount: shown.length,
              itemBuilder: (_, i) {
                final v = shown[i];
                final r = v.best;
                final kbps = const {'flac', 'wav', 'aiff', 'aif', 'alac'}.contains(r.ext)
                    ? r.ext.toUpperCase()
                    : (r.bitrate > 0 ? '${r.bitrate} kbps' : r.ext);
                return CheckboxListTile(
                  dense: true,
                  value: _picked.contains(v.key),
                  onChanged: (on) => setState(() {
                    if (on == true) {
                      _picked.add(v.key);
                    } else {
                      _picked.remove(v.key);
                    }
                  }),
                  title: Text(r.fileName, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${v.label}  ·  $kbps  ·  ${(r.size / 1048576).toStringAsFixed(1)} MB  ·  '
                    '${v.sources.length} ${v.sources.length == 1 ? 'source' : 'sources'}'
                    '${r.freeSlot ? '  ·  ready now' : ''}',
                  ),
                );
              },
            ),
          ),
          if (_picked.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _get,
                  icon: const Icon(Icons.download),
                  label: Text('Get ${_picked.length} selected'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
