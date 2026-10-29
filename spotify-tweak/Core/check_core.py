#!/usr/bin/env python3
"""Compile original Swift sources and run offline core/ObjC-bridge fixtures.

This never reads an IPA, contacts a provider, modifies Spotify, or uses the
user's imported lyrics. All persistence is under a temporary directory.
"""
from pathlib import Path
import json
import subprocess
import tempfile

CORE = Path(__file__).resolve().parent
ROOT = CORE.parents[1]
manifest = json.loads((CORE / "sources.json").read_text())
sources = [ROOT / name for name in manifest["sources"]]
assert all(path.is_file() and path.is_relative_to(ROOT) for path in sources)
runtime = ROOT / "spotify-tweak/src/Runtime.swift"
checks = r'''
import Foundation

private actor Gate {
    var calls: [String] = []
    private var pending: CheckedContinuation<Void, Never>?
    func fetch(_ track: TrackSnapshot) async throws -> LyricsPlusProvider.FetchOutcome? {
        calls.append(track.title)
        if track.title == "Slow" {
            // Deliberately ignores cancellation until released: generation checks
            // must still reject a late provider result.
            await withCheckedContinuation { pending = $0 }
        }
        return try LyricsPlusProvider.parse(data: Data("{\"type\":\"Line\",\"lyrics\":[{\"time\":1000,\"duration\":2000,\"text\":\"Provider fixture\"}]}".utf8), durationMs: track.durationMs)
    }
    func release() { pending?.resume(); pending = nil }
}

@MainActor private final class Reply {
    var count = 0
    var value: String?
    var error: NSError?
    func receive(_ value: String?, _ error: NSError?) {
        count += 1
        precondition(count == 1, "A public completion fired more than once")
        self.value = value; self.error = error
    }
}

@main private struct Checks {
    @MainActor static func main() async throws {
        var assertions = 0
        func check(_ value: Bool, _ message: String) {
            assertions += 1
            precondition(value, message)
        }
        func wait(_ condition: () async -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !(await condition()) {
                precondition(ProcessInfo.processInfo.systemUptime < deadline, "Fixture timed out")
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        func decoded(_ document: IVLCoreDocument) throws -> LyricsResult {
            try JSONDecoder().decode(LyricsResult.self, from: document.lyricsJSON)
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let storage = root.appendingPathComponent("isolated")
        let first = root.appendingPathComponent("first.lrc")
        let second = root.appendingPathComponent("second.lrc")
        try (Data([0xff, 0xfe]) + "[00:01]첫 줄\n[00:02]Second".data(using: .utf16LittleEndian)!).write(to: first)
        try Data("[00:03]Replacement".utf8).write(to: second)
        let track = IVLCoreTrack(title: "Song", artist: "Artist", spotifyID: "5RCOXpwf6rpZi6HGRACY3S", durationMs: 4000)
        let other = IVLCoreTrack(title: "Other", artist: "Artist", durationMs: 5000)
        let slow = IVLCoreTrack(title: "Slow", artist: "Artist", durationMs: 5000)
        let gate = Gate()
        let loader = IVLCoreLoader(storageDirectory: storage, fetchLyrics: { try await gate.fetch($0) })
        check(track.trackKey == "spotify:5RCOXpwf6rpZi6HGRACY3S", "Original track identity is retained")
        check(try await loader.load(track: track) == nil, "Default load is local only")
        check(await gate.calls.isEmpty, "Construction and local-only lookup never start a provider")
        let imported = try await loader.importLocalFile(first, track: track)
        check(imported.trackKey == track.trackKey && imported.providerID == "local" && imported.lineCount == 2, "Import returns original model JSON with captured identity")
        check(try decoded(imported).lines.first?.text == "첫 줄", "UTF16 source is decoded by the original parser")
        check(try decoded(imported).lines.last?.endTimeMs == 4000, "Original LRC timing survives the boundary")
        let loaded = try await loader.load(track: track, allowNetwork: true)!
        let callsAfterLocal = await gate.calls
        check(try decoded(loaded).lines.count == 2 && callsAfterLocal.isEmpty, "Local lyrics override optional network lookup")
        let restarted = IVLCoreLoader(storageDirectory: storage)
        check(try await restarted.load(track: track)?.providerID == "local", "Imports survive loader recreation")
        try loader.removeLocalLyrics(track: track)
        check(try await restarted.load(track: track) == nil, "Removal is visible across instances")
        let old = try loader.reserveLocalImport(track: track)
        let latest = try restarted.reserveLocalImport(track: track)
        _ = try await restarted.importLocalFile(second, intent: latest)
        do { _ = try await loader.importLocalFile(first, intent: old); preconditionFailure("Stale import committed") }
        catch { check(error is CancellationError, "Invocation order survives reversed async execution") }
        check(try decoded(await restarted.load(track: track)!).lines.first?.text == "Replacement", "Latest import wins")
        let removed = try loader.reserveLocalImport(track: track)
        try restarted.removeLocalLyrics(track: track)
        do { _ = try await loader.importLocalFile(first, intent: removed); preconditionFailure("Removed import was resurrected") }
        catch { check(error is CancellationError, "Removal invalidates a synchronously reserved import") }
        check(try await loader.load(track: track) == nil, "Removed lyrics remain absent")
        let network = try await loader.load(track: other, allowNetwork: true)!
        let networkResult = try decoded(network)
        check(network.providerID == "lyricsplus" && networkResult.lines.first?.text == "Provider fixture", "Opt-in calls the provider adapter and preserves its result")

        let oldLoad = Task { try await loader.load(track: slow, allowNetwork: true) }
        try await wait { await gate.calls.contains("Slow") }
        let newestLoad = try await loader.load(track: other, allowNetwork: true)
        await gate.release()
        do { _ = try await oldLoad.value; preconditionFailure("Old track published a late result") }
        catch { check(error is CancellationError, "New track rejects old provider completion even when provider ignores cancellation") }
        check(newestLoad?.trackKey == other.trackKey, "Newest track result survives")

        let independentGate = Gate()
        let independent = IVLCoreLoader(storageDirectory: storage, fetchLyrics: { try await independentGate.fetch($0) })
        let independentLoad = Task { try await independent.load(track: slow, allowNetwork: true) }
        try await wait { await independentGate.calls.contains("Slow") }
        let differentTrackImport = try independent.reserveLocalImport(track: track)
        _ = try await independent.importLocalFile(first, intent: differentTrackImport)
        try independent.removeLocalLyrics(track: track)
        await independentGate.release()
        check(try await independentLoad.value?.trackKey == slow.trackKey, "Import/removal for A must not cancel B's active load")

        let cancelGate = Gate()
        let cancellable = IVLCoreLoader(storageDirectory: storage, fetchLyrics: { try await cancelGate.fetch($0) })
        let cancelled = Task { try await cancellable.load(track: slow, allowNetwork: true) }
        try await wait { await cancelGate.calls.contains("Slow") }
        cancelled.cancel()
        await cancelGate.release()
        do { _ = try await cancelled.value; preconditionFailure("Parent cancellation returned lyrics") }
        catch { check(error is CancellationError, "Parent cancellation is propagated") }

        // Execute the actual Objective-C-visible bridge, with isolated storage.
        let bridge = IVLyricsSpotifyBridge(loader: loader)
        check(!IVLyricsSpotifyBridge.hostAdapterAvailable, "A compiled bridge does not claim Spotify integration")
        let json = "{\"title\":\"Song\",\"artist\":\"Artist\",\"spotifyID\":\"5RCOXpwf6rpZi6HGRACY3S\",\"durationMs\":4000}"
        for invalid in ["", "{}", "{\"title\":\"\",\"artist\":\"Artist\"}", String(repeating: "x", count: 65537)] {
            let response = Reply()
            bridge.loadTrackJSON(invalid, allowNetwork: false, completion: response.receive)
            check(response.count == 1 && response.error != nil, "Invalid or oversized JSON is rejected once")
        }
        let importReply = Reply()
        bridge.importFileURL(first, trackJSON: json, completion: importReply.receive)
        try await wait { importReply.count == 1 }
        check(importReply.error == nil && importReply.value?.contains("첫 줄") == true, "Public import returns valid lyrics JSON")
        let loadReply = Reply()
        bridge.loadTrackJSON(json, allowNetwork: false, completion: loadReply.receive)
        try await wait { loadReply.count == 1 }
        check(loadReply.error == nil && loadReply.value?.contains("첫 줄") == true, "Public load sees the local override")
        let removeReply = Reply()
        bridge.removeLocalLyricsForTrackJSON(json) { removeReply.receive(nil, $0) }
        check(removeReply.count == 1 && removeReply.error == nil, "Public removal completes synchronously")
        check(try await restarted.load(track: track) == nil, "Public removal persists")
        let obsoleteImport = Reply()
        bridge.importFileURL(first, trackJSON: json, completion: obsoleteImport.receive)
        let newerRemoval = Reply()
        bridge.removeLocalLyricsForTrackJSON(json) { newerRemoval.receive(nil, $0) }
        try await wait { obsoleteImport.count == 1 }
        check(obsoleteImport.error != nil && newerRemoval.count == 1, "Remove wins even before the import task starts")
        check(try await loader.load(track: track) == nil, "The bridge cannot resurrect removed lyrics")
        let firstReply = Reply(), secondReply = Reply()
        bridge.importFileURL(first, trackJSON: json, completion: firstReply.receive)
        bridge.importFileURL(second, trackJSON: json, completion: secondReply.receive)
        try await wait { firstReply.count == 1 && secondReply.count == 1 }
        check(firstReply.error != nil && secondReply.error == nil, "Bridge import order is reserved before async scheduling")
        check(try decoded(await loader.load(track: track)!).lines.first?.text == "Replacement", "Bridge keeps the latest selected file")

        let bridgeGate = Gate()
        let bridgeLoader = IVLCoreLoader(storageDirectory: root.appendingPathComponent("bridge-cancel"), fetchLyrics: { try await bridgeGate.fetch($0) })
        let cancelledBridge = IVLyricsSpotifyBridge(loader: bridgeLoader)
        let cancellationReply = Reply()
        cancelledBridge.loadTrackJSON("{\"title\":\"Slow\",\"artist\":\"Artist\"}", allowNetwork: true, completion: cancellationReply.receive)
        try await wait { await bridgeGate.calls.contains("Slow") }
        cancelledBridge.cancelLoading()
        await bridgeGate.release()
        try await wait { cancellationReply.count == 1 }
        check(cancellationReply.value == nil && cancellationReply.error != nil, "Public cancellation finishes once without publishing stale data")

        let changingGate = Gate()
        let changingLoader = IVLCoreLoader(storageDirectory: root.appendingPathComponent("bridge-edits"), fetchLyrics: { try await changingGate.fetch($0) })
        let changingBridge = IVLyricsSpotifyBridge(loader: changingLoader)
        let retainedLoad = Reply()
        let slowJSON = "{\"title\":\"Slow\",\"artist\":\"Artist\",\"durationMs\":5000}"
        changingBridge.loadTrackJSON(slowJSON, allowNetwork: true, completion: retainedLoad.receive)
        try await wait { await changingGate.calls.contains("Slow") }
        let unrelatedImport = Reply()
        changingBridge.importFileURL(first, trackJSON: json, completion: unrelatedImport.receive)
        try await wait { unrelatedImport.count == 1 }
        let unrelatedRemoval = Reply()
        changingBridge.removeLocalLyricsForTrackJSON(json) { unrelatedRemoval.receive(nil, $0) }
        await changingGate.release()
        try await wait { retainedLoad.count == 1 }
        check(unrelatedImport.error == nil && unrelatedRemoval.error == nil, "Unrelated track edits complete independently")
        check(retainedLoad.error == nil && retainedLoad.value?.contains("Provider fixture") == true, "Bridge edits for A preserve B's pending result")

        let replacedLoad = Reply()
        changingBridge.loadTrackJSON(slowJSON, allowNetwork: true, completion: replacedLoad.receive)
        try await wait { await changingGate.calls.count == 2 }
        let replacingImport = Reply()
        changingBridge.importFileURL(second, trackJSON: slowJSON, completion: replacingImport.receive)
        try await wait { replacingImport.count == 1 }
        await changingGate.release()
        try await wait { replacedLoad.count == 1 }
        check(replacingImport.error == nil && replacingImport.value?.contains("Replacement") == true, "Same-track import becomes the new source")
        check(replacedLoad.value == nil && replacedLoad.error != nil, "Same-track mutation rejects the older provider result at the public boundary")
        print("CORE_FOUNDATION_CHECKS_PASSED assertions=\(assertions); no Spotify/IPA/device integration tested")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="ivlyrics-tweak-core-") as directory:
    work = Path(directory)
    fixture = work / "CoreChecks.swift"
    fixture.write_text(checks)
    base = ["xcrun", "swiftc", "-swift-version", manifest["swift_version"], "-parse-as-library"]
    all_sources = [*map(str, sources), str(runtime)]
    subprocess.run([*base, "-module-name", "IVLyricsSpotify", "-emit-module", "-emit-library",
                    *all_sources, "-emit-module-path", str(work / "IVLyricsSpotify.swiftmodule"),
                    "-o", str(work / "libIVLyricsSpotify.dylib")], check=True)
    client = work / "PublicClient.swift"
    client.write_text('''import Foundation
import IVLyricsSpotify
func inspect(_ directory: URL) async throws -> Data? {
    let loader = IVLCoreLoader(storageDirectory: directory)
    let track = IVLCoreTrack(title: "Song", artist: "Artist")
    return try await loader.load(track: track)?.lyricsJSON
}
''')
    subprocess.run([*base, "-typecheck", "-I", str(work), str(client)], check=True)
    binary = work / "checks"
    subprocess.run([*base, *all_sources, str(fixture), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(work)], check=True, timeout=30)
