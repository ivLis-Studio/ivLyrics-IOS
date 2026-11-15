#!/bin/bash
set -euo pipefail

# Opens motion lyrics the way a listener does (the entry in the lyrics menu) and leaves it by touch,
# on an iPhone Simulator. Built like scripts/test-settings-navigation.sh, whose output directory it
# can share to reuse that build.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOTION_OUTPUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/ivlyrics-motion-ui.XXXXXX")}"
mkdir -p "$MOTION_OUTPUT"
MOTION_OUTPUT="$(cd "$MOTION_OUTPUT" && pwd)"
MOTION_DEVICE="${IVLYRICS_NAVIGATION_DEVICE:-}"
if [[ -z "$MOTION_DEVICE" ]]; then
    MOTION_DEVICE="$(xcrun simctl list devices available --json | ruby -rjson -e '
      devices = JSON.parse(STDIN.read).fetch("devices").values.flatten
      device = devices.find { |entry| entry["name"] == "iPhone SE (3rd generation)" } ||
        devices.find { |entry| entry["deviceTypeIdentifier"].include?("iPhone-SE") } ||
        devices.find { |entry| entry["name"].start_with?("iPhone") && !entry["name"].include?("Max") }
      abort "No available iPhone Simulator" unless device
      puts device.fetch("udid")
    ')"
fi

xcrun simctl bootstatus "$MOTION_DEVICE" -b

cd "$ROOT_DIR"
IVLYRICS_LLAMA_STUB=1 xcodebuild \
    -project ivLyrics-IOS.xcodeproj \
    -scheme ivLyrics-IOS \
    -configuration Release \
    -destination "platform=iOS Simulator,id=$MOTION_DEVICE" \
    -parallel-testing-enabled NO \
    -derivedDataPath "$MOTION_OUTPUT/derived" \
    -resultBundlePath "$MOTION_OUTPUT/motion-lyrics.xcresult" \
    -only-testing:ivLyrics-IOSUITests/MotionLyricsUITests \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG \
    SWIFT_ENABLE_OPAQUE_TYPE_ERASURE=NO \
    CODE_SIGNING_ALLOWED=NO \
    test
