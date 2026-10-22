import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

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
      if (preset == null) {
        await p.remove('md_preset');
      } else {
        await p.setString('md_preset', preset!);
      }
    } catch (_) {}
  }

  void set({double? i, int? fpsV, double? dimV, int? auto, String? pick, bool shuffle = false}) {
    if (i != null) intensity = i;
    if (auto != null) autoSecs = auto;
    if (fpsV != null) fps = fpsV;
    if (dimV != null) dim = dimV;
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
    _t = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!_ready) return;
      final a = widget.levels.map((v) => v.clamp(0.0, 1.0).toStringAsFixed(2)).join(',');
      _c.runJavaScript('window.setLevels&&window.setLevels([$a])');
    });
  }

  int _seenPoke = 0;
  void _apply([bool force = false]) {
    if (!_ready && force != true) return;
    final m = MilkdropSettings.instance;
    // Calm (0) .. wild (1) maps to a gentle .. strong picture.
    _c.runJavaScript('window.setGain&&window.setGain(${(0.15 + m.intensity * 1.1).toStringAsFixed(2)});'
        'window.setAuto&&window.setAuto(${m.autoSecs});'
        'window.setFps&&window.setFps(${m.fps});'
        'window.setDim&&window.setDim(${m.dim.toStringAsFixed(2)});'
        'window.loadName&&window.loadName(${jsonEncode(m.preset)});');
    if (m.poke != _seenPoke) {
      _seenPoke = m.poke;
      _c.runJavaScript('window.nextPreset&&window.nextPreset();');
    }
  }

  @override
  void dispose() {
    MilkdropSettings.instance.removeListener(_apply);
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
