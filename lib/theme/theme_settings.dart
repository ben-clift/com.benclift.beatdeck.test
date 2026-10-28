import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A named set of colours the user can pick in Appearance.
class ThemePreset {
  const ThemePreset(this.name, this.bg, this.panel, this.accentA, this.accentB, this.text, this.muted);
  final String name;
  final Color bg, panel, accentA, accentB, text, muted;
}

/// Colours, box shape, 3D depth and background, chosen by the user and saved
/// on the phone. Everything in the app reads its look from here.
class ThemeSettings extends ChangeNotifier {
  ThemeSettings._();
  static final ThemeSettings instance = ThemeSettings._();

  static const presets = <ThemePreset>[
    ThemePreset('Ember', Color(0xFF0D0D0F), Color(0xFF17171A), Color(0xFFFF5A2B), Color(0xFFE9DCB5), Color(0xFFEDEBE6), Color(0xFF8C8A85)),
    ThemePreset('Ocean', Color(0xFF07131C), Color(0xFF0E2230), Color(0xFF2DB6FF), Color(0xFFBFE9FF), Color(0xFFE6F3FA), Color(0xFF7F9AAB)),
    ThemePreset('Forest', Color(0xFF0A130D), Color(0xFF122419), Color(0xFF45D483), Color(0xFFD7EBC2), Color(0xFFE8F2E8), Color(0xFF86998B)),
    ThemePreset('Violet', Color(0xFF120D1C), Color(0xFF1D1530), Color(0xFFB36BFF), Color(0xFFF1D9FF), Color(0xFFF0E8FA), Color(0xFF9A8FB0)),
    ThemePreset('Sunset', Color(0xFF1A0D10), Color(0xFF2A1519), Color(0xFFFF7A59), Color(0xFFFFD08A), Color(0xFFFBEDE6), Color(0xFFB09088)),
    ThemePreset('Mono', Color(0xFF0B0B0B), Color(0xFF181818), Color(0xFFFFFFFF), Color(0xFFBDBDBD), Color(0xFFEFEFEF), Color(0xFF8A8A8A)),
  ];

  /// Backgrounds and boxes may not be very light, because the text would
  /// vanish into them. Anything lighter than this is darkened to fit.
  static const double maxLuminance = 0.25;
  static bool tooLight(Color c) => c.computeLuminance() > maxLuminance;
  static Color limitLight(Color c) {
    if (!tooLight(c)) return c;
    var h = HSVColor.fromColor(c);
    for (var i = 0; i < 60 && tooLight(h.toColor()); i++) {
      h = h.withValue(math.max(0.0, h.value - 0.02)).withSaturation(h.saturation);
    }
    return h.toColor();
  }

  static const shapeNames = ['Square', 'Rounded', 'Soft', 'Bevel', 'Squircle'];
  static const depthNames = ['Flat', 'Soft', 'Raised', 'Deep'];
  static const backgroundNames = ['Solid', 'Gradient', 'Glow', 'Grid floor', 'Spotlight'];

  Color bg = presets[0].bg;
  Color panel = presets[0].panel;
  Color accentA = presets[0].accentA;
  Color accentB = presets[0].accentB;
  Color text = presets[0].text;
  Color muted = presets[0].muted;
  int shape = 0; // see shapeNames
  int depth = 0; // see depthNames
  int background = 0; // see backgroundNames
  String preset = 'Ember';

  Color get line => Color.lerp(panel, text, 0.14)!;
  Color get panelAlt => Color.lerp(panel, text, 0.06)!;
  bool get isLight => bg.computeLuminance() > 0.5;

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      Color c(String k, Color d) => Color(p.getInt(k) ?? d.toARGB32());
      // The old light "Paper" set is gone: go back to the default colours.
      if (p.getString('th_preset') == 'Paper') {
        await p.setString('th_preset', 'Ember');
        await p.remove('th_bg');
        await p.remove('th_panel');
        await p.remove('th_a');
        await p.remove('th_b');
        await p.remove('th_text');
        await p.remove('th_muted');
      }
      bg = limitLight(c('th_bg', bg));
      panel = limitLight(c('th_panel', panel));
      accentA = c('th_a', accentA);
      accentB = c('th_b', accentB);
      text = c('th_text', text);
      muted = c('th_muted', muted);
      shape = (p.getInt('th_shape') ?? 0).clamp(0, 4);
      depth = (p.getInt('th_depth') ?? 0).clamp(0, 3);
      background = (p.getInt('th_bgstyle') ?? 0).clamp(0, 4);
      preset = p.getString('th_preset') ?? 'Ember';
      // A light background that has just been darkened would leave dark text unreadable.
      if ((text.computeLuminance() - bg.computeLuminance()).abs() < 0.3) {
        text = presets[0].text;
        muted = presets[0].muted;
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt('th_bg', bg.toARGB32());
      await p.setInt('th_panel', panel.toARGB32());
      await p.setInt('th_a', accentA.toARGB32());
      await p.setInt('th_b', accentB.toARGB32());
      await p.setInt('th_text', text.toARGB32());
      await p.setInt('th_muted', muted.toARGB32());
      await p.setInt('th_shape', shape);
      await p.setInt('th_depth', depth);
      await p.setInt('th_bgstyle', background);
      await p.setString('th_preset', preset);
    } catch (_) {}
  }

  void applyPreset(ThemePreset t) {
    bg = t.bg;
    panel = t.panel;
    accentA = t.accentA;
    accentB = t.accentB;
    text = t.text;
    muted = t.muted;
    preset = t.name;
    notifyListeners();
    _save();
  }

  void setColor(String which, Color c) {
    switch (which) {
      case 'bg':
        bg = limitLight(c);
      case 'panel':
        panel = limitLight(c);
      case 'a':
        accentA = c;
      case 'b':
        accentB = c;
      case 'text':
        text = c;
      case 'muted':
        muted = c;
    }
    preset = 'Custom';
    notifyListeners();
    _save();
  }

  void setStyle({int? shapeV, int? depthV, int? bgV}) {
    if (shapeV != null) shape = shapeV;
    if (depthV != null) depth = depthV;
    if (bgV != null) background = bgV;
    notifyListeners();
    _save();
  }

  void reset() {
    applyPreset(presets[0]);
    shape = 0;
    depth = 0;
    background = 0;
    notifyListeners();
    _save();
  }

  // ---- Shapes and depth --------------------------------------------------

  /// The outline for boxes and buttons. [size] is the shorter side of the
  /// thing being drawn, so round shapes can become full circles on small ones.
  OutlinedBorder shapeBorder({double size = 100, Color? side, double width = 1}) {
    final s = BorderSide(color: side ?? line, width: width);
    switch (shape) {
      case 1:
        return RoundedRectangleBorder(borderRadius: BorderRadius.circular(math.min(12, size / 2)), side: s);
      case 2:
        return RoundedRectangleBorder(borderRadius: BorderRadius.circular(math.min(26, size / 2)), side: s);
      case 3:
        return BeveledRectangleBorder(borderRadius: BorderRadius.circular(math.min(12, size / 3)), side: s);
      case 4:
        return RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(math.min(26, size / 2)), side: s);
      default:
        return RoundedRectangleBorder(borderRadius: BorderRadius.circular(math.min(4, size / 2)), side: s);
    }
  }

  static Color lighten(Color c, double a) {
    final h = HSLColor.fromColor(c);
    return h.withLightness((h.lightness + a).clamp(0.0, 1.0)).toColor();
  }

  static Color darken(Color c, double a) => lighten(c, -a);

  /// Box paint with the chosen shape and depth: flat, soft shadow, raised 3D
  /// (lit top edge, darker bottom) or deep. [size] as in [shapeBorder].
  ShapeDecoration box({Color? color, double size = 100, bool hot = false}) {
    final base = color ?? panel;
    final edge = hot ? accentA : line;
    final light = isLight;
    switch (depth) {
      case 1:
        return ShapeDecoration(
          color: base,
          shape: shapeBorder(size: size, side: edge, width: hot ? 1.5 : 1),
          shadows: [BoxShadow(color: Colors.black.withValues(alpha: light ? 0.14 : 0.40), blurRadius: 10, offset: const Offset(0, 4))],
        );
      case 2:
        return ShapeDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [lighten(base, light ? 0.03 : 0.07), darken(base, light ? 0.06 : 0.08)],
          ),
          shape: shapeBorder(size: size, side: hot ? accentA : lighten(edge, 0.08), width: hot ? 1.5 : 1),
          shadows: [
            BoxShadow(color: Colors.black.withValues(alpha: light ? 0.22 : 0.55), blurRadius: 8, offset: const Offset(0, 5)),
            BoxShadow(color: Colors.white.withValues(alpha: light ? 0.7 : 0.05), blurRadius: 0, offset: const Offset(0, -1)),
          ],
        );
      case 3:
        return ShapeDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [lighten(base, light ? 0.05 : 0.13), darken(base, light ? 0.10 : 0.14)],
          ),
          shape: shapeBorder(size: size, side: hot ? accentA : lighten(edge, 0.12), width: hot ? 2 : 1.2),
          shadows: [
            BoxShadow(color: Colors.black.withValues(alpha: light ? 0.30 : 0.70), blurRadius: 18, offset: const Offset(0, 11)),
            BoxShadow(color: accentA.withValues(alpha: 0.10), blurRadius: 26, offset: const Offset(0, 4)),
            BoxShadow(color: Colors.white.withValues(alpha: light ? 0.8 : 0.08), blurRadius: 0, offset: const Offset(-1, -1)),
          ],
        );
      default:
        return ShapeDecoration(color: base, shape: shapeBorder(size: size, side: edge, width: hot ? 1.5 : 1));
    }
  }
}

/// The page background chosen in Appearance, drawn behind every page.
class ThemeBackground extends StatelessWidget {
  const ThemeBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final t = ThemeSettings.instance;
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: BackgroundPainter(t.background, t.depth, t.bg, t.accentA, t.accentB),
      ),
    );
  }
}

class BackgroundPainter extends CustomPainter {
  BackgroundPainter(this.style, this.depth, this.bg, this.a, this.b);
  final int style, depth;
  final Color bg, a, b;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.drawRect(r, Paint()..color = bg);
    final k = 0.6 + depth * 0.25; // depth makes every effect stronger
    switch (style) {
      case 1:
        canvas.drawRect(
          r,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [ThemeSettings.lighten(bg, 0.07 * k), bg, ThemeSettings.darken(bg, 0.05 * k)],
            ).createShader(r),
        );
      case 2:
        void glow(Offset c, double rad, Color col) {
          canvas.drawRect(
            r,
            Paint()..shader = RadialGradient(colors: [col.withValues(alpha: 0.30 * k), col.withValues(alpha: 0)]).createShader(Rect.fromCircle(center: c, radius: rad)),
          );
        }
        glow(Offset(size.width * 0.1, size.height * 0.05), size.width * 1.0, a);
        glow(Offset(size.width * 0.95, size.height * 0.95), size.width * 1.1, b);
      case 3:
        // A floor of lines running away to a horizon: depth you can see.
        final hy = size.height * 0.52;
        canvas.drawRect(
          r,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [ThemeSettings.darken(bg, 0.03), bg],
              stops: const [0, 0.55],
            ).createShader(r),
        );
        final line = Paint()
          ..color = a.withValues(alpha: 0.16 * k)
          ..strokeWidth = 1;
        for (var i = -12; i <= 12; i++) {
          canvas.drawLine(Offset(size.width / 2, hy), Offset(size.width / 2 + i * size.width * 0.16, size.height), line);
        }
        for (var j = 1; j <= 9; j++) {
          final f = math.pow(j / 9, 2.2).toDouble();
          final y = hy + (size.height - hy) * f;
          canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
        }
        canvas.drawRect(
          Rect.fromLTWH(0, hy - 40, size.width, 80),
          Paint()
            ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [a.withValues(alpha: 0), a.withValues(alpha: 0.12 * k), a.withValues(alpha: 0)])
                .createShader(Rect.fromLTWH(0, hy - 40, size.width, 80)),
        );
      case 4:
        canvas.drawRect(
          r,
          Paint()
            ..shader = RadialGradient(
              center: const Alignment(0, -0.5),
              radius: 1.0,
              colors: [ThemeSettings.lighten(bg, 0.09 * k), bg, ThemeSettings.darken(bg, 0.06 * k)],
              stops: const [0, 0.6, 1],
            ).createShader(r),
        );
      default:
        break;
    }
  }

  @override
  bool shouldRepaint(BackgroundPainter o) => o.style != style || o.depth != depth || o.bg != bg || o.a != a || o.b != b;
}
