# Spotify module UI

These UIKit surfaces use the original `TrackSnapshot`, `LyricsResult`, lyric timing,
and local-file parser through `IVLCoreLoader`. The separately verified host adapter
provides playback state and mounts a surface inside the native lyric area. This
directory does not discover Spotify classes or change native views.

## Host interface

Call the following Objective-C interface on the main thread:

```objc
IVLyricsSpotifyUI *ui = [IVLyricsSpotifyUI shared];
[ui updateStateJSON:json];
[ui attachCardToView:lyricCard];
[ui attachFullscreenToView:lyricContent];
[ui detachFromView:previousLyricContent];
[ui presentFromViewController:presenter];
[ui hostDisconnected];
```

State JSON accepts `title`, `artist`, `album`, `spotifyID`, `isrc`, `durationMs`,
`positionMs`, `playing`, and `speed` (positive playback rate, normally `1`, including
while paused). Durations and positions are milliseconds. Metadata changes reload
lyrics; position-only updates preserve the current result.

`hasTrackAndLyrics` and `setOnReadyChanged:` report whether module lyrics can be
shown. Setting the callback immediately reports current readiness. The host owns
hiding/restoring native content. Module surfaces hide themselves when not ready;
the explicit modal screen remains available to retry or import local lyrics.
Mount only inside the lyric content view, not a parent containing playback controls.

Repeated attachment is idempotent. Top-level module children have identifiers
starting with `ivlyrics.spotify.`. Detachment removes only the shared UI instance's
own immediate child surfaces and stops their display clocks; it never changes
native views. On disconnect, pending loads are cancelled and readiness becomes
false.

Register the host-owned seek function with:

```c
void IVLyricsSpotifyUISetSeekHandler(void (*handler)(int64_t positionMs));
```

The callback receives milliseconds, is invoked on the main thread, and is clamped
to a known track duration. The UI does not directly control Spotify playback.

## Behavior

The card and full list show provider information, timed active lines, automatic
scrolling, line-tap seek, and syllable progress colors without rebuilding lyric
text or spacing. Manual scrolling pauses following for five seconds. Display
clocks stop when surfaces leave a window. Korean and English interface labels are
included; this is not a copy of the standalone app's complete settings or AI UI.

The document picker accepts LRC and plain-text files. It captures the song when
opened, so selecting a file after playback changes still saves to the original
song. Core edit generations and UI request generations prevent stale imports,
provider loads, or removals from replacing a later result. Local overrides persist
through the shared Core's isolated module storage. Import/remove errors remain
visible in the provider caption while previous lyrics stay on screen.

## Synthetic iOS validation

```sh
python3 spotify-tweak/UI/run_ui_harness.py --device SIMULATOR_UDID
```

The runner builds only a dedicated UIKit fixture app against the current Core
source manifest. It installs and launches that app on the selected simulator, then
writes `UI/.build/ui-checks.json` and `UI/.build/ui-screenshot.png`. Production
packaging must include only the top-level UI Swift sources, not `Harness/`.

The fixture checks real view layout, visible table cells, active lines, auto-scroll,
seek units, duplicate mounting, detachment, readiness/native preservation, stale
loads, file persistence, invalid-file feedback, removal ordering, and disconnect.
It presents the real document picker but supplies its selection callback with a
synthetic local file. It uses no network and does not install or run Spotify.
Passing this harness establishes UIKit behavior, not actual Spotify integration,
real Files-provider selection, device signing, or installation acceptance.
