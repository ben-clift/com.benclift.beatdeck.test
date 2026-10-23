import 'package:flutter/material.dart';
import 'package:sidedeck/theme/theme_settings.dart';

/// BeatDeck look. The colours, box shape and depth come from the user's
/// Appearance settings (see [ThemeSettings]); fonts stay fixed.
class SideDeckTheme {
  static ThemeSettings get _t => ThemeSettings.instance;

  static Color get bg => _t.bg;
  static Color get panel => _t.panel;
  static Color get panelAlt => _t.panelAlt;
  static Color get line => _t.line;
  static Color get accentA => _t.accentA;
  static Color get accentB => _t.accentB;
  static Color get accentC => const Color(0xFF8FA8E8);
  static Color get accentD => const Color(0xFFE07A8C);
  static Color get text => _t.text;
  static Color get muted => _t.muted;

  /// Page colour: clear when a background picture is chosen, so it shows through.
  static Color get pageBg => _t.background == 0 ? _t.bg : Colors.transparent;

  static const label = 'BarlowCondensed';
  static const mono = 'JetBrainsMono';

  static ThemeData dark() {
    final t = _t;
    final light = t.isLight;
    final shape = t.shapeBorder(size: 46, side: Colors.transparent, width: 0);
    final scheme = (light ? const ColorScheme.light() : const ColorScheme.dark()).copyWith(
      primary: t.accentA,
      onPrimary: t.accentA.computeLuminance() > 0.5 ? const Color(0xFF16100D) : Colors.white,
      secondary: t.accentB,
      onSecondary: t.accentB.computeLuminance() > 0.5 ? const Color(0xFF16130A) : Colors.white,
      surface: t.panel,
      onSurface: t.text,
      surfaceContainerHighest: t.panelAlt,
      outline: t.line,
      error: const Color(0xFFE5483C),
    );
    final base = ThemeData(
      brightness: light ? Brightness.light : Brightness.dark,
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: 'Barlow',
      splashFactory: InkRipple.splashFactory,
    );
    final caps = const TextStyle(fontFamily: label, fontWeight: FontWeight.w700, letterSpacing: 1.1, fontSize: 15);
    final elev = t.depth == 0 ? 0.0 : (t.depth == 1 ? 2.0 : (t.depth == 2 ? 5.0 : 9.0));
    final sideLine = BorderSide(color: t.line);
    return base.copyWith(
      scaffoldBackgroundColor: pageBg,
      canvasColor: t.panel,
      dividerColor: t.line,
      dividerTheme: DividerThemeData(color: t.line, thickness: 1, space: 1),
      textTheme: base.textTheme.apply(bodyColor: t.text, displayColor: t.text).copyWith(
            headlineSmall: const TextStyle(fontFamily: label, fontWeight: FontWeight.w700, fontSize: 28, letterSpacing: .4),
            titleLarge: const TextStyle(fontFamily: label, fontWeight: FontWeight.w700, fontSize: 24, letterSpacing: .6),
            titleMedium: const TextStyle(fontFamily: label, fontWeight: FontWeight.w600, fontSize: 19, letterSpacing: .5),
            labelLarge: caps,
          ),
      appBarTheme: AppBarTheme(
        backgroundColor: t.background == 0 ? t.bg : Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(fontFamily: label, fontWeight: FontWeight.w700, fontSize: 24, letterSpacing: 1.2, color: t.text),
      ),
      cardTheme: CardThemeData(
        color: t.panel,
        elevation: elev,
        shadowColor: Colors.black,
        margin: EdgeInsets.zero,
        shape: t.shapeBorder(size: 200),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: t.panel,
        elevation: elev + 4,
        shape: t.shapeBorder(size: 200),
        titleTextStyle: TextStyle(fontFamily: label, fontWeight: FontWeight.w700, fontSize: 24, letterSpacing: .8, color: t.text),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: t.panel,
        modalBackgroundColor: t.panel,
        elevation: elev + 4,
        shape: t.shape == 3
            ? BeveledRectangleBorder(borderRadius: const BorderRadius.vertical(top: Radius.circular(12)), side: sideLine)
            : RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(t.shape == 0 ? 6 : (t.shape == 1 ? 14 : 28))),
                side: sideLine),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(shape: shape, textStyle: caps, elevation: elev, shadowColor: Colors.black, minimumSize: const Size(64, 46)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(shape: shape, textStyle: caps, elevation: elev, shadowColor: Colors.black, minimumSize: const Size(64, 46)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(shape: shape, textStyle: caps, side: sideLine, minimumSize: const Size(64, 46)),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: shape, textStyle: caps, foregroundColor: t.accentB),
      ),
      chipTheme: ChipThemeData(
        shape: t.shapeBorder(size: 34),
        backgroundColor: Colors.transparent,
        selectedColor: t.accentA.withValues(alpha: .22),
        side: sideLine,
        showCheckmark: false,
        elevation: elev / 2,
        labelStyle: TextStyle(fontFamily: label, fontWeight: FontWeight.w600, fontSize: 15, letterSpacing: .5, color: t.text),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
            shape: shape,
            side: sideLine,
            textStyle: const TextStyle(fontFamily: label, fontWeight: FontWeight.w600, fontSize: 15, letterSpacing: .5),
            selectedBackgroundColor: t.accentA.withValues(alpha: .22),
            selectedForegroundColor: t.text),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: t.panelAlt,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(t.shape == 0 ? 4 : 12), borderSide: sideLine),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(t.shape == 0 ? 4 : 12), borderSide: sideLine),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(t.shape == 0 ? 4 : 12), borderSide: BorderSide(color: t.accentA)),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 3,
        activeTrackColor: t.accentA,
        inactiveTrackColor: t.line,
        thumbColor: t.accentB,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7, elevation: t.depth == 0 ? 0 : 4),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? t.accentB : t.muted),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? t.accentA : t.line),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: t.accentA, linearTrackColor: t.line),
      listTileTheme: ListTileThemeData(iconColor: t.muted, textColor: t.text),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: t.panelAlt,
        contentTextStyle: TextStyle(fontFamily: 'Barlow', color: t.text, fontSize: 15),
        behavior: SnackBarBehavior.floating,
        shape: t.shapeBorder(size: 48),
      ),
    );
  }
}
