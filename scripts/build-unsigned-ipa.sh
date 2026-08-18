#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR_INPUT="${1:-${ROOT_DIR}/build/unsigned-ipa}"
mkdir -p "$OUTPUT_DIR_INPUT"
OUTPUT_DIR="$(cd "$OUTPUT_DIR_INPUT" && pwd)"

PROJECT_PATH="${ROOT_DIR}/ivLyrics-IOS.xcodeproj"
SCHEME="ivLyrics-IOS"
PRODUCT_NAME="ivLyrics-IOS"
BUNDLE_IDENTIFIER="kr.ivlis.ivlyrics.ios"
VERSION_NAME="${VERSION_NAME:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
RELEASE_TAG="${RELEASE_TAG:-local}"

if [[ ! "$VERSION_NAME" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
    echo "Invalid VERSION_NAME: $VERSION_NAME" >&2
    exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "Invalid BUILD_NUMBER: $BUILD_NUMBER" >&2
    exit 1
fi

SAFE_TAG="$(printf '%s' "$RELEASE_TAG" | tr -c 'A-Za-z0-9._-' '-')"
WORK_DIR="$(mktemp -d "${RUNNER_TEMP:-/tmp}/ivlyrics-ios-unsigned.XXXXXX")"
ARCHIVE_PATH="${WORK_DIR}/${PRODUCT_NAME}.xcarchive"
PACKAGE_DIR="${WORK_DIR}/package"
IPA_NAME="${PRODUCT_NAME}-${SAFE_TAG}-unsigned.ipa"
IPA_PATH="${OUTPUT_DIR}/${IPA_NAME}"
CHECKSUM_PATH="${IPA_PATH}.sha256"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "Building ${PRODUCT_NAME} ${VERSION_NAME} (${BUILD_NUMBER})"
xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "${WORK_DIR}/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    'CODE_SIGN_IDENTITY=' \
    'DEVELOPMENT_TEAM=' \
    MARKETING_VERSION="$VERSION_NAME" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    archive

APP_PATH="${ARCHIVE_PATH}/Products/Applications/${PRODUCT_NAME}.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "Archived app not found: $APP_PATH" >&2
    exit 1
fi

if codesign -d "$APP_PATH" >/dev/null 2>&1; then
    echo "Expected an unsigned app, but a code signature was found." >&2
    exit 1
fi
if find "$APP_PATH" -name embedded.mobileprovision -print -quit | grep -q .; then
    echo "Expected no provisioning profile in the unsigned app." >&2
    exit 1
fi

INFO_PLIST="${APP_PATH}/Info.plist"
EXECUTABLE_NAME="$(plutil -extract CFBundleExecutable raw -o - "$INFO_PLIST")"
BUILT_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST")"
BUILT_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")"
BUILT_NUMBER="$(plutil -extract CFBundleVersion raw -o - "$INFO_PLIST")"
EXECUTABLE_PATH="${APP_PATH}/${EXECUTABLE_NAME}"

if [[ "$BUILT_BUNDLE_ID" != "$BUNDLE_IDENTIFIER" ]]; then
    echo "Unexpected bundle identifier: $BUILT_BUNDLE_ID" >&2
    exit 1
fi
if [[ "$BUILT_VERSION" != "$VERSION_NAME" || "$BUILT_NUMBER" != "$BUILD_NUMBER" ]]; then
    echo "Unexpected app version: ${BUILT_VERSION} (${BUILT_NUMBER})" >&2
    exit 1
fi
if ! xcrun vtool -show-build "$EXECUTABLE_PATH" | grep -Eq 'platform[[:space:]]+IOS'; then
    echo "The archive does not contain an iOS device executable." >&2
    exit 1
fi

mkdir -p "${PACKAGE_DIR}/Payload"
ditto --norsrc --noextattr --noqtn --noacl \
    "$APP_PATH" "${PACKAGE_DIR}/Payload/${PRODUCT_NAME}.app"
rm -f "$IPA_PATH" "$CHECKSUM_PATH"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --noqtn --noacl \
    --keepParent "${PACKAGE_DIR}/Payload" "$IPA_PATH"
unzip -tq "$IPA_PATH"
IPA_ENTRIES="$(unzip -Z1 "$IPA_PATH")"
if ! grep -Eq '^Payload/[^/]+[.]app/Info[.]plist$' <<< "$IPA_ENTRIES"; then
    echo "IPA payload layout is invalid." >&2
    exit 1
fi
if grep -Eq '(^|/)(__MACOSX|[.][_][^/]*)($|/)' <<< "$IPA_ENTRIES"; then
    echo "IPA contains macOS metadata files." >&2
    exit 1
fi

(
    cd "$OUTPUT_DIR"
    shasum -a 256 "$IPA_NAME" > "${IPA_NAME}.sha256"
)

echo "Created unsigned IPA: $IPA_PATH"
echo "SHA-256: $(awk '{print $1}' "$CHECKSUM_PATH")"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "ipa_path=$IPA_PATH"
        echo "checksum_path=$CHECKSUM_PATH"
        echo "ipa_name=$IPA_NAME"
        echo "version_name=$BUILT_VERSION"
        echo "build_number=$BUILT_NUMBER"
    } >> "$GITHUB_OUTPUT"
fi
