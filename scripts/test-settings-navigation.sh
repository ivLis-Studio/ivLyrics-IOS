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
    SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG \
    SWIFT_ENABLE_OPAQUE_TYPE_ERASURE=NO \
    CODE_SIGNING_ALLOWED=NO \
    test
