// swift-tools-version: 5.9
import Foundation
import PackageDescription

// llama.cpp b11364 (commit 46ca246de9bb1c35269722a6240d37d9dfd79cad) for the Local AI provider:
// the release's Metal xcframework, pinned by its SHA-256 checksum.
//
// That xcframework has iOS device and macOS slices but no iOS Simulator slice, and Xcode refuses to
// build a target that links it for the Simulator. Simulator builds therefore set
// IVLYRICS_LLAMA_STUB=1, which swaps in an empty stand-in; Local AI then reports that the
// on-device engine is unavailable. Device builds and archives use the pinned binary.
let simulatorStub = ProcessInfo.processInfo.environment["IVLYRICS_LLAMA_STUB"] == "1"

let package = Package(
    name: "LlamaCpp",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "LlamaCpp", targets: [simulatorStub ? "LlamaCppUnavailable" : "llama"])
    ],
    targets: simulatorStub
        ? [.target(name: "LlamaCppUnavailable", path: "Unavailable")]
        : [
            .binaryTarget(
                name: "llama",
                url: "https://github.com/ggml-org/llama.cpp/releases/download/b11364/llama-b11364-xcframework.zip",
                checksum: "307aa390240aadf904282cb40b2dc0bee5091b24b035af39d661052691035c53"
            )
        ]
)

