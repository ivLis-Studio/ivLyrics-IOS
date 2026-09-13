#!/usr/bin/env python3
"""Exercise the production PiP bitmap cache; optionally compare actual UIKit pixels.

Default mode runs host Swift invalidation/copy checks without an iOS device.
--simulator UDID additionally installs an isolated test app on that simulator.
The app extracts the production static drawing and CVPixelBuffer path. Only the
moving lyric overlay is a deterministic test painter; no real playback occurs.
"""
import argparse
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
cache = (SRC / "PictureInPictureStaticFrameCache.swift").read_text()
controller = (SRC / "LyricsPictureInPictureController.swift").read_text()


def section(source, start, end):
    first = source.index(start)
    return source[first:source.index(end, first + len(start))]


host_checks = r'''
var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    if !condition() { fatalError(message) }
}
let artwork = UIImage(), blurred = UIImage()
let key = PictureInPictureStaticFrameKey(trackKey: "song", width: 4, height: 2, bytesPerRow: 24,
    title: "title", artist: "artist", showArtwork: true, orientation: "landscape",
    backgroundMode: "blur", solidColor: "#123456", artwork: artwork, blurredArtwork: blurred)
let cache = PictureInPictureStaticFrameCache()
let source = UnsafeMutableRawPointer.allocate(byteCount: 48, alignment: 16)
let target = UnsafeMutableRawPointer.allocate(byteCount: 48, alignment: 16)
defer { source.deallocate(); target.deallocate() }
for offset in 0..<48 { source.storeBytes(of: UInt8(offset * 3), toByteOffset: offset, as: UInt8.self) }
check(!cache.restore(key: key, into: target), "First frame must paint")
cache.store(key: key, from: source)
// Copy owns its bytes: later foreground painting must not mutate the cache.
source.initializeMemory(as: UInt8.self, repeating: 255, count: 48)
for _ in 0..<120 {
    check(cache.restore(key: key, into: target), "Steady frames reuse the static raster")
    check((0..<48).allSatisfy { target.load(fromByteOffset: $0, as: UInt8.self) == UInt8($0 * 3) }, "Exact BGRA bytes and row padding restored")
    target.initializeMemory(as: UInt8.self, repeating: 17, count: 48)
}
let mutations: [(inout PictureInPictureStaticFrameKey) -> Void] = [
    { $0.trackKey = "new song" }, { $0.trackKey = nil },
    { $0.width += 1 }, { $0.height += 1 }, { $0.bytesPerRow += 4 },
    { $0.title += " streamed" }, { $0.artist += " translated" },
    { $0.showArtwork.toggle() }, { $0.orientation = "portrait" },
    { $0.backgroundMode = "cover" }, { $0.solidColor = "#ABCDEF" },
    { $0.artwork = UIImage() }, { $0.artwork = nil },
    { $0.blurredArtwork = UIImage() }, { $0.blurredArtwork = nil }
]
for mutate in mutations {
    var next = key
    mutate(&next)
    check(!cache.restore(key: next, into: target), "Every static paint input invalidates")
}
cache.removeAll()
check(!cache.restore(key: key, into: target), "Track reset releases the old frame")
print("PIP_STATIC_FRAME_CACHE_PASSED assertions=\(assertions) stableFrames=120 paints=1")
'''


def run_host(work):
    source = "import Foundation\nfinal class UIImage {}\n" + cache.replace("import UIKit", "") + host_checks
    main = work / "main.swift"
    main.write_text(source)
    subprocess.run(["xcrun", "swiftc", str(main), "-o", str(work / "host-tests")], check=True)
    subprocess.run([str(work / "host-tests")], check=True)
    # The tested buffer path must keep live lyrics after the cached background.
    body = section(controller, "    private func drawFrame(into", "    private func makeSampleBuffer")
    assert body.index("staticFrameCache.store") < body.index("drawLyrics(in:")
    assert "staticFrameCache.removeAll()" in controller


def simulator_source():
    settings = (SRC / "AppSettings.swift").read_text()
    constants = "\n".join(line for line in settings.splitlines()
                          if "static let pipOrientation" in line or "static let pipBackground" in line)
    normalizers = section(settings, "    static func normalizePipOrientation", "    static func normalizePipBackgroundMode")
    normalizers += section(settings, "    static func normalizePipBackgroundMode", "\n    static func ")
    helpers = section(controller, "    private func drawStaticFrame", "    private func drawLyrics")
    helpers += section(controller, "    private func drawText(", "    private func typographyFont")
    helpers += section(controller, "    private func drawArtwork(", "    private func makePixelBuffer")
    helpers += section(controller, "    private func drawFrame(into", "    private func makeSampleBuffer")
    layout = section(controller, "    private struct PictureInPictureFrameLayout", "\n}\n\nstruct PictureInPictureKaraokeContent")
    color = controller[controller.index("private extension UIColor {"):]
    helpers = helpers.replace("private func drawStaticFrame(in rect: CGRect, context: CGContext) {",
                              "private func drawStaticFrame(in rect: CGRect, context: CGContext) { staticPaints += 1")
    prelude = r'''
import UIKit
import CoreVideo
extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
struct Track { var stableKey: String }
struct State {
    var track: Track? = Track(stableKey: "song")
    var title = "日本語 Arabic — PiP", artist = "Artist title"
    var showArtwork = true, orientation = "landscape", backgroundMode = "gradient", solidColor = "#38597A"
}
'''
    probe = r'''
@MainActor final class Probe {
    var state = State()
    var artwork: UIImage?, blurredArtwork: UIImage?
    let staticFrameCache = PictureInPictureStaticFrameCache()
    var phase: CGFloat = 0.25
    var staticPaints = 0
    func drawLyrics(in rect: CGRect) {
        // Dynamic drawing after a cache hit must preserve the CGContext state.
        UIColor.systemPink.withAlphaComponent(0.37).setFill()
        UIRectFill(rect.insetBy(dx: 4, dy: 9))
        drawText("Live lyrics 日本語 العربية", in: rect.insetBy(dx: 8, dy: 20),
                 font: .systemFont(ofSize: 22), color: .white, alignment: .center, lineLimit: 2, shadowed: true)
        UIColor.cyan.withAlphaComponent(phase).setFill()
        UIRectFill(CGRect(x: rect.minX, y: rect.midY, width: rect.width * phase, height: 4))
    }
    func pixels(width: Int, height: Int, reuse: Bool) -> Data {
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                     [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer) == kCVReturnSuccess)
        let pixelBuffer = buffer!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        CVPixelBufferGetBaseAddress(pixelBuffer)!.initializeMemory(as: UInt8.self, repeating: UInt8(phase * 127), count: height * CVPixelBufferGetBytesPerRow(pixelBuffer))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        if reuse { precondition(drawFrame(into: pixelBuffer)) }
        else {
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(context)
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            drawStaticFrame(in: rect, context: context)
            drawLyrics(in: frameLayout(in: rect).lyricsRect)
            context.flush()
            UIGraphicsPopContext()
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        var output = Data()
        for row in 0..<height {
            output.append(CVPixelBufferGetBaseAddress(pixelBuffer)!.advanced(by: row * CVPixelBufferGetBytesPerRow(pixelBuffer)).assumingMemoryBound(to: UInt8.self), count: width * 4)
        }
        return output
    }
'''
    checks = r'''
@MainActor func runPixels() -> String {
    let probe = Probe()
    func image(_ color: UIColor, opaque: Bool = true) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: 73, height: 41), format: format).image { _ in
            color.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 73, height: 41))
            UIColor.yellow.withAlphaComponent(0.5).setFill(); UIRectFill(CGRect(x: 9, y: 5, width: 34, height: 17))
        }
        return UIImage(data: image.pngData()!)!
    }
    let art = image(.systemBlue), blur = image(.systemPurple), transparent = image(.systemOrange, opaque: false)
    var comparisons = 0, cachedPathPaints = 0
    for (orientation, width, height) in [("landscape", 640, 360), ("portrait", 360, 640), ("square", 480, 480)] {
        probe.state.orientation = orientation
        for mode in ["cover", "blur", "gradient", "solid"] {
            probe.state.backgroundMode = mode
            for show in [true, false] {
                probe.state.showArtwork = show
                for images in 0..<4 {
                    // Replacements model missing artwork, network completion and blur completion.
                    probe.artwork = images == 0 ? nil : (images == 3 ? transparent : art)
                    probe.blurredArtwork = images == 2 ? blur : nil
                    for phase: CGFloat in [0.25, 0.75] {
                        probe.phase = phase
                        let expected = probe.pixels(width: width, height: height, reuse: false)
                        let beforePaints = probe.staticPaints
                        let actual = probe.pixels(width: width, height: height, reuse: true)
                        cachedPathPaints += probe.staticPaints - beforePaints
                        comparisons += 1
                        if actual != expected {
                            let repeated = probe.pixels(width: width, height: height, reuse: false)
                            let diffs = zip(actual, expected).filter { $0 != $1 }
                            let maxDiff = diffs.map { abs(Int($0) - Int($1)) }.max() ?? 0
                            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                            try! expected.write(to: docs.appendingPathComponent("expected.bgra"))
                            try! actual.write(to: docs.appendingPathComponent("actual.bgra"))
                            return "FAIL pixels: \(orientation) \(mode) show=\(show) images=\(images) phase=\(phase) bytes=\(diffs.count) maxDiff=\(maxDiff) baselineStable=\(expected == repeated)"
                        }
                    }
                }
            }
        }
    }
    for index in 0..<4 {
        probe.state.track = Track(stableKey: "song\(index)")
        probe.state.title = "Changed title \(index)"
        probe.state.artist = "Changed artist \(index)"
        probe.state.solidColor = index % 2 == 0 ? "#abcdef" : "invalid"
        let expected = probe.pixels(width: 480, height: 480, reuse: false)
        let beforePaints = probe.staticPaints
        let actual = probe.pixels(width: 480, height: 480, reuse: true)
        cachedPathPaints += probe.staticPaints - beforePaints
        comparisons += 1
        if actual != expected { return "FAIL changed metadata/colors" }
    }
    if cachedPathPaints != 112 { return "FAIL expected 112 static paints including transparent fallback, got \(cachedPathPaints)" }
    return "PIP_STATIC_PIXELS_PASSED staticPaints=\(comparisons)->\(cachedPathPaints) comparisons=\(comparisons) changedPixelBytes=0 UIKit=real CVPixelBuffer=real physicalDevice=false"
}
final class Delegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let report = runPixels()
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("result.txt")
        try! report.write(to: url, atomically: true, encoding: .utf8)
        return true
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(Delegate.self))
'''
    return prelude + "enum AppSettings {\n" + constants + "\n" + normalizers + "}\n" + cache + color + probe + helpers + layout + "}\n" + checks


def run_simulator(work, device):
    app = work / "PiPCacheRegression.app"
    app.mkdir(exist_ok=True)
    main = work / "simulator.swift"
    main.write_text(simulator_source())
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    arch = subprocess.check_output(["uname", "-m"], text=True).strip()
    subprocess.run(["xcrun", "swiftc", "-sdk", sdk, "-target", f"{arch}-apple-ios17.0-simulator",
                    str(main), "-o", str(app / "PiPCacheRegression")], check=True)
    bundle = "kr.ivlis.tests.pipstaticcache"
    (app / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": bundle, "CFBundleExecutable": "PiPCacheRegression",
        "CFBundleName": "PiPCacheRegression", "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
        "MinimumOSVersion": "17.0", "UIDeviceFamily": [1, 2], "UILaunchScreen": {},
    }))
    subprocess.run(["xcrun", "simctl", "install", device, str(app)], check=True)
    container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", device, bundle, "data"], text=True).strip())
    report = container / "Documents/result.txt"
    report.unlink(missing_ok=True)
    subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", device, bundle], check=True)
    for _ in range(120):
        if report.exists():
            result = report.read_text()
            print(result)
            (work / "pixel-result.txt").write_text(result + "\n")
            assert result.startswith("PIP_STATIC_PIXELS_PASSED"), result
            return
        time.sleep(0.5)
    raise RuntimeError("Simulator did not write a pixel comparison result within 60 seconds")


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--simulator", help="Booted simulator UDID for real UIKit pixel checks")
parser.add_argument("--output-dir", type=Path, help="Preserve generated probe source and results")
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix="ivlyrics-pip-static-") as temporary:
    work = args.output_dir or Path(temporary)
    work.mkdir(parents=True, exist_ok=True)
    run_host(work)
    if args.simulator:
        run_simulator(work, args.simulator)
