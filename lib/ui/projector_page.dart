import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sidedeck/state/app_mode.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/theme/ph.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';
import 'package:sidedeck/ui/milkdrop_view.dart';

/// Sends the MilkDrop visuals to a second screen (an HDMI or USB-C projector or
/// a wireless display) through a native Android presentation, while the phone
/// keeps the controls. The settings and music levels are sent as the same
/// JavaScript the in-app view uses, so both pictures always match.
class ProjectorOutput extends ChangeNotifier {
  ProjectorOutput._();
  static final ProjectorOutput instance = ProjectorOutput._();
  static const _ch = MethodChannel('beatdeck/projector');

  bool active = false;
  List<String> displays = const [];
  String? name;
  Timer? _t;
  int _tick = 0;
  int _seenPoke = 0;
  List<double> _levels = const [];

  /// Looks for connected second screens.
  Future<void> refresh() async {
    try {
      final r = await _ch.invokeMethod<List<dynamic>>('displays');
      displays = (r ?? const []).cast<String>();
      if (active && !(await _ch.invokeMethod<bool>('active') ?? false)) _ended();
    } catch (_) {
      displays = const [];
    }
    notifyListeners();
  }

  /// Shows the visuals on the first second screen. False if there is none.
  Future<bool> start(List<double> levels) async {
    _levels = levels;
    try {
      name = await _ch.invokeMethod<String>('start');
    } catch (_) {
      name = null;
    }
    active = name != null;
    if (active) {
      _seenPoke = MilkdropSettings.instance.poke;
      MilkdropSettings.instance.addListener(_settings);
      _t?.cancel();
      _t = Timer.periodic(const Duration(milliseconds: 50), (_) => _pulse());
      _js('window.setShots&&window.setShots(false);');
      _settings();
    }
    await refresh();
    return active;
  }

  Future<void> stop() async {
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
    _ended();
    notifyListeners();
  }

  void _ended() {
    active = false;
    name = null;
    _t?.cancel();
    _t = null;
    MilkdropSettings.instance.removeListener(_settings);
  }

  void _js(String code) {
    try {
      _ch.invokeMethod('js', {'code': code});
    } catch (_) {}
  }

  void _settings() {
    final m = MilkdropSettings.instance;
    _js(milkdropSettingsJs(m));
    if (m.poke != _seenPoke) {
      _seenPoke = m.poke;
      _js('window.nextPreset&&window.nextPreset();');
    }
  }

  void _pulse() {
    _tick++;
    _js(milkdropLevelsJs(_levels));
    // The page can still be loading when the first settings go out, so send them
    // again every couple of seconds. This also notices an unplugged screen.
    if (_tick % 40 == 0) {
      _settings();
      refresh();
    }
  }
}

/// The Projector page: send the visuals to a second screen, or fill this
/// screen with just the picture so that casting or mirroring shows it.
class ProjectorPage extends StatefulWidget {
  const ProjectorPage({super.key, required this.dj});
  final DjController dj;

  @override
  State<ProjectorPage> createState() => _ProjectorPageState();
}

class _ProjectorPageState extends State<ProjectorPage> {
  final _out = ProjectorOutput.instance;
  String _q = '';

  @override
  void initState() {
    super.initState();
    MilkdropSettings.instance.load();
    _out.refresh();
  }

  Future<void> _start() async {
    final ok = await _out.start(widget.dj.spectrum);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No second screen found. Plug in the projector (HDMI or USB-C), then tap Look again.')));
    }
  }

  void _full() {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ProjectorFullScreen(dj: widget.dj)));
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Text(t, style: const TextStyle(fontWeight: FontWeight.w700)),
      );

  @override
  Widget build(BuildContext context) {
    final m = MilkdropSettings.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Projector'), toolbarHeight: 48),
      body: ListenableBuilder(
        listenable: Listenable.merge([m, _out]),
        builder: (context, _) {
          final shown = m.names.where((n) => n.toLowerCase().contains(_q.toLowerCase())).take(60).toList();
          final found = _out.displays;
          return ListView(padding: const EdgeInsets.all(20), children: [
            Text(
              _out.active
                  ? 'Showing on ${_out.name}'
                  : (found.isEmpty ? 'No second screen connected' : 'Found: ${found.join(', ')}'),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            const Text(
              'The visuals play on the projector or TV while this phone keeps the controls. '
              'Plug in with an HDMI or USB-C video cable, or connect a wireless display in the phone\'s settings.',
              style: TextStyle(color: Color(0xFFB8B3AA)),
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: FilledButton.icon(
                    onPressed: _out.active ? _out.stop : _start,
                    icon: Icon(_out.active ? Icons.stop_circle_outlined : Icons.cast_connected),
                    label: Text(_out.active ? 'Stop projecting' : 'Show on second screen',
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(tooltip: 'Look again', icon: const Icon(Icons.refresh), onPressed: _out.refresh),
            ]),
            const SizedBox(height: 10),
            SizedBox(
              height: 52,
              child: OutlinedButton.icon(
                onPressed: _full,
                icon: const Icon(Icons.fullscreen),
                label: const Text('Full screen here (for Cast or mirroring)', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Full screen shows only the picture. Start screen mirroring or Cast from the phone\'s quick settings and the TV shows the same thing.',
              style: TextStyle(fontSize: 12, color: Color(0xFF8A857C)),
            ),
            _label('Projector position'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Mirror left to right'),
              subtitle: const Text('For a projector behind the screen'),
              value: m.flipH,
              onChanged: (v) => m.set(flipHV: v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Upside down'),
              subtitle: const Text('For a projector on the ceiling'),
              value: m.flipV,
              onChanged: (v) => m.set(flipVV: v),
            ),
            Text('Brightness: ${(m.dim * 100).round()}%', style: const TextStyle(fontWeight: FontWeight.w700)),
            Slider(value: m.dim, min: 0.1, max: 1, onChanged: (v) => m.set(dimV: v)),
            Text(
                'Intensity: ${m.intensity < 0.2 ? 'very calm' : m.intensity < 0.45 ? 'calm' : m.intensity < 0.7 ? 'medium' : m.intensity < 0.9 ? 'high' : 'wild'}',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            Slider(value: m.intensity, onChanged: (v) => m.set(i: v)),
            const Text('Speed (frames per second)', style: TextStyle(fontWeight: FontWeight.w700)),
            Wrap(spacing: 8, children: [
              for (final f in const [5, 10, 15, 20, 30, 45, 60])
                ChoiceChip(label: Text('$f'), selected: m.fps == f, onSelected: (_) => m.set(fpsV: f)),
            ]),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Smooth blending'),
              subtitle: const Text('At a low speed, fade between pictures instead of jumping'),
              value: m.blend,
              onChanged: (v) => m.set(blendV: v),
            ),
            const MilkdropPaceControls(),
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
            if (m.names.isNotEmpty) ...[
              _label(m.preset == null ? 'Pick a preset (or leave it shuffling)' : 'Showing: ${m.preset}'),
              TextField(
                decoration: const InputDecoration(hintText: 'Search presets', prefixIcon: Icon(Ph.search)),
                onChanged: (v) => setState(() => _q = v),
              ),
              SizedBox(
                height: 200,
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
            ],
            const SizedBox(height: 16),
            const Text(
              'The picture reacts to the music that is playing. Start the music from the first page for the best result.',
              style: TextStyle(fontSize: 12, color: Color(0xFF8A857C)),
            ),
          ]);
        },
      ),
    );
  }
}

/// Just the picture, edge to edge, with nothing else on screen. Tap for the
/// next picture, press and hold to freeze it, Back to leave.
class ProjectorFullScreen extends StatefulWidget {
  const ProjectorFullScreen({super.key, required this.dj});
  final DjController dj;

  @override
  State<ProjectorFullScreen> createState() => _ProjectorFullScreenState();
}

class _ProjectorFullScreenState extends State<ProjectorFullScreen> {
  bool _hint = true;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    _t = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _hint = false);
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    AppMode.applyOrientation();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        MilkdropView(levels: widget.dj.spectrum, fallback: const ColoredBox(color: Colors.black)),
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: _hint ? 1 : 0,
            duration: const Duration(milliseconds: 600),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                margin: const EdgeInsets.only(bottom: 24),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(color: const Color(0xAA000000), borderRadius: BorderRadius.circular(20)),
                child: Text('Tap: next picture   Hold: freeze   Back: leave',
                    style: TextStyle(fontFamily: SideDeckTheme.label, fontSize: 14, color: Colors.white70)),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
