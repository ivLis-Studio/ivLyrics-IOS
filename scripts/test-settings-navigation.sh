#!/bin/bash
set -euo pipefail

# Match the production optimizer and SwiftUI value layout, retaining only the isolated
# DEBUG launch fixture. The real device archive is built separately without DEBUG.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAVIGATION_OUTPUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/ivlyrics-navigation.XXXXXX")}"
mkdir -p "$NAVIGATION_OUTPUT"
NAVIGATION_OUTPUT="$(cd "$NAVIGATION_OUTPUT" && pwd)"
NAVIGATION_DEVICE="${IVLYRICS_NAVIGATION_DEVICE:-}"
if [[ -z "$NAVIGATION_DEVICE" ]]; then
    NAVIGATION_DEVICE="$(xcrun simctl list devices available --json | ruby -rjson -e '
      devices = JSON.parse(STDIN.read).fetch("devices").values.flatten
      device = devices.find { |entry| entry["name"] == "iPhone SE (3rd generation)" } ||
        devices.find { |entry| entry["deviceTypeIdentifier"].include?("iPhone-SE") } ||
        devices.find { |entry| entry["name"].start_with?("iPhone") && !entry["name"].include?("Max") }
      abort "No available iPhone Simulator" unless device
      puts device.fetch("udid")
    ')"
fi

# Cold CI Simulators can time out while Xcode launches the first UI fixture.
# Boot before compilation so system initialization finishes before XCTest starts.
xcrun simctl bootstatus "$NAVIGATION_DEVICE" -b

cd "$ROOT_DIR"
IVLYRICS_LLAMA_STUB=1 xcodebuild \
    -project ivLyrics-IOS.xcodeproj \
    -scheme ivLyrics-IOS \
    -configuration Release \
    -destination "platform=iOS Simulator,id=$NAVIGATION_DEVICE" \
    -parallel-testing-enabled NO \
    -derivedDataPath "$NAVIGATION_OUTPUT/derived" \
    -resultBundlePath "$NAVIGATION_OUTPUT/navigation.xcresult" \
    -only-testing:ivLyrics-IOSUITests/SettingsLayoutUITests/testEverySettingsCategoryOpensFromHomeAndReturns \
    -only-testing:ivLyrics-IOSUITests/SettingsLayoutUITests/testAIProviderBadgeCentersWithAccessibilityText \
    -only-testing:ivLyrics-IOSUITests/SettingsLayoutUITests/testProviderBadgeCenters \
    -only-testing:ivLyrics-IOSUITests/SettingsLayoutUITests/testHomeWordmarkExactWeightsAndLocalizedNavigation \
    -only-testing:ivLyrics-IOSUITests/SettingsLayoutUITests/testHomeWordmarkLandscapeAccessibilityText \
    -only-testing:ivLyrics-IOSUITests/SettingsLayoutUITests/testLrclibEndpointValidationPersistenceAndClear \
    -only-testing:ivLyrics-IOSUITests/SettingsLayoutUITests/testLrclibEndpointLargeTextLayout \
    -only-testing:ivLyrics-IOSUITests/SettingsLayoutUITests/testAlbumCoverLPSwitchSearchPersistenceAndImport \
    -only-testing:ivLyrics-IOSUITests/SettingsLayoutUITests/testAlbumCoverLPSwitchLargeTextLayout \
    -only-testing:ivLyrics-IOSUITests/SettingsLayoutUITests/testVideoTimingShareUsesAppliedVideoAndExactOffset \
    -only-testing:ivLyrics-IOSUITests/SettingsLayoutUITests/testVideoTimingShareUnavailableWithoutAppliedVideo \
    -only-testing:ivLyrics-IOSUITests/SettingsLayoutUITests/testVideoTimingShareRequiresCurrentPlayerAcknowledgement \
    -only-testing:ivLyrics-IOSUITests/SettingsLayoutUITests/testVideoTimingShareEnabledAfterSameSelectionRemount \
    -only-testing:ivLyrics-IOSUITests/SettingsLayoutUITests/testLocalLyricsFilePickerOpensAndCancels \
    -only-testing:ivLyrics-IOSUITests/SettingsLayoutUITests/testLocalLyricsMenuLargeTextLayout \
    -only-testing:ivLyrics-IOSUITests/SettingsLayoutUITests/testLyricsPageSettingsOpenAndReturn \
    -only-testing:ivLyrics-IOSUITests/SettingsLayoutUITests/testLyricsPageSettingsLargeTextAndLandscape \
    -only-testing:ivLyrics-IOSUITests/SettingsLayoutUITests/testLandscapeSettingsRevealAfterAutoHide \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG \
    SWIFT_ENABLE_OPAQUE_TYPE_ERASURE=NO \
    CODE_SIGNING_ALLOWED=NO \
    test
