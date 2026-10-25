#!/bin/bash
# Archives the App Store build and uploads it to App Store Connect.
#   DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer VERSION_NAME=2.0.7 BUILD_NUMBER=80 scripts/upload-app-store.sh
# Use a released Xcode: App Store Connect rejects uploads built with beta toolchains. Signing is automatic
# through the Xcode account for the team; BUILD_NUMBER must exceed every build already uploaded.
# IVLYRICS_DISTRIBUTION=appstore leaves out the GitHub update checker and the Discord account features
# (see AppDistribution in Utilities.swift). The GitHub/AltStore IPA keeps building with the default "github".
set -euo pipefail

if [[ "${IVLYRICS_LLAMA_STUB:-0}" == "1" ]]; then
    echo "App Store archives require the real llama.cpp engine; unset IVLYRICS_LLAMA_STUB." >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_NAME="${VERSION_NAME:?Set VERSION_NAME, for example 2.0.7}"
BUILD_NUMBER="${BUILD_NUMBER:?Set BUILD_NUMBER above the last App Store Connect build}"
TEAM_ID="${TEAM_ID:-7NT8ZLSW2P}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ivlyrics-app-store.XXXXXX")"
ARCHIVE_PATH="${WORK_DIR}/ivLyrics-IOS.xcarchive"
EXPORT_OPTIONS="${WORK_DIR}/ExportOptions.plist"

xcodebuild -version
xcodebuild \
    -project "${ROOT_DIR}/ivLyrics-IOS.xcodeproj" \
    -scheme ivLyrics-IOS \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "${WORK_DIR}/DerivedData" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    MARKETING_VERSION="$VERSION_NAME" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    IVLYRICS_DISTRIBUTION=appstore \
    archive

INFO_PLIST="${ARCHIVE_PATH}/Products/Applications/ivLyrics-IOS.app/Info.plist"
if [[ "$(plutil -extract IVLyricsDistribution raw -o - "$INFO_PLIST")" != "appstore" ]]; then
    echo "The archive is not an App Store build." >&2
    exit 1
fi

plutil -create xml1 "$EXPORT_OPTIONS"
plutil -insert method -string app-store-connect "$EXPORT_OPTIONS"
plutil -insert destination -string upload "$EXPORT_OPTIONS"
plutil -insert teamID -string "$TEAM_ID" "$EXPORT_OPTIONS"
plutil -insert signingStyle -string automatic "$EXPORT_OPTIONS"
plutil -insert uploadSymbols -bool true "$EXPORT_OPTIONS"
plutil -insert manageAppVersionAndBuildNumber -bool false "$EXPORT_OPTIONS"

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "${WORK_DIR}/upload" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates
echo "Uploaded ivLyrics ${VERSION_NAME} (${BUILD_NUMBER}); archive kept at ${ARCHIVE_PATH}"
