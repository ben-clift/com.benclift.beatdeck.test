import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sidedeck/suggest/explore.dart';
import 'package:sidedeck/suggest/taste.dart';
import 'package:sidedeck/suggest/track_import.dart';
import 'package:sidedeck/ui/explore_page.dart';
import 'package:sidedeck/ui/finder_host.dart';
import 'package:sidedeck/ui/screenshot_import.dart';
import 'package:sidedeck/wishlist/wishlist.dart';

/// The tracks you already have on your Mac, read from screenshots of Finder
/// or pasted file names. Explore uses them as your taste and hides them from
/// results. Each one gets links to listen or buy on the sites themselves.
class MyTracksPage extends StatefulWidget {
  const MyTracksPage({super.key, this.host = const FinderHost()});

  final FinderHost host;

  @override
  State<MyTracksPage> createState() => _MyTracksPageState();
}

class _MyTracksPageState extends State<MyTracksPage> {
  final _my = MyTracks.instance;
  final _wish = WishListController();
  bool _busy = false;
  bool _finding = false;
  bool _stop = false;
  String _progress = '';

  @override
  void initState() {
    super.initState();
    _my.load();
  }

  @override
  void dispose() {
    _stop = true;
    _wish.dispose();
    super.dispose();
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _open(String url) async {
    var ok = false;
    try {
      ok = (await const MethodChannel('sidedeck/audio').invokeMethod<bool>('openUrl', {'url': url})) ?? false;
    } catch (_) {}
    if (!ok) _toast('Could not open the link.');
  }

  /// Shows the lines for checking; returns the text, or null when cancelled.
  Future<String?> _review(String intro, List<String> lines) {
    final c = TextEditingController(text: lines.join('\n'));
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Is this right?'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(intro, style: const TextStyle(fontSize: 12, color: Color(0xFF8A857C))),
            const SizedBox(height: 8),
            Flexible(
              child: TextField(
                controller: c,
                maxLines: null,
                minLines: 8,
                decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Add')),
        ],
      ),
    );
  }

  Future<void> _fromScreenshots() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final lines = await ScreenshotImport.pickAndRead();
      if (lines.isEmpty) {
        _toast('No text found.');
        return;
      }
      var found = TrackNameParser.parseAll(lines);
      if (found.length < 3) {
        // No file extensions in view: take any line that looks like a song.
        found = TrackNameParser.parseAll(lines.where((l) => l.contains(' - ') || l.contains('_')), requireExt: false);
      }
      if (!mounted) return;
      final text = await _review(
        'One song per line: Artist - Title (Mix) [Label]. Fix anything the camera read wrongly, and delete lines that are folders.',
        [for (final t in found) t.display],
      );
      if (text == null) return;
      await _addText(text, fromFiles: false);
    } catch (e) {
      _toast('Could not read the screenshots: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pasteNames() async {
    final clip = (await Clipboard.getData('text/plain'))?.text ?? '';
    if (!mounted) return;
    final text = await _review(
      'Paste file names or "Artist - Title" lines, one per line. Numbers, extensions and key/BPM endings are cleaned up.',
      clip.split('\n'),
    );
    if (text == null) return;
    await _addText(text, fromFiles: true);
  }

  Future<void> _addText(String text, {required bool fromFiles}) async {
    final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty);
    final list = <ImportedTrack>[];
    final seen = <String>{};
    for (final l in lines) {
      final t = TrackNameParser.parse(l, requireExt: false, stripNumbers: fromFiles && TrackNameParser.hasAudioExtension(l));
      if (t != null && seen.add(t.id)) list.add(t);
    }
    final n = await _my.addAll(list);
    Taste.invalidate();
    _toast(n == 0 ? 'Nothing new to add.' : 'Added $n track${n == 1 ? '' : 's'}.');
  }

  Future<void> _findLinks() async {
    if (_finding) {
      _stop = true;
      return;
    }
    final todo = _my.tracks.where((t) => !t.checked).toList();
    if (todo.isEmpty) {
      _toast('Every track has been checked already.');
      return;
    }
    _stop = false;
    setState(() {
      _finding = true;
      _progress = '0 / ${todo.length}';
    });
    var hits = 0;
    var failures = 0;
    for (var i = 0; i < todo.length && !_stop && mounted; i++) {
      final t = todo[i];
      try {
        final link = await DirectLinks.deezer(t);
        t.deezer = link;
        t.checked = true;
        if (link.isNotEmpty) hits++;
        failures = 0;
      } catch (_) {
        failures++;
        if (failures >= 4) {
          _toast('Deezer is not answering. Check your connection and try again.');
          break;
        }
      }
      if (mounted) setState(() => _progress = '${i + 1} / ${todo.length}');
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    await _my.save();
    if (mounted) {
      setState(() => _finding = false);
      _toast('Found $hits direct link${hits == 1 ? '' : 's'}. The shop searches are on every track.');
    }
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove all?'),
        content: const Text('This empties the list of tracks you imported. Your files are not touched.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove all')),
        ],
      ),
    );
    if (ok == true) {
      await _my.clear();
      Taste.invalidate();
    }
  }

  void _soulseek(ImportedTrack t) {
    widget.host.soulseek(context, t.linkQuery);
  }

  void _exploreFrom(ImportedTrack t) {
    final a = t.artist.split(RegExp(r',|&| feat| ft| x ')).first.trim();
    if (a.isEmpty) {
      _toast('This track has no artist to start from.');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ExplorePage(host: widget.host, initialArtist: a)),
    );
  }

  Widget _row(ImportedTrack t) {
    final links = ExploreParse.links(t.linkQuery);
    final sub = [
      if (t.artist.isNotEmpty) t.artist,
      if (t.mix.isNotEmpty && !t.isOriginal) t.mix,
      if (t.label.isNotEmpty) t.label,
      if (t.key.isNotEmpty) t.key,
      if (t.bpm > 0) '${t.bpm.round()} bpm',
    ].join(' · ');
    return ListTile(
      dense: true,
      title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: sub.isEmpty ? null : Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
      leading: t.deezer.isNotEmpty
          ? IconButton(
              tooltip: 'Open on Deezer',
              icon: const Icon(Icons.play_circle_outline),
              onPressed: () => _open(t.deezer),
            )
          : IconButton(
              tooltip: 'Listen on YouTube',
              icon: const Icon(Icons.search),
              onPressed: () => _open(links['YouTube']!),
            ),
      trailing: PopupMenuButton<String>(
        onSelected: (v) async {
          if (v.startsWith('link:')) _open(links[v.substring(5)]!);
          if (v == 'deezer') _open(t.deezer);
          if (v == 'explore') _exploreFrom(t);
          if (v == 'soulseek') _soulseek(t);
          if (v == 'wish') {
            final added = await _wish.addSong('Explore finds', 'My tracks', t.artist, t.title);
            _toast(added ? 'Added to your wish list.' : 'Already on your wish list.');
          }
          if (v == 'remove') {
            await _my.remove(t);
            Taste.invalidate();
          }
        },
        itemBuilder: (_) => [
          if (t.deezer.isNotEmpty) const PopupMenuItem(value: 'deezer', child: Text('Open on Deezer')),
          const PopupMenuItem(value: 'link:YouTube', child: Text('Listen: YouTube')),
          const PopupMenuItem(value: 'link:Bandcamp', child: Text('Listen: Bandcamp')),
          const PopupMenuItem(value: 'link:Traxsource', child: Text('Buy: Traxsource')),
          const PopupMenuItem(value: 'link:Beatport', child: Text('Buy: Beatport')),
          const PopupMenuItem(value: 'link:Hardwax', child: Text('Buy: Hardwax')),
          const PopupMenuItem(value: 'explore', child: Text('Explore from this artist')),
          const PopupMenuItem(value: 'wish', child: Text('Add to wish list')),
          PopupMenuItem(value: 'soulseek', child: Text(widget.host.hasSoulseek ? 'Find on Soulseek' : 'Copy for Soulseek')),
          const PopupMenuItem(value: 'remove', child: Text('Remove from the list')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Screenshots and my tracks'),
        actions: [
          IconButton(
            tooltip: 'Explore',
            icon: const Icon(Icons.explore_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => ExplorePage(host: widget.host)),
            ),
          ),
          IconButton(
            tooltip: 'Import from screenshot',
            icon: const Icon(Icons.photo_library_outlined),
            onPressed: _busy ? null : _fromScreenshots,
          ),
          IconButton(
            tooltip: 'Paste names',
            icon: const Icon(Icons.content_paste),
            onPressed: _busy ? null : _pasteNames,
          ),
          IconButton(
            tooltip: 'Remove all',
            icon: const Icon(Icons.delete_outline),
            onPressed: _my.tracks.isEmpty ? null : _clear,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _my,
        builder: (context, _) {
          final list = _my.tracks;
          if (list.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text(
                    'Add screenshots of the folders on your Mac (Finder list view works well), or paste file names. '
                    'They count as music you own, and BeatDeck finds artists and labels related to them.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _busy ? null : _fromScreenshots,
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('Import from screenshot'),
                  ),
                  TextButton(onPressed: _busy ? null : _pasteNames, child: const Text('Paste names instead')),
                ]),
              ),
            );
          }
          final labels = {for (final t in list) if (t.label.isNotEmpty) t.label.toLowerCase()}.length;
          final direct = list.where((t) => t.deezer.isNotEmpty).length;
          final unchecked = list.where((t) => !t.checked).length;
          return Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(children: [
                Expanded(
                  child: Text(
                    '${list.length} tracks · $labels labels · $direct direct links'
                    '${_finding ? ' · checking $_progress' : ''}',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF8A857C)),
                  ),
                ),
                TextButton.icon(
                  onPressed: (unchecked == 0 && !_finding) ? null : _findLinks,
                  icon: Icon(_finding ? Icons.stop : Icons.link, size: 18),
                  label: Text(_finding ? 'Stop' : 'Find links'),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
              child: Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _fromScreenshots,
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('Add screenshots'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => ExplorePage(host: widget.host, fromMyTracks: true)),
                    ),
                    icon: const Icon(Icons.hub_outlined),
                    label: const Text('Find related'),
                  ),
                ),
              ]),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: list.length,
                itemBuilder: (_, i) => _row(list[i]),
              ),
            ),
          ]);
        },
      ),
    );
  }
}
