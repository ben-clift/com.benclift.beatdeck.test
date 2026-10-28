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

## Projector (28 Oct 2026)
- New "Projector" entrance on the first page (below Request or import) and in the menu. It opens a Projector page that sends the MilkDrop visuals to a second screen (HDMI or USB-C projector, or a wireless display) through a native Android presentation (`ProjectorPresentation.kt`), while the phone keeps the controls. Brightness, intensity, speed, change timer and presets apply to both screens.
- "Full screen here" shows only the picture, edge to edge, so Cast or screen mirroring shows it on a TV. Tap = next picture, hold = freeze, Back = leave.
- Mirror left to right and Upside down switches, for a projector behind the screen or on the ceiling.
- Not yet checked on a phone with a real projector. Two MilkDrop pages at once (Booth plus projector) may need a lower frame rate on slow phones.
- Not done: films, TV and games from consoles or PCs (needs a capture card and a separate app; protected streaming video cannot be captured).

## Smooth blending (28 Oct 2026)
- MilkDrop at a low speed (under 30 frames a second) no longer jumps from one picture to the next: each new frame is faded in over the last one at full screen speed. "Smooth blending" switch in Visuals settings and on the Projector page, on by default. Switch it off for the old sharp frames.
- The picture is about one frame behind the music (200 ms at 5 frames a second) because it fades towards the newest frame.

## Slow and steady MilkDrop (28 Oct 2026)
- Visuals settings and the Projector page have a "Slow and steady" button and two new sliders. Motion speed (10 to 100%) slows how fast the pictures move and how sharply they follow the music. Change blend (2 to 30 s) sets how long one picture takes to melt into the next, including when you tap for the next one. "Change picture every" now goes up to 10 minutes.
- The shared controls are `MilkdropPaceControls` in `milkdrop_view.dart`.
- Random (28 Oct 2026): a "Random" change timer (10 s to 5 min, a new time after each change), and Random switches for intensity, motion speed and change blend. Each picks a new value at every change of picture, between the lowest setting and the slider. Brightness and frame rate are not randomised.

## Your photos in MilkDrop (28 Oct 2026)
- Visuals settings start with "Your photos". "Choose from my gallery" opens a browser for the phone's photos: pick an album (Camera, Screenshots, WhatsApp, Download and so on) and a time (any time, last 7 days, last 30 days, this year, or your own dates), tick photos and add them. It asks for permission to see photos, and reads them only on the phone.
- "Phone photo picker (people, places)" opens Android's own picker, which on many phones shows Google Photos with its people, places and albums. BeatDeck cannot read the names of people itself, so this is the way to choose by who is in the photo.
- Photos are copied as small JPEGs (about 900 pixels) into the app, up to 40. They show over the picture, slowly zooming and melting from one to the next. Photo strength (off to 100%) and how long each stays (10 s to 2 min) are in the same section; "Remove all photos" clears them.
- Not yet: blend styles (glow through the dark parts, overlay), the Projector page and second screen showing the photos.


## Home screen (28 Oct 2026)
- After the splash, the app opens on a new Home screen. It lists everything that was in the top-right menu: Appearance, Projector, Explore, Connect my Mac, Pro mode and Admin code, plus Shazam and the test-version days left. Admin code is only in the top-right menu.
- "The Booth" is the first button on Home. It goes to the genre screen (or straight back to the music if something is playing). A back arrow on the genre screen returns to Home.
- Sending logs and Report a problem are not on Home; they stay in the top-right menu, which is unchanged.

## Test version length (28 Oct 2026)
- The friends test build now runs for 30 days after it was built (was 3). Builds already installed keep their old end date; install the new build to get the longer time.

## Welcome screen (28 Oct 2026)
- After the splash there is now a short pitch screen ("Your set, on its own.") listing what BeatDeck does, with an Enter button that opens Home. It shows on every launch.

## Photo archive (28 Oct 2026)
- Visuals settings, "Your photos": a new "Online archive" button opens The Met's open collection (public domain, no sign-up). Pick a theme (Highlights, Landscapes, Portraits, Flowers, Sea and ships, Cities, Night, Animals, Japanese prints, Photographs, Patterns, Impressionism), tick pictures, or use "Select all" or "Random" with a chosen number (10, 25, 50, 100 or 200). Pictures are copied small onto the phone like your own photos.
- The photo limit went from 40 to 200.
- Mostly artworks, with a smaller number of historic photographs. Only pictures marked public domain are used.
- The phone gallery picker has the same "Select all (up to the room left)" and "Random N" (10, 25, 50, 100, 200), picking from the whole open album and date choice, not just the photos on screen.
