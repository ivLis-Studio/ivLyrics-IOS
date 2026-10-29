# Development package

This is an **unverified development preview**, not an IPA or an installer for a non-jailbroken phone.
It contains only the ivLyrics module and filter, with no Spotify binary, signing identity,
provisioning profile, or original app resources. The host adapter targets the statically inspected
Spotify 9.1.60 (916001969). Runtime integration on an actual iPhone remains unverified.

Requirements: macOS, full Xcode with its iPhoneOS SDK selected by `xcode-select`, and Python 3.9 or newer.
The build uses `clang`, `swiftc`, `lipo`, `otool`, `vtool`, and `codesign` from Xcode/macOS. It does not require
Theos, `dpkg-deb`, CydiaSubstrate, or a jailbreak package manager.

From the repository root:

```sh
python3 spotify-tweak/scripts/test_packaging.py
python3 spotify-tweak/scripts/build_deb.py --allow-unverified
python3 spotify-tweak/scripts/build_deb.py --verify spotify-tweak/packaging/out/ivlyrics-spotify-preview_0.2.0_iphoneos-arm.deb
```

The default build refuses to run without `--allow-unverified`. Outputs and intermediate files stay in
the ignored `spotify-tweak/packaging/out/` directory. `--output PATH` can select another build directory;
the caller is responsible for excluding that directory from Git.

`Core/sources.json` lists Swift source paths relative to the iOS repository root. Shared app sources
are compiled in place. The builder also includes `Core/*.swift`, `src/*.swift`, `UI/*.swift`, and
C/Objective-C/C++ sources under `src/`. `UI/Harness/` is deliberately excluded. Native files compile
to objects, then link with Swift 5 language mode into `IVLyricsSpotify`, targeting `arm64-apple-ios17.0`.

The legacy Debian architecture label is `iphoneos-arm`; the binary itself is thin **arm64**
iPhoneOS `MH_DYLIB`. The `.deb` contains:

```text
Library/MobileSubstrate/DynamicLibraries/ivLyricsSpotify.dylib
Library/MobileSubstrate/DynamicLibraries/ivLyricsSpotify.plist
```

This layout lets an external injection tool locate the payload. It does not install MobileSubstrate
or make iOS load the library automatically. The filter names the original `com.spotify.client` host;
the runtime accepts a rewritten bundle identifier but still requires the exact executable/version/ABI.

The builder verifies archive members, package identity, arm64 architecture, iPhoneOS minimum 17.0,
install name, dynamic dependencies, runtime search paths, missing jailbreak runtime symbols,
required host/UI entry points, and an ad-hoc code signature. Only Apple system frameworks/libraries and system Swift libraries
through `/usr/lib/swift` are accepted. `verification.json` records these results and source hashes,
with `host_integration_verified: false` and `spotify_playback_ui_adapter_implemented: true`.
The report also hashes the source manifest, native headers, build script, control and filter files.

An ad-hoc signature validates the built file's integrity. An injection/signing tool must still place
the dylib in the IPA, add its load command, and re-sign the resulting app for installation.
Package checks do not establish injection, launch, playback, or actual device compatibility.
