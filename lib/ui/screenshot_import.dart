import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

/// Reads the song names off screenshots of a playlist (on the phone, no
/// internet needed) and lets the user check them before importing.
class ScreenshotImport {
  static final _noise = RegExp(
    r'^(\d{1,2}:\d{2}(:\d{2})?|\d+%?|e|shuffle|play|download(ed)?|playlist|liked songs|songs?|add|search|home|library|your library|create|premium|explore|followers?|likes?|share|more|tracks?|repost(s)?|comments?|plays?|made for you|recommended|following|follow|sort|filter|now playing|spotify|soundcloud|next up|queue|everything|public|private|by .*|\d+ (songs?|tracks?|likes?|plays?|min|hr).*|.*\d+ (songs?|tracks?)$|.*[0-9]{1,2}:[0-9]{2}$)$',
    caseSensitive: false,
  );

  /// Pick screenshots and return the text lines found, in reading order.
  static Future<List<String>> pickAndRead() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.image, allowMultiple: true);
    if (res == null) return [];
    final rec = TextRecognizer(script: TextRecognitionScript.latin);
    final out = <String>[];
    try {
      for (final f in res.files) {
        final path = f.path;
        if (path == null) continue;
        final text = await rec.processImage(InputImage.fromFilePath(path));
        for (final b in text.blocks) {
          for (final l in b.lines) {
            final t = l.text.trim();
            if (t.length < 2 || _noise.hasMatch(t)) continue;
            out.add(t);
          }
        }
      }
    } finally {
      await rec.close();
    }
    return out;
  }

  /// 0 = "Title then artist" lines, 1 = "Artist then title", 2 = "Artist - Title".
  static int guessLayout(List<String> lines) {
    if (lines.isEmpty) return 0;
    final dashed = lines.where((l) => RegExp(r'\s[-–—]\s').hasMatch(l)).length;
    return dashed * 2 >= lines.length ? 2 : 0;
  }

  static String toText(List<String> lines, int layout) {
    if (layout == 2) return lines.join('\n');
    final out = <String>[];
    for (var i = 0; i + 1 < lines.length; i += 2) {
      final a = layout == 0 ? lines[i + 1] : lines[i];
      final t = layout == 0 ? lines[i] : lines[i + 1];
      out.add('$a - $t');
    }
    return out.join('\n');
  }

  /// Shows what was read; returns the checked "Artist - Title" text, or null.
  static Future<String?> review(BuildContext context, List<String> lines) {
    var layout = guessLayout(lines);
    final c = TextEditingController(text: toText(lines, layout));
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: SideDeckTheme.panel,
          title: const Text('Is this right?'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('One song per line, Artist - Title. Fix anything that looks wrong.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF8A857C))),
              const SizedBox(height: 8),
              SegmentedButton<int>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 0, label: Text('Title, artist', style: TextStyle(fontSize: 11))),
                  ButtonSegment(value: 1, label: Text('Artist, title', style: TextStyle(fontSize: 11))),
                  ButtonSegment(value: 2, label: Text('A - T', style: TextStyle(fontSize: 11))),
                ],
                selected: {layout},
                onSelectionChanged: (v) => setS(() {
                  layout = v.first;
                  c.text = toText(lines, layout);
                }),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: TextField(
                  controller: c,
                  maxLines: null,
                  minLines: 8,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Import')),
          ],
        ),
      ),
    );
  }
}
