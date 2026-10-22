import 'package:flutter/material.dart';

/// BeatDeck look: dark hardware-style panels, hairline borders, square
/// corners, condensed caps for labels and a single signal-orange accent.
class SideDeckTheme {
  static const bg = Color(0xFF0D0D0F);
  static const panel = Color(0xFF17171A);
  static const panelAlt = Color(0xFF222226);
  static const line = Color(0xFF2E2E33);
  static const accentA = Color(0xFFFF5A2B); // signal orange
  static const accentB = Color(0xFFE9DCB5); // tape cream
  static const accentC = Color(0xFF8FA8E8);
  static const accentD = Color(0xFFE07A8C);
  static const text = Color(0xFFEDEBE6);
  static const muted = Color(0xFF8C8A85);

  static const label = 'BarlowCondensed';
  static const mono = 'JetBrainsMono';

  static ThemeData dark() {
    const shape = RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4)));
    final scheme = const ColorScheme.dark(
      primary: accentA,
      onPrimary: Color(0xFF16100D),
      secondary: accentB,
      onSecondary: Color(0xFF16130A),
      surface: panel,
      onSurface: text,
      surfaceContainerHighest: panelAlt,
      outline: line,
      error: Color(0xFFE5483C),
    );
    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: 'Barlow',
      splashFactory: InkRipple.splashFactory,
    );
    final caps = const TextStyle(
        fontFamily: label, fontWeight: FontWeight.w700, letterSpacing: 1.1, fontSize: 15);
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      canvasColor: panel,
      dividerColor: line,
      dividerTheme: const DividerThemeData(color: line, thickness: 1, space: 1),
      textTheme: base.textTheme.apply(bodyColor: text, displayColor: text).copyWith(
            headlineSmall: const TextStyle(fontFamily: label, fontWeight: FontWeight.w700, fontSize: 28, letterSpacing: .4),
            titleLarge: const TextStyle(fontFamily: label, fontWeight: FontWeight.w700, fontSize: 24, letterSpacing: .6),
            titleMedium: const TextStyle(fontFamily: label, fontWeight: FontWeight.w600, fontSize: 19, letterSpacing: .5),
            labelLarge: caps,
          ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
            fontFamily: label, fontWeight: FontWeight.w700, fontSize: 24, letterSpacing: 1.2, color: text),
      ),
      cardTheme: CardThemeData(
        color: panel,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4), side: const BorderSide(color: line)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: panel,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4), side: const BorderSide(color: line)),
        titleTextStyle: const TextStyle(
            fontFamily: label, fontWeight: FontWeight.w700, fontSize: 24, letterSpacing: .8, color: text),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: panel,
        modalBackgroundColor: panel,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
            side: BorderSide(color: line)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
            shape: shape, textStyle: caps, minimumSize: const Size(64, 46)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
            shape: shape, textStyle: caps, elevation: 0, minimumSize: const Size(64, 46)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
            shape: shape, textStyle: caps, side: const BorderSide(color: line), minimumSize: const Size(64, 46)),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: shape, textStyle: caps, foregroundColor: accentB),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(3), side: const BorderSide(color: line)),
        backgroundColor: Colors.transparent,
        selectedColor: accentA.withOpacity(.22),
        side: const BorderSide(color: line),
        showCheckmark: false,
        labelStyle: const TextStyle(fontFamily: label, fontWeight: FontWeight.w600, fontSize: 15, letterSpacing: .5, color: text),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
            shape: shape,
            side: const BorderSide(color: line),
            textStyle: const TextStyle(fontFamily: label, fontWeight: FontWeight.w600, fontSize: 15, letterSpacing: .5),
            selectedBackgroundColor: accentA.withOpacity(.22),
            selectedForegroundColor: text),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: panelAlt,
        border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(4)), borderSide: BorderSide(color: line)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(4)), borderSide: BorderSide(color: line)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(4)), borderSide: BorderSide(color: accentA)),
      ),
      sliderTheme: const SliderThemeData(
        trackHeight: 3,
        activeTrackColor: accentA,
        inactiveTrackColor: line,
        thumbColor: accentB,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7, elevation: 0),
        overlayShape: RoundSliderOverlayShape(overlayRadius: 16),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accentB : muted),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accentA : line),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: accentA, linearTrackColor: line),
      listTileTheme: const ListTileThemeData(iconColor: muted, textColor: text),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: panelAlt,
        contentTextStyle: TextStyle(fontFamily: 'Barlow', color: text, fontSize: 15),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(3))),
      ),
    );
  }
}
