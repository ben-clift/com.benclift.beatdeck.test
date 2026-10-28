import 'package:flutter/material.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/suggest/taste.dart';
import 'package:sidedeck/suggest/taste_library.dart';
import 'package:sidedeck/ui/finder_host.dart';
import 'package:sidedeck/ui/soulseek_page.dart';

/// The finder as the full app runs it: Soulseek search opens in the app and
/// your playlists count as your taste. Only the full app imports this file.
FinderHost fullAppFinderHost(LibraryController lib) {
  Taste.libraryReader = TasteLibrary.reader(lib);
  return FinderHost(
    searchSoulseek: (context, query) => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => SoulseekPage(library: lib, initialQuery: query)),
    ),
  );
}
