import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/ui/milkdrop_photo_store.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Receives a small still of the MilkDrop picture every few seconds (JPEG).
void Function(Uint8List jpeg)? milkdropArtSink;

/// MilkDrop settings: how wild it is, how often the picture changes, and an
/// optional fixed preset. Saved on the phone.
class MilkdropSettings extends ChangeNotifier {
  MilkdropSettings._();
  static final MilkdropSettings instance = MilkdropSettings._();

  /// 0 (very calm) .. 1 (wild).
  double intensity = 0.3;

  /// Frames per second drawn (lower = slower, gentler motion).
  int fps = 15;

  /// Screen brightness of the picture, 0.1 .. 1.
  double dim = 0.8;

  /// Seconds between automatic changes; 0 = never change.
  int autoSecs = 30;

  /// Projector: mirror the picture left-right and/or upside down.
  bool flipH = false;
  bool flipV = false;

  /// Fade between frames at a low frame rate so the motion is smooth, not jerky.
  bool blend = true;

  /// How fast the pictures move, 0.1 (very slow) .. 1 (normal).
  double speed = 1.0;

  /// Random: a new value at every change of picture, up to the slider's setting.
  bool randSpeed = false;
  bool randFade = false;
  bool randIntensity = false;

  /// Your photos over the picture: 0 = off, 1 = fully showing. Seconds each photo stays.
  double photoStrength = 0;
  int photoSecs = 20;

  /// Seconds a change from one picture to the next takes.
  int fade = 3;

  /// A fixed preset name, or null to let it shuffle.
  String? preset;
  List<String> names = [];
  int _poke = 0; // bumped to ask for "next preset"
  int get poke => _poke;

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      intensity = p.getDouble('md_intensity') ?? 0.3;
      autoSecs = p.getInt('md_auto') ?? 30;
      fps = p.getInt('md_fps') ?? 15;
      dim = p.getDouble('md_dim') ?? 0.8;
      flipH = p.getBool('md_flip_h') ?? false;
      flipV = p.getBool('md_flip_v') ?? false;
      blend = p.getBool('md_blend') ?? true;
      speed = p.getDouble('md_speed') ?? 1.0;
      randSpeed = p.getBool('md_rand_speed') ?? false;
      randFade = p.getBool('md_rand_fade') ?? false;
      randIntensity = p.getBool('md_rand_int') ?? false;
      photoStrength = p.getDouble('md_photo') ?? 0;
      photoSecs = p.getInt('md_photo_secs') ?? 20;
      fade = p.getInt('md_fade') ?? 3;
      preset = p.getString('md_preset');
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setDouble('md_intensity', intensity);
      await p.setInt('md_auto', autoSecs);
      await p.setInt('md_fps', fps);
      await p.setDouble('md_dim', dim);
      await p.setBool('md_flip_h', flipH);
      await p.setBool('md_flip_v', flipV);
      await p.setBool('md_blend', blend);
      await p.setDouble('md_speed', speed);
      await p.setBool('md_rand_speed', randSpeed);
      await p.setBool('md_rand_fade', randFade);
      await p.setBool('md_rand_int', randIntensity);
      await p.setDouble('md_photo', photoStrength);
      await p.setInt('md_photo_secs', photoSecs);
      await p.setInt('md_fade', fade);
      if (preset == null) {
        await p.remove('md_preset');
      } else {
        await p.setString('md_preset', preset!);
      }
    } catch (_) {}
  }

  void set({double? i, int? fpsV, double? dimV, int? auto, String? pick, bool shuffle = false, bool? flipHV, bool? flipVV, bool? blendV, double? speedV, int? fadeV, bool? randSpeedV, bool? randFadeV, bool? randIntensityV, double? photoV, int? photoSecsV}) {
    if (i != null) intensity = i;
    if (auto != null) autoSecs = auto;
    if (fpsV != null) fps = fpsV;
    if (dimV != null) dim = dimV;
    if (flipHV != null) flipH = flipHV;
    if (flipVV != null) flipV = flipVV;
    if (blendV != null) blend = blendV;
    if (speedV != null) speed = speedV;
    if (fadeV != null) fade = fadeV;
    if (randSpeedV != null) randSpeed = randSpeedV;
    if (randFadeV != null) randFade = randFadeV;
    if (randIntensityV != null) randIntensity = randIntensityV;
    if (photoV != null) photoStrength = photoV;
    if (photoSecsV != null) photoSecs = photoSecsV;
    if (pick != null) preset = pick;
    if (shuffle) preset = null;
    notifyListeners();
    _save();
  }

  void setNames(List<String> n) {
    names = n;
    notifyListeners();
  }

  void next() {
    preset = null;
    _poke++;
    notifyListeners();
    _save();
  }
}

/// The JavaScript that applies [m] to a MilkDrop page. Used by the in-app view
/// and by the projector page on a second screen, so both always match.
String milkdropSettingsJs(MilkdropSettings m) {
  // Calm (0) .. wild (1) maps to a gentle .. strong picture.
  return 'window.setGain&&window.setGain(${(0.15 + m.intensity * 1.1).toStringAsFixed(2)});'
      'window.setAuto&&window.setAuto(${m.autoSecs});'
      'window.setFps&&window.setFps(${m.fps});'
      'window.setDim&&window.setDim(${m.dim.toStringAsFixed(2)});'
      'window.setFlip&&window.setFlip(${m.flipH},${m.flipV});'
      'window.setBlend&&window.setBlend(${m.blend});'
      'window.setPace&&window.setPace(${m.speed.toStringAsFixed(2)},${m.fade});'
      'window.setRandom&&window.setRandom(${m.randSpeed},${m.randFade},${m.randIntensity});'
      'window.setPhotos&&window.setPhotos(${m.photoStrength.toStringAsFixed(2)},${m.photoSecs});'
      'window.loadName&&window.loadName(${jsonEncode(m.preset)});';
}

/// The JavaScript that feeds 14 music levels (0..1) to a MilkDrop page.
String milkdropLevelsJs(List<double> levels) {
  final a = levels.map((v) => v.clamp(0.0, 1.0).toStringAsFixed(2)).join(',');
  return 'window.setLevels&&window.setLevels([$a])';
}

/// MilkDrop-style visuals (butterchurn, bundled in the app, works offline).
/// The music levels are sent to the page ~20 times a second. Until the page
/// is drawing (or if the phone cannot do it), [fallback] shows instead.
class MilkdropView extends StatefulWidget {
  const MilkdropView({super.key, required this.levels, required this.fallback});

  /// 14 band levels, 0..1, updated in place by the player.
  final List<double> levels;
  final Widget fallback;

  @override
  State<MilkdropView> createState() => _MilkdropViewState();
}

class _MilkdropViewState extends State<MilkdropView> {
  late final WebViewController _c;
  Timer? _t;
  bool _ready = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..addJavaScriptChannel('Md', onMessageReceived: (m) {
        if (!mounted) return;
        if (m.message == 'ok') {
          setState(() => _ready = true);
          _apply(true);
          _sendPhotos();
        }
        if (m.message.startsWith('art:')) {
          try {
            final i = m.message.indexOf(',');
            if (i > 0) milkdropArtSink?.call(base64Decode(m.message.substring(i + 1)));
          } catch (_) {}
        }
        if (m.message.startsWith('names:')) {
          try {
            MilkdropSettings.instance.setNames((jsonDecode(m.message.substring(6)) as List).cast<String>());
          } catch (_) {}
        }
        if (m.message == 'fail') setState(() => _failed = true);
      })
      ..loadFlutterAsset('assets/milkdrop/index.html');
    MilkdropSettings.instance.load();
    MilkdropSettings.instance.addListener(_apply);
    MilkdropPhotos.instance.load();
    MilkdropPhotos.instance.addListener(_sendPhotos);
    _t = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!_ready) return;
      _c.runJavaScript(milkdropLevelsJs(widget.levels));
    });
  }

  int _photoVer = -1;
  bool _sending = false;

  /// Sends the chosen photos to the page, one at a time, whenever the list changes.
  Future<void> _sendPhotos() async {
    final ph = MilkdropPhotos.instance;
    if (!_ready || _sending || _photoVer == ph.version) return;
    _sending = true;
    try {
      while (mounted && _photoVer != ph.version) {
        _photoVer = ph.version;
        await _c.runJavaScript('window.clearPhotos&&window.clearPhotos();');
        for (final f in List.of(ph.files)) {
          if (!mounted) break;
          final b = base64Encode(await f.readAsBytes());
          await _c.runJavaScript('window.addPhoto&&window.addPhoto("data:image/jpeg;base64,$b");');
        }
      }
    } catch (_) {}
    _sending = false;
  }

  int _seenPoke = 0;
  void _apply([bool force = false]) {
    if (!_ready && force != true) return;
    final m = MilkdropSettings.instance;
    _c.runJavaScript(milkdropSettingsJs(m));
    if (m.poke != _seenPoke) {
      _seenPoke = m.poke;
      _c.runJavaScript('window.nextPreset&&window.nextPreset();');
    }
  }

  @override
  void dispose() {
    MilkdropSettings.instance.removeListener(_apply);
    MilkdropPhotos.instance.removeListener(_sendPhotos);
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return widget.fallback;
    return Stack(fit: StackFit.expand, children: [
      if (!_ready) widget.fallback,
      Opacity(opacity: _ready ? 1 : 0, child: WebViewWidget(controller: _c)),
    ]);
  }
}

/// Motion speed, the length of a change between pictures, how often it
/// changes, and a one-tap "slow and steady" setting. Used in the Visuals sheet
/// and on the Projector page.
class MilkdropPaceControls extends StatelessWidget {
  const MilkdropPaceControls({super.key});

  static String _t(int s) => s == 0 ? 'Never' : s < 0 ? 'Random' : s < 60 ? '${s}s' : '${s ~/ 60}m';

  @override
  Widget build(BuildContext context) {
    final m = MilkdropSettings.instance;
    const secs = [0, -1, 10, 20, 30, 60, 120, 300, 600];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: OutlinedButton.icon(
          onPressed: () => m.set(i: 0.15, speedV: 0.1, fadeV: 20, auto: 120, blendV: true),
          icon: const Icon(Icons.spa_outlined),
          label: const Text('Slow and steady'),
        ),
      ),
      const SizedBox(height: 8),
      Text('Motion speed: ${(m.speed * 100).round()}%', style: const TextStyle(fontWeight: FontWeight.w700)),
      Slider(value: m.speed, min: 0.1, max: 1, onChanged: (v) => m.set(speedV: v)),
      Text('Change blend: ${m.fade}s', style: const TextStyle(fontWeight: FontWeight.w700)),
      const Text('How long one picture takes to melt into the next', style: TextStyle(fontSize: 12, color: Color(0xFF8A857C))),
      Slider(value: m.fade.toDouble(), min: 2, max: 30, divisions: 28, onChanged: (v) => m.set(fadeV: v.round())),
      const Text('Change picture every', style: TextStyle(fontWeight: FontWeight.w700)),
      Wrap(spacing: 8, children: [
        for (final s in secs) ChoiceChip(label: Text(_t(s)), selected: m.autoSecs == s, onSelected: (_) => m.set(auto: s)),
      ]),
      const SizedBox(height: 8),
      const Text('Random: a new value at every change', style: TextStyle(fontWeight: FontWeight.w700)),
      const Text('Picks between the lowest setting and the slider each time the picture changes. "Random" above picks the time too (10 s to 5 min).',
          style: TextStyle(fontSize: 12, color: Color(0xFF8A857C))),
      Wrap(spacing: 8, children: [
        FilterChip(label: const Text('Intensity'), selected: m.randIntensity, onSelected: (v) => m.set(randIntensityV: v)),
        FilterChip(label: const Text('Motion speed'), selected: m.randSpeed, onSelected: (v) => m.set(randSpeedV: v)),
        FilterChip(label: const Text('Change blend'), selected: m.randFade, onSelected: (v) => m.set(randFadeV: v)),
      ]),
    ]);
  }
}
