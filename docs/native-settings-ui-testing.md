# Native settings and lyric-popup UI checks

The shared **ivLyrics-IOS** scheme contains the **ivLyrics-IOSUITests** UI-testing
target. Its ten settings tests launch the actual SwiftUI settings and per-track popup,
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

The suite covers the settings home (menu list and search), General/AI settings,
search with the keyboard open and dismissed (a result opens its menu and scrolls
to the row), the light/dark theme switch and menu navigation, English/Korean long
descriptions, actual toggle changes, Language/Video popup actions, portrait,
landscape and `DynamicTypeSize.accessibility3` / `accessibility5`. The home page,
General settings and the Language popup use AX5 in landscape, including actual
toggle/regeneration actions; the Video landscape case retains AX3 coverage. A
screenshot matrix captures the home page and every settings menu (three scroll
positions each) in Korean in both themes, plus Appearance, AI and Advanced in
landscape at AX5; those captures are review evidence, not assertions. It checks
button/input frames against the 44-point minimum and verifies that popup close and
footer controls remain fully inside the window. Search asserts the native input's
own frame and taps near its top edge to verify focus across its height. Reveal
gestures scroll in either direction and require visibility, not just `isHittable`.
After one native menu/result tap, navigation waits for the home scroll to disappear
and the destination scroll to exist and be hittable (up to 30 seconds for loaded CI
Simulators). This is a state wait, not a tap retry; reveal's container check, native
pointer actions, 44-point targets and full-frame scroll containment remain unchanged.
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
SIMCTL_CHILD_IVLYRICS_UI_THEME=light \
xcrun simctl launch booted kr.ivlis.ivlyrics.ios --ivlyrics-ui-test
```

Supported surfaces are `settings`, `language`, `video`, `background`, `sync`,
`lrclib`, `onboarding` and `first-language`; settings tab values are `home` (the default menu list with search),
`general`, `providers`, `ai`, `appearance`, `lyrics`, `player` and `system`.
`IVLYRICS_UI_THEME` is `dark` (default) or `light`. Set
`SIMCTL_CHILD_IVLYRICS_UI_TEXT_SIZE=accessibility3` or `accessibility5` for accessibility text, and
rotate the Simulator to inspect landscape. The default is English and standard
Large text. Stable identifiers include:

- `settings.search`, `settings.search.clear`, `settings.close`, `settings.scroll`
- `settings.home`, `settings.menu.<menu>`, `settings.theme.light`, `settings.theme.dark`,
  `settings.preview.toggle`
- `settings.result.setting.metadata_translation`, `settings.toggle.metadata`
- `settings.ai.toggle.local-ai`, `settings.ai.expand.<provider>`, `settings.toggle.cultural`,
  `settings.lyrics.toggle.<provider>`
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

## First-install setup and first-language prompt

`SetupFlowUITests` adds twelve native flow tests and retained screenshot/AX-tree
attachments. Run it with the same Simulator command above, replacing the filter
with `-only-testing:ivLyrics-IOSUITests/SetupFlowUITests`. The tested production
views live in `SetupViews.swift`:

- Three phases: language/manual theme, playback connection with explicit Web API
  opt-in, and required Client ID plus a separate optional metadata disclosure for
  Client Secret. Basic setup skips inactive metadata validation, so an invalid old
  Secret cannot block App Remote; the stored Secret remains intact. The existing Spotify
  registration guide is disclosed on demand; its redirect URI remains copyable.
- Language switching, both themes, native 48pt credential inputs, keyboard Return,
  empty-ID gating, secret failure/retry, and exact ID/secret drafts after Back.
- First-phase Hello / 안녕하세요 crossfades every 3.5 seconds without changing
  persisted UI/output language or other localized copy. Opening the picker settles
  to Korean or the English fallback even if cancelled; explicit selection, Back,
  theme recomposition and leaving the phase retain that stopped session state.
  Backgrounding cancels the wait and foregrounding starts a fresh interval.
- ID-only setup hands off to the connection action. The fixture consumes this
  action and asserts that authentication is still false; it never reports a fake
  OAuth login. With the metadata disclosure selected and a nonempty secret, a controlled failed validation response
  exercises the real spinner, inline status and retry button without a network call.
- A compact prompt with inline close, current-rule defaults, two independent
  switches, Apply/Original only, missing-provider hints only for selected features,
  remembered per-language rules across process relaunch, and no reload of a
  replacement track. Explicit original-only and close have different persistence.
- Portrait screenshots of every phase in Korean/light/dark and the prompt in
  English/Korean/German/Arabic/Thai; German AX5 landscape scrolls to and operates
  the actual switches and action buttons. Assertions check the input/button frames
  and native switch wrapper hit areas, not just screenshot appearance.

The app reads the real system Reduce Motion preference. To verify that case,
record the previous value, enable it on the exact test Simulator, then restore it
afterward:

```sh
xcrun simctl spawn <SIMULATOR_UUID> defaults read com.apple.Accessibility ReduceMotionEnabled
xcrun simctl spawn <SIMULATOR_UUID> defaults write com.apple.Accessibility ReduceMotionEnabled -bool true
```

For focused welcome checks, run `testWelcomeRotatesWithoutMutatingLanguageAndSelectionStopsIt`,
`testWelcomePickerDismissalAndBackKeepGreetingStable` and
`testWelcomeBackgroundPauseAndPhaseExit` with Reduce Motion off. Then enable the
real preference and run `testWelcomeAccessibilityStaticAndLargeTextLandscape`;
that test skips when the system preference is off. It checks the stable Korean
greeting and German/light AX5 landscape language/action reachability. Restore the
previous Simulator preference afterward. The welcome title's Debug-only AX value
records actual UI/output settings, saved preference values, rotation eligibility
and system Reduce Motion; no accessibility environment is injected. Host checks
execute the production greeting policy for every lifecycle/accessibility input
combination, including VoiceOver. Real VoiceOver speech/focus still needs a device.

The closed fixture's `ui.harness.preferences` AX label records the actual
`UIAccessibility.isReduceMotionEnabled` result along with persisted rules and
provider/auth state. This is evidence of the system setting, not an injected
SwiftUI environment override. Repeat the suite on a narrow phone (for example a
375pt iPhone SE) and inspect screenshots for wrapping and clipping.

Additional Debug-only fixture options are `IVLYRICS_UI_TRANSLATION_PROVIDER=keyless`
(otherwise both keyless providers are explicitly off),
`IVLYRICS_UI_CONFIGURED_LANGUAGE=1` (both default language features on),
`IVLYRICS_UI_STALE_TRACK=1`, and `IVLYRICS_UI_FORCE_PROMPT=1` (reopen the real prompt
even when already remembered). `IVLYRICS_UI_DEFAULTS_ID` lets a test reuse its own
unique preference suite across process relaunch. Preferences and credentials
remain isolated from normal app state. Normal setup does not enable AI providers
or download models.

`IVLYRICS_UI_SAVED_SECRET=1` seeds only an isolated fake old Secret for the native
Web-API-off regression. The dedicated `first_language.translation_provider_required`
copy describes a missing translation provider and is localized in every locale.
It does not reuse the legacy Bing/Google upsell copy.

```sh
python3 scripts/test-setup-flows.py
python3 scripts/validate-i18n.py
```

The host test executes production callback methods against controllable async
service doubles: duplicate submits, failed retry, late success/error after edits,
edits during awaited cache work, all four feature choices, replaced prompts,
duplicate callbacks and track identity. Native tests cover real AppSettings
persistence. Neither harness proves physical Spotify App Remote/OAuth success,
real credential issuance, VoiceOver device behavior, or local-model inference.
The Simulator build still requires `IVLYRICS_LLAMA_STUB=1`.

CI's `ios-validation.yml` explicitly filters both new Swift paths and the setup
scripts on push/PR, runs the host regression, and leaves the native test action
unfiltered so both native suites run and export their attachments. A workflow
dispatch or parent-owned push is required to observe a remote CI result.
