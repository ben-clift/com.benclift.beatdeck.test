import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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
    _loadIntro();
    _keepAhead = Timer.periodic(const Duration(seconds: 8), (_) => _refill());
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
      final genres = [for (final v in vibes) ...v.genres];
      final af = AutoFetch.instance;
      af.genres = genres;
      af.genre = genres.first;
      af.pinned = true;
      af.mixKinds = false;
      af.intensity = _intensity.round();
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
      await dj.startAutomix(paths(), fadeSeconds: 24, startOffsetSeconds: 10);
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
    if (!widget.dj.automixCut()) _toast('No next track is ready yet. Try Skip in a moment.');
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

  Widget _playing(DjController dj) {
    final d = dj.deck(dj.automixPlayingDeck.clamp(0, 1));
    final af = AutoFetch.instance;
    final genre = d.path == null ? '' : (dj.genreOf?.call(d.path!) ?? '');
    final status = af.running && af.status.isNotEmpty ? af.status : (dj.automixStatus ?? '');
    final upcoming = dj.automixUpcoming;
    final hue = (genre.isEmpty ? d.title : genre).codeUnits.fold<int>(7, (a, c) => (a * 31 + c) % 360).toDouble();
    final c1 = HSLColor.fromAHSL(1, hue, 0.55, 0.38).toColor();
    final c2 = HSLColor.fromAHSL(1, (hue + 40) % 360, 0.6, 0.12).toColor();
    final frac = d.duration > 0 ? (d.position / d.duration).clamp(0.0, 1.0) : 0.0;
    return ListView(
      children: [
        // Big "cover": colour comes from the genre, like an album picture.
        AspectRatio(
          aspectRatio: 1.15,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [c1, c2]),
            ),
            child: Stack(children: [
              // MilkDrop visuals reacting to the music; the Winamp-style bars
              // show first, and when the phone is on Low brightness.
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: ValueListenableBuilder<bool>(
                    valueListenable: ScreenBrightness.lowPower,
                    builder: (context, low, _) {
                      final bars = Padding(
                        padding: const EdgeInsets.fromLTRB(18, 18, 18, 56),
                        child: CustomPaint(painter: _WinampPainter(dj.spectrum, dj.spectrumPeak)),
                      );
                      return low ? bars : MilkdropView(levels: dj.spectrum, fallback: bars);
                    },
                  ),
                ),
              ),
              Positioned(
                right: 4,
                top: 4,
                child: IconButton(
                  tooltip: 'Visuals settings',
                  icon: const Icon(Icons.tune, color: Colors.white70),
                  onPressed: () => _sheet('Visuals', const _VisualsBox()),
                ),
              ),
              Positioned(
                left: 12,
                bottom: 12,
                child: Wrap(spacing: 8, children: [
                  if (genre.isNotEmpty) _chip(genre.toUpperCase()),
                  if (d.bpm > 1) _chip('${(d.bpm * d.rate).round()} BPM'),
                ]),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        Text(d.loaded ? d.title : '…',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
        if (d.artist.isNotEmpty)
          Text(d.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, color: _dim)),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: frac,
            minHeight: 4,
            backgroundColor: const Color(0xFF404040),
            valueColor: const AlwaysStoppedAnimation(Colors.white),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(children: [
            Text(_mmss(d.position), style: const TextStyle(fontSize: 12, color: _dim)),
            const Spacer(),
            Text(_mmss(d.duration), style: const TextStyle(fontSize: 12, color: _dim)),
          ]),
        ),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(
            iconSize: 34,
            tooltip: 'Back to genres',
            onPressed: () => setState(() => _showChooser = true),
            icon: const Icon(Icons.arrow_back),
          ),
          const SizedBox(width: 16),
          Material(
            color: Colors.white,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: dj.automixPauseToggle,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Icon(dj.automixPaused ? Icons.play_arrow : Icons.pause, size: 38, color: Colors.black),
              ),
            ),
          ),
          const SizedBox(width: 20),
          IconButton(iconSize: 40, onPressed: _skip, icon: const Icon(Icons.skip_next)),
          const SizedBox(width: 8),
          ListenableBuilder(
            listenable: Starred.instance,
            builder: (_, __) {
              final n = _cleanNames(d);
              final on = Starred.instance.has(n.artist, n.title);
              return IconButton(
                iconSize: 34,
                tooltip: on ? 'Remove star' : 'Star this track',
                onPressed: () => _toggleStar(dj),
                icon: Icon(on ? Icons.star : Icons.star_border, color: on ? const Color(0xFFFFC83D) : null),
              );
            },
          ),
        ]),
        const SizedBox(height: 12),
        // Queue card, like the Spotify queue sheet.
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(16)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Text('Queue', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const Spacer(),
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
        ),
        const SizedBox(height: 14),
        Row(children: [
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
          _action(Icons.fast_forward, 'Stop track', _cut),
          _action(Icons.stop_circle_outlined, 'End set', _stop),
        ]),
      ],
    );
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
          const SizedBox(height: 4),
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
