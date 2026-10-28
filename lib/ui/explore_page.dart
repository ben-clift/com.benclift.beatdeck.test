import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sidedeck/suggest/discover.dart';
import 'package:sidedeck/suggest/explore.dart';
import 'package:sidedeck/suggest/taste.dart';
import 'package:sidedeck/suggest/track_import.dart';
import 'package:sidedeck/theme/ph.dart';
import 'package:sidedeck/ui/finder_host.dart';
import 'package:sidedeck/ui/my_tracks_page.dart';
import 'package:sidedeck/wishlist/wishlist.dart';

/// Finds new artists, labels and tracks by following links outward from an
/// artist, a label or a genre. Songs open on the sites themselves (YouTube,
/// Bandcamp, Traxsource and so on) in the phone's browser; nothing plays or
/// downloads here until you choose Soulseek on a track.
class ExplorePage extends StatefulWidget {
  const ExplorePage({super.key, this.host = const FinderHost(), this.initialArtist, this.fromMyTracks = false});

  final FinderHost host;

  /// When set, the page starts exploring from this artist straight away.
  final String? initialArtist;

  /// When true, starts by finding music related to the imported My tracks.
  final bool fromMyTracks;

  @override
  State<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage> {
  final _ex = Explore();
  final _wish = WishListController();
  final _name = TextEditingController();
  final _genre = TextEditingController();
  final _bpmLo = TextEditingController();
  final _bpmHi = TextEditingController();
  String _kind = 'artist';
  int _hops = 2;
  bool _hideOwned = true;

  @override
  void initState() {
    super.initState();
    _ex.loadDismissed().then((_) {
      if (mounted) setState(() {});
    });
    Discover.loadToken();
    if (widget.fromMyTracks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _relatedToMyTracks();
      });
    }
    final a = widget.initialArtist;
    if (a != null && a.trim().isNotEmpty) {
      _name.text = a.trim();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _go();
      });
    }
  }

  @override
  void dispose() {
    _ex.cancel();
    _ex.dispose();
    _wish.dispose();
    _name.dispose();
    _genre.dispose();
    _bpmLo.dispose();
    _bpmHi.dispose();
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

  Future<void> _go() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _toast('Type an ${_kind == 'genre' ? 'genre' : _kind} first.');
      return;
    }
    FocusScope.of(context).unfocus();
    await Taste.refresh();
    await _ex.run(
      kind: _kind,
      name: name,
      hops: _hops,
      genre: _kind == 'genre' ? '' : _genre.text.trim(),
      hideOwned: _hideOwned,
    );
  }

  Future<void> _relatedToMyTracks() async {
    final tracks = await MyTracks.instance.loadAll();
    await Taste.refresh();
    await _ex.runMany(Explore.seedsFrom(tracks), hideOwned: _hideOwned);
  }

  Future<void> _fromLibrary() async {
    await Taste.refresh();
    final pick = Taste.pick(1);
    if (pick.isEmpty) {
      _toast('No artists found in your playlists yet.');
      return;
    }
    setState(() {
      _kind = 'artist';
      _name.text = pick.first;
    });
    await _go();
  }

  void _startFrom(ExploreHit h) {
    setState(() {
      _kind = h.kind;
      _name.text = h.name;
    });
    _go();
  }

  double? _num(TextEditingController c) => double.tryParse(c.text.trim());

  Future<void> _tokenDialog() async {
    final c = TextEditingController(text: Discover.token);
    final t = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discogs token'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Optional. Lets genre starts use Discogs as well as Bandcamp. Free at discogs.com/settings/developers.'),
          const SizedBox(height: 8),
          TextField(controller: c, decoration: const InputDecoration(hintText: 'Paste token')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
        ],
      ),
    );
    if (t != null) await Discover.saveToken(t);
  }

  String _why(ExploreHit h) {
    final via = h.via.toList();
    final parts = <String>[
      'via ${via.take(3).join(', ')}${via.length > 3 ? ' +${via.length - 3}' : ''}',
      if (h.owned) 'you own this',
      if (h.genreMatch) '${_genre.text.trim().isEmpty ? _name.text.trim() : _genre.text.trim()} ✓',
      'hop ${h.hop}',
    ];
    return parts.join(' · ');
  }

  Future<void> _tracks(ExploreHit h) async {
    final future = _ex.topTracks(h.name);
    final lo = _num(_bpmLo);
    final hi = _num(_bpmHi);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.7,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(h.name, style: Theme.of(ctx).textTheme.titleLarge),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Top tracks from Deezer, for names and tempo only.${lo != null || hi != null ? ' Tempo filter on.' : ''}',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ),
            Expanded(
              child: FutureBuilder<List<ExploreTrack>>(
                future: future,
                builder: (ctx, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final all = snap.data ?? const <ExploreTrack>[];
                  final tracks = [
                    for (final t in all)
                      if (t.bpm <= 0 || ((lo == null || t.bpm >= lo) && (hi == null || t.bpm <= hi))) t,
                  ];
                  if (tracks.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(all.isEmpty
                          ? 'Deezer has no tracks for this name. Use the Listen links instead.'
                          : 'None of the tracks are in your tempo range.'),
                    );
                  }
                  return ListView(children: [for (final t in tracks) _trackRow(ctx, t)]);
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _trackRow(BuildContext ctx, ExploreTrack t) {
    final q = '${t.artist} ${t.title}';
    final links = ExploreParse.links(q);
    return ListTile(
      dense: true,
      title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(t.bpm > 0 ? '${t.bpm.round()} BPM' : 'tempo unknown'),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          tooltip: 'Listen on YouTube',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Ph.headphones, size: 20),
          onPressed: () => _open(links['YouTube']!),
        ),
        IconButton(
          tooltip: 'Buy on Traxsource',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.shopping_cart_outlined, size: 20),
          onPressed: () => _open(links['Traxsource']!),
        ),
        IconButton(
          tooltip: 'Add to wish list',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.playlist_add, size: 22),
          onPressed: () async {
            final added = await _wish.addSong('Explore finds', 'Explore', t.artist, t.title);
            _toast(added ? 'Added to the Explore finds wish list.' : 'Already on the list.');
          },
        ),
        IconButton(
          tooltip: widget.host.hasSoulseek ? 'Find on Soulseek' : 'Copy for Soulseek',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Ph.travelExplore, size: 20),
          onPressed: () => widget.host.soulseek(ctx, q),
        ),
      ]),
    );
  }

  Widget _row(ExploreHit h) {
    final isArtist = h.kind == 'artist';
    return ListTile(
      leading: Icon(isArtist ? Icons.person_outline : Icons.album_outlined),
      title: Text(h.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(_why(h), maxLines: 2, overflow: TextOverflow.ellipsis),
      onTap: () => isArtist ? _tracks(h) : _startFrom(h),
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'tracks') _tracks(h);
          if (v == 'from') _startFrom(h);
          if (v == 'ra') _open(ExploreParse.raArtistUrl(h.name));
          if (v == 'no') _ex.dismiss(h);
          if (v.startsWith('link:')) _open(ExploreParse.links(h.name)[v.substring(5)]!);
        },
        itemBuilder: (_) => [
          if (isArtist) const PopupMenuItem(value: 'tracks', child: Text('Top tracks')),
          const PopupMenuItem(value: 'from', child: Text('Explore from here')),
          const PopupMenuItem(value: 'link:YouTube', child: Text('Listen: YouTube')),
          const PopupMenuItem(value: 'link:Bandcamp', child: Text('Listen: Bandcamp')),
          const PopupMenuItem(value: 'link:Traxsource', child: Text('Buy: Traxsource')),
          const PopupMenuItem(value: 'link:Beatport', child: Text('Buy: Beatport')),
          const PopupMenuItem(value: 'link:Hardwax', child: Text('Buy: Hardwax')),
          if (isArtist) const PopupMenuItem(value: 'ra', child: Text('Resident Advisor page')),
          const PopupMenuItem(value: 'no', child: Text('Not for me')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Explore'),
        actions: [
          IconButton(
            tooltip: 'My tracks',
            icon: const Icon(Icons.library_music_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => MyTracksPage(host: widget.host)),
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'token') await _tokenDialog();
              if (v == 'forget') {
                await _ex.forgetDismissed();
                _toast('Everything you said "not for me" to can appear again.');
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'token', child: Text('Discogs token')),
              PopupMenuItem(
                value: 'forget',
                enabled: _ex.dismissedCount > 0,
                child: Text('Forget "not for me" (${_ex.dismissedCount})'),
              ),
            ],
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _ex,
        builder: (context, _) => Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'artist', label: Text('Artist')),
                  ButtonSegment(value: 'label', label: Text('Label')),
                  ButtonSegment(value: 'genre', label: Text('Genre')),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() => _kind = s.first),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _name,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _go(),
                decoration: InputDecoration(
                  labelText: _kind == 'genre' ? 'Genre, for example melodic house' : (_kind == 'label' ? 'Label' : 'Artist'),
                  isDense: true,
                ),
              ),
              if (_kind != 'genre') ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _genre,
                  decoration: const InputDecoration(labelText: 'Favour a genre (optional)', isDense: true),
                ),
              ],
              const SizedBox(height: 8),
              Row(children: [
                const Text('Hops'),
                const SizedBox(width: 8),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 1, label: Text('1')),
                    ButtonSegment(value: 2, label: Text('2')),
                    ButtonSegment(value: 3, label: Text('3')),
                  ],
                  selected: {_hops},
                  onSelectionChanged: (s) => setState(() => _hops = s.first),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _bpmLo,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'BPM from', isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _bpmHi,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'to', isDense: true),
                  ),
                ),
              ]),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Hide music I already own'),
                value: _hideOwned,
                onChanged: (v) => setState(() => _hideOwned = v),
              ),
              Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _ex.busy ? null : _go,
                    icon: const Icon(Ph.search, size: 20),
                    label: const Text('Explore'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _ex.busy ? null : _fromLibrary,
                  child: const Text('From my music'),
                ),
                if (_ex.busy) ...[
                  const SizedBox(width: 8),
                  TextButton(onPressed: _ex.cancel, child: const Text('Stop')),
                ],
              ]),
            ]),
          ),
          if (_ex.busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
          if (_ex.status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Align(alignment: Alignment.centerLeft, child: Text(_ex.status, style: Theme.of(context).textTheme.bodySmall)),
            ),
          Expanded(
            child: _ex.hits.isEmpty && !_ex.busy && _ex.status.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(28),
                      child: Text(
                        'Start from an artist, a label or a genre. Each hop follows the links one step further: '
                        'artist to their labels, label to its artists, and similar artists. '
                        'Tap an artist for top tracks, or the menu for listen and buy links.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: _ex.hits.length,
                    itemBuilder: (_, i) => _row(_ex.hits[i]),
                  ),
          ),
        ]),
      ),
    );
  }
}
