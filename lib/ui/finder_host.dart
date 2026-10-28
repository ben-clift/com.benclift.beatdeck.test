import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// What the music finder needs from whatever app it sits in. The standalone
/// finder uses the plain version (no Soulseek, so the search text is copied).
/// The full app passes one that opens its Soulseek search.
class FinderHost {
  const FinderHost({this.searchSoulseek});

  /// Opens a Soulseek search for the text. Null when the app has no Soulseek.
  final void Function(BuildContext context, String query)? searchSoulseek;

  bool get hasSoulseek => searchSoulseek != null;

  /// Soulseek search where there is one, otherwise the text is copied so it
  /// can be pasted into any Soulseek app.
  Future<void> soulseek(BuildContext context, String query) async {
    final open = searchSoulseek;
    if (open != null) {
      open(context, query);
      return;
    }
    await Clipboard.setData(ClipboardData(text: query));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Copied "$query". Paste it into your Soulseek app.')),
      );
    }
  }
}
