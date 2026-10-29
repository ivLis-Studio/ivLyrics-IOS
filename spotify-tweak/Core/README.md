# Shared lyrics core

This module accepts track metadata from a separate host adapter. Constructing it
does not discover Spotify runtime classes, register hooks, start network requests,
or show UI. Core fixtures do not establish that IPA injection or device playback
works; those require separate host integration tests.

`sources.json` lists paths relative to the repository root. Compile those files
directly with Swift 5 language mode. The app's `LyricsRepository`, provider
transports, sync applier, models, parser, local store, caches and secure store are
compiled in place. Matching, retries, fallback, quality selection, sync timing and
contributor privacy algorithms are not copied or rewritten. iOS builds target iOS 17
or later and link Foundation, CryptoKit, NaturalLanguage and Security. The standalone
app's `@main`, App Remote, Web API authorization, SwiftUI, Local AI, resource
bundles and settings singleton are absent. `CoreLocalization` supplies the minimal
read-only settings snapshot, provider metadata and status strings required by the
original model and repository.

Resource limitation: the original Japanese tokenizer looks for
`tiny_segmenter_model.json` in `Bundle.main`. This development fixture does not
install that model into Spotify's app bundle, so Japanese word segmentation
uses the original `NLTokenizer` fallback. Reusing source files does not yet
establish identical Japanese word grouping to the standalone app. A verified
resource bundle/model-data connection remains part of future host integration.

Create `IVLCoreLoader` and supply an `IVLCoreTrack` obtained by a separately
verified host adapter. `load(track:allowNetwork:)` defaults to local-only;
explicit network permission enables the original repository. The default module
policy enables LRCLIB and LyricsPlus, prefers more detailed lyric timing, and
prefers registered ivSync providers. Paxsenix and Unison sources are also compiled
because the repository refers to them; they are disabled by the default module
snapshot. No host preferences, Spotify access token, API client ID or client secret
are read. The adapter must supply a valid ISRC for ivSync discovery: without one,
title/artist LRCLIB and LyricsPlus lookup still works, but the module has no Spotify
API credentials with which to discover an ISRC. Results preserve the original `LyricsResult` JSON schema in
`IVLCoreDocument.lyricsJSON` and include their `trackKey` for caller validation.

The original repository records provider failures in diagnostic logs and can
return an empty result after failed attempts. The core preserves that no-result
behavior; the UI cannot distinguish every upstream HTTP/network failure from
missing lyrics. Error-caption fixtures cover thrown errors, not every provider
failure path.

Each loader cancels its previous load and rejects an older generation's result.
Parent-task cancellation propagates to the provider. The caller must also guard
its own current track before publishing a payload. Local imports use the
original store's atomic writes and latest-operation protection. A UI/Objective-C
adapter must call `reserveLocalImport(track:)` synchronously before scheduling
`importLocalFile(_:intent:)`, and call `removeLocalLyrics(track:)` synchronously.
This preserves user intent order even if async tasks start out of order.
Import/removal invalidates only a load for the same track; choosing a new track
for `load` cancels the previous load. By default imports live in
`Application Support/ivLyricsSpotify/LocalLyrics`, separate from the standalone
app's `LocalLyrics` folder. They take priority before any provider work.

`CoreRepository` creates the original repository only after network opt-in. It
injects that local store, a `ProviderCache` child directory, and a dedicated
defaults suite/keychain service derived from the module storage path. The original
`LyricsRepository()` initializer retains the standalone app's existing storage
defaults. Only the `ProviderCache` directory is excluded from backups; the local
import directory remains eligible. Injected cache roots use the original expiry/size pruning algorithm,
with a separate throttle per root; they never sweep the standalone app's cache.
Clearing repository caches does not
delete imports or another storage root's entries.

Run these checks on macOS:

```sh
python3 spotify-tweak/Core/check_core.py
python3 spotify-tweak/Core/check_repository.py
```

The first checks the public module/Objective-C bridge, imports, opt-in and stale
load cancellation with temporary files. The second compiles the complete original
repository and exercises LRCLIB through a loopback HTTP fixture, cached ivSync
application and isolated persistence. Its dedicated preferences domain is removed
after the fixture. These checks do not prove Spotify compatibility, IPA injection,
entitlement compatibility, signing or device playback.
