# Shared lyrics core preparation

This is a Foundation-only module for an unverified host adapter. It does not
discover Spotify runtime classes, register hooks, start network requests, show
UI, sign an IPA, or establish that injection works. A target IPA and a real
installation are still required to verify the host integration.

`sources.json` lists paths relative to the repository root. Compile those files
directly with Swift 5 language mode; the app's models, parser, local file store,
and LyricsPlus transport are not copied or rewritten. iOS builds target iOS 17
or later and link Foundation, CryptoKit, and NaturalLanguage. The standalone
app's `@main`, App Remote, Web API authorization, SwiftUI, Local AI, resource
bundles and settings singleton are deliberately absent. `CoreLocalization`
only satisfies `AppStatus.text(settings:)` in the original `Models.swift`.

Resource limitation: the original Japanese tokenizer looks for
`tiny_segmenter_model.json` in `Bundle.main`. This development fixture does not
install that model into Spotify's app bundle, so Japanese word segmentation
uses the original `NLTokenizer` fallback. Reusing source files does not yet
establish identical Japanese word grouping to the standalone app. A verified
resource bundle/model-data connection remains part of future host integration.

Create `IVLCoreLoader` and supply an `IVLCoreTrack` obtained by a separately
verified host adapter. `load(track:allowNetwork:)` defaults to local-only;
explicit network permission enables the existing LyricsPlus provider. Other
providers, including LRCLIB matching and ivSync, are not included in this
minimal module. Results preserve the original `LyricsResult` JSON schema in
`IVLCoreDocument.lyricsJSON` and include their `trackKey` for caller validation.

Each loader cancels its previous load and rejects an older generation's result.
Parent-task cancellation propagates to the provider. The caller must also guard
its own current track before publishing a payload. Local imports use the
original store's atomic writes and latest-operation protection. A UI/Objective-C
adapter must call `reserveLocalImport(track:)` synchronously before scheduling
`importLocalFile(_:intent:)`, and call `removeLocalLyrics(track:)` synchronously.
This preserves user intent order even if async tasks start out of order.
Import/removal invalidates only a load for the same track; choosing a new track
for `load` cancels the previous load. By default imports
they live in `Application Support/ivLyricsSpotify/LocalLyrics`, separate from
the standalone app's `LocalLyrics` folder. Tests inject a temporary directory.

Run `python3 spotify-tweak/Core/check_core.py` on macOS for offline fixtures and
the public module compile check. These checks do not prove Spotify compatibility,
IPA injection, entitlement compatibility, signing or device playback.
