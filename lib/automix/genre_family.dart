/// Groups genre names (from file tags or Deezer) into families so that
/// "Deep House", "Tech House" and "Disco" count as similar, while "Drum &
/// Bass" does not mix into them.
const _families = <String, List<String>>{
  'house': ['house', 'disco', 'garage', 'balearic', 'afro', 'soulful', 'funk', 'amapiano'],
  'techno': ['techno', 'minimal', 'acid', 'industrial', 'schranz', 'tech'],
  'trance': ['trance', 'progressive', 'psy', 'goa'],
  'breaks': ['breaks', 'breakbeat', 'breakcore', 'electro', 'big beat', 'bigbeat', 'trip hop', 'miami bass', 'broken beat', 'bass', 'dubstep', 'grime', 'uk funky'],
  'dnb': ['drum', 'dnb', 'd&b', 'jungle', 'liquid', 'neurofunk', 'hardcore'],
  'dub': ['dub', 'reggae', 'dancehall', 'roots', 'ska', 'rocksteady', 'lovers rock', 'rockers', 'two tone', 'ragga', 'steppers'],
  'ambient': ['ambient', 'downtempo', 'chill', 'electronica', 'idm', 'glitch', 'clicks and cuts', 'new age', 'trip'],
  'hiphop': ['hip', 'rap', 'trap', 'r&b', 'rnb', 'soul'],
  'pop': ['pop', 'singer'],
};

/// Families that sit next to each other and mix well.
const _near = <String, Set<String>>{
  'house': {'techno', 'breaks'},
  'techno': {'house', 'trance', 'breaks'},
  'trance': {'techno'},
  'breaks': {'house', 'techno', 'dnb'},
  'dnb': {'breaks'},
  'dub': {'ambient'},
  'ambient': {'dub'},
  'hiphop': {'breaks'},
  'pop': {'bands'},
  'bands': {'pop'},
};

final _bandWords = RegExp(
    r'\b(rock|indie|punk|metal|goth|gothic|grunge|emo|screamo|shoegaze|britpop|madchester|alternative|folk|blues|country|americana|ska punk|ska-punk|dark ?wave|cold ?wave|new wave|dream pop|acoustic|singer.?songwriter|post-?rock|post-?punk|jangle pop|power pop|glam)\b');

/// The family of [genre], or null when unknown or empty.
String? genreFamily(String genre) {
  final g = genre.toLowerCase();
  if (g.trim().isEmpty) return null;
  // "tech house" is house-family first, "dub techno" is techno-family first,
  // so test the most specific wording before the single words.
  if (g.contains('dub techno')) return 'techno';
  for (final k in const ['techstep', 'darkstep', 'hardstep', 'jazzstep', 'sambass', 'liquid funk', 'funkstep', 'tech funk', 'drumfunk', 'crossbreed', 'neurofunk', 'jump up', 'drill and bass']) {
    if (g.contains(k)) return 'dnb';
  }
  // Band music. Whole words only, so "emo" is not found inside another word.
  if (_bandWords.hasMatch(g) &&
      !g.contains('indie dance') &&
      !g.contains('indie electronic') &&
      !g.contains('nu disco')) {
    return 'bands';
  }
  if (g.contains('bassline')) return 'house';
  if (g.contains('bigbeat') || g.contains('big beat') || g.contains('breakbeat hardcore')) return 'breaks';
  if (g.contains('break') && !g.contains('garage') && !g.contains('drum')) return 'breaks';
  if (g.contains('tech house') || g.contains('deep house')) return 'house';
  if (g.contains('drum') && g.contains('bass')) return 'dnb';
  for (final e in _families.entries) {
    for (final k in e.value) {
      if (g.contains(k)) return e.key;
    }
  }
  return null;
}

/// True when two genres are the same family or neighbours. Unknown genres
/// count as a match (the tempo decides).
bool genresSimilar(String a, String b) {
  final fa = genreFamily(a);
  final fb = genreFamily(b);
  if (fa == null || fb == null) return true;
  return fa == fb || (_near[fa]?.contains(fb) ?? false);
}


final _vocalWords = RegExp(r'\b(feat|ft|featuring|vocal|vocals|vox|acapella|a cappella|sung|singer)\b', caseSensitive: false);
final _instWords = RegExp(r'\b(instrumental|inst|karaoke|dub mix|beats?)\b', caseSensitive: false);

/// True when [name] (artist and title, or a file name) clashes with the
/// vocal choice: 1 = wants vocals, 2 = wants instrumentals, 0 = either.
bool vocalClash(String name, int mode) {
  if (mode == 2) return _vocalWords.hasMatch(name);
  if (mode == 1) return _instWords.hasMatch(name);
  return false;
}
