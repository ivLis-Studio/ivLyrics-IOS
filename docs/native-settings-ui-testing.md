# Native settings and lyric-popup UI checks

The shared **ivLyrics-IOS** scheme contains the **ivLyrics-IOSUITests** UI-testing
target. Its seven tests launch the actual SwiftUI settings and per-track popup,
use native accessibility frames and interactions, and retain both PNG screenshots
and accessibility-tree text attachments in the `.xcresult`. They are not HTML
screenshots or a substitute for physical-device testing.

## Run on an iPhone Simulator

Use a full Xcode installation. Select an available small iPhone Simulator UUID
from `xcrun simctl list devices available`; an iPhone SE is a useful narrow case.
The llama.cpp package needs its existing Simulator stand-in:

```sh
IVLYRICS_LLAMA_STUB=1 xcodebuild test \
  -project ivLyrics-IOS.xcodeproj \
  -scheme ivLyrics-IOS \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UUID>' \
  -parallel-testing-enabled NO \
  -resultBundlePath /tmp/ivlyrics-settings-ui.xcresult \
  CODE_SIGNING_ALLOWED=NO

xcrun xcresulttool export attachments \
  --path /tmp/ivlyrics-settings-ui.xcresult \
  --output-path /tmp/ivlyrics-settings-ui-attachments
```

Choose a fresh result-bundle path for each run. CI should retain the result bundle
and exported attachments even when an assertion fails. To focus the run, append
`-only-testing:ivLyrics-IOSUITests/SettingsLayoutUITests`.

The suite covers General/AI settings, search with the keyboard open and dismissed,
English/Korean long descriptions, actual toggle changes, Language/Video popup
actions, portrait, landscape and `DynamicTypeSize.accessibility3` / `accessibility5`.
General settings and the Language popup use AX5 in landscape, including actual
toggle/regeneration actions; the Video landscape case retains AX3 coverage. It checks
button/input frames against the 44-point minimum and verifies that popup close and
footer controls remain fully inside the window. Search asserts the native input's
own frame and taps near its top edge to verify focus across its height. Reveal
gestures scroll in either direction and require visibility, not just `isHittable`.
The Video portrait path also measures and taps all six offset buttons and reset,
checking their displayed values and restoring zero before dismissal. Input borders
are drawn inside their bounds rather than relying on test geometry tolerances.
Screenshots use the full native display to avoid application-cropping artifacts
after rotation, and launch/assertion failures retain screenshots and AX trees too.
A Debug-only non-interactive geometry probe
measures the toggle's real row/wrapper hit area: the native switch's visual knob
is allowed to retain its normal 31-point height.

Inspect retained images for text overlap, clipping and scrim contrast; frame
assertions cannot prove every glyph is unclipped. Re-run on another iPhone size
and on a physical device before calling the visual audit accepted. VoiceOver,
Switch Control and keyboard layouts also deserve device checks. Simulator AX5
coverage does not replace physical-device acceptance.

## Manual Debug route

After installing a **Debug** build, launch without Spotify, AI credentials or login:

```sh
SIMCTL_CHILD_IVLYRICS_UI_SURFACE=settings \
SIMCTL_CHILD_IVLYRICS_DEBUG_SETTINGS_TAB=ai \
SIMCTL_CHILD_IVLYRICS_UI_LANGUAGE=ko \
xcrun simctl launch booted kr.ivlis.ivlyrics.ios --ivlyrics-ui-test
```

Supported surfaces are `settings`, `language`, `video`, `background`, `sync` and
`lrclib`; settings tab values are `general`, `providers`, `ai`, `appearance`,
`lyrics`, `player` and `system`. Set
`SIMCTL_CHILD_IVLYRICS_UI_TEXT_SIZE=accessibility3` or `accessibility5` for accessibility text, and
rotate the Simulator to inspect landscape. The default is English and standard
Large text. Stable identifiers include:

- `settings.search`, `settings.search.clear`, `settings.close`, `settings.scroll`
- `settings.result.setting.metadata_translation`, `settings.toggle.metadata`
- `settings.ai.toggle.local-ai`, `settings.toggle.cultural`
- `lyrics.menu.close`, `lyrics.menu.scroll`, `lyrics.menu.regenerate`
- `lyrics.menu.video.url`, `lyrics.menu.video.apply`

## Isolation and release boundaries

Only `--ivlyrics-ui-test` in a **Debug** build enables the route; deep links cannot
enable it. It does not construct the production ContentView, start live playback,
register audio-route monitoring, start the display clock or configure the PiP
audio session. Preferences and credentials use fresh, isolated namespaces. The
creator account's separate preferences/keychain namespace is isolated too.

Debug-only guards consume login, cloud, cache-clearing, search, connection testing
and other service actions while the fixture is active. Video selection and lyrics
regeneration return deterministic offline fixture results through the same view
actions. No authentication is treated as successful and no real lyrics/cache
state is cleared. Normal Debug launches and Release builds retain the production
paths, settings defaults and security checks.

The harness and XCTest source are conditional on `DEBUG`; the UI target is
Simulator-only, `SKIP_INSTALL=YES` and excluded from the shared scheme's archive
action. The Release-only hit-area modifier is a no-op. The parent owns workflow
registration, release validation and artifact inspection.

## Fast host regression

```sh
python3 scripts/test-settings-ui.py
python3 scripts/validate-i18n.py
```

The host regression checks project/scheme wiring and fixture boundaries, then
compiles and executes the production manual-search method against late cancelled
success/error callbacks, plus the actual native-search coordinator against deferred,
cancelled and idempotent focus requests. It is not a native render/build check. Native testing
requires the full-Xcode CI command above.
