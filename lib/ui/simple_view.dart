import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/debug/debug_log.dart';
import 'package:sidedeck/soulseek/slsk_keeper.dart';
import 'package:sidedeck/soulseek/slsk_setup.dart';
import 'package:sidedeck/soulseek/soulseek_client.dart';
import 'package:sidedeck/state/app_mode.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/state/screen_brightness.dart';
import 'package:sidedeck/suggest/auto_fetch.dart';
import 'package:sidedeck/suggest/genres.dart';
import 'package:sidedeck/suggest/suggest_service.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

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

class _SimpleViewState extends State<SimpleView> {
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
    _restore();
  }

  @override
  void dispose() {
    _artist.dispose();
    _track.dispose();
    super.dispose();
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
      List<String> paths() => [for (final t in widget.library.tracks) t.path];

      final req = _hasRequest;
      final reqArtist = _artist.text.trim(), reqTrack = _track.text.trim();
      final hadMusic = paths().isNotEmpty;
      if (req && !hadMusic) {
        af.enqueueTracks([Suggestion(reqArtist, reqTrack, 0, 'your request')], widget.library);
      }
      if (paths().isEmpty) {
        // Nothing on the phone yet: fetch the first track, then start.
        final started = DateTime.now();
        var asked = DateTime.fromMillisecondsSinceEpoch(0);
        while (mounted && run == _run && paths().isEmpty) {
          if (DateTime.now().difference(started).inMinutes >= 5) {
            setState(() => _note = 'Could not find music. Check your internet and try again.');
            return;
          }
          if (!soulseek.online) {
            setState(() => _note = 'Connecting…');
          } else {
            setState(() => _note = af.status.isNotEmpty ? af.status : 'Finding your first track…');
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
      } else if (req && hadMusic) {
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
    widget.dj.stopAutomix();
    setState(() {
      _starting = false;
      _note = '';
    });
  }

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
        return Scaffold(
          backgroundColor: SideDeckTheme.bg,
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    const Text('BeatDeck',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: 1)),
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
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'log', child: Text('Report a problem (copy log)')),
                        PopupMenuItem(value: 'pro', child: Text('Switch to Pro mode')),
                      ],
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Expanded(child: on ? _playing(dj) : _chooser()),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _chooser() {
    return ListView(
      children: [
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

  Widget _playing(DjController dj) {
    final d = dj.deck(dj.automixPlayingDeck.clamp(0, 1));
    final genre = d.path == null ? '' : (dj.genreOf?.call(d.path!) ?? '');
    final af = AutoFetch.instance;
    final status = af.running && af.status.isNotEmpty ? af.status : (dj.automixStatus ?? '');
    return ListView(
      children: [
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: SideDeckTheme.panel,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(children: [
            const Text('NOW PLAYING',
                style: TextStyle(fontSize: 11, letterSpacing: 1.5, color: Color(0xFF8A857C))),
            const SizedBox(height: 10),
            Text(d.loaded ? d.title : '…',
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            if (d.artist.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(d.artist,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16, color: Color(0xFFB8B3AA))),
            ],
            if (genre.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(genre.toUpperCase(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 13, letterSpacing: 1.2, fontWeight: FontWeight.w700, color: SideDeckTheme.accentB)),
            ],
            if (d.bpm > 1) ...[
              const SizedBox(height: 10),
              Text('${(d.bpm * d.rate).round()} BPM',
                  style: const TextStyle(color: SideDeckTheme.accentA, fontWeight: FontWeight.w700)),
            ],
          ]),
        ),
        const SizedBox(height: 12),
        if (status.isNotEmpty)
          Text(status,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Color(0xFF8A857C))),
        const SizedBox(height: 12),
        _requestBox(running: true),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(
            child: SizedBox(
              height: 60,
              child: FilledButton.icon(
                onPressed: _skip,
                icon: const Icon(Icons.skip_next, size: 28),
                label: const Text('Skip', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SizedBox(
              height: 60,
              child: OutlinedButton.icon(
                onPressed: _stop,
                icon: const Icon(Icons.stop, size: 28),
                label: const Text('Stop', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              ),
            ),
          ),
        ]),
      ],
    );
  }
}
