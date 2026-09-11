#!/usr/bin/env python3
"""Execute production Swift sync-fetch code with local transport/cache fixtures.

No network, credentials, private defaults, or device access. The baseline is the
released 1.3.12 source. UIKit rendering is unchanged and is not claimed here.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
current = (ROOT / "ivLyrics-IOS/LyricsRepository.swift").read_text()
baseline = subprocess.check_output(
    ["git", "show", "ae0f15f:ivLyrics-IOS/LyricsRepository.swift"], cwd=ROOT, text=True
)


def section(source, start, end):
    first = source.index(start)
    return source[first:source.index(end, first + len(start))]


# Assert the actual load and every provider path forward the same context; only
# successful live results enter it, and lifetime does not survive loadLyrics.
load = section(current, "    func loadLyrics(", "    private func lyricsCacheKey(")
assert "defer { activeSyncDataLoads.removeValue(forKey: syncDataLoad.id) }" in load
assert load.count("load: syncDataLoad") == 3
assert "syncDataLoad: syncDataLoad" in load
assert "syncDataLoad.isrc = TrackSnapshot.normalizeIsrc(isrc)" in load
assert "try Task.checkCancellation()" not in load
for start, end in [
    ("    private func shouldRevalidateCachedResult(", "    func loadLyrics("),
    ("    private func applySyncData(", "    func clearCache() {"),
    ("    func loadManualLrclibCandidate(", "    func validateSpotifyCredentials("),
]:
    # Cache clearing changed; policy, timing application and manual selection did not.
    if end in current and end in baseline:
        assert section(current, start, end) == section(baseline, start, end)
provider = section(current, "    private func loadProviderVariants(", "    private func loadLrclibVariants(")
assert provider.count("syncDataLoad: syncDataLoad") == 3
assert provider.count("load: syncDataLoad") == 2
assert "forceContributorRefresh: true" in load
assert "if !result.contributors.isEmpty" in section(current, "    private func shouldRevalidateCachedResult(", "    private func preferredIvLyricsSyncProviderId(")

transport = section(current, "    private func get(", "    private func isCancellationError(")
assert 'response.value(forHTTPHeaderField: "X-Sync-Metadata-Accepted") == "1"' in transport
assert 'response.value(forHTTPHeaderField: "X-Cache")?.uppercased() != "HIT"' in transport
prelude = r'''
import Foundation
extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
struct TrackSnapshot: Sendable {
    var title = "Test", artist = "Artist", album = "Album", trackId = "track"
    static func normalizeIsrc(_ value: String) -> String { value.trimmed.uppercased().replacingOccurrences(of: "-", with: "") }
}
struct SpotifyTrackMatch: Sendable { var title: String, artist: String, album: String, spotifyId: String }
enum AppSettings { static func lyricsProviderById(_ id: String) -> String? { ["lrclib", "paxsenix", "lyricsplus", "unison"].contains(id) ? id : nil } }
enum IvLyricsUtilities {
    static func firstNonEmpty(_ values: String?...) -> String { values.compactMap { $0?.trimmed }.first { !$0.isEmpty } ?? "" }
    static func encodeParams(_ params: [String: String]) -> String {
        var url = URLComponents(); url.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }; return url.percentEncodedQuery ?? ""
    }
}
struct SyncDataResult: Sendable, Equatable { var payload: String, provider: String }
final class FixtureCache {
    var values: [String: String] = [:], writes = 0
    func get(_ key: String) -> String { values[key] ?? "" }
    func put(_ key: String, body: String) { writes += 1; values[key] = body }
    func clear() { values.removeAll() }
    func removeByKeyPrefix(_ prefix: String) { values = values.filter { !$0.key.hasPrefix(prefix) } }
    func remove(_ key: String) { values.removeValue(forKey: key) }
}
final class MemoryFixture {
    var keys: [String] = []
    func removeAll() { keys.removeAll() }
    func removeValue(forKey key: String) { keys.removeAll { $0 == key } }
}
'''
context = section(current, "    private var activeSyncDataLoads:", "    init() {")
clear = section(current, "    func clearCache() {", "    func searchManualLrclib(")


def repo(source, name, original):
    fetch = section(source, "    private func fetchSyncData(", "    private func shouldRequestSyncDataFromOpenDb(")
    if original:
        fetch = fetch.replace("        forceContributorRefresh: Bool = false", "        load: SyncDataLoadContext,\n        forceContributorRefresh: Bool = false")
    return f"actor {name} {{\n" + context + clear + fetch + r'''
    let syncDataBase = "https://fixture.invalid/sync", syncDataRequestVersion = "20260701"
    let syncDataResponseCache = FixtureCache(), diskCache = FixtureCache(), cache = MemoryFixture()
    private var loads: [String: SyncDataLoadContext] = [:]
    var requests: [[String: String]] = [], body = "live-public", failures = 0, parseFailures = 0
    var blocked = false, continuation: CheckedContinuation<Void, Never>?
    var openDbAvailable = true, bypass = false, metadataAck = false
    func begin(_ id: String, trackKey: String = "track", isrc: String = "USABC1234567") {
        let load = SyncDataLoadContext(trackKey: trackKey, isrc: isrc)
        loads[id] = load; activeSyncDataLoads[load.id] = load
    }
    func end(_ id: String) { if let load = loads.removeValue(forKey: id) { activeSyncDataLoads.removeValue(forKey: load.id) } }
    func consume(_ id: String, isrc: String = "USABC1234567", provider: String = "lrclib", track: TrackSnapshot = .init(), refresh: Bool = false) async -> SyncDataResult? {
        await fetchSyncData(isrc: isrc, providerId: provider, track: track, spotifyMatch: nil, log: { _ in }, load: loads[id]!, forceContributorRefresh: refresh)
    }
    func configure(body: String? = nil, failures: Int = 0, parseFailures: Int = 0, blocked: Bool = false) {
        if let body { self.body = body }; self.failures = failures; self.parseFailures = parseFailures; self.blocked = blocked
    }
    func stats() -> (Int, Int, Int) { (requests.count, syncDataResponseCache.writes, activeSyncDataLoads.count) }
    func enableAck() { metadataAck = true }
    func requestParams() -> [[String: String]] { requests }
    func seedDisk(_ body: String) { syncDataResponseCache.values[syncDataCacheKey("USABC1234567", providerId: "lrclib")] = body }
    func release() { continuation?.resume(); continuation = nil; blocked = false }
    func waiting() -> Bool { continuation != nil }
    func get(_ url: String, headers: [String: String], onSyncMetadataAccepted: (() -> Void)? = nil) async throws -> String {
        requests.append(Dictionary(uniqueKeysWithValues: URLComponents(string: url)!.queryItems!.map { ($0.name, $0.value ?? "") }))
        if blocked { await withCheckedContinuation { continuation = $0 } }
        if failures > 0 { failures -= 1; throw URLError(.timedOut) }
        if metadataAck { onSyncMetadataAccepted?() }
        return body
    }
    func parseSyncDataResponse(_ body: String, expectedProvider: String, log: (String) -> Void, fromCache: Bool) throws -> SyncDataResult? {
        if parseFailures > 0 { parseFailures -= 1; throw URLError(.cannotParseResponse) }
        if body == "absent" { return nil }
        return .init(payload: body, provider: expectedProvider)
    }
    func redactedSyncDataResponseForPersistence(_ body: String) -> String? { body == "absent" ? body : "{\"identityRedacted\":true}" }
    func syncDataCacheKey(_ isrc: String, providerId: String) -> String { syncDataCacheKeyPrefix(isrc) + providerId }
    func syncDataCacheKeyPrefix(_ isrc: String) -> String { TrackSnapshot.normalizeIsrc(isrc) + ":" }
    func syncDataHeaders() -> [String: String] { [:] }
    func describeParams(_ params: [String: String]) -> String { "fixture" }
    func shouldBypassSyncDataServerCache(_ isrc: String) -> Bool { bypass }
    func shouldRequestSyncDataFromOpenDb(isrc: String, provider: String, log: (String) -> Void) async -> Bool { openDbAvailable }
    func isOpenDbUnavailable(log: (String) -> Void) async -> Bool { !openDbAvailable }
    func clearOpenDbCache() {}
    func markSyncDataServerCacheBypass(_ isrc: String) { bypass = true }
    func isCancellationError(_ error: Error) -> Bool { error is CancellationError || (error as? URLError)?.code == .cancelled }
}
'''

checks = r'''
@main struct Tests {
    static func main() async {
        var count = 0
        func check(_ condition: Bool, _ message: String) { count += 1; if !condition { fatalError(message) } }
        let base = BaselineRepository(), candidate = CandidateRepository()
        await base.begin("load"); await candidate.begin("load")
        let b1 = await base.consume("load", refresh: true), c1 = await candidate.consume("load", refresh: true)
        let b2 = await base.consume("load"), c2 = await candidate.consume("load")
        check(b1 == c1 && b2 == c2, "hydration/apply payload unchanged")
        check(await base.stats().0 == 2 && candidate.stats().0 == 1, "hydration plus apply Worker GET 2 to 1")
        check(await candidate.requestParams().allSatisfy { $0["metadata"] == "1" }, "remaining request still reports metadata")
        await candidate.end("load"); await candidate.begin("next")
        await candidate.configure(body: "live-private")
        check(await candidate.consume("next", refresh: true)?.payload == "live-private", "new load revalidates changed privacy")
        check(await candidate.stats().0 == 2, "identity is not retained between loads")
        for (index, provider) in ["paxsenix", "lyricsplus", "unison"].enumerated() {
            check(await candidate.consume("next", provider: provider)?.provider == provider, "provider key isolation")
            check(await candidate.stats().0 == index + 3, "one request per other provider")
        }
        var enriched = TrackSnapshot(); enriched.trackId = "later-id"; enriched.album = "Complete Album"
        _ = await candidate.consume("next", track: enriched)
        check(await candidate.stats().0 == 6, "metadata fingerprint enrichment requests again")
        check(await candidate.requestParams().last?["trackId"] == "later-id", "enriched metadata is reported")
        _ = await candidate.consume("next", isrc: "USABC1234568")
        check(await candidate.stats().0 == 7, "different ISRC does not reuse response")
        await candidate.end("next")
        check(await candidate.stats().2 == 0, "completed operation drops all live contexts")

        let ack = CandidateRepository(); await ack.begin("x"); await ack.enableAck()
        _ = await ack.consume("x", refresh: true)
        _ = await ack.consume("x", provider: "paxsenix")
        let ackParams = await ack.requestParams()
        check(ackParams[0]["metadata"] == "1" && ackParams[0]["metadata_ack"] == "1", "metadata ACK is explicitly requested")
        check(ackParams[1]["metadata"] == nil, "confirmed same metadata is omitted for another provider in same load")
        _ = await ack.consume("x", provider: "lyricsplus", track: enriched)
        check(await ack.requestParams().last?["metadata"] == "1", "changed metadata needs its own ACK")
        await ack.end("x"); await ack.begin("new")
        _ = await ack.consume("new", refresh: true)
        check(await ack.requestParams().last?["metadata"] == "1", "ACK expires with operation")
        check(await candidate.requestParams().allSatisfy { $0["metadata"] == "1" }, "missing ACK never suppresses metadata")
        let badAck = CandidateRepository(); await badAck.begin("x"); await badAck.enableAck(); await badAck.configure(parseFailures: 1)
        _ = await badAck.consume("x", refresh: true)
        _ = await badAck.consume("x", provider: "paxsenix")
        check(await badAck.requestParams().last?["metadata"] == "1", "unparseable response ACK is not reused")
        let retry = CandidateRepository(); await retry.begin("x")
        await retry.configure(failures: 1)
        check(await retry.consume("x", refresh: true) == nil, "network failure retains fallback")
        check(await retry.consume("x", refresh: true) != nil, "network failure is retryable within operation")
        check(await retry.stats().0 == 2, "failed attempt is not metadata ACK or response cache")
        let parse = CandidateRepository(); await parse.begin("x"); await parse.configure(parseFailures: 1)
        _ = await parse.consume("x", refresh: true); _ = await parse.consume("x", refresh: true)
        check(await parse.stats().0 == 2, "parse failure is retryable")
        let absent = CandidateRepository(); await absent.begin("x"); await absent.configure(body: "absent")
        _ = await absent.consume("x", refresh: true); _ = await absent.consume("x", refresh: true)
        check(await absent.stats().0 == 2, "absence does not enter positive live response cache")
        let disk = CandidateRepository(); await disk.begin("x"); await disk.seedDisk("disk-no-contributors")
        _ = await disk.consume("x"); check(await disk.stats().0 == 0, "existing reusable disk path preserved")
        _ = await disk.consume("x", refresh: true)
        check(await disk.stats().0 == 1, "disk result cannot suppress forced privacy refresh")

        for mode in ["all", "track", "isrc", "cancel"] {
            let r = CandidateRepository(); await r.begin("x"); await r.configure(blocked: true)
            let task = Task { await r.consume("x", refresh: true) }
            while !(await r.waiting()) { await Task.yield() }
            if mode == "all" { await r.clearCache() }
            if mode == "track" { await r.clearCacheForTrack("track") }
            if mode == "isrc" { await r.clearSyncDataCacheForIsrc("USABC1234567") }
            if mode == "cancel" { task.cancel() }
            await r.release()
            check(await task.value == nil, "late response invalidated by \(mode)")
            check(await r.stats().1 == 0, "late response never repopulates disk after \(mode)")
            await r.end("x"); await r.begin("fresh")
            _ = await r.consume("fresh", refresh: true)
            check(await r.stats().0 == 2, "fresh operation retries after \(mode)")
        }
        let independent = CandidateRepository(); await independent.begin("a", trackKey: "other"); await independent.begin("b", trackKey: "track")
        _ = await independent.consume("a", refresh: true)
        await independent.clearCacheForTrack("track")
        _ = await independent.consume("a", refresh: true)
        check(await independent.stats().0 == 1, "unrelated track clear preserves current operation")
        check(await independent.consume("b", refresh: true) == nil, "target track clear invalidates only target")
        let cancelled = CandidateRepository(); await cancelled.begin("a"); await cancelled.begin("b")
        let cancelTask = Task { withUnsafeCurrentTask { $0?.cancel() }; return await cancelled.consume("a", refresh: true) }
        check(await cancelTask.value == nil, "pre-cancelled consumer performs no request")
        check(await cancelled.consume("b", refresh: true) != nil, "one operation cancellation does not cancel another")
        check(await cancelled.stats().0 == 1, "other operation owns its transport")
        print("PASS \(count) Swift sync-load checks; hydration/apply GET and metadata requests 2 -> 1 (50%); next-load privacy request retained")
    }
}
'''
# Await actor reads separately: Swift's boolean operators use autoclosures.
checks = checks.replace('check(await base.stats().0 == 2 && candidate.stats().0 == 1,', 'let baselineCount = await base.stats().0, candidateCount = await candidate.stats().0\n        check(baselineCount == 2 && candidateCount == 1,')
with tempfile.TemporaryDirectory(prefix="ivlyrics-sync-load-") as temp:
    source = Path(temp) / "probe.swift"
    source.write_text(prelude + repo(baseline, "BaselineRepository", True) + repo(current, "CandidateRepository", False) + checks)
    executable = Path(temp) / "probe"
    subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
