# Changes from SideDeck

Forked from SideDeck 1.1.1 (https://github.com/manueljpy/SideDeck), 20 Oct 2026.

- Removed the original signed-release workflow (needs the author's keys).
- Added .github/workflows/build.yml: analyze, test and build a debug APK on every push.
- Planned: key lock button and pitch controls, local playlists, automix, Soulseek search.

## Soulseek step A (20 Oct 2026)
- Library header: rescan button, and an "Open Seeker" button (finds the app by its launcher name).
- The library rescans its folder whenever BeatDeck comes back to the foreground, so files Seeker just downloaded appear without a manual refresh.
- Step B (Soulseek search built into BeatDeck) is a later project.

## Customisable look (20 Oct 2026)
- Palette button on the controller screen opens "Customise look": 12 gentle background colours, 12 controller body colours, and 12 accent colours for each of the four decks. Saved on the phone, with a Reset button. Defaults are the matte graphite / amber / teal look.

## Effects
- Master FX unit in the engine (`native/engine/fx.hpp`): echo (ping-pong, tempo-synced), reverb, flanger.
- FX pull-down on the controller screen (top right), next to the Automix pull-down.

## Friends build
- Own app id com.benclift.beatdeck.test. Simple mode is the default: pick a vibe, tap Start. Pro mode (menu) is the full BeatDeck.

## Explore (27 Oct 2026)
- New Explore page (Pro: compass button in the library toolbar; Simple mode: menu). Start from an artist, a label or a genre and follow the links outward, 1 to 3 hops: artist to their labels (MusicBrainz), label to its artists (MusicBrainz), artist to similar artists (Deezer). Genre starts use the Bandcamp and Discogs lists.
- Ranked by how many links lead there; labels you own raise the artists on them. Music you already own is marked and hidden by default. "Not for me" hides an artist or label for good (Forget list in the page menu).
- Each result has Listen (YouTube, Bandcamp) and Buy (Traxsource, Beatport, Hardwax) links, which are search pages opened in the phone's browser, and a link to the artist's Resident Advisor page. Tap an artist for top tracks with tempo (Deezer), with a BPM filter, add to wish list, and Find on Soulseek.
- Paced to MusicBrainz's one request a second, at most 30 requests a run, parsed answers kept for a week.
- Not yet: who plays the same nights (events), remixer links, tempo for artists and labels.

## My tracks (27 Oct 2026)
- Explore has a "My tracks" page: import screenshots of Finder lists (read on the phone) or paste file names. Scene-style names, track numbers, key/BPM endings, compilation prefixes and `[Label]` endings are cleaned into artist, title, mix and label.
- Imported tracks count as music you own: Explore hides them and uses their artists and labels as your taste.
- Each track has Listen (YouTube, Bandcamp) and Buy (Traxsource, Beatport, Hardwax) search links, a direct Deezer link where Deezer has the track ("Find links"), Explore from this artist, wish list and Soulseek.

## Separate part apps (28 Oct 2026)
- Plan: each part of BeatDeck gets its own app, built from this same repo with its own entry file, then they are put together. Order: finder, Soulseek, decks and mixer, Auto DJ, combined app.
- BeatDeck Finder (`lib/apps/finder_main.dart`, app id `com.benclift.beatdeck.finder`) is the first: Explore, My tracks, wish list, listen/buy links. No audio engine and no Soulseek (the Soulseek button copies the search text). The CI publishes it as its own release, "BeatDeck Finder".
- To make that possible, `Taste` no longer reads the music library itself: `taste_library.dart` plugs that in for the full app, and `FinderHost` gives the finder pages their Soulseek button.
- `test/part_independence_test.dart` fails the build if the finder ever imports the engine, decks or Soulseek.

## Screenshots and related music (28 Oct 2026)
- The My tracks page is now "Screenshots and my tracks": an "Add screenshots" button and a "Find related" button side by side. BeatDeck Finder opens on it.
- "Find related" starts from the artists and labels that appear most in your tracks (up to 6 artists and 2 labels), looks one step out from each, and ranks what is linked to several of them higher. Results use the Explore list (listen, buy, top tracks, wish list, Soulseek).
