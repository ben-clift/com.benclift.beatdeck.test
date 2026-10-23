import 'dart:async';
import 'package:sidedeck/theme/ph.dart';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/automix/genre_family.dart';
import 'package:sidedeck/debug/debug_log.dart';
import 'package:sidedeck/debug/log_upload.dart';
import 'package:sidedeck/mac/mac_sync.dart';
import 'package:sidedeck/soulseek/slsk_keeper.dart';
import 'package:sidedeck/soulseek/slsk_setup.dart';
import 'package:sidedeck/soulseek/soulseek_client.dart';
import 'package:sidedeck/state/app_mode.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/state/expiry.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/state/dislikes.dart';
import 'package:sidedeck/state/ratings.dart';
import 'package:sidedeck/suggest/harmony.dart';
import 'package:sidedeck/state/screen_brightness.dart';
import 'package:sidedeck/state/starred.dart';
import 'package:sidedeck/suggest/auto_fetch.dart';
import 'package:sidedeck/suggest/genres.dart';
import 'package:sidedeck/suggest/shazam_watcher.dart';
import 'package:sidedeck/suggest/suggest_service.dart';
import 'package:sidedeck/ui/appearance_page.dart';
import 'package:sidedeck/ui/equaliser_view.dart';
import 'package:sidedeck/ui/milkdrop_view.dart';
import 'package:sidedeck/ui/screenshot_import.dart';
import 'package:sidedeck/wishlist/wishlist.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';
import 'package:sidedeck/theme/theme_settings.dart';

Color get _bg => SideDeckTheme.pageBg;
Color get _panel => SideDeckTheme.panel;
Color get _green => SideDeckTheme.accentA;
Color get _dim => SideDeckTheme.muted;

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
  // Which Booth button is selected (sheet open or just pressed), and how long
  // fetches usually take, for the wait estimate shown on the buttons.
  String? _sel;
  // Controls at the top of the phone (notification shade, lock screen).
  static const _np = MethodChannel('beatdeck/nowplaying');
  String _npSig = '';
  bool _npAsked = false;

  void _npUpdate(DjController dj) {
    final on = dj.automixOn;
    final d = dj.deck(dj.automixPlayingDeck.clamp(0, 1));
    final n = d.loaded ? _cleanNames(d) : (artist: '', title: '');
    final sig = '$on|${n.title}|${n.artist}|${dj.automixPaused}';
    if (sig == _npSig) return;
    _npSig = sig;
    if (!on) {
      _np.invokeMethod<void>('hide').catchError((_) {});
      return;
    }
    if (!_npAsked) {
      _npAsked = true;
      Permission.notification.request().catchError((_) => PermissionStatus.denied);
    }
    _np.invokeMethod<void>('update', {'title': n.title, 'artist': n.artist, 'playing': !dj.automixPaused}).catchError((_) {});
  }

  Future<dynamic> _npAction(MethodCall c) async {
    if (c.method != 'action' || !mounted) return null;
    final dj = widget.dj;
    switch (c.arguments) {
      case 'PAUSE':
        if (!dj.automixPaused) dj.automixPauseToggle();
      case 'PLAY':
        if (dj.automixPaused) dj.automixPauseToggle();
      case 'NEXT':
        _skip();
      case 'SWAP':
        _dislikeNow();
    }
    return null;
  }
  DateTime? _flashUntil;
  Timer? _btnTick;
  DateTime? _busySince;
  double _avgWait = 45;

  String? _waitText() {
    final since = _busySince;
    if (since == null) return null;
    final left = _avgWait - DateTime.now().difference(since).inSeconds;
    return left > 3 ? '~${left.round()}s' : 'soon';
  }

  /// Highlight a button while its sheet is open.
  Future<void> _selSheet(String label, String title, Widget body) async {
    setState(() => _sel = label);
    await _sheet(title, body);
    if (mounted) setState(() => _sel = null);
  }

  /// Flash a button for a moment after a one-shot press.
  void _flash(String label, VoidCallback f) {
    f();
    setState(() {
      _sel = label;
      _flashUntil = DateTime.now().add(const Duration(milliseconds: 1500));
    });
    Future<void>.delayed(const Duration(milliseconds: 1500), () {
      if (mounted && _sel == label) setState(() {
            _sel = null;
            _flashUntil = null;
          });
    });
  }

  String? _pressNote;
  DateTime? _noteUntil;

  /// A one-shot orb press: highlight it and show a countdown on the visuals.
  void _press(String label, String? note, VoidCallback f, {int secs = 3}) {
    f();
    final until = DateTime.now().add(Duration(seconds: secs));
    setState(() {
      _sel = label;
      _pressNote = note;
      _noteUntil = note == null ? null : until;
      _flashUntil = until;
    });
    Future<void>.delayed(Duration(seconds: secs), () {
      if (mounted && _sel == label) {
        setState(() {
          _sel = null;
          _flashUntil = null;
          _pressNote = null;
          _noteUntil = null;
        });
      }
    });
  }

  Widget _noteBadge() {
    String? t;
    final until = _noteUntil;
    if (_pressNote != null && until != null) {
      final left = until.difference(DateTime.now()).inSeconds + 1;
      t = '$_pressNote  ${left < 0 ? 0 : left}s';
    }
    if (AutoFetch.instance.manualBusy) {
      t = 'Finding a track  ${_waitText() ?? ''}';
    }
    if (t == null) return const SizedBox.shrink();
    return Positioned(
      top: 10,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(color: const Color(0xCC000000), borderRadius: BorderRadius.circular(20), border: Border.all(color: SideDeckTheme.accentA)),
            child: Text(t, style: TextStyle(color: SideDeckTheme.accentA, fontWeight: FontWeight.w800, fontSize: 16)),
          ),
        ),
      ),
    );
  }

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
  int _mood = 0; // 0 whatever, 1 sad .. 4 happy (by musical key)
  bool _genresOpen = false;
  bool _optionsOpen = false;
  bool _reqOpen = false;
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
    _np.setMethodCallHandler(_npAction);
    LogUpload.watchPlay(() => widget.dj.automixOn && !widget.dj.automixPaused);
    milkdropArtSink = (b) {
      if (widget.dj.automixOn) _np.invokeMethod<void>('art', b).catchError((_) {});
    };
    _btnTick = Timer.periodic(const Duration(seconds: 1), (_) {
      final busy = AutoFetch.instance.manualBusy;
      if (busy && _busySince == null) _busySince = DateTime.now();
      if (!busy && _busySince != null) {
        final el = DateTime.now().difference(_busySince!).inSeconds;
        if (el >= 5 && el <= 300) _avgWait = _avgWait * 0.6 + el * 0.4;
        _busySince = null;
      }
      if (mounted && (busy || _flashUntil != null)) setState(() {});
    });
    _restore();
    Starred.instance.load();
    StyleSettings.instance.load();
    _loadIntro();
    _keepAhead = Timer.periodic(const Duration(seconds: 8), (_) {
      _flushDeletes();
      if (widget.dj.playlistActive) return;
      _styleFallback();
      _refill();
      _libraryFallback();
      _autoDedupe();
      _autoClean();
    });
  }

  Future<void> _loadStyle() => StyleSettings.instance.load();
  DateTime _lastStyle = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastLib = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastDedupe = DateTime.now().subtract(const Duration(minutes: 9, seconds: 30)); // first sweep ~30 s after start

  /// Deletes extra copies of songs already in the library, every 10 minutes.
  /// Never touches a track that is playing or waiting, or a starred one.
  Future<void> _autoDedupe() async {
    if (!mounted || DateTime.now().difference(_lastDedupe).inMinutes < 10) return;
    _lastDedupe = DateTime.now();
    final dj = widget.dj;
    final busy = <String>{
      for (var i = 0; i < 2; i++)
        if (dj.deck(i).path != null) dj.deck(i).path!,
      ...dj.automixUpcoming,
    };
    final extras = widget.library
        .duplicateTracks()
        .where((t) => !busy.contains(t.path) && Ratings.instance.starsOf(t.path) == 0)
        .toList();
    if (extras.isEmpty) return;
    final n = await widget.library.deleteTracks(extras);
    DebugLog.add('library', 'auto-deleted $n duplicate track${n == 1 ? '' : 's'} already in the library');
  }
  DateTime _lastClean = DateTime.now().subtract(const Duration(minutes: 4, seconds: 30)); // first pass ~30 s after start
  bool _cleaning = false;

  /// Deletes extra copies of tracks already in the library, from the phone.
  /// Never touches a track that is loaded on a deck or waiting in the queue,
  /// a starred track, or a track with a different length (another mix).
  // Tracks to delete from the phone as soon as no deck is using them.
  final Set<String> _pendingDelete = {};

  Future<void> _flushDeletes() async {
    if (_pendingDelete.isEmpty || !mounted) return;
    final dj = widget.dj;
    final inUse = {for (var i = 0; i < 2; i++) if (dj.deck(i).path != null) dj.deck(i).path!};
    final ready = _pendingDelete.where((p) => !inUse.contains(p)).toList();
    if (ready.isEmpty) return;
    final tracks = [for (final t in widget.library.tracks) if (ready.contains(t.path)) t];
    _pendingDelete.removeAll(ready);
    if (tracks.isEmpty) return;
    final n = await widget.library.deleteTracks(tracks);
    DebugLog.add('library', 'deleted $n track${n == 1 ? '' : 's'} from the phone on request');
    if (mounted) setState(() {});
  }

  /// Delete a track even if it is playing or waiting: a playing one is skipped
  /// first and deleted once it has faded out; a waiting one leaves the queue.
  void _deleteNow(String path) {
    final dj = widget.dj;
    Dislikes.instance.add(path);
    dj.automixRemove(path);
    _pendingDelete.add(path);
    final playingDeck = dj.automixPlayingDeck.clamp(0, 1);
    if (dj.automixOn && dj.deck(playingDeck).path == path) {
      final msg = dj.automixSkip(playingDeck);
      if (msg != null) _toast(msg);
    }
    _flushDeletes();
  }

  /// Hold a row in the Booth queue: take it out of the queue, or delete it.
  Future<void> _queueMenu(String path, {bool playing = false}) async {
    final nm = _nameOf(path);
    final starred = Ratings.instance.starsOf(path) > 0;
    final pick = await showDialog<String>(
      context: context,
      builder: (dc) => SimpleDialog(
        title: Text(nm.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        children: [
          if (!playing) SimpleDialogOption(onPressed: () => Navigator.pop(dc, 'blend'), child: const Text('Play next, then blend it in by hand')),
          if (!playing) SimpleDialogOption(onPressed: () => Navigator.pop(dc, 'now'), child: const Text('Play next and blend now')),
          if (!playing) SimpleDialogOption(onPressed: () => Navigator.pop(dc, 'queue'), child: const Text('Remove from the queue')),
          if (playing) SimpleDialogOption(onPressed: () => Navigator.pop(dc, 'skip'), child: const Text('Skip it (keep the file)')),
          if (!starred) SimpleDialogOption(onPressed: () => Navigator.pop(dc, 'delete'), child: Text(playing ? 'Skip it and delete from the phone' : 'Delete from the phone')),
          if (starred) Padding(padding: EdgeInsets.fromLTRB(24, 8, 24, 8), child: Text('Starred, so it cannot be deleted. Un-star it first.', style: TextStyle(color: _dim))),
        ],
      ),
    );
    if (!mounted || pick == null) return;
    final dj = widget.dj;
    if (pick == 'blend') {
      if (!dj.manualMixStart(prefer: path)) {
        _toast('Wait for the current mix to finish.');
      } else {
        _toast('Loading it. Then move the blend slider at the bottom.');
      }
    } else if (pick == 'now') {
      final msg = dj.automixSkip(dj.automixPlayingDeck, prefer: path);
      if (msg != null) _toast(msg);
    } else if (pick == 'queue') {
      if (!dj.automixRemove(path)) _toast('That one is being mixed in right now.');
    } else if (pick == 'skip') {
      final msg = dj.automixSkip(dj.automixPlayingDeck);
      if (msg != null) _toast(msg);
    } else if (pick == 'delete') {
      _deleteNow(path);
      _toast('Deleted.');
    }
  }

  Future<void> _autoClean() async {
    if (!mounted || _cleaning || DateTime.now().difference(_lastClean).inMinutes < 5) return;
    _cleaning = true;
    _lastClean = DateTime.now();
    try {
      final dj = widget.dj;
      final busy = <String>{
        for (var i = 0; i < 2; i++)
          if (dj.deck(i).path != null) dj.deck(i).path!,
        ...dj.automixUpcoming,
      };
      final dups = widget.library
          .duplicateTracks()
          .where((t) => !busy.contains(t.path) && Ratings.instance.starsOf(t.path) == 0)
          .toList();
      if (dups.isEmpty) return;
      final n = await widget.library.deleteTracks(dups);
      if (n > 0) DebugLog.add('library', 'auto-clean: deleted $n duplicate track${n == 1 ? '' : 's'} from the phone');
    } catch (_) {
    } finally {
      _cleaning = false;
    }
  }

  /// Nothing downloaded and waiting? Play something from the library: the
  /// track whose key mixes best with the one playing (and a close tempo).
  void _libraryFallback() {
    final dj = widget.dj;
    if (!mounted || !dj.automixOn || dj.automixUpcoming.isNotEmpty) return;
    final d = dj.deck(dj.automixPlayingDeck.clamp(0, 1));
    if (!d.loaded || d.duration <= 0) return;
    final left = d.duration - d.position;
    final st = StyleSettings.instance;
    final styleActive = st.mode != 0 && st.chosen().isNotEmpty;
    // My style gets the first go; the library steps in when time is short.
    if (left > (styleActive ? 45 : 90)) return;
    if (DateTime.now().difference(_lastLib).inSeconds < 25) return;
    _lastLib = DateTime.now();
    // Only genres you picked; any genre only when the track is nearly over.
    final best = _bestByKey(dj, d) ?? (left <= 30 ? _bestByKey(dj, d, pickedOnly: false) : null);
    if (best == null) return;
    DebugLog.add('simple', 'nothing waiting: playing library track ${_nameOf(best).title} (best key match)');
    dj.automixAllow(best);
    dj.automixAppend(best);
  }

  /// The track whose key (and tempo) mixes best with what is playing: tracks
  /// already waiting in the queue and the whole library compete. Honours the
  /// genre, vocal, mood, year and tempo settings.
  /// A track fits the genres you picked (a track with no genre tag fits).
  bool _pickedGenreOk(DjController dj, String path) {
    final picked = AutoFetch.instance.genres;
    if (picked.isEmpty) return true;
    final tag = (dj.genreOf?.call(path) ?? '').trim();
    if (tag.isEmpty) return true;
    return picked.any((g) => genresSimilar(g, tag));
  }

  String? _bestByKey(DjController dj, DeckState d, {Set<String> exclude = const {}, bool pickedOnly = true}) {
    final cur = d.key >= 0 ? CamelotKey.fromIndex(d.key) : null;
    final bpm = d.bpm > 1 ? d.bpm * d.rate : 0.0;
    final byPath = {for (final t in widget.library.tracks) t.path: t};
    final pool = <String, LibraryTrack?>{
      ...byPath,
      for (final u in dj.automixUpcoming) u: byPath[u],
    };
    String? best;
    var bestScore = -1e9;
    final rnd = math.Random();
    pool.forEach((path, t) {
      if (path == d.path || exclude.contains(path) || Dislikes.instance.hasPath(path)) return;
      final waiting = dj.automixUpcoming.contains(path);
      if (!waiting && dj.playedRecently(path)) return;
      if (!File(path).existsSync() || !dj.automixFits(path)) return;
      if (pickedOnly && !_pickedGenreOk(dj, path)) return;
      final tt = t ?? byPath[path];
      var score = 0.0;
      final tk = tt?.key == null ? null : CamelotKey.fromIndex(tt!.key!);
      score += (cur != null && tk != null) ? keyMatch(cur, tk).score.toDouble() : 35;
      final tb = tt?.bpm ?? 0;
      if (bpm > 0 && tb > 1) score -= ((tb - bpm).abs() / bpm * 100).clamp(0, 40).toDouble();
      if (waiting) score += 8; // already downloaded and ready
      score += rnd.nextDouble() * 6;
      if (score > bestScore) {
        bestScore = score;
        best = path;
      }
    });
    return best;
  }

  /// X button: this track is not for me. Drop it for good and bring in the
  /// best-fitting track right away.
  void _dislikeNow() {
    final dj = widget.dj;
    final d = dj.deck(dj.automixPlayingDeck.clamp(0, 1));
    final path = d.path;
    if (path != null) Dislikes.instance.add(path);
    final ex = {if (path != null) path};
    final best = _bestByKey(dj, d, exclude: ex) ?? _bestByKey(dj, d, exclude: ex, pickedOnly: false);
    if (best == null) {
      _toast('Not for you. Looking for another...');
      final msg = dj.automixSkip(dj.automixPlayingDeck);
      if (msg != null) _toast(msg);
      return;
    }
    final n = _nameOf(best);
    _toast('Swapping in ${n.artist.isEmpty ? '' : '${n.artist} - '}${n.title}');
    final msg = dj.automixReplaceNow(best);
    if (msg != null) _toast(msg);
  }

  /// When there is nothing else to play next, play music in the style of the
  /// starred tracks: first from the library, else related artists from Deezer.
  Future<void> _styleFallback({bool force = false}) async {
    final dj = widget.dj;
    final st = StyleSettings.instance;
    final stars = st.chosen();
    if (!mounted || !dj.automixOn) return;
    if (stars.isEmpty) {
      if (force) {
        st.lastNote.value = 'Star some tracks first. My style copies their sound.';
        _toast(st.lastNote.value);
      }
      return;
    }
    if (!force && st.mode == 0) return; // off
    final d = dj.deck(dj.automixPlayingDeck.clamp(0, 1));
    if (!force) {
      // A My style track is already playing or waiting: one at a time.
      final af = AutoFetch.instance;
      if (af.manualPending > 0 || af.isStyleRun) return;
      if (af.isStyle(d.path ?? '') || dj.automixUpcoming.any(af.isStyle)) return;
      // Needs an open slot in the queue (the queue is normally kept full, so
      // waiting for it to be empty meant My style never ran).
      if (dj.automixUpcoming.length >= _ahead) return;
      final gap = st.mode == 1 ? 3 : st.everyMin;
      if (DateTime.now().difference(_lastStyle).inMinutes < gap) return;
    }
    _lastStyle = DateTime.now();
    final genres = {for (final t in stars) if (t.genre.isNotEmpty) t.genre.toLowerCase()};
    final artists = {for (final t in stars) t.artist.toLowerCase()};
    final useGenre = st.matchGenre && genres.isNotEmpty;
    final bpms = [for (final t in stars) if (t.bpm > 0) t.bpm]..sort();
    final mid = st.bpmFrom > 0 ? (st.bpmFrom + st.bpmTo) ~/ 2 : (bpms.isEmpty ? 0 : bpms[bpms.length ~/ 2]);
    final local = <LibraryTrack>[
      for (final t in widget.library.tracks)
        if (!dj.playedRecently(t.path) &&
            !((dj.vocalMode?.call() ?? 0) != 0 &&
                vocalClash(t.path.split(RegExp(r'[\\/]')).last, dj.vocalMode!.call())) &&
            File(t.path).existsSync() &&
            (!useGenre ||
                genres.contains((t.genre.isNotEmpty ? t.genre : (dj.genreOf?.call(t.path) ?? '')).toLowerCase()) ||
                artists.contains(t.artist.toLowerCase())) &&
            (st.bpmFrom > 0
                ? (t.bpm == null || t.bpm! <= 0 || (t.bpm! >= st.bpmFrom && t.bpm! <= st.bpmTo))
                : (mid == 0 || t.bpm == null || t.bpm! <= 0 || (t.bpm! - mid).abs() <= mid * st.bpmTol / 100)))
          t,
    ]..shuffle();
    final starKeys = {for (final t in stars) '${t.artist}|${t.title}'.toLowerCase()};
    local.sort((a, b) {
      final sa = starKeys.contains('${a.artist}|${a.title}'.toLowerCase()) ? 1 : 0;
      final sb = starKeys.contains('${b.artist}|${b.title}'.toLowerCase()) ? 1 : 0;
      return sa - sb; // tracks you have not starred yet come first
    });
    if (local.isNotEmpty) {
      st.lastNote.value = 'Playing from your library: ${local.first.artist.isEmpty ? '' : '${local.first.artist} - '}${local.first.title}';
      DebugLog.add('simple', 'nothing waiting: playing a library track in the style of your starred ones');
      dj.automixAllow(local.first.path);
      AutoFetch.instance.markStyle(local.first.path);
      if (force) {
        dj.automixPlayTrack(local.first.path);
      } else {
        dj.automixAppend(local.first.path);
      }
      return;
    }
    if (!st.download || !soulseek.online) {
      DebugLog.add('simple', 'my style: nothing in library fits and downloads are ${!st.download ? 'off' : 'offline (Soulseek not connected)'}');
      if (force) {
        st.lastNote.value = !st.download ? 'Nothing in your library fits. Turn on downloads in My style.' : 'Soulseek is not connected yet, so I cannot fetch new music.';
        _toast(st.lastNote.value);
      }
      return;
    }
    if (AutoFetch.instance.running && !force) return;
    final rnd = math.Random();
    final seed = stars[rnd.nextInt(stars.length)];
    DebugLog.add('simple', 'looking for artists like ${seed.artist} (adventure ${st.adventure})');
    st.lastNote.value = 'Looking for music like ${seed.artist.isEmpty ? seed.title : seed.artist}...';
    var found = await SuggestService().styleTracks(seed.artist);
    // Adventurous: go one step further out, to artists related to those.
    if (st.adventure >= 2 && found.isNotEmpty) {
      final hop = found[rnd.nextInt(found.length)].artist;
      final more = await SuggestService().styleTracks(hop);
      if (more.isNotEmpty) found = more;
    }
    if (st.adventure == 0) {
      // Close to home: the starred artists' own other tracks come first.
      found = [...found.where((t) => artists.contains(t.artist.toLowerCase())), ...found];
    } else {
      // Further out: skip artists already starred so it is new music.
      final fresh = found.where((t) => !artists.contains(t.artist.toLowerCase())).toList();
      if (fresh.length >= 3) found = fresh;
    }
    found = found.where((t) => !starKeys.contains('${t.artist}|${t.title}'.toLowerCase())).toList();
    if (found.isEmpty || !mounted) {
      st.lastNote.value = 'Could not find anything new like ${seed.artist}. Will try again.';
      DebugLog.add('simple', 'my style: no suggestions for ${seed.artist}');
      if (force) _toast(st.lastNote.value);
      _lastStyle = DateTime.now().subtract(const Duration(minutes: 2));
      return;
    }
    final pick = found.take(3).toList();
    st.lastNote.value = 'Fetching: ${pick.map((t) => '${t.artist} - ${t.title}').join(', ')}';
    if (force) dj.armPlayNext();
    AutoFetch.instance.enqueueTracks(pick, widget.library, style: true);
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
    milkdropArtSink = null;
    _btnTick?.cancel();
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
              icon: const Icon(Ph.download),
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
                  trailing: const Icon(Ph.playArrow),
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
        child: ExpansionTile(
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
              icon: const Icon(Ph.folderOpen),
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
            icon: const Icon(Ph.cloud),
            label: const Text('SoundCloud'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _importing ? null : () => _openAndWait('spotify'),
            icon: const Icon(Ph.libraryMusic),
            label: const Text('Spotify'),
          ),
        ),
      ]),
      SizedBox(
        width: double.infinity,
        child: FilledButton.tonalIcon(
          onPressed: _importing ? null : _importScreenshots,
          icon: const Icon(Ph.imageSearch),
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
      const Text('BEATDECK', style: TextStyle(fontFamily: SideDeckTheme.label, fontSize: 40, fontWeight: FontWeight.w700, letterSpacing: 3)),
      const SizedBox(height: 6),
      const Text('Finds the music, fetches it, mixes it.',
          style: TextStyle(color: Color(0xFFB8B3AA))),
      const SizedBox(height: 20),
      step(Ph.public, 'Music comes from Soulseek',
          'A free file-sharing network run by music fans. You need a Soulseek login to use it. It is free and takes seconds.'),
      step(Ph.tune, 'Pick what you like',
          'Choose genres, speed and intensity, or ask for a specific artist or track.'),
      step(Ph.download, 'First time: 3 tracks download first',
          'The first start waits until 3 tracks have arrived, so the mix never runs dry. Keep the app open.'),
      step(Ph.skipNext, 'Skip and Stop',
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
              icon: const Icon(Ph.search),
              label: const Text('Play this next'),
            ),
          ),
        if (running) const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _soundCloud,
            icon: const Icon(Ph.cloud),
            label: const Text('SoundCloud'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _shazam,
            icon: const Icon(Ph.hearing),
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
      _mood = p.getInt('simple_mood') ?? 0;
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
      af.mood = _mood;
      widget.dj.moodMode = () => AutoFetch.instance.mood;
      af.vocalTerms = [
        if (_vocal != 2)
          for (final v in vibes)
            for (final t in (_vocalTypes[v.label] ?? _vocalDefault))
              if (_typesOn.contains('${v.label}|${t.$1}')) ...t.$2,
      ];
      widget.dj.vocalMode = () => AutoFetch.instance.vocal;
      SharedPreferences.getInstance().then((p) {
        p.setInt('simple_vocal', _vocal);
        p.setInt('simple_mood', _mood);
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
  Future<void> _openEq() {
    return Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _EqPage(dj: widget.dj)));
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
    bool msOnly = false;
    int sortMode = 0; // 0 A to Z, 1 BPM low to high, 2 BPM high to low
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
            // One entry per genre, ignoring capital letters (Deep House = Deep house).
            final names = <String, String>{};
            for (final t in all) {
              final g = gOf(t).trim();
              if (g.isNotEmpty) names.putIfAbsent(g.toLowerCase(), () => g);
            }
            final genres = names.keys.toList();
            final bpms = [for (final t in all) if ((t.bpm ?? 0) > 0) t.bpm!];
            final lo = bpms.isEmpty ? 60.0 : bpms.reduce(math.min).floorToDouble();
            final hi = bpms.isEmpty ? 200.0 : math.max(bpms.reduce(math.max).ceilToDouble(), lo + 1);
            final range = bpm == null ? null : RangeValues(bpm!.start.clamp(lo, hi), bpm!.end.clamp(lo, hi));
            bool passes(LibraryTrack t) =>
                (!msOnly || AutoFetch.instance.isStyle(t.path)) &&
                (q.isEmpty || '${t.artist} ${t.title}'.toLowerCase().contains(q.toLowerCase())) &&
                (decade == 0 || (t.year >= decade && t.year <= decade + 9)) &&
                (range == null || ((t.bpm ?? 0) >= range.start && (t.bpm ?? 0) <= range.end));
            // How many tracks each genre has under the other filters; most first, empty ones A to Z.
            final counts = <String, int>{for (final g in genres) g: 0};
            var anyCount = 0;
            for (final t in all) {
              if (!passes(t)) continue;
              anyCount++;
              final g = gOf(t).trim().toLowerCase();
              if (g.isNotEmpty) counts[g] = (counts[g] ?? 0) + 1;
            }
            genres.sort((a, b) {
              final c = counts[b]!.compareTo(counts[a]!);
              return c != 0 ? c : names[a]!.toLowerCase().compareTo(names[b]!.toLowerCase());
            });
            final shown = [
              for (final t in all)
                if (passes(t) && !_pendingDelete.contains(t.path) && (genre.isEmpty || gOf(t).trim().toLowerCase() == genre)) t,
            ]..sort((a, b) {
                if (sortMode != 0) {
                  // Tracks with no tempo go last.
                  final ab = (a.bpm ?? 0) > 0 ? a.bpm! : (sortMode == 1 ? 9999.0 : -1.0);
                  final bb = (b.bpm ?? 0) > 0 ? b.bpm! : (sortMode == 1 ? 9999.0 : -1.0);
                  final c = sortMode == 1 ? ab.compareTo(bb) : bb.compareTo(ab);
                  if (c != 0) return c;
                }
                return '${a.artist} ${a.title}'.toLowerCase().compareTo('${b.artist} ${b.title}'.toLowerCase());
              });
            final playingPath = dj.deck(dj.automixPlayingDeck.clamp(0, 1)).path;
            return ListenableBuilder(listenable: dj, builder: (_, __) => Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Row(children: [
                  const Icon(Ph.libraryMusic),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Library (${shown.length}${shown.length == all.length ? '' : ' of ${all.length}'})  ·  swipe right to delete, hold to cue next',
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  ),
                  FilterChip(
                    label: Text('MS ${all.where((t) => AutoFetch.instance.isStyle(t.path)).length}'),
                    tooltip: 'Only tracks picked by My style',
                    selected: msOnly,
                    visualDensity: VisualDensity.compact,
                    onSelected: (v) => setS(() => msOnly = v),
                  ),
                  PopupMenuButton<int>(
                    tooltip: 'Order the list',
                    icon: Icon(Ph.tune, color: sortMode == 0 ? null : SideDeckTheme.accentA),
                    initialValue: sortMode,
                    onSelected: (v) => setS(() => sortMode = v),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 0, child: Text('A to Z')),
                      PopupMenuItem(value: 1, child: Text('BPM, slowest first')),
                      PopupMenuItem(value: 2, child: Text('BPM, fastest first')),
                    ],
                  ),
                  if (shown.isNotEmpty)
                    FilledButton.icon(
                      style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10), visualDensity: VisualDensity.compact),
                      icon: const Icon(Ph.playArrow, size: 18),
                      label: Text(dj.playlistActive ? 'Restart ${shown.length}' : 'Play ${shown.length}'),
                      onPressed: () {
                        final msg = dj.automixPlaylist([for (final t in shown) t.path]);
                        if (msg != null) {
                          _toast(msg);
                        } else {
                          _toast('Playing these ${shown.length} in order.');
                          Navigator.pop(ctx);
                        }
                      },
                    ),
                  Builder(builder: (_) {
                    final dups = lib.duplicateTracks().where((t) => Ratings.instance.starsOf(t.path) == 0).toList();
                    if (dups.isEmpty) return const SizedBox.shrink();
                    return TextButton.icon(
                      style: _tight,
                      icon: const Icon(Ph.deleteOutline, size: 16),
                      label: Text('Delete ${dups.length} duplicate${dups.length == 1 ? '' : 's'}'),
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: ctx,
                          builder: (dc) => AlertDialog(
                            title: const Text('Delete duplicates?'),
                            content: Text(
                                '${dups.length} extra cop${dups.length == 1 ? 'y' : 'ies'} of tracks you already have will be deleted from the phone. '
                                'The best copy of each (analysed first, then the biggest file) stays. Starred tracks are never deleted.'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(dc, false), child: const Text('Cancel')),
                              FilledButton(onPressed: () => Navigator.pop(dc, true), child: const Text('Delete')),
                            ],
                          ),
                        );
                        if (ok == true) {
                          final n = await lib.deleteTracks(dups);
                          _toast('Deleted $n duplicate${n == 1 ? '' : 's'}.');
                          setS(() {});
                        }
                      },
                    );
                  }),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: TextField(
                  decoration: const InputDecoration(prefixIcon: Icon(Ph.search), hintText: 'Search artist or track', isDense: true, border: OutlineInputBorder()),
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
                        DropdownMenuItem(value: '', child: Text('Any genre ($anyCount)')),
                        for (final g in genres)
                          DropdownMenuItem(
                            value: g,
                            child: Row(children: [
                              Expanded(child: Text(names[g]!, overflow: TextOverflow.ellipsis)),
                              Text('${counts[g]}',
                                  style: TextStyle(
                                      fontFamily: SideDeckTheme.mono,
                                      color: counts[g] == 0 ? const Color(0xFF6B6860) : SideDeckTheme.accentB)),
                            ]),
                          ),
                      ],
                      onChanged: (v) => setS(() => genre = v ?? ''),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (bpms.length > 1)
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          visualDensity: VisualDensity.compact,
                          side: BorderSide(color: range == null ? const Color(0xFF2E2E33) : SideDeckTheme.accentA)),
                      onPressed: () async {
                        var tmp = range ?? RangeValues(lo, hi);
                        await showDialog<void>(
                          context: ctx,
                          builder: (dc) => StatefulBuilder(
                            builder: (dc, setD) => AlertDialog(
                              title: Text(tmp.start <= lo && tmp.end >= hi ? 'BPM: any' : 'BPM ${tmp.start.round()} to ${tmp.end.round()}'),
                              content: RangeSlider(
                                values: tmp,
                                min: lo,
                                max: hi,
                                onChanged: (v) {
                                  setD(() => tmp = v);
                                  setS(() => bpm = (v.start <= lo && v.end >= hi) ? null : v);
                                },
                              ),
                              actions: [
                                TextButton(
                                    onPressed: () {
                                      setS(() => bpm = null);
                                      Navigator.pop(dc);
                                    },
                                    child: const Text('Any BPM')),
                                FilledButton(onPressed: () => Navigator.pop(dc), child: const Text('Done')),
                              ],
                            ),
                          ),
                        );
                      },
                      child: Text(range == null ? 'BPM' : '${range.start.round()}-${range.end.round()}',
                          style: TextStyle(color: range == null ? null : SideDeckTheme.accentA)),
                    ),
                  const SizedBox(width: 8),
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
              const Divider(height: 8),
              Expanded(
                child: shown.isEmpty
                    ? Center(child: Text('No tracks match those filters.', style: TextStyle(color: _dim)))
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
                          final now = playingPath == t.path;
                          final inList = dj.playlistActive && (dj.playlist?.contains(t.path) ?? false);
                          final tile = ListTile(
                            dense: true,
                            selected: now,
                            selectedColor: SideDeckTheme.accentA,
                            selectedTileColor: const Color(0xFF3A2218),
                            leading: Icon(now ? Ph.equalizer : (dj.playedRecently(t.path) ? Ph.checkCircleOutline : Ph.playArrow)),
                            trailing: inList && !now ? Text('${dj.playlist!.indexOf(t.path) + 1}', style: TextStyle(fontFamily: SideDeckTheme.mono, color: _dim)) : null,
                            title: Text((AutoFetch.instance.isStyle(t.path) ? 'MS  ' : '') + t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: sub.isEmpty ? null : Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
                            onTap: () {
                              Navigator.pop(ctx);
                              final msg = dj.automixPlayTrack(t.path);
                              if (msg != null) _toast(msg);
                            },
                            // Hold a track: cue it up as the next track, then blend it in.
                            onLongPress: () {
                              HapticFeedback.mediumImpact();
                              if (dj.manualMixStart(prefer: t.path)) {
                                Navigator.pop(ctx);
                                _toast('Cued up next. Move the blend slider to mix it in.');
                              } else {
                                _toast(dj.automixOn ? 'Wait for the current mix to finish.' : 'Start Auto DJ first.');
                              }
                            },
                          );
                          return Dismissible(
                            key: ValueKey('lib-${t.path}'),
                            direction: DismissDirection.startToEnd,
                            background: Container(
                              color: const Color(0xFF8E2F2F),
                              alignment: Alignment.centerLeft,
                              padding: const EdgeInsets.only(left: 20),
                              child: const Icon(Icons.delete_outline, color: Colors.white),
                            ),
                            confirmDismiss: (_) async {
                              if (Ratings.instance.starsOf(t.path) > 0) {
                                _toast('That track is starred. Un-star it first to delete it.');
                                return false;
                              }
                              return true;
                            },
                            onDismissed: (_) {
                              _deleteNow(t.path);
                              _toast('Deleted.');
                              setS(() {});
                            },
                            child: tile,
                          );
                        },
                      ),
              ),
            ]));
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
                    const Icon(Ph.star, color: Color(0xFFFFC83D)),
                    const SizedBox(width: 8),
                    Text('Starred (${shown.length}${shown.length == all.length ? '' : ' of ${all.length}'})',
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: TextField(
                    decoration: const InputDecoration(prefixIcon: Icon(Ph.search), hintText: 'Search artist or track', isDense: true, border: OutlineInputBorder()),
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
                          style: TextStyle(color: _dim)),
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
                              style: TextStyle(color: _dim)))
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
                              leading: const Icon(Ph.playArrow),
                              trailing: IconButton(
                                tooltip: 'Remove star',
                                icon: const Icon(Ph.star, color: Color(0xFFFFC83D)),
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

  // Tracks with no genre tag now play like any other, so nothing is flagged.
  bool _unknownKind(DjController dj, String path) => false;

  void _skip() {
    final dj = widget.dj;
    final msg = dj.automixSkip(dj.automixPlayingDeck);
    if (msg != null) _toast(msg);
  }

  void _toast(String m) {
    final h = MediaQuery.of(context).size.height;
    final m2 = ScaffoldMessenger.of(context);
    m2.hideCurrentSnackBar();
    // At the top, under the title, so it never covers the sliders at the bottom.
    m2.showSnackBar(SnackBar(
      content: Text(m),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
      margin: EdgeInsets.fromLTRB(16, 0, 16, (h - 170).clamp(0.0, h).toDouble()),
    ));
  }

  /// Token for the automatic log upload, and a send-now button.
  Future<void> _macSheet() async {
    final ms = MacSync.instance;
    await ms.load();
    if (!mounted) return;
    final addr = TextEditingController(text: ms.url);
    final code = TextEditingController(text: ms.pin);
    await showDialog<void>(
      context: context,
      builder: (dc) => AlertDialog(
        title: const Text('Connect my Mac'),
        content: SingleChildScrollView(
          child: ListenableBuilder(
            listenable: ms,
            builder: (_, __) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text(
                'On the Mac (same Wi-Fi as this phone):\n'
                '1. Open Terminal and paste:\n'
                'curl -O https://raw.githubusercontent.com/ben-clift/com.benclift.beatdeck.test/main/tools/beatdeck-share.py\n'
                '2. Then run it with your folders, for example:\n'
                'python3 beatdeck-share.py ~/Music ~/Desktop/DJ\n'
                '3. Type the address and code it prints here.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 10),
              TextField(controller: addr, decoration: const InputDecoration(labelText: 'Address, e.g. http://192.168.1.20:8765', isDense: true), onChanged: (v) => ms.url = v),
              const SizedBox(height: 6),
              TextField(controller: code, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Code', isDense: true), onChanged: (v) => ms.pin = v),
              const SizedBox(height: 6),
              TextField(
                controller: TextEditingController(text: '${ms.limit}'),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Tracks to bring per run (they use phone storage)', isDense: true),
                onChanged: (v) => ms.limit = (int.tryParse(v) ?? 200).clamp(1, 100000),
              ),
              const SizedBox(height: 10),
              if (ms.status.isNotEmpty) Text(ms.status, style: TextStyle(color: SideDeckTheme.accentA)),
              if (ms.running && ms.total > 0) ...[
                const SizedBox(height: 6),
                LinearProgressIndicator(value: (ms.done / ms.total).clamp(0.0, 1.0)),
                Text('${ms.done} of ${ms.total} · 10 at a time', style: TextStyle(fontSize: 12, color: _dim)),
              ],
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => ms.running ? ms.stop() : ms.test(), child: ListenableBuilder(listenable: ms, builder: (_, __) => Text(ms.running ? 'Stop' : 'Test'))),
          ListenableBuilder(
            listenable: ms,
            builder: (_, __) => FilledButton(
              onPressed: ms.running
                  ? null
                  : () {
                      ms.url = addr.text;
                      ms.pin = code.text;
                      unawaited(ms.start(widget.library));
                    },
              child: Text(ms.running ? 'Syncing…' : 'Bring my tracks over'),
            ),
          ),
          TextButton(onPressed: () => Navigator.pop(dc), child: const Text('Close')),
        ],
      ),
    );
  }

  Future<void> _logSettings() async {
    await LogUpload.load();
    if (!mounted) return;
    final c = TextEditingController(text: LogUpload.token);
    await showDialog<void>(
      context: context,
      builder: (dc) => StatefulBuilder(
        builder: (dc, setD) => AlertDialog(
          title: const Text('Send logs automatically'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Every 15 minutes of play, and after a failure, the log is sent so problems can be fixed without copying and pasting.'),
            const SizedBox(height: 10),
            TextField(
              controller: c,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'GitHub token', isDense: true),
              onChanged: (v) {
                LogUpload.token = v;
                LogUpload.save();
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Send automatically'),
              subtitle: Text(LogUpload.status.isEmpty ? (LogUpload.token.trim().isEmpty ? 'Off until a token is set' : 'On') : LogUpload.status),
              value: LogUpload.auto,
              onChanged: (v) {
                setD(() => LogUpload.auto = v);
                LogUpload.save();
              },
            ),
          ]),
          actions: [
            TextButton(
              onPressed: () async {
                await LogUpload.send(reason: 'manual');
                setD(() {});
              },
              child: const Text('Send now'),
            ),
            FilledButton(onPressed: () => Navigator.pop(dc), child: const Text('Done')),
          ],
        ),
      ),
    );
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
        WidgetsBinding.instance.addPostFrameCallback((_) => _npUpdate(dj));
        final viz = on && !_showChooser && _introDone;
        if (dj.spectrumOn != viz) {
          WidgetsBinding.instance.addPostFrameCallback((_) => dj.setSpectrumOn(viz));
        }
        return Scaffold(
          backgroundColor: _bg,
          body: SafeArea(
            child: Padding(
              padding: (viz && MediaQuery.of(context).orientation == Orientation.landscape)
                  ? const EdgeInsets.all(6)
                  : const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!(viz && MediaQuery.of(context).orientation == Orientation.landscape)) Row(children: [
                    if (on && !_showChooser)
                      IconButton(
                        tooltip: 'Back',
                        icon: const Icon(Ph.keyboardArrowDown, size: 30),
                        onPressed: () => setState(() => _showChooser = true),
                      ),
                    Text(on && !_showChooser ? 'The Booth' : 'BeatDeck',
                        style: const TextStyle(fontFamily: SideDeckTheme.label, fontSize: 26, fontWeight: FontWeight.w700, letterSpacing: 2.2)),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Screen brightness',
                      icon: const Icon(Ph.brightness6),
                      onPressed: () => ScreenBrightness.set((ScreenBrightness.level + 1) % 4),
                    ),
                    PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'log') _copyLog();
                        if (v == 'send') _logSettings();
                        if (v == 'mac') _macSheet();
                        if (v == 'look') Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AppearancePage()));
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
                        const PopupMenuItem(value: 'look', child: Text('Appearance: colours, shapes, 3D')),
                        const PopupMenuItem(value: 'mac', child: Text('Connect my Mac (shared folders)')),
                        const PopupMenuItem(value: 'send', child: Text('Send logs to Ben automatically')),
                        const PopupMenuItem(value: 'log', child: Text('Report a problem (copy log)')),
                        const PopupMenuItem(value: 'pro', child: Text('Switch to Pro mode')),
                      ],
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Expanded(child: !_introLoaded ? const SizedBox.shrink() : (!_introDone ? _intro() : (on && !_showChooser ? _playing(dj) : _chooser()))),
                  if (viz && MediaQuery.of(context).orientation == Orientation.portrait) _bottomBar(dj),
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
      borderRadius: BorderRadius.circular(5),
      child: InkWell(
        borderRadius: BorderRadius.circular(5),
        onTap: () => setState(() => _showChooser = false),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
          child: Row(children: [
            Icon(Ph.equalizer, color: _green),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('NOW PLAYING', style: TextStyle(fontSize: 10, letterSpacing: 1.2, color: _dim)),
                Text(d.loaded ? d.title : '…', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
              ]),
            ),
            IconButton(
              tooltip: dj.automixPaused ? 'Play' : 'Pause',
              icon: Icon(dj.automixPaused ? Ph.playArrow : Ph.pause),
              onPressed: dj.automixPauseToggle,
            ),
            const Icon(Ph.keyboardArrowUp),
            const SizedBox(width: 4),
          ]),
        ),
      ),
    );
  }

  Widget _sectionLink({required String title, required String summary, required bool open, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        decoration: ThemeSettings.instance.box(size: 50),
        child: Row(children: [
          Text(title.toUpperCase(),
              style: const TextStyle(fontFamily: SideDeckTheme.label, fontWeight: FontWeight.w700, fontSize: 17, letterSpacing: 1.4)),
          const SizedBox(width: 12),
          Expanded(child: Text(summary, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: _dim))),
          Icon(open ? Ph.keyboardArrowUp : Ph.keyboardArrowDown, color: SideDeckTheme.accentB),
        ]),
      ),
    );
  }

  String _optionsSummary() {
    final b = <String>[];
    b.add(const ['Any mood', 'Sad', 'Moody', 'Bright', 'Happy'][_mood]);
    if (_vocal != 0) b.add(_vocal == 1 ? 'Vocal' : 'Instrumental');
    if (!_bpmAny) b.add('${_bpm.start.round()}-${_bpm.end.round()} BPM');
    if (_decade != 0) b.add('${_decade}s');
    return b.join(' · ');
  }

  /// Happy to sad meter. The track's musical key decides: minor keys sound sad, major keys happy.
  Widget _moodBox() {
    const names = ['Whatever', 'Sad', 'Moody', 'Bright', 'Happy'];
    final any = _mood == 0;
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Mood', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const Spacer(),
          Text(names[_mood], style: TextStyle(color: SideDeckTheme.accentA, fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          ChoiceChip(
            label: const Text('Whatever'),
            selected: any,
            onSelected: _starting ? null : (v) => setState(() => _mood = v ? 0 : 3),
          ),
        ]),
        Opacity(
          opacity: any ? .35 : 1,
          child: Row(children: [
            Text('SAD', style: TextStyle(fontFamily: SideDeckTheme.label, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: _dim)),
            Expanded(
              child: Slider(
                value: any ? 2.5 : (5 - _mood).toDouble(),
                min: 1,
                max: 4,
                divisions: 3,
                onChanged: _starting ? null : (v) => setState(() => _mood = 5 - v.round()),
              ),
            ),
            Text('HAPPY', style: TextStyle(fontFamily: SideDeckTheme.label, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: _dim)),
          ]),
        ),
        const Text('Chosen by each track\'s musical key: minor sounds sad, major sounds happy.',
            style: TextStyle(fontSize: 12, color: Color(0xFF8A857C))),
      ]),
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
        const SizedBox(height: 14),
        _sectionLink(
          title: 'Genres',
          summary: _picked.isEmpty
              ? 'None picked'
              : (_picked.length <= 2
                  ? _picked.map((i) => _vibes[i].label).join(', ')
                  : '${_vibes[_picked.first].label} +${_picked.length - 1}'),
          open: _genresOpen,
          onTap: () => setState(() => _genresOpen = !_genresOpen),
        ),
        if (_genresOpen) Padding(padding: const EdgeInsets.only(top: 6, bottom: 4), child: Wrap(
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
        )),
        const SizedBox(height: 6),
        _sectionLink(
          title: 'Options',
          summary: _optionsSummary(),
          open: _optionsOpen,
          onTap: () => setState(() => _optionsOpen = !_optionsOpen),
        ),
        if (_optionsOpen) ...[
          _moodBox(),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            title: Text('Sub-genres', style: TextStyle(fontSize: 14, color: SideDeckTheme.accentB)),
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
              title: Text('Vocal styles', style: TextStyle(fontSize: 14, color: SideDeckTheme.accentB)),
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
              style: TextStyle(color: SideDeckTheme.accentA, fontWeight: FontWeight.w700)),
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
              style: TextStyle(color: SideDeckTheme.accentA, fontWeight: FontWeight.w700)),
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
        ],
        const SizedBox(height: 6),
        _sectionLink(
          title: 'Request or import',
          summary: 'A track, artist or playlist',
          open: _reqOpen,
          onTap: () => setState(() => _reqOpen = !_reqOpen),
        ),
        if (_reqOpen) ...[
          const SizedBox(height: 10),
          _requestBox(running: false),
          const SizedBox(height: 16),
          _importBox(),
        ],
        const SizedBox(height: 20),
        SizedBox(
          height: 64,
          child: FilledButton.icon(
            onPressed: _starting ? null : _start,
            icon: const Icon(Ph.playArrow, size: 30),
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

  Future<void> _sheet(String title, Widget body) {
    return showModalBottomSheet<void>(
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

  Widget _action(IconData icon, String label, VoidCallback onTap, {bool sel = false, String? sub}) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Container(
          decoration: ThemeSettings.instance.box(
              color: sel ? Color.lerp(SideDeckTheme.panelAlt, SideDeckTheme.accentA, 0.22) : SideDeckTheme.panelAlt, hot: sel, size: 60),
          child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: ThemeSettings.instance.shapeBorder(size: 60),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 2),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 24, color: sel ? SideDeckTheme.accentA : null),
                const SizedBox(height: 4),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(label.toUpperCase(), maxLines: 1,
                      style: TextStyle(fontFamily: SideDeckTheme.label, fontWeight: FontWeight.w600, fontSize: 13, letterSpacing: .6,
                          color: sel ? SideDeckTheme.accentA : null)),
                ),
                if (sub != null)
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(sub, maxLines: 1,
                        style: TextStyle(fontFamily: SideDeckTheme.mono, fontSize: 11, color: SideDeckTheme.accentB)),
                  ),
              ]),
            ),
          ),
        )),
      ),
    );
  }

  static final _tight = TextButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 6),
    minimumSize: const Size(0, 36),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    textStyle: const TextStyle(fontFamily: SideDeckTheme.label, fontWeight: FontWeight.w700, fontSize: 14, letterSpacing: .4),
  );

  /// Pitch (tempo) fader and volume, pinned to the bottom of the Booth.
  Widget _bottomBar(DjController dj) {
    final di = dj.automixPlayingDeck.clamp(0, 1);
    final d = dj.deck(di);
    final pct = (d.rate - 1) * 100;
    final bpm = d.bpm > 1 ? (d.bpm * d.rate).toStringAsFixed(1) : '--';
    Widget lab(String t, String v) => SizedBox(
          width: 96,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(t, style: TextStyle(fontFamily: SideDeckTheme.label, fontWeight: FontWeight.w700, fontSize: 13, letterSpacing: 1.2, color: _dim)),
            Text(v, style: const TextStyle(fontFamily: SideDeckTheme.mono, fontSize: 13)),
          ]),
        );
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      decoration: ThemeSettings.instance.box(size: 120),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          GestureDetector(onDoubleTap: () => dj.setRate(di, 1.0), child: lab('PITCH', '$bpm BPM')),
          Expanded(
            child: Slider(
              min: -10,
              max: 10,
              value: pct.clamp(-10.0, 10.0),
              onChanged: d.loaded ? (v) => dj.setRate(di, 1 + v / 100) : null,
            ),
          ),
          SizedBox(
            width: 48,
            child: GestureDetector(
              onTap: () => dj.setRate(di, 1.0),
              child: Text('${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(1)}%',
                  textAlign: TextAlign.right, style: TextStyle(fontFamily: SideDeckTheme.mono, fontSize: 12, color: _dim)),
            ),
          ),
        ]),
        Row(children: [
          lab('BLEND', dj.blending ? '${(dj.blendProgress * 100).round()}%' : (dj.manualPending ? 'starting…' : 'manual')),
          Expanded(
            child: Slider(
              min: 0,
              max: 1,
              value: dj.blending ? dj.blendProgress.clamp(0.0, 1.0) : 0.0,
              onChanged: (v) {
                if (dj.blending) {
                  dj.takeBlend(v); // drag it any time: you take over from where it is
                } else if (v > 0.02 && !dj.manualPending) {
                  if (!dj.manualMixStart()) _toast(dj.automixOn ? 'Still finding the next track…' : 'Start Auto DJ first.');
                }
              },
            ),
          ),
          SizedBox(
            width: 48,
            child: _orb(Ph.skipNext, () {
              if (dj.blending) {
                dj.takeBlend(1.0);
              } else if (!dj.manualMixStart()) {
                _toast(dj.automixOn ? 'Still finding the next track…' : 'Start Auto DJ first.');
              } else {
                _toast('Bringing the next track in. Move the blend slider.');
              }
            }, tip: 'Play next track, then blend by hand', size: 36, sel: dj.manualMixing || dj.manualPending),
          ),
        ]),
        Row(children: [
          lab('AUTO SYNC', dj.autoSyncOn ? 'BPMs match' : 'off'),
          const Spacer(),
          Switch(value: dj.autoSyncOn, onChanged: (v) => dj.setAutoSync(v)),
          const SizedBox(width: 6),
        ]),
        Row(children: [
          lab('AUTO FX', dj.autoFxOn ? 'on' : 'off'),
          const Spacer(),
          Switch(value: dj.autoFxOn, onChanged: (v) => dj.setAutoFx(v)),
          const SizedBox(width: 6),
        ]),
        Row(children: [
          lab('VOLUME', '${(dj.master * 100).round()}%'),
          Expanded(
            child: Slider(min: 0, max: 1, value: dj.master.clamp(0.0, 1.0), onChanged: dj.setMaster),
          ),
          const SizedBox(width: 48),
        ]),
      ]),
    );
  }

  /// Small label on queue rows picked by My style.
  Widget _styleTag() => Container(
        margin: const EdgeInsets.only(top: 3),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(border: Border.all(color: SideDeckTheme.accentA), borderRadius: BorderRadius.circular(3)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Ph.insights, size: 12, color: SideDeckTheme.accentA),
          SizedBox(width: 4),
          Text('MY STYLE',
              style: TextStyle(fontFamily: SideDeckTheme.label, fontWeight: FontWeight.w700, fontSize: 12, letterSpacing: 1, color: SideDeckTheme.accentA)),
        ]),
      );

  Widget _queueCard(DjController dj, DeckState d, List<String> upcoming, String status) {
    return
Container(
          padding: const EdgeInsets.all(14),
          decoration: ThemeSettings.instance.box(size: 300),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Text('Queue', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const Spacer(),
              TextButton.icon(
                style: _tight,
                onPressed: _showLibrary,
                icon: const Icon(Ph.libraryMusic, size: 16),
                label: ListenableBuilder(listenable: widget.library, builder: (_, __) => Text('Library (${widget.library.tracks.length})')),
              ),
              ListenableBuilder(
                listenable: Starred.instance,
                builder: (_, __) => TextButton.icon(
                  style: _tight,
                  onPressed: _showStarred,
                  icon: const Icon(Ph.star, size: 16, color: Color(0xFFFFC83D)),
                  label: Text('Starred (${Starred.instance.items.length})'),
                ),
              ),
            ]),
            SizedBox(height: 10),
            InkWell(
              onLongPress: d.path == null ? null : () => _queueMenu(d.path!, playing: true),
              child: Row(children: [
                Icon(Ph.equalizer, color: _green),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(d.loaded ? ((d.path != null && AutoFetch.instance.isStyle(d.path!)) ? 'MS  ${d.title}' : d.title) : '…',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: _green, fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ]),
            ),
            if (d.path != null && AutoFetch.instance.isStyle(d.path!))
              Padding(padding: const EdgeInsets.only(left: 32, top: 2), child: _styleTag()),
            const Divider(height: 24, color: Color(0xFF2E2E33)),
            Row(children: [
              Text('Next up', style: TextStyle(color: _dim)),
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
                        onLongPress: () => _queueMenu(upcoming[i]),
                        onTap: () {
                          final msg = dj.automixSkip(dj.automixPlayingDeck, prefer: upcoming[i]);
                          if (msg != null) _toast(msg);
                        },
                        child: Row(children: [
                        Icon(_unknownKind(dj, upcoming[i]) ? Ph.helpOutline : Ph.checkCircle,
                            color: _unknownKind(dj, upcoming[i]) ? const Color(0xFFFFC83D) : _green, size: 22),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text((AutoFetch.instance.isStyle(upcoming[i]) ? 'MS  ' : '') + _nameOf(upcoming[i]).title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
                            if (_nameOf(upcoming[i]).artist.isNotEmpty)
                              Text(_nameOf(upcoming[i]).artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: _dim, fontSize: 13)),
                            if (AutoFetch.instance.isStyle(upcoming[i])) _styleTag(),
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
                              style: TextStyle(color: _dim)),
                        ),
                      ]),
              ),
          ]),
        );
  }

  Widget _actionRow() {
    final busy = AutoFetch.instance.manualBusy;
    final wait = _waitText();
    return Row(children: [
          _action(Ph.equalizer, 'EQ', () => _selSheetEq(), sel: _sel == 'EQ'),
          _action(Ph.skipNext, 'Play next', () => _flash('Play next', () {
            if (widget.dj.automixUpcoming.isNotEmpty) {
              _skip();
            } else {
              _selSheet('Play next', 'Play something next', _requestBox(running: true));
            }
          }), sel: _sel == 'Play next'),
          _action(Ph.search, 'Request', () => _selSheet('Request', 'Request a track', _requestBox(running: true)),
              sel: _sel == 'Request' || busy, sub: busy ? wait : null),
          _action(Ph.playlistAdd, 'Import', () => _selSheet('Import', 'Import a playlist', _importBox()), sel: _sel == 'Import'),
          _action(Ph.insights, 'My style', () => _selSheet('My style', 'My style', _StyleBox(onPlayNow: () => _styleFallback(force: true))),
              sel: _sel == 'My style' || (busy && AutoFetch.instance.isStyleRun), sub: (busy && AutoFetch.instance.isStyleRun) ? wait : null),
          _action(Ph.tune, 'Mixing', () => _selSheet('Mixing', 'Mixing', _MixBox(dj: widget.dj)), sel: _sel == 'Mixing'),
          _action(Ph.fastForward, 'Jump ahead', () => _flash('Jump ahead', _cut), sel: _sel == 'Jump ahead'),
          _action(Ph.stopCircleOutlined, 'End set', () => _flash('End set', _stop), sel: _sel == 'End set'),
        ]);
  }

  Future<void> _selSheetEq() async {
    setState(() => _sel = 'EQ');
    try {
      await Future.sync(_openEq);
    } finally {
      if (mounted) setState(() => _sel = null);
    }
  }

  Widget _glass(Widget child, {double r = 5, EdgeInsets pad = const EdgeInsets.all(14)}) => ClipRRect(
        borderRadius: BorderRadius.circular(r),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            padding: pad,
            decoration: ThemeSettings.instance.box(color: SideDeckTheme.bg.withValues(alpha: 0.7), size: 120),
            child: child,
          ),
        ),
      );

  /// Round glass button.
  Widget _orb(IconData icon, VoidCallback onTap, {String? tip, Color? color, double size = 46, bool sel = false}) => Tooltip(
        message: tip ?? '',
        child: InkWell(
          customBorder: ThemeSettings.instance.shapeBorder(size: size),
          onTap: onTap,
          child: Container(
            width: size,
            height: size,
            decoration: ThemeSettings.instance.box(color: sel ? Color.lerp(Colors.black, SideDeckTheme.accentA, 0.45)! : Colors.black.withValues(alpha: 0.25), hot: sel, size: size),
            child: Icon(icon, size: size * 0.5, color: sel ? SideDeckTheme.accentA : (color ?? Colors.white)),
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
              valueColor: const AlwaysStoppedAnimation(Color(0xFFE9DCB5)),
            ),
          ),
          InkWell(
            customBorder: const CircleBorder(),
            onTap: dj.automixPauseToggle,
            child: Container(
              width: size - 18,
              height: size - 18,
              decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFE9DCB5)),
              child: Icon(dj.automixPaused ? Ph.playArrow : Ph.pause, size: size * 0.45, color: Colors.black),
            ),
          ),
        ]),
      );

  Widget _starOrb(DjController dj, DeckState d) => ListenableBuilder(
        listenable: Starred.instance,
        builder: (_, __) {
          final n = _cleanNames(d);
          final on = Starred.instance.has(n.artist, n.title);
          return _orb(on ? Ph.star : Ph.starBorder, () => _press('star', null, () => _toggleStar(dj), secs: 1), sel: _sel == 'star',
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
        return Stack(fit: StackFit.expand, children: [low ? bars : MilkdropView(levels: dj.spectrum, fallback: bars), _noteBadge()]);
      },
    );
    final chips = Wrap(spacing: 8, children: [
      if (genre.isNotEmpty) _chip(genre.toUpperCase()),
      if (d.bpm > 1) _chip('${(d.bpm * d.rate).round()} BPM'),
    ]);
    final tune = _orb(Ph.tune, () => _sheet('Visuals', const _VisualsBox()), tip: 'Visuals settings', size: 40);
    final title = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(d.loaded ? d.title : '…', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      if (d.artist.isNotEmpty) Text(d.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: _dim)),
      Text('${_mmss(d.position)} / ${_mmss(d.duration)}', style: TextStyle(fontSize: 12, color: _dim)),
    ]);

    return LayoutBuilder(builder: (context, box) {
      final land = box.maxWidth > box.maxHeight;
      if (land) {
        // Landscape: only the visuals, with the track name and genre.
        return Stack(fit: StackFit.expand, children: [
          ClipRRect(borderRadius: BorderRadius.circular(5), child: visuals),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.fromLTRB(20, 36, 20, 16),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00000000), Color(0xCC000000)],
                  ),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Expanded(
                    child: Text(
                      d.loaded ? (d.artist.isNotEmpty ? '${d.artist} - ${d.title}' : d.title) : '…',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontFamily: SideDeckTheme.label, fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: .8),
                    ),
                  ),
                  if (genre.isNotEmpty) ...[const SizedBox(width: 12), _chip(genre.toUpperCase())],
                ]),
              ),
            ),
          ),
        ]);
      }
      // Portrait: visuals behind everything; a glass drawer slides up over them.
      return Stack(fit: StackFit.expand, children: [
        ClipRRect(borderRadius: BorderRadius.circular(5), child: visuals),
        Positioned(left: 12, top: 12, child: chips),
        Positioned(right: 8, top: 8, child: tune),
        DraggableScrollableSheet(
          initialChildSize: 0.44,
          minChildSize: 0.26,
          maxChildSize: 0.94,
          builder: (context, sc) => ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: Container(
                color: const Color(0xCC0B0B10),
                child: ListView(controller: sc, padding: const EdgeInsets.fromLTRB(16, 8, 16, 84), children: [
                  Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)))),
                  const SizedBox(height: 12),
                  title,
                  if (widget.dj.playlistActive)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(children: [
                        Icon(Ph.libraryMusic, size: 16, color: SideDeckTheme.accentA),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text('Playlist ${widget.dj.playlistPos} of ${widget.dj.playlist!.length}, in order',
                              style: TextStyle(color: SideDeckTheme.accentA, fontWeight: FontWeight.w700)),
                        ),
                        TextButton(style: _tight, onPressed: widget.dj.automixPlaylistStop, child: const Text('Stop playlist')),
                      ]),
                    ),
                  const SizedBox(height: 14),
                  Wrap(alignment: WrapAlignment.spaceEvenly, crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, runSpacing: 10, children: [
                    _orb(Ph.arrowBack, () => _press('back', null, () => setState(() => _showChooser = true), secs: 1), tip: 'Back to genres', sel: _sel == 'back'),
                    _dial(dj, frac, 84),
                    _orb(Ph.skipNext, () => _press('skip', 'Mixing to next track', _skip, secs: 8), tip: 'Next track', sel: _sel == 'skip'),
                    _starOrb(dj, d),
                    _orb(Ph.close, () => _press('swap', 'Swapping this track', _dislikeNow, secs: 8), tip: "Don't like it: swap it now", color: const Color(0xFFB05A4A), sel: _sel == 'swap'),
                    _orb(Ph.insights, () {
                      if (StyleSettings.instance.chosen().isEmpty) {
                        _toast('Star some tracks first. My style copies their sound.');
                      } else {
                        _press('style', 'Finding something in your style', () => _styleFallback(force: true), secs: 5);
                      }
                    }, tip: 'Play My style now', color: SideDeckTheme.accentA, sel: _sel == 'style' || AutoFetch.instance.manualBusy),
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
        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(5)),
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
            ? const Color(0xFF5C8A57)
            : (f < 0.82 ? const Color(0xFFB0A04A) : const Color(0xFFA9503F));
        paint.color = on ? base : base.withValues(alpha: 0.08);
        final y = size.height - (j + 1) * segH;
        canvas.drawRect(Rect.fromLTWH(x, y + 1, barW, segH - 2), paint);
      }
      final pk = (peaks[i].clamp(0.0, 1.0) * segs).round().clamp(1, segs);
      paint.color = const Color(0x99C9C3B5);
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
                icon: const Icon(Ph.skipNext),
                label: const Text('Next picture'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: m.preset == null ? null : () => m.set(shuffle: true),
                icon: const Icon(Ph.shuffle),
                label: Text(m.preset == null ? 'Shuffling' : 'Back to shuffle'),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Text(m.preset == null ? 'Pick a preset (or leave it shuffling)' : 'Showing: ${m.preset}',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          TextField(
            decoration: const InputDecoration(hintText: 'Search presets', prefixIcon: Icon(Ph.search)),
            onChanged: (v) => setState(() => _q = v),
          ),
          SizedBox(
            height: 220,
            child: ListView(children: [
              for (final n in shown)
                ListTile(
                  dense: true,
                  title: Text(n, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: m.preset == n ? const Icon(Ph.check, color: Color(0xFFFF5A2B)) : null,
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
  double blend = 30; // 0 = automatic, else seconds the blend itself lasts
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final p = await SharedPreferences.getInstance();
      fade = p.getDouble('mix_fade') ?? 24;
      offset = p.getDouble('mix_offset') ?? 10;
      early = p.getDouble('mix_early') ?? 0;
      blend = p.getDouble('mix_blend') ?? 30;
      _loaded = true;
    } catch (_) {}
  }

  Future<void> save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setDouble('mix_fade', fade);
      await p.setDouble('mix_offset', offset);
      await p.setDouble('mix_early', early);
      await p.setDouble('mix_blend', blend);
    } catch (_) {}
  }

  void apply(DjController dj) {
    if (dj.automixOn) dj.setMixTiming(fade: fade, startOffset: offset, earlyAfter: early, blend: blend);
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
      SizedBox(height: 70, child: CustomPaint(painter: _MixPainter(m.blend > 0 ? math.max(m.blend, m.fade) : m.fade, m.offset))),
      const SizedBox(height: 8),
      Text('Mix out: starts ${m.fade.round()} s before the end', style: const TextStyle(fontWeight: FontWeight.w700)),
      Slider(value: m.fade, min: 4, max: 60, divisions: 28, label: '${m.fade.round()} s', onChanged: (v) => _chg(() => m.fade = v)),
      Text(m.blend == 0 ? 'Blend length: auto (matches the mix-out time)' : 'Blend length: ${m.blend.round()} s', style: const TextStyle(fontWeight: FontWeight.w700)),
      Slider(value: m.blend, min: 0, max: 90, divisions: 45, label: m.blend == 0 ? 'Auto' : '${m.blend.round()} s', onChanged: (v) => _chg(() => m.blend = v)),
      const Text('How long the two tracks overlap. Short is a quick swap, long is a slow blend. Fast and slow tempos may still shorten it.',
          style: TextStyle(fontSize: 12, color: Color(0xFF8A857C))),
      const SizedBox(height: 4),
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
    final paintMix = Paint()..color = const Color(0xFFE9DCB5);
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
  final ValueNotifier<String> lastNote = ValueNotifier('Nothing picked yet.');
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
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(border: Border.all(color: SideDeckTheme.accentA), borderRadius: BorderRadius.circular(4)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('WHAT MY STYLE DOES',
              style: TextStyle(fontFamily: SideDeckTheme.label, fontWeight: FontWeight.w700, fontSize: 16, letterSpacing: 1.4, color: SideDeckTheme.accentA)),
          const SizedBox(height: 6),
          const Text(
              'Star the tracks you love (the star button while a track plays). My style learns their genre, tempo and artists, '
              'then picks more music like them. It plays tracks you already have first. If there are none, it finds similar artists online and downloads them.\n'
              'Use it when the genre queue runs dry, or mix it in regularly below. Tick which starred tracks count, and set how far from them it may roam.',
              style: TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          Text(
              n == 0
                  ? 'You have no starred tracks yet. Star a few and come back.'
                  : 'Using $n starred track${n == 1 ? '' : 's'} · ${st.mode == 0 ? 'Off' : (st.mode == 1 ? 'About every 3 min, when a queue slot is free' : 'Mixed in about every ${st.everyMin} min')}',
              style: TextStyle(color: SideDeckTheme.accentB, fontWeight: FontWeight.w600)),
          ValueListenableBuilder<String>(
            valueListenable: st.lastNote,
            builder: (_, v, __) => Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Last pick: $v', style: const TextStyle(fontSize: 13, color: Color(0xFF8A857C))),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 12),
      const Text('Starred tracks to use', style: TextStyle(fontWeight: FontWeight.w700)),
      Wrap(spacing: 8, children: [
        for (final g in {for (final t in Starred.instance.items) if (t.genre.isNotEmpty) t.genre}.toList()..sort())
          ActionChip(
            avatar: Icon(
              Starred.instance.items.where((t) => t.genre == g).every((t) => !st.excluded.contains(t.key))
                  ? Ph.checkBox
                  : Ph.checkBoxOutlineBlank,
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
        for (final e in const [(0, 'Off'), (1, 'Every few minutes (about 3)'), (2, 'Mixed in regularly')])
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
        icon: const Icon(Ph.insights),
        label: const Text('Play something in my style now'),
      ),
    ]);
  }
}
