import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/automix/genre_family.dart';
import 'package:sidedeck/debug/debug_log.dart';
import 'package:sidedeck/soulseek/slsk_keeper.dart';
import 'package:sidedeck/soulseek/slsk_setup.dart';
import 'package:sidedeck/soulseek/soulseek_client.dart';
import 'package:sidedeck/state/app_mode.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/state/expiry.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/state/screen_brightness.dart';
import 'package:sidedeck/state/starred.dart';
import 'package:sidedeck/suggest/auto_fetch.dart';
import 'package:sidedeck/suggest/genres.dart';
import 'package:sidedeck/suggest/shazam_watcher.dart';
import 'package:sidedeck/suggest/suggest_service.dart';
import 'package:sidedeck/ui/equaliser_view.dart';
import 'package:sidedeck/ui/milkdrop_view.dart';
import 'package:sidedeck/ui/screenshot_import.dart';
import 'package:sidedeck/wishlist/wishlist.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

const _bg = Color(0xFF121212);
const _panel = Color(0xFF1F1F1F);
const _green = Color(0xFF1DB954);
const _dim = Color(0xFFB3B3B3);

/// Kinds of vocal worth asking for in each genre (name, words to look for).
const _vocalTypes = <String, List<(String, List<String>)>>{
  'House': [('Diva / female', ['diva', 'female', 'feat']), ('Soulful / gospel', ['soul', 'gospel', 'choir']), ('Chopped vocal', ['chop', 'sample', 'edit']), ('Male', ['male', 'vs'])],
  'Garage': [('MC', ['mc', 'vs']), ('Female R&B vocal', ['female', 'r&b', 'feat']), ('Vocal VIP', ['vip', 'vocal', 'vox'])],
  'Drum & bass': [('MC', ['mc']), ('Soulful', ['soul', 'feat']), ('Ragga', ['ragga', 'dancehall'])],
  'Jungle': [('MC', ['mc']), ('Ragga', ['ragga', 'dancehall', 'reggae'])],
  'Techno': [('Spoken / chant', ['spoken', 'chant', 'voice']), ('Sampled', ['sample', 'vocal'])],
  'Trance': [('Female trance vocal', ['feat', 'female', 'vocal']), ('Uplifting anthem', ['anthem', 'uplifting'])],
  'Hip hop': [('Rap', ['rap', 'mc']), ('Sung hooks', ['feat', 'ft'])],
  'Soul & R&B': [('Female', ['female', 'feat']), ('Male', ['male']), ('Gospel / choir', ['gospel', 'choir'])],
  'Disco & funk': [('Diva', ['diva', 'feat']), ('Group vocals', ['band', 'group'])],
  'Reggae & dub': [('Toasting / MC', ['mc', 'toast']), ('Roots singing', ['roots', 'feat'])],
};
const _vocalDefault = <(String, List<String>)>[('Female', ['female', 'feat']), ('Male', ['male']), ('Choir / gospel', ['choir', 'gospel']), ('Spoken', ['spoken', 'voice'])];

class _Vibe {
  const _Vibe(this.label, this.genres, {this.bands = false});
  final String label;
  final List<String> genres;
  final bool bands;
}

const _vibes = <_Vibe>[
  _Vibe('House', ['house', 'deep house', 'tech house']),
  _Vibe('Garage', ['uk garage', 'speed garage', '2-step', 'garage house']),
  _Vibe('Techno', ['techno', 'minimal techno']),
  _Vibe('Hard techno', ['hard techno', 'hardcore']),
  _Vibe('Trance', ['trance', 'progressive trance']),
  _Vibe('Psytrance', ['psytrance', 'goa trance']),
  _Vibe('Drum & bass', ['drum and bass', 'liquid drum and bass']),
  _Vibe('Jungle', ['jungle']),
  _Vibe('Breaks', ['breakbeat', 'big beat']),
  _Vibe('Dubstep & grime', ['dubstep', 'grime']),
  _Vibe('Electro', ['electro']),
  _Vibe('Disco & funk', ['disco', 'nu disco', 'funk']),
  _Vibe('Hip hop', ['hip hop', 'boom bap']),
  _Vibe('Soul & R&B', ['soul', 'r&b']),
  _Vibe('Reggae & dub', ['reggae', 'dub']),
  _Vibe('Afrobeats', ['afrobeats', 'amapiano']),
  _Vibe('Chill & ambient', ['downtempo', 'chillout', 'ambient']),
  _Vibe('Jazz', ['jazz', 'acid jazz']),
  _Vibe('Rock & indie', ['indie rock', 'rock', 'alternative'], bands: true),
  _Vibe('Punk & metal', ['punk', 'metal'], bands: true),
  _Vibe('Goth & post-punk', ['post punk', 'goth', 'new wave'], bands: true),
];

/// The whole app for someone who has never used it: pick what you like, tap
/// Start, music plays and mixes by itself.
class SimpleView extends StatefulWidget {
  const SimpleView({super.key, required this.dj, required this.library});

  final DjController dj;
  final LibraryController library;

  @override
  State<SimpleView> createState() => _SimpleViewState();
}

const _firstTracks = 3;
const _ahead = 3; // tracks kept waiting after the one playing

class _SimpleViewState extends State<SimpleView> with WidgetsBindingObserver {
  Timer? _keepAhead;
  DateTime _lastAsk = DateTime.fromMillisecondsSinceEpoch(0);
  bool _showChooser = false; // on the genre screen while music plays
  bool _introLoaded = false;
  bool _introDone = true;
  final _slUser = TextEditingController();
  final _slPass = TextEditingController();
  bool _signing = false;
  String _signNote = '';
  String? _awaiting; // 'soundcloud' or 'spotify': waiting for a copied link
  bool _importing = false;
  final Set<int> _picked = {0};
  bool _starting = false;
  final _artist = TextEditingController();
  final _track = TextEditingController();
  double _intensity = 0;
  int _vocal = 0; // 0 any, 1 vocals, 2 instrumental
  final Set<String> _typesOn = {}; // vocal types chosen ("Genre|Type")
  final Set<String> _subOff = {}; // sub-genres switched off
  int _decade = 0; // 0 = any year, else the first year of the decade
  bool _bpmAny = true;
  RangeValues _bpm = const RangeValues(120, 130);
  String _note = '';
  int _run = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restore();
    Starred.instance.load();
    StyleSettings.instance.load();
    _loadIntro();
    _keepAhead = Timer.periodic(const Duration(seconds: 8), (_) {
      _refill();
      _styleFallback();
    });
  }

  Future<void> _loadStyle() => StyleSettings.instance.load();
  DateTime _lastStyle = DateTime.fromMillisecondsSinceEpoch(0);

  /// When there is nothing else to play next, play music in the style of the
  /// starred tracks: first from the library, else related artists from Deezer.
  Future<void> _styleFallback({bool force = false}) async {
    final dj = widget.dj;
    final st = StyleSettings.instance;
    final stars = st.chosen();
    if (!mounted || !dj.automixOn || stars.isEmpty) return;
    if (!force && st.mode == 0) return; // off
    final d = dj.deck(dj.automixPlayingDeck.clamp(0, 1));
    if (!force) {
      if (st.mode == 1) {
        // only when nothing else is waiting and the end is near
        if (dj.automixUpcoming.isNotEmpty) return;
        if (d.duration <= 0 || d.duration - d.position > 60) return;
        if (DateTime.now().difference(_lastStyle).inSeconds < 40) return;
      } else {
        // mixed in regularly: at most one every few minutes
        if (dj.automixUpcoming.length >= _ahead) return;
        if (DateTime.now().difference(_lastStyle).inMinutes < st.everyMin) return;
      }
    }
    _lastStyle = DateTime.now();
    final genres = {for (final t in stars) if (t.genre.isNotEmpty) t.genre.toLowerCase()};
    final artists = {for (final t in stars) t.artist.toLowerCase()};
    final bpms = [for (final t in stars) if (t.bpm > 0) t.bpm]..sort();
    final mid = st.bpmFrom > 0 ? (st.bpmFrom + st.bpmTo) ~/ 2 : (bpms.isEmpty ? 0 : bpms[bpms.length ~/ 2]);
    final local = <LibraryTrack>[
      for (final t in widget.library.tracks)
        if (!dj.playedRecently(t.path) &&
            File(t.path).existsSync() &&
            (!st.matchGenre ||
                genres.contains((t.genre.isNotEmpty ? t.genre : (dj.genreOf?.call(t.path) ?? '')).toLowerCase()) ||
                artists.contains(t.artist.toLowerCase())) &&
            (st.bpmFrom > 0
                ? (t.bpm == null || t.bpm! <= 0 || (t.bpm! >= st.bpmFrom && t.bpm! <= st.bpmTo))
                : (mid == 0 || t.bpm == null || t.bpm! <= 0 || (t.bpm! - mid).abs() <= mid * st.bpmTol / 100)))
          t,
    ]..shuffle();
    if (local.isNotEmpty) {
      DebugLog.add('simple', 'nothing waiting: playing a library track in the style of your starred ones');
      dj.automixAllow(local.first.path);
      if (force) {
        dj.automixPlayTrack(local.first.path);
      } else {
        dj.automixAppend(local.first.path);
      }
      return;
    }
    if (!st.download || !soulseek.online || AutoFetch.instance.running) return;
    final seed = stars[math.Random().nextInt(stars.length)];
    DebugLog.add('simple', 'looking for artists like ${seed.artist} (adventure ${st.adventure})');
    var found = await SuggestService().relatedTracks(seed.artist);
    // Adventurous: go one step further out, to artists related to those.
    if (st.adventure >= 2 && found.isNotEmpty) {
      final hop = found[math.Random().nextInt(found.length)].artist;
      final more = await SuggestService().relatedTracks(hop);
      if (more.isNotEmpty) found = more;
    }
    if (st.adventure == 0) {
      // Close to home: the starred artists' own other tracks come first.
      found = [...found.where((t) => artists.contains(t.artist.toLowerCase())), ...found];
    }
    if (found.isEmpty || !mounted) return;
    if (force) dj.armPlayNext();
    AutoFetch.instance.enqueueTracks(found.take(3).toList(), widget.library);
  }

  /// Keeps 3 tracks waiting after the one playing, whatever happens: when
  /// fewer are ready and nothing is being fetched, ask for another.
  void _refill() {
    final dj = widget.dj;
    final af = AutoFetch.instance;
    if (!mounted || !dj.automixOn) return;
    if (dj.automixUpcoming.length >= _ahead) return;
    if (af.running || af.manualPending > 0 || !soulseek.online) return;
    if (DateTime.now().difference(_lastAsk).inSeconds < 7) return;
    _lastAsk = DateTime.now();
    final pool = af.genres.isNotEmpty ? af.genres : [af.genre];
    final g = pool[math.Random().nextInt(pool.length)];
    DebugLog.add('simple', 'only ${dj.automixUpcoming.length} of $_ahead tracks waiting: fetching another ($g)');
    dj.onNeedTrack?.call('', 0, null, '', g);
  }

  @override
  void dispose() {
    _keepAhead?.cancel();
    widget.dj.setSpectrumOn(false);
    WidgetsBinding.instance.removeObserver(this);
    _slUser.dispose();
    _slPass.dispose();
    _artist.dispose();
    _track.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _awaiting != null) _offerClipboard();
  }

  bool _isLink(String t, String kind) =>
      kind == 'soundcloud' ? t.contains('soundcloud.com') : (t.contains('spotify.com') || t.startsWith('spotify:'));

  /// Back from SoundCloud or Spotify: if they copied a playlist link, offer it.
  Future<void> _offerClipboard() async {
    final kind = _awaiting;
    if (kind == null || _importing) return;
    String text = '';
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
    } catch (_) {}
    final link = RegExp(r'(https?://\S+|spotify:\S+)').firstMatch(text)?.group(0) ?? '';
    if (link.isEmpty || !_isLink(link, kind) || !mounted) return;
    _awaiting = null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import this playlist?'),
        content: Text(link, maxLines: 3, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Import')),
        ],
      ),
    );
    if (ok == true) await _importLink(kind, link);
  }

  Future<void> _importLink(String kind, String link) async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final ctl = WishListController();
      await Future<void>.delayed(const Duration(milliseconds: 300)); // let saved lists load first
      final good = kind == 'soundcloud' ? await ctl.importSoundCloud(link) : await ctl.importLink(link);
      if (!good || ctl.lists.isEmpty) {
        _toast(ctl.message ?? 'Could not import that link.');
        return;
      }
      final l = ctl.lists.first;
      if (ctl.message != null) _toast(ctl.message!);
      if (mounted) await _showPlaylist(l);
    } catch (e) {
      DebugLog.add('simple', 'import failed: $e');
      _toast('Could not import that link.');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// Tracks of an imported playlist: tap one to play it, or fetch them all.
  Future<void> _showPlaylist(WishList l) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: SideDeckTheme.panel,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        builder: (ctx, scroll) => Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(l.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('Tap a track to play it.', style: TextStyle(color: Color(0xFF8A857C))),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextButton.icon(
              icon: const Icon(Icons.download),
              label: Text('Download all ${l.items.length}'),
              onPressed: () {
                AutoFetch.instance.enqueueTracks(
                    [for (final i in l.items) Suggestion(i.artist, i.title, 0, 'Your playlist')], widget.library);
                SlskKeeper.instance.setEnabled(true);
                SlskSetup.setAutoFetchForAutomix(true);
                Navigator.pop(ctx);
                _toast('Finding all ${l.items.length} tracks, one after another.');
              },
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: scroll,
              itemCount: l.items.length,
              itemBuilder: (_, i) {
                final it = l.items[i];
                return ListTile(
                  title: Text(it.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: it.artist.isEmpty ? null : Text(it.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: const Icon(Icons.play_arrow),
                  onTap: () {
                    Navigator.pop(ctx);
                    _playFromList(it);
                  },
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  void _playFromList(WishItem it) {
    _artist.text = it.artist;
    _track.text = it.title;
    if (widget.dj.automixOn) {
      _requestNow();
    } else {
      _start();
    }
  }

  Future<void> _importScreenshots() async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final lines = await ScreenshotImport.pickAndRead();
      if (!mounted) return;
      if (lines.isEmpty) {
        _toast('No song names found. Try a clearer screenshot of the playlist.');
        return;
      }
      final text = await ScreenshotImport.review(context, lines);
      if (text == null || text.trim().isEmpty || !mounted) return;
      final ctl = WishListController();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!await ctl.importText('Screenshot playlist', text, source: 'Screenshot')) {
        _toast(ctl.message ?? 'No songs found.');
        return;
      }
      if (mounted) await _showPlaylist(ctl.lists.first);
    } catch (e) {
      DebugLog.add('simple', 'screenshot import failed: $e');
      _toast('Could not read that screenshot.');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _openSaved() async {
    final ctl = WishListController();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    if (ctl.lists.isEmpty) {
      _toast('No imported playlists yet.');
      return;
    }
    final l = await showDialog<WishList>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Imported playlists'),
        children: [
          for (final x in ctl.lists)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, x),
              child: Text('${x.name} (${x.items.length})'),
            ),
        ],
      ),
    );
    if (l != null && mounted) await _showPlaylist(l);
  }

  Future<void> _openAndWait(String kind) async {
    final url = kind == 'soundcloud' ? 'https://soundcloud.com/' : 'https://open.spotify.com/';
    var ok = false;
    try {
      ok = (await const MethodChannel('sidedeck/audio').invokeMethod<bool>('openUrl', {'url': url})) ?? false;
    } catch (_) {}
    if (!ok) {
      _toast('Could not open it.');
      return;
    }
    _awaiting = kind;
    _toast('Open a playlist, tap Share, then Copy link, and come back here.');
  }

  Future<void> _pasteDialog() async {
    final c = TextEditingController();
    final link = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Paste a playlist link'),
        content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(hintText: 'SoundCloud or Spotify link')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Import')),
        ],
      ),
    );
    if (link == null || link.isEmpty) return;
    await _importLink(link.contains('soundcloud.com') ? 'soundcloud' : 'spotify', link);
  }

  Widget _importBox() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Import a playlist', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      const Text('Open it, tap Share, Copy link, then come back. Then pick a track to play.',
          style: TextStyle(fontSize: 12, color: Color(0xFF8A857C))),
      Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: const ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.only(bottom: 8),
          title: Text('How do I import a playlist?', style: TextStyle(fontSize: 14, color: SideDeckTheme.accentB)),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('SoundCloud', style: TextStyle(fontWeight: FontWeight.w800)),
            Text('1. Tap the SoundCloud button below. It opens SoundCloud.\n'
                '2. Open a playlist (sign in if it asks).\n'
                '3. Tap the Share button on the playlist.\n'
                '4. Tap Copy link.\n'
                '5. Come back to BeatDeck. It asks "Import this playlist?". Tap Import.\n'
                '6. Your tracks appear in a list. Tap one to play it, or tap Download all.',
                style: TextStyle(color: Color(0xFFB8B3AA))),
            SizedBox(height: 10),
            Text('Spotify', style: TextStyle(fontWeight: FontWeight.w800)),
            Text('1. Tap the Spotify button below.\n'
                '2. Open a playlist, tap the three dots, then Share, then Copy link.\n'
                '3. Come back to BeatDeck and tap Import.\n'
                'The playlist must be public.',
                style: TextStyle(color: Color(0xFFB8B3AA))),
            SizedBox(height: 10),
            Text('Easiest: a screenshot', style: TextStyle(fontWeight: FontWeight.w800)),
            Text('Open the playlist in any app, take a screenshot (more than one if it is long), '
                'come back, tap "From a screenshot" and choose them. Check the list it reads, then tap Import.',
                style: TextStyle(color: Color(0xFFB8B3AA))),
            SizedBox(height: 10),
            Text('Nothing happened?', style: TextStyle(fontWeight: FontWeight.w800)),
            Text('Tap "Paste a link", paste the link you copied, then Import. '
                'SoundCloud only lets us read the first few tracks of a big playlist.',
                style: TextStyle(color: Color(0xFFB8B3AA))),
          ],
        ),
      ),
      ListenableBuilder(
        listenable: widget.library,
        builder: (_, __) {
          final lib = widget.library;
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: OutlinedButton.icon(
              onPressed: lib.loading ? null : lib.pickFolder,
              icon: const Icon(Icons.folder_open),
              label: Text(lib.folderPath == null || lib.folderPath!.isEmpty
                  ? 'Use my own music folder'
                  : 'My music: ${lib.folderPath!.split('/').last} (${lib.tracks.length} tracks). Change'),
            ),
          );
        },
      ),
      Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _importing ? null : () => _openAndWait('soundcloud'),
            icon: const Icon(Icons.cloud),
            label: const Text('SoundCloud'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _importing ? null : () => _openAndWait('spotify'),
            icon: const Icon(Icons.library_music),
            label: const Text('Spotify'),
          ),
        ),
      ]),
      SizedBox(
        width: double.infinity,
        child: FilledButton.tonalIcon(
          onPressed: _importing ? null : _importScreenshots,
          icon: const Icon(Icons.image_search),
          label: const Text('From a screenshot'),
        ),
      ),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        TextButton(onPressed: _importing ? null : _pasteDialog, child: Text(_importing ? 'Importing…' : 'Paste a link')),
        TextButton(onPressed: _importing ? null : _openSaved, child: const Text('My playlists')),
      ]),
    ]);
  }

  Future<void> _loadIntro() async {
    try {
      final p = await SharedPreferences.getInstance();
      _introDone = p.getBool('simple_intro_v1') ?? false;
      _slUser.text = p.getString('slsk_user') ?? '';
    } catch (_) {}
    if (mounted) setState(() => _introLoaded = true);
  }

  Future<void> _finishIntro() async {
    try {
      await (await SharedPreferences.getInstance()).setBool('simple_intro_v1', true);
    } catch (_) {}
    if (mounted) setState(() => _introDone = true);
  }

  /// Sign in to Soulseek with the name and password typed (a new name is
  /// created by the server the first time), or make a login for them.
  Future<void> _signIn({required bool make}) async {
    if (_signing) return;
    if (make) {
      try {
        final p = await SharedPreferences.getInstance();
        await p.remove('slsk_user');
        await p.remove('slsk_pass');
      } catch (_) {}
      await _ensureAccount();
      final p = await SharedPreferences.getInstance();
      _slUser.text = p.getString('slsk_user') ?? '';
      _slPass.text = p.getString('slsk_pass') ?? '';
    }
    final u = _slUser.text.trim(), pw = _slPass.text;
    if (u.isEmpty || pw.isEmpty) {
      setState(() => _signNote = 'Type a name and a password, or tap "Make one for me".');
      return;
    }
    setState(() {
      _signing = true;
      _signNote = 'Signing in…';
    });
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('slsk_user', u);
      await p.setString('slsk_pass', pw);
      soulseek.manualDisconnect = false;
      await SlskKeeper.instance.setEnabled(true);
      await soulseek.connect(u, pw);
      for (var i = 0; i < 30 && !soulseek.online && (soulseek.error ?? '').isEmpty; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      if (soulseek.online) {
        await _finishIntro();
      } else {
        setState(() => _signNote = (soulseek.error ?? '').isNotEmpty
            ? '${soulseek.error}\nTry a different name, or tap "Make one for me".'
            : 'Could not connect. Check your internet and try again.');
      }
    } finally {
      if (mounted) setState(() => _signing = false);
    }
  }

  Widget _intro() {
    Widget step(IconData i, String t, String d) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(i, color: SideDeckTheme.accentA),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                Text(d, style: const TextStyle(color: Color(0xFFB8B3AA))),
              ]),
            ),
          ]),
        );
    return ListView(children: [
      const SizedBox(height: 12),
      const Text('Welcome to BeatDeck', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
      const SizedBox(height: 6),
      const Text('Your own DJ. It finds music, downloads it and mixes it for you.',
          style: TextStyle(color: Color(0xFFB8B3AA))),
      const SizedBox(height: 20),
      step(Icons.public, 'Music comes from Soulseek',
          'A free file-sharing network run by music fans. You need a Soulseek login to use it. It is free and takes seconds.'),
      step(Icons.tune, 'Pick what you like',
          'Choose genres, speed and intensity, or ask for a specific artist or track.'),
      step(Icons.download, 'First time: 3 tracks download first',
          'The first start waits until 3 tracks have arrived, so the mix never runs dry. Keep the app open.'),
      step(Icons.skip_next, 'Skip and Stop',
          'Skip moves to the next track. Stop ends the set. Tell Ben what you think.'),
      const SizedBox(height: 8),
      const Text('Soulseek login', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      TextField(
        controller: _slUser,
        autocorrect: false,
        enabled: !_signing,
        decoration: const InputDecoration(labelText: 'Username', border: OutlineInputBorder(), isDense: true),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _slPass,
        obscureText: true,
        enabled: !_signing,
        decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder(), isDense: true),
      ),
      const SizedBox(height: 4),
      const Text('New name? Just choose one: it is created the first time you sign in.',
          style: TextStyle(fontSize: 12, color: Color(0xFF8A857C))),
      const SizedBox(height: 12),
      SizedBox(
        height: 52,
        child: FilledButton(
          onPressed: _signing ? null : () => _signIn(make: false),
          child: Text(_signing ? 'Signing in…' : 'Sign in', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        ),
      ),
      TextButton(
        onPressed: _signing ? null : () => _signIn(make: true),
        child: const Text('Make one for me'),
      ),
      if (_signNote.isNotEmpty)
        Text(_signNote, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFE0A080))),
    ]);
  }

  bool get _hasRequest => _artist.text.trim().isNotEmpty || _track.text.trim().isNotEmpty;

  /// Fetch exactly what they typed and play it next.
  void _requestNow() {
    final a = _artist.text.trim(), t = _track.text.trim();
    if (a.isEmpty && t.isEmpty) return;
    widget.dj.armPlayNext();
    AutoFetch.instance.enqueueTracks([Suggestion(a, t, 0, 'your request')], widget.library);
    FocusManager.instance.primaryFocus?.unfocus();
    _toast('Looking for ${[a, t].where((x) => x.isNotEmpty).join(' - ')}. It plays next when it arrives.');
  }

  /// Shazam names a song playing around you; BeatDeck reads the result from
  /// Shazam's notification and fetches the track (and more like it).
  Future<void> _shazam() async {
    final ok = await ShazamWatcher.instance.accessGranted();
    if (!ok) {
      if (!mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Allow Shazam link'),
          content: const Text(
              'BeatDeck needs "notification access" to see which song Shazam found. '
              'On the next screen, switch on BeatDeck Shazam, then come back.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Open settings')),
          ],
        ),
      );
      if (go == true) await ShazamWatcher.instance.openAccessSettings();
      return;
    }
    await ShazamWatcher.instance.setOn(true);
    widget.dj.armPlayNext();
    var opened = false;
    try {
      opened = (await const MethodChannel('sidedeck/audio').invokeMethod<bool>('openAppByName', {'name': 'Shazam'})) ?? false;
    } catch (_) {}
    _toast(opened
        ? 'Tap Shazam to listen. When it names the song, come back: it is fetched and plays next.'
        : 'Shazam is not installed. Install it from the Play Store, then try again.');
  }

  Future<void> _soundCloud() async {
    final q = Uri.encodeQueryComponent([_artist.text.trim(), _track.text.trim()].where((x) => x.isNotEmpty).join(' '));
    final url = q.isEmpty ? 'https://soundcloud.com/discover' : 'https://soundcloud.com/search?q=$q';
    var ok = false;
    try {
      ok = (await const MethodChannel('sidedeck/audio').invokeMethod<bool>('openUrl', {'url': url})) ?? false;
    } catch (_) {}
    if (!ok) _toast('Could not open SoundCloud.');
  }

  Widget _requestBox({required bool running}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Want something specific?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      TextField(
        controller: _artist,
        textInputAction: TextInputAction.next,
        decoration: const InputDecoration(labelText: 'Artist', border: OutlineInputBorder(), isDense: true),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _track,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(labelText: 'Track name (optional)', border: OutlineInputBorder(), isDense: true),
      ),
      const SizedBox(height: 8),
      Row(children: [
        if (running)
          Expanded(
            child: FilledButton.tonalIcon(
              onPressed: _requestNow,
              icon: const Icon(Icons.search),
              label: const Text('Play this next'),
            ),
          ),
        if (running) const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _soundCloud,
            icon: const Icon(Icons.cloud),
            label: const Text('SoundCloud'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _shazam,
            icon: const Icon(Icons.hearing),
            label: const Text('Shazam'),
          ),
        ),
      ]),
    ]);
  }

  Future<void> _restore() async {
    try {
      final p = await SharedPreferences.getInstance();
      _vocal = p.getInt('simple_vocal') ?? 0;
      _subOff.addAll(p.getStringList('simple_suboff') ?? const []);
      _typesOn.addAll(p.getStringList('simple_types') ?? const []);
      final s = p.getStringList('simple_vibes');
      if (s != null && s.isNotEmpty) {
        _picked
          ..clear()
          ..addAll(s.map(int.parse).where((i) => i >= 0 && i < _vibes.length));
        if (_picked.isEmpty) _picked.add(0);
        if (mounted) setState(() {});
      }
    } catch (_) {}
  }

  void _toggle(int i) {
    setState(() {
      if (_picked.contains(i)) {
        if (_picked.length > 1) _picked.remove(i);
      } else {
        // Bands and electronic never mix: picking one kind clears the other.
        _picked.removeWhere((j) => _vibes[j].bands != _vibes[i].bands);
        _picked.add(i);
      }
    });
  }

  /// A Soulseek account made for this phone the first time, no sign-up.
  Future<void> _ensureAccount() async {
    final p = await SharedPreferences.getInstance();
    if ((p.getString('slsk_user') ?? '').isEmpty || (p.getString('slsk_pass') ?? '').isEmpty) {
      const chars = 'abcdefghijkmnpqrstuvwxyz23456789';
      final r = math.Random.secure();
      String gen(int n) => List.generate(n, (_) => chars[r.nextInt(chars.length)]).join();
      await p.setString('slsk_user', 'bdf${gen(8)}');
      await p.setString('slsk_pass', gen(14));
    }
  }

  Future<void> _start() async {
    if (_starting) return;
    final run = ++_run;
    setState(() {
      _starting = true;
      _note = 'Getting ready…';
    });
    try {
      final vibes = [for (final i in _picked) _vibes[i]];
      final af = AutoFetch.instance;
      final genres = <String>[];
      for (final v in vibes) {
        final on = v.genres.where((g) => !_subOff.contains(g)).toList();
        genres.addAll(on.isEmpty ? v.genres : on);
      }
      af.vocal = _vocal;
      af.vocalTerms = [
        if (_vocal != 2)
          for (final v in vibes)
            for (final t in (_vocalTypes[v.label] ?? _vocalDefault))
              if (_typesOn.contains('${v.label}|${t.$1}')) ...t.$2,
      ];
      widget.dj.vocalMode = () => AutoFetch.instance.vocal;
      SharedPreferences.getInstance().then((p) {
        p.setInt('simple_vocal', _vocal);
        p.setStringList('simple_suboff', _subOff.toList());
        p.setStringList('simple_types', _typesOn.toList());
      }).catchError((_) {});
      af.genres = genres;
      af.genre = genres.first;
      af.pinned = true;
      af.mixKinds = false;
      af.intensity = _intensity.round();
      af.useYearRange = _decade != 0;
      if (_decade != 0) {
        af.yearFrom = _decade;
        af.yearTo = _decade + 9;
      }
      widget.dj.decadeRange = _decade == 0 ? null : (_decade, _decade + 9);
      af.endless = true;
      af.buffer = 4; // keep fetching until 4 tracks are waiting, so it never runs dry
      var lo = 999.0, hi = 0.0;
      for (final grp in genreGroups) {
        for (final g in grp.$2) {
          if (genres.contains(g.name)) {
            lo = math.min(lo, g.min);
            hi = math.max(hi, g.max);
          }
        }
      }
      if (!_bpmAny) {
        af.bpmMin = _bpm.start.roundToDouble();
        af.bpmMax = _bpm.end.roundToDouble();
      } else if (hi > 0) {
        af.bpmMin = lo;
        af.bpmMax = hi;
      }
      await af.save();
      try {
        (await SharedPreferences.getInstance())
            .setStringList('simple_vibes', [for (final i in _picked) '$i']);
      } catch (_) {}
      await _ensureAccount();
      await SlskSetup.setAutoFetchForAutomix(true);
      soulseek.manualDisconnect = false;
      await SlskKeeper.instance.setEnabled(true);

      final dj = widget.dj;
      // Only tracks that can really play now: the file is there and it was not
      // played in the last 24 hours (the player skips those).
      List<String> paths() => [
            for (final t in widget.library.tracks)
              if (File(t.path).existsSync() && !dj.playedRecently(t.path)) t.path,
          ];

      final req = _hasRequest;
      final reqArtist = _artist.text.trim(), reqTrack = _track.text.trim();
      final hadMusic = paths().length >= _firstTracks;
      if (req && !hadMusic) {
        af.enqueueTracks([Suggestion(reqArtist, reqTrack, 0, 'your request')], widget.library);
      }
      if (!hadMusic) {
        // First time: download a few tracks before anything plays.
        final started = DateTime.now();
        var asked = DateTime.fromMillisecondsSinceEpoch(0);
        while (mounted && run == _run && paths().length < _firstTracks) {
          if (DateTime.now().difference(started).inMinutes >= 5) {
            if (paths().isEmpty) {
              setState(() => _note = 'Could not find music. Check your internet and try again.');
              return;
            }
            break; // slow network: start with what has arrived
          }
          if (!soulseek.online) {
            setState(() => _note = 'Connecting…');
          } else {
            setState(() => _note = 'Downloading your first tracks (${paths().length} of $_firstTracks)…${af.status.isNotEmpty ? '\n${af.status}' : ''}');
            final waitingForRequest = req && DateTime.now().difference(started).inSeconds < 90;
            if (!waitingForRequest && !af.running && af.manualPending == 0 && DateTime.now().difference(asked).inSeconds >= 8) {
              asked = DateTime.now();
              final g = genres[math.Random().nextInt(genres.length)];
              dj.onNeedTrack?.call('', 0, null, '', g);
            }
          }
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        if (!mounted || run != _run) return;
      }
      await MixSettings.instance.load();
      await dj.startAutomix(paths(), fadeSeconds: MixSettings.instance.fade, startOffsetSeconds: MixSettings.instance.offset);
      MixSettings.instance.apply(dj);
      if (!dj.automixOn) {
        setState(() => _note = dj.automixStatus ?? '');
      } else if (mounted) {
        setState(() => _showChooser = false);
      }
      if (dj.automixOn && req && hadMusic) {
        dj.armPlayNext();
        af.enqueueTracks([Suggestion(reqArtist, reqTrack, 0, 'your request')], widget.library);
      }
    } catch (e) {
      DebugLog.add('simple', 'start failed: $e');
      if (mounted) setState(() => _note = 'Something went wrong. Try again.');
    } finally {
      if (mounted && run == _run) setState(() => _starting = false);
    }
  }

  void _stop() {
    _run++;
    _showChooser = false;
    widget.dj.stopAutomix();
    setState(() {
      _starting = false;
      _note = '';
    });
  }

  /// The full equaliser (presets, ten sliders, your own saved settings) on its
  /// own screen, turned sideways so the sliders have room.
  void _openEq() {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _EqPage(dj: widget.dj)));
  }

  /// Artist and title of what is on the deck, cleaned of track numbers and
  /// file endings ("01. Artist - Title.flac" becomes Artist / Title).
  ({String artist, String title}) _cleanNames(DeckState d) {
    var t = d.title.replaceFirst(RegExp(r'\.(flac|mp3|m4a|wav|ogg|opus|aiff?)$', caseSensitive: false), '');
    t = t.replaceFirst(RegExp(r'^\d{1,3}\s*[\.\-_)]\s*'), '').trim();
    var a = d.artist.trim();
    if (a.isEmpty) {
      final dash = t.indexOf(' - ');
      if (dash > 0) {
        a = t.substring(0, dash).trim();
        t = t.substring(dash + 3).trim();
      }
    }
    return (artist: a, title: t);
  }

  void _toggleStar(DjController dj) {
    final d = dj.deck(dj.automixPlayingDeck.clamp(0, 1));
    if (!d.loaded) return;
    final n = _cleanNames(d);
    final genre = d.path == null ? '' : (dj.genreOf?.call(d.path!) ?? '');
    final was = Starred.instance.has(n.artist, n.title);
    Starred.instance.toggle(n.artist, n.title, genre, d.bpm > 1 ? d.bpm.round() : 0);
    _toast(was ? 'Removed from your stars.' : 'Starred: ${n.title}');
  }

  /// Your starred tracks with filters: search, genre, artist and BPM.
  void _showLibrary() {
    final lib = widget.library;
    final dj = widget.dj;
    String q = '', genre = '';
    int decade = 0;
    RangeValues? bpm;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _panel,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.9,
        builder: (ctx, scroll) => StatefulBuilder(
          builder: (ctx, setS) {
            String gOf(LibraryTrack t) => t.genre.isNotEmpty ? t.genre : (dj.genreOf?.call(t.path) ?? '');
            final all = lib.tracks.toList();
            final genres = {for (final t in all) if (gOf(t).isNotEmpty) gOf(t)}.toList()..sort();
            final bpms = [for (final t in all) if ((t.bpm ?? 0) > 0) t.bpm!];
            final lo = bpms.isEmpty ? 60.0 : bpms.reduce(math.min).floorToDouble();
            final hi = bpms.isEmpty ? 200.0 : math.max(bpms.reduce(math.max).ceilToDouble(), lo + 1);
            final range = bpm == null ? null : RangeValues(bpm!.start.clamp(lo, hi), bpm!.end.clamp(lo, hi));
            final shown = [
              for (final t in all)
                if ((q.isEmpty || '${t.artist} ${t.title}'.toLowerCase().contains(q.toLowerCase())) &&
                    (genre.isEmpty || gOf(t) == genre) &&
                    (decade == 0 || (t.year >= decade && t.year <= decade + 9)) &&
                    (range == null || ((t.bpm ?? 0) >= range.start && (t.bpm ?? 0) <= range.end)))
                  t,
            ]..sort((a, b) => '${a.artist} ${a.title}'.toLowerCase().compareTo('${b.artist} ${b.title}'.toLowerCase()));
            return Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Row(children: [
                  const Icon(Icons.library_music),
                  const SizedBox(width: 8),
                  Text('Library (${shown.length}${shown.length == all.length ? '' : ' of ${all.length}'})',
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: TextField(
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search artist or track', isDense: true, border: OutlineInputBorder()),
                  onChanged: (v) => setS(() => q = v),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(children: [
                  Expanded(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: genres.contains(genre) ? genre : '',
                      dropdownColor: _panel,
                      underline: const SizedBox.shrink(),
                      items: [
                        const DropdownMenuItem(value: '', child: Text('Any genre')),
                        for (final g in genres) DropdownMenuItem(value: g, child: Text(g, overflow: TextOverflow.ellipsis)),
                      ],
                      onChanged: (v) => setS(() => genre = v ?? ''),
                    ),
                  ),
                  const SizedBox(width: 12),
                  DropdownButton<int>(
                    value: decade,
                    dropdownColor: _panel,
                    underline: const SizedBox.shrink(),
                    items: [
                      const DropdownMenuItem(value: 0, child: Text('Any year')),
                      for (final y in const [2020, 2010, 2000, 1990, 1980, 1970, 1960])
                        DropdownMenuItem(value: y, child: Text(y >= 2000 ? 'The ${y}s' : 'The ${y.toString().substring(2)}s')),
                    ],
                    onChanged: (v) => setS(() => decade = v ?? 0),
                  ),
                ]),
              ),
              if (bpms.length > 1)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(children: [
                    Text(range == null ? 'BPM any' : 'BPM ${range.start.round()}-${range.end.round()}', style: const TextStyle(color: _dim)),
                    Expanded(
                      child: RangeSlider(
                        values: range ?? RangeValues(lo, hi),
                        min: lo,
                        max: hi,
                        onChanged: (v) => setS(() => bpm = (v.start <= lo && v.end >= hi) ? null : v),
                      ),
                    ),
                  ]),
                ),
              const Divider(height: 8),
              Expanded(
                child: shown.isEmpty
                    ? const Center(child: Text('No tracks match those filters.', style: TextStyle(color: _dim)))
                    : ListView.builder(
                        controller: scroll,
                        itemCount: shown.length,
                        itemBuilder: (_, i) {
                          final t = shown[i];
                          final sub = [
                            if (t.artist.isNotEmpty) t.artist,
                            if (gOf(t).isNotEmpty) gOf(t),
                            if ((t.bpm ?? 0) > 0) '${t.bpm!.round()} BPM',
                            if (t.year > 0) '${t.year}',
                          ].join('  ·  ');
                          return ListTile(
                            dense: true,
                            leading: Icon(dj.playedRecently(t.path) ? Icons.check_circle_outline : Icons.play_arrow),
                            title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: sub.isEmpty ? null : Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
                            onTap: () {
                              Navigator.pop(ctx);
                              final msg = dj.automixPlayTrack(t.path);
                              if (msg != null) _toast(msg);
                            },
                          );
                        },
                      ),
              ),
            ]);
          },
        ),
      ),
    );
  }

  void _showStarred() {
    String q = '', genre = '', artist = '';
    RangeValues? bpm;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _panel,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        builder: (ctx, scroll) => StatefulBuilder(
          builder: (ctx, setS) => ListenableBuilder(
            listenable: Starred.instance,
            builder: (ctx, _) {
              final all = Starred.instance.items;
              final genres = {for (final t in all) if (t.genre.isNotEmpty) t.genre}.toList()..sort();
              final artists = {for (final t in all) if (t.artist.isNotEmpty) t.artist}.toList()..sort();
              final bpms = [for (final t in all) if (t.bpm > 0) t.bpm];
              final lo = bpms.isEmpty ? 60.0 : bpms.reduce(math.min).toDouble();
              final hi = bpms.isEmpty ? 200.0 : math.max(bpms.reduce(math.max).toDouble(), lo + 1);
              final range = bpm == null ? null : RangeValues(bpm!.start.clamp(lo, hi), bpm!.end.clamp(lo, hi));
              final shown = [
                for (final t in all)
                  if ((q.isEmpty || '${t.artist} ${t.title}'.toLowerCase().contains(q.toLowerCase())) &&
                      (genre.isEmpty || t.genre == genre) &&
                      (artist.isEmpty || t.artist == artist) &&
                      (range == null || (t.bpm > 0 && t.bpm >= range.start.round() && t.bpm <= range.end.round())))
                    t,
              ];
              Widget chips(List<String> items, String sel, void Function(String) pick) => SizedBox(
                    height: 40,
                    child: ListView(scrollDirection: Axis.horizontal, children: [
                      for (final g in items)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(label: Text(g), selected: sel == g, onSelected: (v) => setS(() => pick(v ? g : ''))),
                        ),
                    ]),
                  );
              return Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Row(children: [
                    const Icon(Icons.star, color: Color(0xFFFFC83D)),
                    const SizedBox(width: 8),
                    Text('Starred (${shown.length}${shown.length == all.length ? '' : ' of ${all.length}'})',
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: TextField(
                    decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search artist or track', isDense: true, border: OutlineInputBorder()),
                    onChanged: (v) => setS(() => q = v),
                  ),
                ),
                if (genres.isNotEmpty)
                  Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: chips(genres, genre, (v) => genre = v)),
                if (artists.length > 1)
                  Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 0), child: chips(artists, artist, (v) => artist = v)),
                if (bpms.length > 1)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(children: [
                      Text(range == null ? 'BPM any' : 'BPM ${range.start.round()}-${range.end.round()}',
                          style: const TextStyle(color: _dim)),
                      Expanded(
                        child: RangeSlider(
                          values: range ?? RangeValues(lo, hi),
                          min: lo,
                          max: hi,
                          onChanged: (v) => setS(() => bpm = (v.start <= lo && v.end >= hi) ? null : v),
                        ),
                      ),
                    ]),
                  ),
                const Divider(height: 8),
                Expanded(
                  child: shown.isEmpty
                      ? Center(
                          child: Text(all.isEmpty ? 'Tap the star on a track you like.' : 'Nothing matches those filters.',
                              style: const TextStyle(color: _dim)))
                      : ListView.builder(
                          controller: scroll,
                          itemCount: shown.length,
                          itemBuilder: (_, i) {
                            final t = shown[i];
                            final sub = [
                              if (t.artist.isNotEmpty) t.artist,
                              if (t.genre.isNotEmpty) t.genre,
                              if (t.bpm > 0) '${t.bpm} BPM',
                            ].join('  ·  ');
                            return ListTile(
                              title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: sub.isEmpty ? null : Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
                              leading: const Icon(Icons.play_arrow),
                              trailing: IconButton(
                                tooltip: 'Remove star',
                                icon: const Icon(Icons.star, color: Color(0xFFFFC83D)),
                                onPressed: () => Starred.instance.toggle(t.artist, t.title, t.genre, t.bpm),
                              ),
                              onTap: () {
                                Navigator.pop(ctx);
                                _playFromList(WishItem(t.artist, t.title));
                              },
                            );
                          },
                        ),
                ),
              ]);
            },
          ),
        ),
      ),
    );
  }

  void _cut() {
    if (widget.dj.automixJumpAhead()) return;
    if (!widget.dj.automixCut()) _toast('Near the end and no next track is ready yet. Try Skip in a moment.');
  }

  bool _unknownKind(DjController dj, String path) =>
      genreFamily(dj.genreOf?.call(path) ?? '') == null && !(AutoFetch.instance.isRequested(path));

  void _skip() {
    final dj = widget.dj;
    final msg = dj.automixSkip(dj.automixPlayingDeck);
    if (msg != null) _toast(msg);
  }

  void _toast(String m) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  void _copyLog() {
    Clipboard.setData(ClipboardData(text: DebugLog.instance.lines.join("\n")));
    _toast('Copied. Paste it into a message to Ben.');
  }

  @override
  Widget build(BuildContext context) {
    final dj = widget.dj;
    return ListenableBuilder(
      listenable: Listenable.merge([dj, AutoFetch.instance, soulseek]),
      builder: (context, _) {
        final on = dj.automixOn;
        final viz = on && !_showChooser && _introDone;
        if (dj.spectrumOn != viz) {
          WidgetsBinding.instance.addPostFrameCallback((_) => dj.setSpectrumOn(viz));
        }
        return Scaffold(
          backgroundColor: _bg,
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    if (on && !_showChooser)
                      IconButton(
                        tooltip: 'Back',
                        icon: const Icon(Icons.keyboard_arrow_down, size: 30),
                        onPressed: () => setState(() => _showChooser = true),
                      ),
                    Text(on && !_showChooser ? 'The Booth' : 'BeatDeck',
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: 1)),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Screen brightness',
                      icon: const Icon(Icons.brightness_6),
                      onPressed: () => ScreenBrightness.set((ScreenBrightness.level + 1) % 4),
                    ),
                    PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'log') _copyLog();
                        if (v == 'pro') AppMode.set(false);
                      },
                      itemBuilder: (_) => [
                        if (Expiry.expiresAt != null)
                          PopupMenuItem(
                            enabled: false,
                            child: FutureBuilder<String?>(
                              future: Expiry.remaining(),
                              builder: (_, snap) => Text('Test version: ${snap.data ?? '…'}'),
                            ),
                          ),
                        const PopupMenuItem(value: 'log', child: Text('Report a problem (copy log)')),
                        const PopupMenuItem(value: 'pro', child: Text('Switch to Pro mode')),
                      ],
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Expanded(child: !_introLoaded ? const SizedBox.shrink() : (!_introDone ? _intro() : (on && !_showChooser ? _playing(dj) : _chooser()))),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Small "now playing" bar on the genre screen: tap it to go back.
  Widget _miniPlayer(DjController dj) {
    final d = dj.deck(dj.automixPlayingDeck.clamp(0, 1));
    return Material(
      color: _panel,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => setState(() => _showChooser = false),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
          child: Row(children: [
            const Icon(Icons.equalizer, color: _green),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('NOW PLAYING', style: TextStyle(fontSize: 10, letterSpacing: 1.2, color: _dim)),
                Text(d.loaded ? d.title : '…', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
              ]),
            ),
            IconButton(
              tooltip: dj.automixPaused ? 'Play' : 'Pause',
              icon: Icon(dj.automixPaused ? Icons.play_arrow : Icons.pause),
              onPressed: dj.automixPauseToggle,
            ),
            const Icon(Icons.keyboard_arrow_up),
            const SizedBox(width: 4),
          ]),
        ),
      ),
    );
  }

  Widget _chooser() {
    return ListView(
      children: [
        if (widget.dj.automixOn) _miniPlayer(widget.dj),
        const SizedBox(height: 12),
        const Text('What do you feel like?',
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        const Text(
          'Pick one or more, then tap Start. The music is found, downloaded and mixed for you.',
          style: TextStyle(color: Color(0xFFB8B3AA)),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (var i = 0; i < _vibes.length; i++)
              FilterChip(
                label: Text(_vibes[i].label, style: const TextStyle(fontSize: 16)),
                selected: _picked.contains(i),
                onSelected: _starting ? null : (_) => _toggle(i),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              ),
          ],
        ),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            title: const Text('Sub-genres', style: TextStyle(fontSize: 14, color: SideDeckTheme.accentB)),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final i in _picked)
          if (_vibes[i].genres.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text('${_vibes[i].label}:', style: const TextStyle(color: Color(0xFFB8B3AA))),
                for (final g in _vibes[i].genres)
                  FilterChip(
                    visualDensity: VisualDensity.compact,
                    label: Text(g),
                    selected: !_subOff.contains(g),
                    onSelected: _starting ? null : (v) => setState(() => v ? _subOff.remove(g) : _subOff.add(g)),
                  ),
              ]),
            ),
              if (!_picked.any((i) => _vibes[i].genres.length > 1))
                const Text('Nothing more to choose for this genre.', style: TextStyle(color: Color(0xFF8A857C))),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          const Text('Vocals', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const Spacer(),
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 0, label: Text('Any')),
              ButtonSegment(value: 1, label: Text('Vocal')),
              ButtonSegment(value: 2, label: Text('Instrumental')),
            ],
            selected: {_vocal},
            onSelectionChanged: _starting ? null : (v) => setState(() => _vocal = v.first),
          ),
        ]),
        if (_vocal != 2)
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              title: const Text('Vocal styles', style: TextStyle(fontSize: 14, color: SideDeckTheme.accentB)),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final i in _picked)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text('${_vibes[i].label} vocals:', style: const TextStyle(color: Color(0xFFB8B3AA))),
                for (final t in (_vocalTypes[_vibes[i].label] ?? _vocalDefault))
                  FilterChip(
                    visualDensity: VisualDensity.compact,
                    label: Text(t.$1),
                    selected: _typesOn.contains('${_vibes[i].label}|${t.$1}'),
                    onSelected: _starting
                        ? null
                        : (v) => setState(() => v ? _typesOn.add('${_vibes[i].label}|${t.$1}') : _typesOn.remove('${_vibes[i].label}|${t.$1}')),
                  ),
              ]),
            ),
              ],
            ),
          ),
        const SizedBox(height: 20),
        Row(children: [
          const Text('Speed (BPM)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const Spacer(),
          Text(_bpmAny ? 'Any' : '${_bpm.start.round()} to ${_bpm.end.round()}',
              style: const TextStyle(color: SideDeckTheme.accentA, fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          Switch(
            value: !_bpmAny,
            onChanged: _starting ? null : (v) => setState(() => _bpmAny = !v),
          ),
        ]),
        if (!_bpmAny)
          RangeSlider(
            values: _bpm,
            min: 70,
            max: 180,
            divisions: 110,
            labels: RangeLabels('${_bpm.start.round()}', '${_bpm.end.round()}'),
            onChanged: _starting ? null : (v) => setState(() => _bpm = v),
          ),
        const SizedBox(height: 12),
        Row(children: [
          const Text('Intensity', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const Spacer(),
          Text(const ['Any', 'Medium', 'High', 'Peak'][_intensity.round()],
              style: const TextStyle(color: SideDeckTheme.accentA, fontWeight: FontWeight.w700)),
        ]),
        Slider(
          value: _intensity,
          min: 0,
          max: 3,
          divisions: 3,
          label: const ['Any', 'Medium', 'High', 'Peak'][_intensity.round()],
          onChanged: _starting ? null : (v) => setState(() => _intensity = v),
        ),
        const SizedBox(height: 8),
        Row(children: [
          const Text('Year', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const Spacer(),
          DropdownButton<int>(
            value: _decade,
            underline: const SizedBox.shrink(),
            dropdownColor: _panel,
            items: [
              const DropdownMenuItem(value: 0, child: Text('Any year')),
              for (final y in const [2020, 2010, 2000, 1990, 1980, 1970, 1960])
                DropdownMenuItem(value: y, child: Text(y >= 2000 ? 'The ${y}s' : "The ${y.toString().substring(2)}s")),
            ],
            onChanged: _starting ? null : (v) => setState(() => _decade = v ?? 0),
          ),
        ]),
        const SizedBox(height: 8),
        _requestBox(running: false),
        const SizedBox(height: 16),
        _importBox(),
        const SizedBox(height: 20),
        SizedBox(
          height: 64,
          child: FilledButton.icon(
            onPressed: _starting ? null : _start,
            icon: const Icon(Icons.play_arrow, size: 30),
            label: Text(_starting ? 'Starting…' : 'Start',
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          ),
        ),
        if (_note.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(_note, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFB8B3AA))),
        ],
        if (_starting) ...[
          const SizedBox(height: 12),
          TextButton(onPressed: _stop, child: const Text('Cancel')),
        ],
        const SizedBox(height: 24),
        const Text(
          'The first track can take a minute on a new phone. Keep the app open.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: Color(0xFF8A857C)),
        ),
      ],
    );
  }

  String _mmss(double sec) {
    final t = sec.isFinite && sec > 0 ? sec.round() : 0;
    return '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')}';
  }

  ({String title, String artist}) _nameOf(String path) {
    for (final t in widget.library.tracks) {
      if (t.path == path) return (title: t.title, artist: t.artist);
    }
    final f = path.split(RegExp(r'[\\/]')).last.replaceFirst(RegExp(r'\.[^.]+$'), '');
    return (title: f, artist: '');
  }

  void _sheet(String title, Widget body) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _panel,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            body,
          ]),
        ),
      ),
    );
  }

  Widget _action(IconData icon, String label, VoidCallback onTap) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Material(
          color: const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 24),
                const SizedBox(height: 4),
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _queueCard(DjController dj, DeckState d, List<String> upcoming, String status) {
    return
Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(16)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Text('Queue', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const Spacer(),
              TextButton.icon(
                onPressed: _showLibrary,
                icon: const Icon(Icons.library_music, size: 18),
                label: ListenableBuilder(listenable: widget.library, builder: (_, __) => Text('Library (${widget.library.tracks.length})')),
              ),
              ListenableBuilder(
                listenable: Starred.instance,
                builder: (_, __) => TextButton.icon(
                  onPressed: _showStarred,
                  icon: const Icon(Icons.star, size: 18, color: Color(0xFFFFC83D)),
                  label: Text('Starred (${Starred.instance.items.length})'),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              const Icon(Icons.equalizer, color: _green),
              const SizedBox(width: 10),
              Expanded(
                child: Text(d.loaded ? d.title : '…',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _green, fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ]),
            const Divider(height: 24, color: Color(0xFF333333)),
            Row(children: [
              const Text('Next up', style: TextStyle(color: _dim)),
              const Spacer(),
              Text('${upcoming.length.clamp(0, _ahead)} of $_ahead ready',
                  style: TextStyle(color: upcoming.length >= _ahead ? _green : _dim, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 6),
            for (var i = 0; i < math.max(_ahead, math.min(upcoming.length, 5)); i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: i < upcoming.length
                    ? InkWell(
                        onTap: () {
                          final msg = dj.automixSkip(dj.automixPlayingDeck, prefer: upcoming[i]);
                          if (msg != null) _toast(msg);
                        },
                        child: Row(children: [
                        Icon(_unknownKind(dj, upcoming[i]) ? Icons.help_outline : Icons.check_circle,
                            color: _unknownKind(dj, upcoming[i]) ? const Color(0xFFFFC83D) : _green, size: 22),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(_nameOf(upcoming[i]).title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
                            if (_nameOf(upcoming[i]).artist.isNotEmpty)
                              Text(_nameOf(upcoming[i]).artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _dim, fontSize: 13)),
                            if (_unknownKind(dj, upcoming[i]))
                              const Text('Genre unknown. Tap to play it', style: TextStyle(color: Color(0xFFFFC83D), fontSize: 12)),
                          ]),
                        ),
                      ]))
                    : Row(children: [
                        const SizedBox(width: 22, height: 22, child: Padding(padding: EdgeInsets.all(3), child: CircularProgressIndicator(strokeWidth: 2))),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                              i == upcoming.length && status.isNotEmpty ? status : 'Finding track ${i + 1}…',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: _dim)),
                        ),
                      ]),
              ),
          ]),
        );
  }

  Widget _actionRow() {
    return Row(children: [
          _action(Icons.equalizer, 'EQ', _openEq),
          _action(Icons.skip_next, 'Play next', () {
            if (widget.dj.automixUpcoming.isNotEmpty) {
              _skip();
            } else {
              _sheet('Play something next', _requestBox(running: true));
            }
          }),
          _action(Icons.search, 'Request', () => _sheet('Request a track', _requestBox(running: true))),
          _action(Icons.playlist_add, 'Import', () => _sheet('Import a playlist', _importBox())),
          _action(Icons.auto_awesome, 'My style', () => _sheet('My style', _StyleBox(onPlayNow: () => _styleFallback(force: true)))),
          _action(Icons.tune, 'Mixing', () => _sheet('Mixing', _MixBox(dj: widget.dj))),
          _action(Icons.fast_forward, 'Jump ahead', _cut),
          _action(Icons.stop_circle_outlined, 'End set', _stop),
        ]);
  }

  Widget _glass(Widget child, {double r = 22, EdgeInsets pad = const EdgeInsets.all(14)}) => ClipRRect(
        borderRadius: BorderRadius.circular(r),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            padding: pad,
            decoration: BoxDecoration(
              color: const Color(0xB30B0B10),
              borderRadius: BorderRadius.circular(r),
              border: Border.all(color: const Color(0x33FFFFFF)),
            ),
            child: child,
          ),
        ),
      );

  /// Round glass button.
  Widget _orb(IconData icon, VoidCallback onTap, {String? tip, Color? color, double size = 46}) => Tooltip(
        message: tip ?? '',
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: const Color(0x44FFFFFF))),
            child: Icon(icon, size: size * 0.5, color: color ?? Colors.white),
          ),
        ),
      );

  /// The dial: a ring that fills as the track plays, with play/pause inside.
  Widget _dial(DjController dj, double frac, double size) => SizedBox(
        width: size,
        height: size,
        child: Stack(alignment: Alignment.center, children: [
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              value: frac,
              strokeWidth: 5,
              backgroundColor: const Color(0x33FFFFFF),
              valueColor: const AlwaysStoppedAnimation(Color(0xFF35E0C2)),
            ),
          ),
          InkWell(
            customBorder: const CircleBorder(),
            onTap: dj.automixPauseToggle,
            child: Container(
              width: size - 18,
              height: size - 18,
              decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF35E0C2)),
              child: Icon(dj.automixPaused ? Icons.play_arrow : Icons.pause, size: size * 0.45, color: Colors.black),
            ),
          ),
        ]),
      );

  Widget _starOrb(DjController dj, DeckState d) => ListenableBuilder(
        listenable: Starred.instance,
        builder: (_, __) {
          final n = _cleanNames(d);
          final on = Starred.instance.has(n.artist, n.title);
          return _orb(on ? Icons.star : Icons.star_border, () => _toggleStar(dj),
              tip: on ? 'Remove star' : 'Star this track', color: on ? const Color(0xFFFFC83D) : null);
        },
      );

  Widget _playing(DjController dj) {
    final d = dj.deck(dj.automixPlayingDeck.clamp(0, 1));
    final af = AutoFetch.instance;
    final genre = d.path == null ? '' : (dj.genreOf?.call(d.path!) ?? '');
    final status = af.running && af.status.isNotEmpty ? af.status : (dj.automixStatus ?? '');
    final upcoming = dj.automixUpcoming;
    final frac = d.duration > 0 ? (d.position / d.duration).clamp(0.0, 1.0) : 0.0;
    final visuals = ValueListenableBuilder<bool>(
      valueListenable: ScreenBrightness.lowPower,
      builder: (context, low, _) {
        final bars = Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 56),
          child: CustomPaint(painter: _WinampPainter(dj.spectrum, dj.spectrumPeak)),
        );
        return low ? bars : MilkdropView(levels: dj.spectrum, fallback: bars);
      },
    );
    final chips = Wrap(spacing: 8, children: [
      if (genre.isNotEmpty) _chip(genre.toUpperCase()),
      if (d.bpm > 1) _chip('${(d.bpm * d.rate).round()} BPM'),
    ]);
    final tune = _orb(Icons.tune, () => _sheet('Visuals', const _VisualsBox()), tip: 'Visuals settings', size: 40);
    final title = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(d.loaded ? d.title : '…', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      if (d.artist.isNotEmpty) Text(d.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, color: _dim)),
      Text('${_mmss(d.position)} / ${_mmss(d.duration)}', style: const TextStyle(fontSize: 12, color: _dim)),
    ]);

    return LayoutBuilder(builder: (context, box) {
      final land = box.maxWidth > box.maxHeight;
      if (land) {
        // Landscape: the visuals fill the whole page, controls float on a glass bar.
        return Stack(fit: StackFit.expand, children: [
          ClipRRect(borderRadius: BorderRadius.circular(14), child: visuals),
          Positioned(left: 12, top: 12, child: chips),
          Positioned(right: 8, top: 8, child: tune),
          Positioned(
            left: 12,
            right: 12,
            bottom: 10,
            child: _glass(
              Row(children: [
                Expanded(child: title),
                const SizedBox(width: 12),
                _orb(Icons.arrow_back, () => setState(() => _showChooser = true), tip: 'Back to genres'),
                const SizedBox(width: 10),
                _dial(dj, frac, 64),
                const SizedBox(width: 10),
                _orb(Icons.skip_next, _skip, tip: 'Next track'),
                const SizedBox(width: 10),
                _starOrb(dj, d),
                const SizedBox(width: 10),
                _orb(Icons.queue_music, () => _sheet('Queue', _queueCard(dj, d, upcoming, status)), tip: 'Queue'),
                const SizedBox(width: 10),
                _orb(Icons.more_horiz, () => _sheet('More', _actionRow()), tip: 'More'),
              ]),
              pad: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            ),
          ),
        ]);
      }
      // Portrait: visuals behind everything; a glass drawer slides up over them.
      return Stack(fit: StackFit.expand, children: [
        ClipRRect(borderRadius: BorderRadius.circular(14), child: visuals),
        Positioned(left: 12, top: 12, child: chips),
        Positioned(right: 8, top: 8, child: tune),
        DraggableScrollableSheet(
          initialChildSize: 0.44,
          minChildSize: 0.26,
          maxChildSize: 0.94,
          builder: (context, sc) => ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: Container(
                color: const Color(0xCC0B0B10),
                child: ListView(controller: sc, padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), children: [
                  Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)))),
                  const SizedBox(height: 12),
                  title,
                  const SizedBox(height: 14),
                  Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                    _orb(Icons.arrow_back, () => setState(() => _showChooser = true), tip: 'Back to genres'),
                    _dial(dj, frac, 84),
                    _orb(Icons.skip_next, _skip, tip: 'Next track'),
                    _starOrb(dj, d),
                  ]),
                  const SizedBox(height: 16),
                  _actionRow(),
                  const SizedBox(height: 14),
                  _queueCard(dj, d, upcoming, status),
                ]),
              ),
            ),
          ),
        ),
      ]);
    });
  }

  Widget _chip(String t) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
        child: Text(t, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.8)),
      );
}

/// Bars made of small blocks, green at the bottom to red at the top, with a
/// falling cap on each: the old Winamp look.
class _WinampPainter extends CustomPainter {
  _WinampPainter(this.levels, this.peaks);

  final List<double> levels;
  final List<double> peaks;

  @override
  void paint(Canvas canvas, Size size) {
    final n = levels.length;
    if (n == 0 || size.width <= 0 || size.height <= 0) return;
    const gap = 4.0;
    final barW = (size.width - gap * (n - 1)) / n;
    const segs = 16;
    final segH = size.height / segs;
    final paint = Paint();
    for (var i = 0; i < n; i++) {
      final x = i * (barW + gap);
      final lit = (levels[i].clamp(0.0, 1.0) * segs).round();
      for (var j = 0; j < segs; j++) {
        final f = j / (segs - 1);
        final on = j < lit;
        final base = f < 0.55
            ? const Color(0xFF3DDC4A)
            : (f < 0.82 ? const Color(0xFFE8D840) : const Color(0xFFE5483C));
        paint.color = on ? base : base.withValues(alpha: 0.10);
        final y = size.height - (j + 1) * segH;
        canvas.drawRect(Rect.fromLTWH(x, y + 1, barW, segH - 2), paint);
      }
      final pk = (peaks[i].clamp(0.0, 1.0) * segs).round().clamp(1, segs);
      paint.color = Colors.white70;
      canvas.drawRect(Rect.fromLTWH(x, size.height - pk * segH + 1, barW, 2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WinampPainter old) => true;
}

class _EqPage extends StatefulWidget {
  const _EqPage({required this.dj});
  final DjController dj;

  @override
  State<_EqPage> createState() => _EqPageState();
}

class _EqPageState extends State<_EqPage> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  }

  @override
  void dispose() {
    AppMode.applyOrientation();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        toolbarHeight: 40,
        title: const Text('Equaliser', style: TextStyle(fontSize: 16)),
      ),
      body: EqualiserView(dj: widget.dj),
    );
  }
}


/// MilkDrop settings: intensity, change timer and a preset list.
class _VisualsBox extends StatefulWidget {
  const _VisualsBox();
  @override
  State<_VisualsBox> createState() => _VisualsBoxState();
}

class _VisualsBoxState extends State<_VisualsBox> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final m = MilkdropSettings.instance;
    return ListenableBuilder(
      listenable: m,
      builder: (_, __) {
        const secs = [0, 10, 20, 30, 60, 120];
        final shown = m.names.where((n) => n.toLowerCase().contains(_q.toLowerCase())).take(60).toList();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Intensity: ${m.intensity < 0.2 ? 'very calm' : m.intensity < 0.45 ? 'calm' : m.intensity < 0.7 ? 'medium' : m.intensity < 0.9 ? 'high' : 'wild'}',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          Slider(value: m.intensity, onChanged: (v) => m.set(i: v)),
          Text('Brightness: ${(m.dim * 100).round()}%', style: const TextStyle(fontWeight: FontWeight.w700)),
          Slider(value: m.dim, min: 0.1, max: 1, onChanged: (v) => m.set(dimV: v)),
          const Text('Speed (frames per second)', style: TextStyle(fontWeight: FontWeight.w700)),
          Wrap(spacing: 8, children: [
            for (final f in const [5, 10, 15, 20, 30, 45, 60])
              ChoiceChip(label: Text('$f'), selected: m.fps == f, onSelected: (_) => m.set(fpsV: f)),
          ]),
          const SizedBox(height: 8),
          const Text('Change picture', style: TextStyle(fontWeight: FontWeight.w700)),
          Wrap(spacing: 8, children: [
            for (final s in secs)
              ChoiceChip(
                label: Text(s == 0 ? 'Never' : s < 60 ? '${s}s' : '${s ~/ 60}m'),
                selected: m.autoSecs == s,
                onSelected: (_) => m.set(auto: s),
              ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: m.next,
                icon: const Icon(Icons.skip_next),
                label: const Text('Next picture'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: m.preset == null ? null : () => m.set(shuffle: true),
                icon: const Icon(Icons.shuffle),
                label: Text(m.preset == null ? 'Shuffling' : 'Back to shuffle'),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Text(m.preset == null ? 'Pick a preset (or leave it shuffling)' : 'Showing: ${m.preset}',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          TextField(
            decoration: const InputDecoration(hintText: 'Search presets', prefixIcon: Icon(Icons.search)),
            onChanged: (v) => setState(() => _q = v),
          ),
          SizedBox(
            height: 220,
            child: ListView(children: [
              for (final n in shown)
                ListTile(
                  dense: true,
                  title: Text(n, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: m.preset == n ? const Icon(Icons.check, color: Color(0xFF1DB954)) : null,
                  onTap: () => m.set(pick: n),
                ),
            ]),
          ),
        ]);
      },
    );
  }
}


/// How tracks are mixed: when the mix out starts, where the next track comes
/// in, and whether a track may be changed early. Saved on the phone.
class MixSettings {
  MixSettings._();
  static final MixSettings instance = MixSettings._();
  double fade = 24; // seconds of blend, starting this long before the end
  double offset = 10; // seconds into the next track
  double early = 0; // 0 = full tracks, else minimum seconds before an early change
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final p = await SharedPreferences.getInstance();
      fade = p.getDouble('mix_fade') ?? 24;
      offset = p.getDouble('mix_offset') ?? 10;
      early = p.getDouble('mix_early') ?? 0;
      _loaded = true;
    } catch (_) {}
  }

  Future<void> save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setDouble('mix_fade', fade);
      await p.setDouble('mix_offset', offset);
      await p.setDouble('mix_early', early);
    } catch (_) {}
  }

  void apply(DjController dj) {
    if (dj.automixOn) dj.setMixTiming(fade: fade, startOffset: offset, earlyAfter: early);
    dj.earlyEndAfter = early;
    save();
  }
}

class _MixBox extends StatefulWidget {
  const _MixBox({required this.dj});
  final DjController dj;
  @override
  State<_MixBox> createState() => _MixBoxState();
}

class _MixBoxState extends State<_MixBox> {
  final m = MixSettings.instance;
  @override
  void initState() {
    super.initState();
    m.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  void _chg(VoidCallback f) {
    setState(f);
    m.apply(widget.dj);
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(height: 70, child: CustomPaint(painter: _MixPainter(m.fade, m.offset))),
      const SizedBox(height: 8),
      Text('Mix out: starts ${m.fade.round()} s before the end', style: const TextStyle(fontWeight: FontWeight.w700)),
      Slider(value: m.fade, min: 4, max: 60, divisions: 28, label: '${m.fade.round()} s', onChanged: (v) => _chg(() => m.fade = v)),
      Text('Mix in: next track comes in ${m.offset.round()} s from its start', style: const TextStyle(fontWeight: FontWeight.w700)),
      Slider(value: m.offset, min: 0, max: 60, divisions: 30, label: '${m.offset.round()} s', onChanged: (v) => _chg(() => m.offset = v)),
      const SizedBox(height: 4),
      const Text('Change track', style: TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      Wrap(spacing: 8, children: [
        for (final e in const [(0.0, 'Full tracks'), (180.0, 'After 3 min'), (240.0, 'After 4 min'), (120.0, 'After 2 min')])
          ChoiceChip(label: Text(e.$2), selected: m.early == e.$1, onSelected: (_) => _chg(() => m.early = e.$1)),
      ]),
      const SizedBox(height: 4),
      const Text('Full tracks plays each one to its mix point. The others let it change early at a quiet spot once the track has played that long.',
          style: TextStyle(fontSize: 12, color: Color(0xFF8A857C))),
    ]);
  }
}

/// Two bars: the track going out (its last seconds marked) and the next one
/// coming in, lined up so the overlap is the mix.
class _MixPainter extends CustomPainter {
  _MixPainter(this.fade, this.offset);
  final double fade, offset;
  @override
  void paint(Canvas c, Size s) {
    const total = 300.0; // a 5-minute window
    final w = s.width;
    double x(double sec) => w * (sec / total);
    final outEnd = 240.0;
    final inStart = outEnd - fade;
    final paintOut = Paint()..color = const Color(0xFF6B6558);
    final paintMix = Paint()..color = const Color(0xFF35E0C2);
    final paintIn = Paint()..color = const Color(0xFFFFC83D);
    final r = Radius.circular(6);
    c.drawRRect(RRect.fromLTRBR(0, 4, x(outEnd), 26, r), paintOut);
    c.drawRRect(RRect.fromLTRBR(x(inStart), 4, x(outEnd), 26, r), paintMix);
    c.drawRRect(RRect.fromLTRBR(x(inStart), 40, w, 62, r), paintIn);
    // Where the music of the new track really starts (its own offset).
    c.drawRect(Rect.fromLTWH(x(inStart), 40, math.max(2, x(0)), 22), Paint()..color = const Color(0x00000000));
    final tp = TextPainter(
      text: TextSpan(text: 'out', style: const TextStyle(color: Colors.white, fontSize: 11)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, const Offset(8, 9));
    final tp2 = TextPainter(
      text: TextSpan(text: 'mix ${fade.round()} s', style: const TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.w700)),
      textDirection: TextDirection.ltr,
    )..layout();
    if (x(fade) > tp2.width + 8) tp2.paint(c, Offset(x(inStart) + 6, 9));
    final tp3 = TextPainter(
      text: TextSpan(text: 'next track (in at ${offset.round()} s)', style: const TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.w700)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp3.paint(c, Offset(x(inStart) + 6, 45));
  }

  @override
  bool shouldRepaint(_MixPainter o) => o.fade != fade || o.offset != offset;
}


/// Settings for music chosen in the style of the starred tracks.
class StyleSettings {
  StyleSettings._();
  static final StyleSettings instance = StyleSettings._();
  int mode = 1; // 0 off, 1 only when nothing else is waiting, 2 mixed in regularly
  int everyMin = 6; // for mode 2: at most one every N minutes
  int adventure = 1; // 0 close to my stars, 1 similar artists, 2 further out
  double bpmTol = 12; // % either side of the starred tempo for library picks
  bool matchGenre = true;
  bool download = true; // may fetch new tracks (else library only)
  final Set<String> excluded = {}; // starred tracks left out (by key)
  double bpmFrom = 0; // 0 = automatic from the starred tracks
  double bpmTo = 0;
  bool _loaded = false;

  /// The starred tracks that define the style.
  List<StarredTrack> chosen() => [for (final t in Starred.instance.items) if (!excluded.contains(t.key)) t];

  Future<void> load() async {
    if (_loaded) return;
    try {
      final p = await SharedPreferences.getInstance();
      excluded
        ..clear()
        ..addAll(p.getStringList('style_excl') ?? const []);
      bpmFrom = p.getDouble('style_bpm_from') ?? 0;
      bpmTo = p.getDouble('style_bpm_to') ?? 0;
      mode = p.getInt('style_mode') ?? 1;
      everyMin = p.getInt('style_every') ?? 6;
      adventure = p.getInt('style_adv') ?? 1;
      bpmTol = p.getDouble('style_bpm') ?? 12;
      matchGenre = p.getBool('style_genre') ?? true;
      download = p.getBool('style_dl') ?? true;
      _loaded = true;
    } catch (_) {}
  }

  Future<void> save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList('style_excl', excluded.toList());
      await p.setDouble('style_bpm_from', bpmFrom);
      await p.setDouble('style_bpm_to', bpmTo);
      await p.setInt('style_mode', mode);
      await p.setInt('style_every', everyMin);
      await p.setInt('style_adv', adventure);
      await p.setDouble('style_bpm', bpmTol);
      await p.setBool('style_genre', matchGenre);
      await p.setBool('style_dl', download);
    } catch (_) {}
  }
}

class _StyleBox extends StatefulWidget {
  const _StyleBox({required this.onPlayNow});
  final VoidCallback onPlayNow;
  @override
  State<_StyleBox> createState() => _StyleBoxState();
}

class _StyleBoxState extends State<_StyleBox> {
  final st = StyleSettings.instance;
  @override
  void initState() {
    super.initState();
    st.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  void _chg(VoidCallback f) {
    setState(f);
    st.save();
  }

  @override
  Widget build(BuildContext context) {
    final n = st.chosen().length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(n == 0
          ? 'Star some tracks first. This uses their genre, tempo and artists.'
          : 'Music chosen from the style of your $n starred track${n == 1 ? '' : 's'}.',
          style: const TextStyle(color: Color(0xFF8A857C))),
      const SizedBox(height: 10),
      const Text('Starred tracks to use', style: TextStyle(fontWeight: FontWeight.w700)),
      Wrap(spacing: 8, children: [
        for (final g in {for (final t in Starred.instance.items) if (t.genre.isNotEmpty) t.genre}.toList()..sort())
          ActionChip(
            avatar: Icon(
              Starred.instance.items.where((t) => t.genre == g).every((t) => !st.excluded.contains(t.key))
                  ? Icons.check_box
                  : Icons.check_box_outline_blank,
              size: 18,
            ),
            label: Text(g),
            onPressed: () => _chg(() {
              final of = Starred.instance.items.where((t) => t.genre == g).toList();
              final allOn = of.every((t) => !st.excluded.contains(t.key));
              for (final t in of) {
                allOn ? st.excluded.add(t.key) : st.excluded.remove(t.key);
              }
            }),
          ),
      ]),
      SizedBox(
        height: math.min(200, 56.0 * Starred.instance.items.length),
        child: ListView(children: [
          for (final t in Starred.instance.items)
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: !st.excluded.contains(t.key),
              onChanged: (v) => _chg(() => v == true ? st.excluded.remove(t.key) : st.excluded.add(t.key)),
              title: Text('${t.artist.isEmpty ? '' : '${t.artist} - '}${t.title}', maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text([if (t.genre.isNotEmpty) t.genre, if (t.bpm > 0) '${t.bpm} BPM'].join('  ·  ')),
            ),
        ]),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: Text(st.bpmFrom > 0 ? 'Tempo range: ${st.bpmFrom.round()} to ${st.bpmTo.round()} BPM' : 'Tempo range: automatic',
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        Switch(
          value: st.bpmFrom > 0,
          onChanged: (v) => _chg(() {
            if (v) {
              st.bpmFrom = 120;
              st.bpmTo = 130;
            } else {
              st.bpmFrom = st.bpmTo = 0;
            }
          }),
        ),
      ]),
      if (st.bpmFrom > 0)
        RangeSlider(
          values: RangeValues(st.bpmFrom, st.bpmTo),
          min: 60,
          max: 200,
          labels: RangeLabels('${st.bpmFrom.round()}', '${st.bpmTo.round()}'),
          onChanged: (v) => _chg(() {
            st.bpmFrom = v.start.roundToDouble();
            st.bpmTo = v.end.roundToDouble();
          }),
        ),
      const SizedBox(height: 8),
      const Text('When to use it', style: TextStyle(fontWeight: FontWeight.w700)),
      Wrap(spacing: 8, children: [
        for (final e in const [(0, 'Off'), (1, 'When nothing else is waiting'), (2, 'Mixed in regularly')])
          ChoiceChip(label: Text(e.$2), selected: st.mode == e.$1, onSelected: (_) => _chg(() => st.mode = e.$1)),
      ]),
      if (st.mode == 2) ...[
        Text('About one every ${st.everyMin} min', style: const TextStyle(fontWeight: FontWeight.w700)),
        Slider(value: st.everyMin.toDouble(), min: 2, max: 20, divisions: 18, onChanged: (v) => _chg(() => st.everyMin = v.round())),
      ],
      const SizedBox(height: 4),
      Text('Adventure: ${const ['close to my stars', 'similar artists', 'further out'][st.adventure]}',
          style: const TextStyle(fontWeight: FontWeight.w700)),
      Slider(value: st.adventure.toDouble(), min: 0, max: 2, divisions: 2, onChanged: (v) => _chg(() => st.adventure = v.round())),
      Text('Tempo: within ${st.bpmTol.round()}% of my starred tracks', style: const TextStyle(fontWeight: FontWeight.w700)),
      Slider(value: st.bpmTol, min: 3, max: 30, divisions: 27, onChanged: (v) => _chg(() => st.bpmTol = v)),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Match genre'),
        value: st.matchGenre,
        onChanged: (v) => _chg(() => st.matchGenre = v),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Download new tracks'),
        subtitle: const Text('Off = only use music already on the phone'),
        value: st.download,
        onChanged: (v) => _chg(() => st.download = v),
      ),
      const SizedBox(height: 4),
      FilledButton.icon(
        onPressed: n == 0
            ? null
            : () {
                Navigator.pop(context);
                widget.onPlayNow();
              },
        icon: const Icon(Icons.auto_awesome),
        label: const Text('Play something in my style now'),
      ),
    ]);
  }
}
