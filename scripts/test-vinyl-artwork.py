#!/usr/bin/env python3
"""Run the production vinyl hydration path with controlled out-of-order completions.

Uses string assets instead of UIKit pixels and deliberately completes cancelled
fetches. No network, simulator or rendered animation is involved.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
vinyl = (SRC / "VinylPlayerModeView.swift").read_text()
models = (SRC / "Models.swift").read_text()


def declaration(prefix):
    start = vinyl.index(prefix)
    end = vinyl.index("{", start) + 1
    depth = 1
    while depth:
        depth += (vinyl[end] == "{") - (vinyl[end] == "}")
        end += 1
    return vinyl[start:end].replace("private ", "")


transition = declaration("private func synchronizeTrack(")
assert "await VinylArtworkAccent.asset" not in transition
assert transition.index("incomingTrack = next") < transition.index("Task { @MainActor")
assert "incomingTrack = current" in declaration("private func refreshCurrentTrackAsset()")
track_change = vinyl[vinyl.index("        .onChange(of: model.currentTrack) {"):vinyl.index("        .onChange(of: currentResolvedLabels)")]
assert "refreshCurrentTrackAsset()" in track_change
assert "timeoutInterval: 0.32" in vinyl
disappear = vinyl[vinyl.index("        .onDisappear {"):vinyl.index("    @ViewBuilder")]
assert "artworkTasks.values.forEach { $0.cancel() }" in disappear and "artworkRequests.removeAll()" in disappear

code = r'''
import Foundation
typealias Color = String
typealias UIImage = String
extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
'''
# Verify SwiftUI's onChange equality contract using the actual production model,
# alongside the minimal string-asset model used by the controlled request probe.
code += models[models.index("struct TrackSnapshot:"):models.index("struct LyricsLine:")].replace("TrackSnapshot", "ProductionTrackSnapshot")
code += r'''
struct TrackSnapshot {
    var stableKey: String
    var artworkURL: URL?
    var title = ""
}
@MainActor final class Model { var currentTrack: TrackSnapshot? }
@MainActor enum VinylArtworkAccent {
    struct Asset { var color: Color; var image: UIImage? }
    static var completions: [CheckedContinuation<Asset, Never>?] = []
    static func fallbackColor(key: String) -> Color { "fallback:" + key }
    static func asset(for track: TrackSnapshot) async -> Asset {
        await withCheckedContinuation { completions.append($0) }
    }
    static func complete(_ index: Int, image: String?) {
        let continuation = completions[index]!
        completions[index] = nil
        continuation.resume(returning: Asset(color: image.map { "accent:" + $0 } ?? "fallback", image: image))
    }
}
@MainActor final class ArtworkProbe {
    var displayedTrack: TrackSnapshot?
    var incomingTrack: TrackSnapshot?
    let model = Model()
'''
for name in ["accentColors", "artworkImages", "artworkKeys", "artworkRequests", "artworkTasks", "artworkAssets"]:
    code += next(line for line in vinyl.splitlines() if f"private var {name}" in line).replace("@State private ", "") + "\n"
code += declaration("private func loadAccent(for") + "\n"
code += declaration("private func refreshCurrentTrackAsset()") + "\n"
code += declaration("private func pruneArtworkRequests()") + "\n}\n"
code += r'''
@main struct Checks {
    @MainActor static func main() async {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            count += 1
            if !value() { fatalError(label) }
        }
        func drain(_ condition: () -> Bool) async {
            for _ in 0..<10000 {
                if condition() { return }
                await Task.yield()
            }
            fatalError("Controlled artwork task did not complete")
        }
        let oldURL = URL(string: "https://fixture.invalid/old")!
        let newURL = URL(string: "https://fixture.invalid/new")!
        let old = TrackSnapshot(stableKey: "A", artworkURL: oldURL)
        let updated = TrackSnapshot(stableKey: "A", artworkURL: newURL)
        let probe = ArtworkProbe()
        probe.displayedTrack = old
        probe.model.currentTrack = old
        probe.loadAccent(for: old)
        await drain { VinylArtworkAccent.completions.count == 1 }
        probe.loadAccent(for: old)
        check(VinylArtworkAccent.completions.count == 1 && probe.artworkTasks.count == 1, "Same in-flight URL is deduplicated")
        probe.displayedTrack = updated
        probe.model.currentTrack = updated
        probe.loadAccent(for: updated)
        check(probe.artworkImages["A"] == nil && probe.accentColors["A"] == "fallback:A", "Changed cover uses fallback immediately")
        await drain { VinylArtworkAccent.completions.count == 2 }
        VinylArtworkAccent.complete(1, image: "new")
        await drain { probe.artworkImages["A"] == "new" }
        VinylArtworkAccent.complete(0, image: "stale")
        for _ in 0..<20 { await Task.yield() }
        check(probe.artworkImages["A"] == "new" && probe.accentColors["A"] == "accent:new", "Cancelled old response cannot overwrite a newer cover")
        check(probe.artworkTasks.isEmpty, "Completed task is released")
        probe.loadAccent(for: updated)
        check(VinylArtworkAccent.completions.count == 2 && probe.artworkImages["A"] == "new", "Successful cached artwork avoids another fetch")

        // A -> old URL -> cached new URL: the suspended old request must lose.
        probe.displayedTrack = old
        probe.loadAccent(for: old)
        await drain { VinylArtworkAccent.completions.count == 3 }
        probe.displayedTrack = updated
        probe.loadAccent(for: updated)
        VinylArtworkAccent.complete(2, image: nil)
        for _ in 0..<20 { await Task.yield() }
        check(probe.artworkImages["A"] == "new", "Cancelled fallback cannot replace the restored cached result")

        let incoming = TrackSnapshot(stableKey: "B", artworkURL: oldURL)
        let hydrated = TrackSnapshot(stableKey: "B", artworkURL: newURL, title: "Hydrated title")
        probe.incomingTrack = incoming
        probe.model.currentTrack = incoming
        probe.loadAccent(for: incoming)
        await drain { VinylArtworkAccent.completions.count == 4 }
        let productionBefore = ProductionTrackSnapshot(title: "Original title", artist: "Artist",
            mediaId: "spotify:track:0123456789012345678901", durationMs: 60000, artworkURL: oldURL)
        var productionAfter = productionBefore
        productionAfter.title = "Title-only hydration"
        check(productionAfter.stableKey == productionBefore.stableKey && productionAfter.artworkURL == productionBefore.artworkURL,
              "Title-only Spotify hydration keeps track and cover identity")
        check(productionBefore != productionAfter, "Production equality triggers currentTrack onChange for title-only hydration")
        probe.model.currentTrack = TrackSnapshot(stableKey: "B", artworkURL: oldURL, title: productionAfter.title)
        probe.refreshCurrentTrackAsset()
        check(probe.incomingTrack?.title == "Title-only hydration" && probe.incomingTrack?.artworkURL == oldURL,
              "Incoming metadata refresh does not require a cover URL change")
        check(VinylArtworkAccent.completions.count == 4, "Title-only hydration reuses the in-flight cover request")
        probe.model.currentTrack = hydrated
        probe.refreshCurrentTrackAsset()
        check(probe.incomingTrack?.title == "Hydrated title" && probe.incomingTrack?.artworkURL == newURL,
              "Incoming metadata and artwork snapshot refresh during the transition")
        await drain { VinylArtworkAccent.completions.count == 5 }
        VinylArtworkAccent.complete(3, image: "old-B")
        VinylArtworkAccent.complete(4, image: "new-B")
        await drain { probe.artworkImages["B"] == "new-B" }
        check(probe.artworkImages["A"] == "new", "Incoming hydration leaves outgoing artwork attached to its own record")
        check(probe.artworkImages["B"] == "new-B", "Incoming URL hydration wins during the transition")

        let missing = TrackSnapshot(stableKey: "C", artworkURL: oldURL)
        probe.incomingTrack = missing
        probe.model.currentTrack = missing
        probe.loadAccent(for: missing)
        await drain { VinylArtworkAccent.completions.count == 6 }
        VinylArtworkAccent.complete(5, image: nil)
        await drain { probe.artworkTasks["C"] == nil }
        check(probe.artworkImages["C"] == nil, "Failure keeps fallback instead of a broken image")
        probe.loadAccent(for: missing)
        await drain { VinylArtworkAccent.completions.count == 7 }
        check(VinylArtworkAccent.completions.count == 7, "Failure is not cached permanently")
        probe.incomingTrack = nil
        probe.model.currentTrack = updated
        probe.pruneArtworkRequests()
        VinylArtworkAccent.complete(6, image: "retired-C")
        for _ in 0..<20 { await Task.yield() }
        check(probe.artworkImages["C"] == nil && probe.artworkTasks["C"] == nil, "Retired records cancel work and reject late completions")
        check(probe.artworkImages["A"] == "new" && probe.artworkImages["B"] == nil, "Only visible record images remain retained")

        // Replay the final 96ms: the new record has already committed, but both
        // snapshots still exist. Cleanup retires incoming before its fetch ends.
        let late = ArtworkProbe()
        let committed = TrackSnapshot(stableKey: "late", artworkURL: oldURL, title: "Before hydration")
        late.displayedTrack = committed
        late.incomingTrack = committed
        late.model.currentTrack = committed
        late.loadAccent(for: committed)
        await drain { VinylArtworkAccent.completions.count == 8 }
        VinylArtworkAccent.complete(7, image: "late-old")
        await drain { late.artworkImages["late"] == "late-old" }
        var lateHydration = TrackSnapshot(stableKey: "late", artworkURL: newURL, title: "Cover hydration")
        late.model.currentTrack = lateHydration
        late.refreshCurrentTrackAsset()
        check(late.displayedTrack?.artworkURL == newURL && late.incomingTrack?.artworkURL == newURL,
              "Late handoff cover hydration updates both matching snapshots")
        check(late.artworkImages["late"] == nil, "The old cover is retired while its replacement is pending")
        await drain { VinylArtworkAccent.completions.count == 9 }
        lateHydration.title = "Late title-only hydration"
        late.model.currentTrack = lateHydration
        late.refreshCurrentTrackAsset()
        check(late.displayedTrack?.title == lateHydration.title && late.incomingTrack?.title == lateHydration.title,
              "Late title-only hydration updates both matching snapshots")
        check(VinylArtworkAccent.completions.count == 9, "Late title-only hydration reuses the pending cover request")
        late.incomingTrack = nil
        late.pruneArtworkRequests()
        check(late.displayedTrack?.artworkURL == newURL && late.displayedTrack?.title == lateHydration.title,
              "Retiring incoming preserves the latest committed cover URL and title")
        VinylArtworkAccent.complete(8, image: "late-new")
        await drain { late.artworkTasks["late"] == nil }
        check(late.artworkImages["late"] == "late-new" && late.accentColors["late"] == "accent:late-new",
              "Cover completion after incoming cleanup passes the visible URL guard and stays retained")
        late.refreshCurrentTrackAsset()
        check(VinylArtworkAccent.completions.count == 9 && late.artworkImages["late"] == "late-new",
              "The completed handoff keeps its successful cached artwork")

        // URL ABA must use request identity, not only URL equality.
        var requests = VinylArtworkRequests()
        let key = VinylArtworkRequests.Key(trackKey: "A", artworkURL: oldURL)
        let first = requests.begin(key: key)!
        requests.cancel(trackKey: "A")
        let retry = requests.begin(key: key)!
        check(!requests.finish(first) && requests.finish(retry), "Same URL after cancellation still rejects its previous generation")
        let pending = requests.begin(key: key)!
        requests.removeAll()
        check(!requests.finish(pending), "Closing vinyl mode invalidates every pending generation")
        print("VINYL_ARTWORK_PASSED assertions=\(count) controlledFetches=\(VinylArtworkAccent.completions.count)")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-ios-artwork-") as directory:
    work = Path(directory)
    main = work / "checks.swift"
    main.write_text(code)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(SRC / "BoundedLRUCache.swift"), str(SRC / "VinylMotionPolicy.swift"), str(main), "-o", str(work / "checks")], check=True)
    subprocess.run([str(work / "checks")], check=True, timeout=30)
