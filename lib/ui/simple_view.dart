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
import 'package:sidedeck/theme/sidedeck_theme.dart';

class _Vibe {
  const _Vibe(this.label, this.genres, {this.bands = false});
  final String label;
  final List<String> genres;
  final bool bands;
}

const _vibes = <_Vibe>[
  _Vibe('House', ['house', 'deep house', 'tech house']),
  _Vibe('Techno', ['techno', 'minimal techno']),
  _Vibe('Trance', ['trance', 'progressive trance']),
  _Vibe('Drum & bass', ['drum and bass', 'liquid drum and bass']),
  _Vibe('Breaks', ['breakbeat', 'big beat']),
  _Vibe('Disco & funk', ['disco', 'nu disco']),
  _Vibe('Rock & indie', ['indie rock', 'rock', 'post punk'], bands: true),
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
  String _note = '';
  int _run = 0;

  @override
  void initState() {
    super.initState();
    _restore();
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
      af.intensity = 0;
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
      if (hi > 0) {
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
            if (!af.running && DateTime.now().difference(asked).inSeconds >= 8) {
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
      if (!dj.automixOn) setState(() => _note = dj.automixStatus ?? '');
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
        const SizedBox(height: 28),
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
    final af = AutoFetch.instance;
    final status = af.running && af.status.isNotEmpty ? af.status : (dj.automixStatus ?? '');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(),
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
        const Spacer(),
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
