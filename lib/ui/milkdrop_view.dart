import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

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
        if (m.message == 'ok') setState(() => _ready = true);
        if (m.message == 'fail') setState(() => _failed = true);
      })
      ..loadFlutterAsset('assets/milkdrop/index.html');
    _t = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!_ready) return;
      final a = widget.levels.map((v) => v.clamp(0.0, 1.0).toStringAsFixed(2)).join(',');
      _c.runJavaScript('window.setLevels&&window.setLevels([$a])');
    });
  }

  @override
  void dispose() {
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
