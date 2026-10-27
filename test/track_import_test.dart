import 'package:flutter_test/flutter_test.dart';
import 'package:sidedeck/suggest/track_import.dart';

void main() {
  group('TrackNameParser', () {
    test('plain Artist - Title', () {
      final t = TrackNameParser.parse('Ashee - Poison.mp3')!;
      expect(t.artist, 'Ashee');
      expect(t.title, 'Poison');
      expect(t.mix, '');
    });

    test('scene name with underscores and no spaces', () {
      final t = TrackNameParser.parse('04-christian_nielsen-liberate_(original_mix).flac')!;
      expect(t.artist, 'Christian Nielsen');
      expect(t.title, 'Liberate');
      expect(t.isOriginal, isTrue);
    });

    test('scene name with a remix and a group suffix', () {
      final t = TrackNameParser.parse('03-sababa_5_and_yurika_-_nasnusa_(kino_todo_and_danelz_remix)-tr.mp3')!;
      expect(t.artist, 'Sababa 5 And Yurika');
      expect(t.title, 'Nasnusa');
      expect(t.mix, 'Kino Todo And Danelz Remix');
      expect(t.isOriginal, isFalse);
    });

    test('compilation prefix', () {
      final t = TrackNameParser.parse('VA (Dots & Pearls 8)-[06]-Redshape - Ghost Story.flac')!;
      expect(t.artist, 'Redshape');
      expect(t.title, 'Ghost Story');
      expect(t.release, 'Dots & Pearls 8');
    });

    test('album and track number in the middle', () {
      final t = TrackNameParser.parse('Whitesquare - The Brooklyn Ban Pt.2 - 01 Ephemeral Eyes.aiff')!;
      expect(t.artist, 'Whitesquare');
      expect(t.release, 'The Brooklyn Ban Pt.2');
      expect(t.title, 'Ephemeral Eyes');
    });

    test('key and bpm ending', () {
      final t = TrackNameParser.parse('Satoshi Tomiie - Bassline (Dana Ruh Remix) - 8A - 127.0.mp3')!;
      expect(t.artist, 'Satoshi Tomiie');
      expect(t.title, 'Bassline');
      expect(t.mix, 'Dana Ruh Remix');
      expect(t.key, '8A');
      expect(t.bpm, 127.0);
    });

    test('lost apostrophe', () {
      final t = TrackNameParser.parse('M.A.N.D.Y. - No Stoppin_ (Original Mix).aiff')!;
      expect(t.artist, 'M.A.N.D.Y.');
      expect(t.title, "No Stoppin'");
    });

    test('label in square brackets', () {
      final t = TrackNameParser.parse("Osner - It's Good [Big Love Music].mp3")!;
      expect(t.title, "It's Good");
      expect(t.label, 'Big Love Music');
    });

    test('title first, artist after', () {
      final t = TrackNameParser.parse('Cadenza (Edit) - Yuksek, Polo & Pan.mp3')!;
      expect(t.title, 'Cadenza');
      expect(t.mix, 'Edit');
      expect(t.artist, 'Yuksek, Polo & Pan');
    });

    test('leading track numbers go', () {
      expect(TrackNameParser.parse('1-02 Some Artist - Some Song.mp3')!.artist, 'Some Artist');
      expect(TrackNameParser.parse('05. Some Artist - Some Song.mp3')!.title, 'Some Song');
    });

    test('folders and junk are skipped when an extension is required', () {
      expect(TrackNameParser.parse('_130'), isNull);
      expect(TrackNameParser.parse('selected'), isNull);
      expect(TrackNameParser.parse('Folder - Name'), isNull);
      expect(TrackNameParser.parse('Folder - Name', requireExt: false), isNotNull);
    });

    test('repeats are dropped', () {
      final list = TrackNameParser.parseAll(['A - B.mp3', 'A - B.flac', 'C - D.mp3']);
      expect(list.length, 2);
    });

    test('display reads back to the same track', () {
      final t = TrackNameParser.parse('Blaze - Lovelee Dae (Seth Troxler Extended Remix) [Some Label].mp3')!;
      final back = TrackNameParser.parse(t.display, requireExt: false, stripNumbers: false)!;
      expect(back.id, t.id);
      expect(back.label, 'Some Label');
    });

    test('link query keeps remixes only', () {
      expect(TrackNameParser.parse('A - B (Original Mix).mp3')!.linkQuery, 'A B');
      expect(TrackNameParser.parse('A - B (C Remix).mp3')!.linkQuery, 'A B C Remix');
    });

    test('json round trip', () {
      final t = TrackNameParser.parse('A - B (C Remix) [L].mp3')!..deezer = 'https://x';
      final back = ImportedTrack.fromJson(t.toJson())!;
      expect(back.display, t.display);
      expect(back.deezer, 'https://x');
    });
  });

  group('DirectLinks.matches', () {
    final t = ImportedTrack(artist: 'Osner', title: "It's Good");
    test('accepts the same track', () {
      expect(DirectLinks.matches(t, 'Osner', "It's Good (Original Mix)"), isTrue);
    });
    test('rejects another artist', () {
      expect(DirectLinks.matches(t, 'Somebody Else', "It's Good"), isFalse);
    });
  });
}
