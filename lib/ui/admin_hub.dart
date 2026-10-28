import 'package:flutter/material.dart';
import 'package:sidedeck/state/app_mode.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/ui/explore_page.dart';
import 'package:sidedeck/ui/finder_host_library.dart';
import 'package:sidedeck/ui/free_music_page.dart';
import 'package:sidedeck/ui/my_tracks_page.dart';
import 'package:sidedeck/ui/soulseek_page.dart';
import 'package:sidedeck/ui/suggest_page.dart';
import 'package:sidedeck/ui/wishlist_page.dart';

/// Admin only: one button for each part of BeatDeck, so each can be opened and
/// tried on its own. Opens the part inside this app.
class AdminHubPage extends StatelessWidget {
  const AdminHubPage({super.key, required this.dj, required this.library});

  final DjController dj;
  final LibraryController library;

  void _push(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  Widget _tile(BuildContext context, IconData icon, String title, String sub, VoidCallback onTap) {
    return Card(
      child: ListTile(
        leading: Icon(icon, size: 30),
        title: Text(title),
        subtitle: Text(sub),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final host = fullAppFinderHost(library);
    return Scaffold(
      appBar: AppBar(title: const Text('BeatDeck parts')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _tile(context, Icons.explore_outlined, 'Finder: Explore',
              'Artists, labels and genres, with listen and buy links', () => _push(context, ExplorePage(host: host))),
          _tile(context, Icons.photo_library_outlined, 'Finder: Screenshots and my tracks',
              'Add screenshots of your tracks, then find related music', () => _push(context, MyTracksPage(host: host))),
          _tile(context, Icons.favorite_border, 'Finder: Wish list', 'Songs to look for later',
              () => _push(context, WishListPage(library: library))),
          _tile(context, Icons.travel_explore, 'Soulseek', 'Search and download',
              () => _push(context, SoulseekPage(library: library))),
          _tile(context, Icons.cloud_download_outlined, 'Free music', 'Jamendo and Internet Archive',
              () => _push(context, FreeMusicPage(library: library))),
          _tile(context, Icons.insights, 'Suggest', 'What mixes with the playing track',
              () => _push(context, SuggestPage(dj: dj, library: library))),
          _tile(context, Icons.album_outlined, 'Decks and mixer (Pro mode)', 'The two decks, mixer and effects', () {
            AppMode.set(false);
            Navigator.of(context).pop();
          }),
          _tile(context, Icons.auto_awesome, 'Auto DJ (Simple mode, the Booth)', 'Picks and mixes by itself', () {
            AppMode.set(true);
            Navigator.of(context).pop();
          }),
        ],
      ),
    );
  }
}
