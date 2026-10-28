import 'package:flutter/material.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';
import 'package:sidedeck/theme/theme_settings.dart';
import 'package:sidedeck/ui/my_tracks_page.dart';

/// BeatDeck Finder: the music finder as an app of its own. It opens on the
/// screenshots page (add screenshots of your tracks, then find related
/// music), with Explore, the wish list and listen/buy links one tap away. It has no
/// audio engine and no Soulseek; the "Soulseek" button copies the search text.
///
/// Build it with:
///   flutter build apk -t lib/apps/finder_main.dart --android-project-arg=appId=com.benclift.beatdeck.finder --android-project-arg=appName="BeatDeck Finder"
///
/// test/part_independence_test.dart keeps this file from depending on the
/// engine, the decks or Soulseek.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeSettings.instance.load();
  runApp(const FinderApp());
}

class FinderApp extends StatelessWidget {
  const FinderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BeatDeck Finder',
      debugShowCheckedModeBanner: false,
      theme: SideDeckTheme.dark(),
      home: const MyTracksPage(),
    );
  }
}
