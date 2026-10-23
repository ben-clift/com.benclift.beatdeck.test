import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

/// Launch screen: a record made of rotating arcs, a pulsing equaliser and the
/// name, then a quick fade into the app.
class SplashGate extends StatefulWidget {
  const SplashGate({super.key, required this.child, this.minTime = const Duration(milliseconds: 2600)});
  final Widget child;
  final Duration minTime;

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 6))..repeat();
  bool _done = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(widget.minTime, () {
      if (mounted) setState(() => _done = true);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(fit: StackFit.expand, children: [
      widget.child,
      IgnorePointer(
        ignoring: _done,
        child: AnimatedOpacity(
          opacity: _done ? 0 : 1,
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeOut,
          onEnd: () {
            if (_done && mounted) _c.stop();
          },
          child: _splash(),
        ),
      ),
    ]);
  }

  Widget _splash() {
    return Container(
      color: SideDeckTheme.bg,
      child: Center(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final t = _c.value;
            return Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                width: 230,
                height: 230,
                child: CustomPaint(painter: _RecordPainter(t)),
              ),
              const SizedBox(height: 34),
              Text('BEATDECK',
                  style: TextStyle(
                      fontFamily: SideDeckTheme.label,
                      fontSize: 54,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 8,
                      color: SideDeckTheme.text)),
              const SizedBox(height: 4),
              Text('YOUR SET, ON ITS OWN',
                  style: TextStyle(
                      fontFamily: SideDeckTheme.label,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 5,
                      color: SideDeckTheme.accentB)),
              const SizedBox(height: 40),
              SizedBox(width: 120, height: 26, child: CustomPaint(painter: _BarsPainter(t))),
            ]);
          },
        ),
      ),
    );
  }
}

class _RecordPainter extends CustomPainter {
  _RecordPainter(this.t);
  final double t;

  @override
  void paint(Canvas c, Size s) {
    final ctr = s.center(Offset.zero);
    final R = s.width / 2;
    // Soft glow behind the record.
    c.drawCircle(
        ctr,
        R,
        Paint()
          ..shader = RadialGradient(colors: [
            SideDeckTheme.accentA.withOpacity(.22 + .06 * math.sin(t * 2 * math.pi * 3)),
            Colors.transparent
          ]).createShader(Rect.fromCircle(center: ctr, radius: R)));
    final disc = Paint()..color = const Color(0xFF111114);
    c.drawCircle(ctr, R * .86, disc);
    final groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0xFF26262B);
    for (var i = 0; i < 9; i++) {
      c.drawCircle(ctr, R * (.38 + i * .052), groove);
    }
    // Rotating arcs, each ring at its own speed and direction.
    final rings = [
      (.86, 5.0, SideDeckTheme.accentA, 1.0, 2.2),
      (.74, 4.0, SideDeckTheme.accentB, -1.6, 1.6),
      (.62, 3.0, SideDeckTheme.accentA, 2.4, 1.1),
      (.50, 3.0, SideDeckTheme.accentB, -3.0, 0.9),
    ];
    for (final r in rings) {
      final p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.butt
        ..strokeWidth = r.$2
        ..color = r.$3;
      final rect = Rect.fromCircle(center: ctr, radius: R * r.$1);
      final a0 = t * 2 * math.pi * r.$4;
      c.drawArc(rect, a0, r.$5, false, p);
      c.drawArc(rect, a0 + math.pi, r.$5 * .55, false, p..color = r.$3.withOpacity(.45));
    }
    // Label and spindle.
    c.drawCircle(ctr, R * .24, Paint()..color = SideDeckTheme.accentA);
    c.drawCircle(ctr, R * .06, Paint()..color = SideDeckTheme.bg);
    // Tone arm sweeping in.
    final arm = Paint()
      ..color = SideDeckTheme.text
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final ang = -0.35 + 0.18 * math.sin(t * 2 * math.pi);
    final base = Offset(s.width * .98, s.height * .06);
    final tip = ctr + Offset(math.cos(ang + math.pi * .85), math.sin(ang + math.pi * .85)) * (R * .6);
    c.drawLine(base, tip, arm);
    c.drawCircle(base, 6, Paint()..color = SideDeckTheme.panelAlt);
  }

  @override
  bool shouldRepaint(_RecordPainter o) => o.t != t;
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.t);
  final double t;

  @override
  void paint(Canvas c, Size s) {
    const n = 14;
    final w = s.width / (n * 1.6);
    for (var i = 0; i < n; i++) {
      final h = (.25 + .75 * (0.5 + 0.5 * math.sin(t * 2 * math.pi * 6 + i * .9) * math.sin(t * 2 * math.pi * 2 + i * .4)).abs()) * s.height;
      final x = i * w * 1.6;
      c.drawRect(Rect.fromLTWH(x, s.height - h, w, h),
          Paint()..color = i % 5 == 0 ? SideDeckTheme.accentB : SideDeckTheme.accentA);
    }
  }

  @override
  bool shouldRepaint(_BarsPainter o) => o.t != t;
}
