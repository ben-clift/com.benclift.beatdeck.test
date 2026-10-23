import 'package:flutter/material.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';
import 'package:sidedeck/theme/theme_settings.dart';
import 'package:sidedeck/ui/home_page.dart';
import 'package:sidedeck/ui/live_trace.dart';
import 'package:sidedeck/ui/splash.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeSettings.instance.load();
  runApp(const SideDeckApp());
}

class SideDeckApp extends StatelessWidget {
  const SideDeckApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeSettings.instance,
      builder: (context, _) => MaterialApp(
        title: 'SideDeck',
        debugShowCheckedModeBanner: false,
        theme: SideDeckTheme.dark(),
        builder: (context, child) => Stack(
          children: [
            const Positioned.fill(child: ThemeBackground()),
            if (child != null) child,
            const LiveTrace(),
          ],
        ),
        home: const SplashGate(child: HomePage()),
      ),
    );
  }
}
