import 'package:flutter_test/flutter_test.dart';
import 'package:sidedeck/engine/link_logic.dart';

void main() {
  group('fitRate', () {
    test('plain match', () => expect(fitRate(128, 125), closeTo(1.024, 1e-9)));
    test('double time when too slow', () => expect(fitRate(170, 85), closeTo(2.0, 1e-9)));
    test('half time when too fast', () => expect(fitRate(300, 140), closeTo(300 / 2 / 140, 1e-9)));
    test('no fit', () => expect(fitRate(300, 60), isNull));
    test('bad input', () {
      expect(fitRate(0, 120), isNull);
      expect(fitRate(120, 0), isNull);
    });
  });

  group('decideLink', () {
    LinkDecision d({
      required double link,
      required double deck,
      double lastLink = 0,
      double lastDeck = 0,
      int peers = 1,
    }) =>
        decideLink(linkBpm: link, deckBpm: deck, lastLink: lastLink, lastDeck: lastDeck, peers: peers);

    test('no deck means nothing happens', () {
      expect(d(link: 120, deck: 0).action, LinkAction.none);
    });
    test('switching on with peers adopts the session tempo', () {
      final r = d(link: 126, deck: 120);
      expect(r.action, LinkAction.applyToDeck);
      expect(r.bpm, 126);
    });
    test('switching on alone publishes the deck tempo', () {
      final r = d(link: 120, deck: 128, peers: 0);
      expect(r.action, LinkAction.publish);
      expect(r.bpm, 128);
    });
    test('already matching does nothing', () {
      expect(d(link: 124, deck: 124.02).action, LinkAction.none);
    });
    test('session change moves the deck', () {
      final r = d(link: 130, deck: 124, lastLink: 124, lastDeck: 124);
      expect(r.action, LinkAction.applyToDeck);
      expect(r.bpm, 130);
    });
    test('deck change moves the session', () {
      final r = d(link: 124, deck: 126, lastLink: 124, lastDeck: 124);
      expect(r.action, LinkAction.publish);
      expect(r.bpm, 126);
    });
    test('both changed: Link wins', () {
      final r = d(link: 132, deck: 126, lastLink: 124, lastDeck: 124);
      expect(r.action, LinkAction.applyToDeck);
      expect(r.bpm, 132);
    });
    test('settled after following does not echo back', () {
      final r = d(link: 130, deck: 130, lastLink: 130, lastDeck: 130);
      expect(r.action, LinkAction.none);
    });
  });
}
