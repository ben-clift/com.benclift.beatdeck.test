import 'package:flutter_test/flutter_test.dart';
import 'package:sidedeck/suggest/explore.dart';
import 'package:sidedeck/suggest/track_import.dart';

// Shapes follow MusicBrainz's documented JSON for search and release browse.
const _artistSearch = '''
{"artists":[
  {"id":"a-1","name":"Guti (Argentina)","score":80},
  {"id":"a-2","name":"Guti","score":100,"tags":[{"name":"house","count":3}]}
]}''';

const _releasesWithLabels = '''
{"release-count":3,"releases":[
  {"id":"r1","title":"One","label-info":[{"catalog-number":"CRM1","label":{"id":"l-1","name":"Crosstown Rebels"}}]},
  {"id":"r2","title":"Two","label-info":[{"label":{"id":"l-1","name":"Crosstown Rebels"}},{"label":{"id":"l-2","name":"Opulence"}}]},
  {"id":"r3","title":"Three","label-info":[{"label":{"id":"157afde4-4bf5-4039-8ad2-5a15acc85176","name":"[no label]"}}]},
  {"id":"r4","title":"Four","label-info":[{"catalog-number":"x"}]}
]}''';

const _releasesWithArtists = '''
{"releases":[
  {"id":"r1","artist-credit":[{"name":"Guti","joinphrase":" & ","artist":{"id":"a-2","name":"Guti"}},
                              {"name":"Cali","joinphrase":"","artist":{"id":"a-3","name":"Cali Lanauze"}}]},
  {"id":"r2","artist-credit":[{"name":"Guti","joinphrase":"","artist":{"id":"a-2","name":"Guti"}}]},
  {"id":"r3","artist-credit":[{"name":"Various Artists","joinphrase":"","artist":{"id":"89ad4ac3-39f7-470e-963a-56509c546377","name":"Various Artists"}}]}
]}''';

void main() {
  test('exactMatch takes only an exact name, ignoring case and punctuation', () {
    expect(ExploreParse.exactMatch(_artistSearch, 'artists', 'GUTI')!.id, 'a-2');
    expect(ExploreParse.exactMatch(_artistSearch, 'artists', 'Gut'), isNull);
    expect(ExploreParse.exactMatch('not json', 'artists', 'Guti'), isNull);
    expect(ExploreParse.exactMatch('{}', 'artists', 'Guti'), isNull);
    expect(ExploreParse.exactMatch(_artistSearch, 'artists', ''), isNull);
  });

  test('labelsOf counts releases per label and skips [no label]', () {
    final l = ExploreParse.labelsOf(_releasesWithLabels);
    expect(l.length, 2);
    expect(l.first.name, 'Crosstown Rebels');
    expect(l.first.n, 2);
    expect(l.last.name, 'Opulence');
    expect(ExploreParse.labelsOf('garbage'), isEmpty);
  });

  test('artistsOf lists every credited artist once per release and skips Various Artists', () {
    final a = ExploreParse.artistsOf(_releasesWithArtists);
    expect(a.map((e) => e.name).toList(), ['Guti', 'Cali Lanauze']);
    expect(a.first.n, 2);
    expect(ExploreParse.artistsOf('{"releases":"x"}'), isEmpty);
  });

  test('deezerNames reads related artists', () {
    expect(ExploreParse.deezerNames('{"data":[{"id":1,"name":"Polo & Pan"},{"id":2},{"name":"Yuksek"}]}'),
        ['Polo & Pan', 'Yuksek']);
    expect(ExploreParse.deezerNames('{"error":{}}'), isEmpty);
  });

  test('links encode the search text and RA url keeps letters and digits', () {
    final l = ExploreParse.links('Âme Rej');
    expect(l['Traxsource'], startsWith('https://www.traxsource.com/search?term='));
    expect(l['YouTube'], contains('%C3%82me'));
    expect(ExploreParse.raArtistUrl('M.A.N.D.Y.'), 'https://ra.co/dj/mandy');
  });

  test('a hit key ignores case and punctuation', () {
    expect(ExploreHit('artist', 'Cali Lanauze').key, ExploreHit('artist', 'cali  lanauze!').key);
    expect(ExploreHit('artist', 'Opulence').key, isNot(ExploreHit('label', 'Opulence').key));
  });

  test('seedsFrom picks the most common artists and labels', () {
    final tracks = [
      ImportedTrack(artist: 'Aaa', title: '1', label: 'Lab One'),
      ImportedTrack(artist: 'Bbb & Ccc', title: '2', label: 'Lab One'),
      ImportedTrack(artist: 'Bbb', title: '3', label: 'Lab Two'),
      ImportedTrack(artist: 'Ddd', title: '4'),
      ImportedTrack(title: 'No artist'),
    ];
    final seeds = Explore.seedsFrom(tracks, artists: 2, labels: 1);
    expect([for (final h in seeds) '${h.kind}:${h.name}'], ['artist:Bbb', 'artist:Aaa', 'label:Lab One']);
  });
}
