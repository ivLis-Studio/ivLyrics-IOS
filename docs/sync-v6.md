# Native sync v6

The app requests `/lyrics/sync-data?format=6`. The existing API request-version is independent of the sync document format. `SyncDataV6Codec.swift` validates the v6 schema and adapts metadata/local half-open ranges at the playback boundary. `Timing` retains integer milliseconds and unit boundaries as compact arrays; a line has one timing mark, a word one per word. A virtual codepoint collection supports the existing normalization, slicing and duration-offset paths. It does not persist an expanded legacy JSON document.

Mixed targets preserve each run's precision. Word runs group syllables and carry word metadata; character runs stay individually timed. NFC Unicode scalar indexing matches PC/backend. Derived parent timing is accepted only when every source codepoint has exactly one timed part. Explicit parent/part held ends remain independent. Malformed v6 is rejected with diagnostics and the existing provider fallback remains available. Historical formats still use the existing parser.

The raw-response cache namespace is `sync-data-api-v3-v6`; cached JSON retains v6. Contributor identity redaction/revalidation is unchanged. `SyncDataResult.lineCharCounts` reads v6 `length` and legacy character/compact ranges so LRCLIB matching works before timing application.

Run:

```sh
python3 scripts/test-sync-v6.py
python3 scripts/test-sync-load-reuse.py
python3 scripts/test-lrclib-playback.py
```

`SyncV6Checks.swift` uses the production codec, applier, utilities and lyric models with synthetic data. It checks the fixed `scripts/fixtures/sync-v6-golden.json`, including the same invalid documents rejected by PC/backend/Android. From the sibling PC checkout, `node scripts/sync-codec.mjs --check` verifies fixture copies across all four repositories. CI and unsigned-release validation run the regression. These checks do not establish physical-device playback or App Store availability.
