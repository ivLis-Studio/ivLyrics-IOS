# LlamaCpp

The on-device engine for the Local AI translation provider: llama.cpp
[b11364](https://github.com/ggml-org/llama.cpp/releases/tag/b11364)
(commit 46ca246de9bb1c35269722a6240d37d9dfd79cad), using the release asset
llama-b11364-xcframework.zip (Metal) pinned by its SHA-256 checksum in Package.swift.

That xcframework contains iOS device and macOS slices only. To build for the iOS Simulator, set
IVLYRICS_LLAMA_STUB=1 for the build. For example, the CI does this:

    IVLYRICS_LLAMA_STUB=1 xcodebuild -project ivLyrics-IOS.xcodeproj -scheme ivLyrics-IOS \
        -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build

In the Xcode app, launch Xcode with the variable set (launchctl setenv IVLYRICS_LLAMA_STUB 1)
before building for a simulator. Simulator builds then show Local AI as unavailable; everything
else works as usual.

scripts/local-ai-host-check.py compiles the Swift engine wrapper against the macOS slice and
translates a few lines with a downloaded model file.

