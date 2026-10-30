/// Pure decisions for Ableton Link tempo sync. No audio, no network, so it can
/// be tested on its own.

enum LinkAction { none, applyToDeck, publish }

class LinkDecision {
  const LinkDecision(this.action, [this.bpm = 0]);
  final LinkAction action;
  final double bpm;
}

/// Finds the rate that makes a track of [trackBpm] play at [targetBpm]. If that
/// is outside the deck's 0.5 to 2.0 range it tries double and half time, as a
/// DJ would. Returns null when no musical fit exists.
double? fitRate(double targetBpm, double trackBpm) {
  if (targetBpm <= 0 || trackBpm <= 0) return null;
  for (final t in [targetBpm, targetBpm * 2, targetBpm / 2]) {
    final r = t / trackBpm;
    if (r >= 0.5 && r <= 2.0) return r;
  }
  return null;
}

/// Decides what to do on one poll.
///
/// [linkBpm]   the Link session tempo now.
/// [deckBpm]   the heard tempo of our master deck now (0 when there is none).
/// [lastLink]  the Link tempo at the previous poll (0 right after switching on).
/// [lastDeck]  the deck tempo at the previous poll (0 when there was none).
/// [peers]     other Link apps in the session.
///
/// Rules: when Link switches on and there are peers, the session tempo wins.
/// After that, whichever side changed since the last poll is followed. If both
/// changed, Link wins, so a deck never fights the session.
LinkDecision decideLink({
  required double linkBpm,
  required double deckBpm,
  required double lastLink,
  required double lastDeck,
  required int peers,
  double epsilon = 0.05,
}) {
  if (linkBpm <= 0 || deckBpm <= 0) return const LinkDecision(LinkAction.none);
  final linkMoved = lastLink > 0 && (linkBpm - lastLink).abs() > epsilon;
  final deckMoved = lastDeck > 0 && (deckBpm - lastDeck).abs() > epsilon;
  final first = lastLink <= 0 || lastDeck <= 0;
  if (first) {
    if (peers > 0 && (linkBpm - deckBpm).abs() > epsilon) {
      return LinkDecision(LinkAction.applyToDeck, linkBpm);
    }
    if (peers == 0 && (linkBpm - deckBpm).abs() > epsilon) {
      return LinkDecision(LinkAction.publish, deckBpm);
    }
    return const LinkDecision(LinkAction.none);
  }
  if (linkMoved && (linkBpm - deckBpm).abs() > epsilon) {
    return LinkDecision(LinkAction.applyToDeck, linkBpm);
  }
  if (deckMoved && (linkBpm - deckBpm).abs() > epsilon) {
    return LinkDecision(LinkAction.publish, deckBpm);
  }
  return const LinkDecision(LinkAction.none);
}
