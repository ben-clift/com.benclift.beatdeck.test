import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every part of BeatDeck that is also built as an app of its own must stay
/// usable without the other parts. This reads the imports, so a stray
/// "import soulseek" in the finder fails the build straight away.
Set<String> _closure(List<String> entries) {
  final seen = <String>{};
  final todo = [...entries];
  final re = RegExp(r"^(?:import|export)\s+'package:sidedeck/([^']+)'", multiLine: true);
  while (todo.isNotEmpty) {
    final f = todo.removeLast();
    if (!seen.add(f)) continue;
    final file = File(f);
    if (!file.existsSync()) fail('$f is imported but missing');
    for (final m in re.allMatches(file.readAsStringSync())) {
      todo.add('lib/${m.group(1)}');
    }
  }
  return seen;
}

void main() {
  test('the finder app does not depend on the engine, decks or Soulseek', () {
    final used = _closure(['lib/apps/finder_main.dart']);
    const banned = [
      'lib/engine/',
      'lib/soulseek/',
      'lib/state/',
      'lib/mac/',
      'lib/subsonic/',
      'lib/automix/set_flow.dart',
      'lib/automix/transition_style.dart',
      'lib/ui/home_page.dart',
      'lib/ui/soulseek_page.dart',
      'lib/ui/finder_host_library.dart',
      'lib/suggest/taste_library.dart',
      'lib/suggest/auto_fetch.dart',
    ];
    final bad = [
      for (final f in used)
        for (final b in banned)
          if (f.startsWith(b)) f,
    ];
    expect(bad, isEmpty, reason: 'The finder app must not import: $bad');
    expect(used, contains('lib/ui/explore_page.dart'));
  });
}
