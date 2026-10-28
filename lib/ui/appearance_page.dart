import 'package:flutter/material.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';
import 'package:sidedeck/theme/theme_settings.dart';

/// Colours, box shape, 3D depth and background for every page. Changes show
/// straight away and are saved on the phone.
class AppearancePage extends StatelessWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = ThemeSettings.instance;
    return ListenableBuilder(
      listenable: t,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('Appearance'),
          actions: [TextButton(onPressed: t.reset, child: const Text('Reset'))],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            _preview(t),
            const SizedBox(height: 18),
            _head('Colour sets'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final p in ThemeSettings.presets)
                ChoiceChip(
                  avatar: CircleAvatar(backgroundColor: p.accentA, radius: 8),
                  label: Text(p.name),
                  selected: t.preset == p.name,
                  onSelected: (_) => t.applyPreset(p),
                ),
              if (t.preset == 'Custom') const ChoiceChip(label: Text('Custom'), selected: true, onSelected: null),
            ]),
            const SizedBox(height: 18),
            _head('Your colours'),
            _swatch(context, 'Main colour (buttons, highlights)', 'a', t.accentA),
            _swatch(context, 'Second colour (sliders, links)', 'b', t.accentB),
            _swatch(context, 'Background', 'bg', t.bg),
            _swatch(context, 'Boxes and panels', 'panel', t.panel),
            _swatch(context, 'Text', 'text', t.text),
            _swatch(context, 'Quiet text', 'muted', t.muted),
            const SizedBox(height: 18),
            _head('Box shape'),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (var i = 0; i < ThemeSettings.shapeNames.length; i++)
                _tile(
                  selected: t.shape == i,
                  label: ThemeSettings.shapeNames[i],
                  onTap: () => t.setStyle(shapeV: i),
                  child: Container(
                    width: 64,
                    height: 40,
                    decoration: _shapePreview(t, i),
                  ),
                ),
            ]),
            const SizedBox(height: 18),
            _head('3D depth'),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (var i = 0; i < ThemeSettings.depthNames.length; i++)
                _tile(
                  selected: t.depth == i,
                  label: ThemeSettings.depthNames[i],
                  onTap: () => t.setStyle(depthV: i),
                  child: Container(width: 64, height: 40, decoration: _depthPreview(t, i)),
                ),
            ]),
            const SizedBox(height: 18),
            _head('Background'),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (var i = 0; i < ThemeSettings.backgroundNames.length; i++)
                _tile(
                  selected: t.background == i,
                  label: ThemeSettings.backgroundNames[i],
                  onTap: () => t.setStyle(bgV: i),
                  child: SizedBox(
                    width: 64,
                    height: 40,
                    child: ClipRect(
                      child: CustomPaint(painter: BackgroundPainter(i, t.depth, t.bg, t.accentA, t.accentB)),
                    ),
                  ),
                ),
            ]),
            const SizedBox(height: 8),
            Text('Depth also makes the background effects stronger.', style: TextStyle(color: t.muted, fontSize: 13)),
          ],
        ),
      ),
    );
  }

  Widget _head(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(s.toUpperCase(),
            style: TextStyle(fontFamily: SideDeckTheme.label, fontWeight: FontWeight.w700, fontSize: 16, letterSpacing: 1.4, color: SideDeckTheme.accentB)),
      );

  Decoration _shapePreview(ThemeSettings t, int i) {
    final keep = t.shape;
    t.shape = i;
    final d = ShapeDecoration(color: t.accentA.withValues(alpha: .25), shape: t.shapeBorder(size: 40, side: t.accentA, width: 1.5));
    t.shape = keep;
    return d;
  }

  Decoration _depthPreview(ThemeSettings t, int i) {
    final keep = t.depth;
    t.depth = i;
    final d = t.box(size: 40);
    t.depth = keep;
    return d;
  }

  Widget _tile({required bool selected, required String label, required VoidCallback onTap, required Widget child}) {
    final t = ThemeSettings.instance;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          border: Border.all(color: selected ? t.accentA : t.line, width: selected ? 2 : 1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          child,
          const SizedBox(height: 6),
          Text(label, style: TextStyle(fontFamily: SideDeckTheme.label, fontWeight: FontWeight.w600, color: selected ? t.accentA : t.text)),
        ]),
      ),
    );
  }

  Widget _swatch(BuildContext context, String name, String key, Color c) => ListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(name),
        trailing: Container(
          width: 44,
          height: 28,
          decoration: BoxDecoration(color: c, border: Border.all(color: SideDeckTheme.line), borderRadius: BorderRadius.circular(5)),
        ),
        onTap: () => _pick(context, name, key, c),
      );

  Future<void> _pick(BuildContext context, String name, String key, Color start) async {
    var hsv = HSVColor.fromColor(start);
    await showDialog<void>(
      context: context,
      builder: (dc) => StatefulBuilder(
        builder: (dc, setD) {
          final c = hsv.toColor();
          final limited = key == 'bg' || key == 'panel';
          void set(HSVColor v) {
            // Backgrounds and boxes cannot go very light: the text would vanish.
            final col = limited ? ThemeSettings.limitLight(v.toColor()) : v.toColor();
            setD(() => hsv = limited ? HSVColor.fromColor(col) : v);
            ThemeSettings.instance.setColor(key, col);
          }
          return AlertDialog(
            title: Text(name),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(height: 40, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(6), border: Border.all(color: SideDeckTheme.line))),
                const SizedBox(height: 8),
                const Text('Colour'),
                Slider(value: hsv.hue, min: 0, max: 360, onChanged: (v) => set(hsv.withHue(v))),
                const Text('Strength'),
                Slider(value: hsv.saturation, min: 0, max: 1, onChanged: (v) => set(hsv.withSaturation(v))),
                const Text('Brightness'),
                Slider(value: hsv.value, min: 0, max: 1, onChanged: (v) => set(hsv.withValue(v))),
                if (limited)
                  const Text('Very light colours are not allowed here, so the text stays easy to read.',
                      style: TextStyle(fontSize: 12, color: Color(0xFF8A857C))),
                const SizedBox(height: 6),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final sw in const [
                    Color(0xFFFF5A2B), Color(0xFFFFB02B), Color(0xFFFFE14A), Color(0xFF45D483), Color(0xFF2DB6FF),
                    Color(0xFF6B7BFF), Color(0xFFB36BFF), Color(0xFFFF5FA8), Color(0xFFFFFFFF), Color(0xFF8A8A8A),
                    Color(0xFF222226), Color(0xFF0D0D0F),
                  ])
                    InkWell(
                      onTap: () => set(HSVColor.fromColor(sw)),
                      child: Container(width: 30, height: 30, decoration: BoxDecoration(color: sw, border: Border.all(color: SideDeckTheme.line), borderRadius: BorderRadius.circular(5))),
                    ),
                ]),
              ]),
            ),
            actions: [FilledButton(onPressed: () => Navigator.pop(dc), child: const Text('Done'))],
          );
        },
      ),
    );
  }

  Widget _preview(ThemeSettings t) => Container(
        padding: const EdgeInsets.all(14),
        decoration: t.box(size: 200),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Preview', style: TextStyle(fontFamily: SideDeckTheme.label, fontSize: 22, fontWeight: FontWeight.w700, color: t.text)),
          const SizedBox(height: 4),
          Text('Boxes, buttons and sliders use your choices.', style: TextStyle(color: t.muted)),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: Container(
                height: 44,
                alignment: Alignment.center,
                decoration: t.box(color: t.accentA, size: 44),
                child: Text('BUTTON', style: TextStyle(fontFamily: SideDeckTheme.label, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: t.accentA.computeLuminance() > 0.5 ? Colors.black : Colors.white)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Container(
                height: 44,
                alignment: Alignment.center,
                decoration: t.box(color: t.panelAlt, size: 44, hot: true),
                child: Text('SELECTED', style: TextStyle(fontFamily: SideDeckTheme.label, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: t.accentA)),
              ),
            ),
          ]),
        ]),
      );
}
