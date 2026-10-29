# Development package

This is an **unverified development payload**, not an IPA or an installer for a non-jailbroken phone.
The package contains no Spotify executable, signing identity, provisioning profile, or original app resources.
**The Spotify playback/UI adapter is not implemented.** The bootstrap currently only logs its load;
the reusable lyrics core and bridge are available for a future adapter. Spotify track detection,
playback synchronization, and lyrics UI integration are absent. Host integration has not been
verified against a supplied Spotify IPA.

Requirements: macOS, full Xcode with its iPhoneOS SDK selected by `xcode-select`, and Python 3.9 or newer.
The build uses `clang`, `swiftc`, `lipo`, `otool`, `vtool`, and `codesign` from Xcode/macOS. It does not require
Theos, `dpkg-deb`, CydiaSubstrate, or a jailbreak package manager.

From the repository root:

```sh
python3 spotify-tweak/scripts/test_packaging.py
python3 spotify-tweak/scripts/build_deb.py --allow-unverified
python3 spotify-tweak/scripts/build_deb.py --verify spotify-tweak/packaging/out/ivlyrics-spotify-preview_0.1.0_iphoneos-arm.deb
```

The default build refuses to run without `--allow-unverified`. Outputs and intermediate files stay in
the ignored `spotify-tweak/packaging/out/` directory. `--output PATH` can select another build directory;
the caller is responsible for excluding that directory from Git.

`Core/sources.json` lists Swift source paths relative to the iOS repository root. Original app sources
are compiled in place; they are not copied or changed. The builder also includes `Core/*.swift`,
`src/*.swift`, and C/Objective-C/C++ sources under `src/`. It compiles the native bootstrap to an object,
then links with Swift 5 language mode into module `IVLyricsSpotify`, targeting `arm64-apple-ios17.0`.

The legacy Debian architecture label is `iphoneos-arm`; the binary itself must be a thin **arm64**
iPhoneOS `MH_DYLIB`. The `.deb` has only these payload files:

```text
Library/MobileSubstrate/DynamicLibraries/ivLyricsSpotify.dylib
Library/MobileSubstrate/DynamicLibraries/ivLyricsSpotify.plist
```

This directory layout lets an external injection tool locate the payload. It does not install
MobileSubstrate or make iOS load the library automatically. The bundle filter names the expected
`com.spotify.client` host; the actual supplied IPA still needs to be checked.

The builder verifies the archive members, package identity, arm64 architecture, iPhoneOS minimum
version 17.0, install name, dynamic dependencies, runtime search paths, missing jailbreak runtime
symbols, and an ad-hoc code signature. Only Apple system frameworks/libraries and system Swift
libraries through `/usr/lib/swift` are accepted. `verification.json` records those results and source
hashes, with `host_integration_verified: false` and `spotify_playback_ui_adapter_implemented: false`.

An ad-hoc signature validates the built file's integrity. It is not an installation signature:
an injection/signing tool must place the dylib in the host IPA, add its load command, and re-sign
the resulting app. Packaging checks do not establish injection, launch, playback, or host compatibility.
