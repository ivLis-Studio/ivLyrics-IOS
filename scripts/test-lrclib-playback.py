#!/usr/bin/env python3
"""Run optimized production Swift lookup, HTTP, sync, persistence and cache code.

URLProtocol supplies synthetic responses to real URLSession requests. No public
service, Spotify credentials, or user lyric cache is used. Only unrelated app
dependencies are replaced; matching/ranking and the full host stages are copied
unchanged from the shipping source, alongside the real parser and sync applier.
"""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import plistlib
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
repo = (SRC / "LyricsRepository.swift").read_text()
settings = (SRC / "AppSettings.swift").read_text()
models = (SRC / "Models.swift").read_text()
ats = plistlib.loads((SRC / "Info.plist").read_bytes())["NSAppTransportSecurity"]
assert not any(key.startswith("NSAllowsArbitraryLoads") and value for key, value in ats.items())
assert set(ats["NSExceptionDomains"]) == {"10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "::1/128", "fc00::/7", "fe80::/10"}
assert all(value == {"NSExceptionAllowsInsecureHTTPLoads": True} for value in ats["NSExceptionDomains"].values())


def section(source, start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin + len(start))]


# The defaults property, setter, migration, cloud whitelist/merge/export and
# provider cache signature execute the same statements used by AppSettings.
settings_code = """
final class AppSettings: ObservableObject {
    static let defaultLyricsProviderOrder = ["lrclib", "paxsenix", "lyricsplus", "unison"]
    static let lyricsTypeKaraoke = "karaoke", lyricsTypeSynced = "synced", lyricsTypePlain = "plain"
    static func normalizedLyricsProviderOrder(_ values: [String]) -> [String] { values + defaultLyricsProviderOrder.filter { !values.contains($0) } }
    private let defaults: UserDefaults
    private var isBootstrapping = false
"""
settings_code += next(line for line in settings.splitlines() if "@Published private(set) var lrclibCustomEndpoint:" in line) + "\n"
settings_code += section(settings, "    private static let cloudSettingKeys:", "    static let lyricsProviders:")
settings_code += "    init(defaults: UserDefaults) { self.defaults = defaults\n"
settings_code += section(settings, "        let storedLrclibEndpoint =", "        aiProviderOrder =") + "    }\n"
settings_code += section(settings, "    @discardableResult\n    func setLrclibCustomEndpoint(", "    func moveLyricsProvider(")
settings_code += section(settings, "    private func set(_ key: String, _ value: String)", "    private func setSecure(")
settings_code += section(settings, "    func exportCloudSettings()", "    func importCloudSettings(")
settings_code += "    func importCloudSettings(_ values: [String: Any]) {\n"
settings_code += section(settings, "        for key in Self.cloudSettingKeys {", "        let loaded = AppSettings(defaults: defaults)")
settings_code += "        let loaded = AppSettings(defaults: defaults)\n        lrclibCustomEndpoint = loaded.lrclibCustomEndpoint\n    }\n"
settings_code += """
    struct Snapshot: Sendable {
        var lrclibCustomEndpoint = "", uiLang = "en"
        var lyricsProviderOrder = AppSettings.defaultLyricsProviderOrder
        var lyricsProviderEnabled: [String: Bool] = [:]
        var lyricsProviderTypes: [String: [String: Bool]] = [:]
        var preferSyncDataProvider = true, preferLyricsTypeOverProviderOrder = true
"""
settings_code += section(settings, "        func isLyricsTypeEnabled(", "        var enabled: Bool {") + "    }\n}\n"

production = "import Foundation\nimport Combine\n" + settings_code
production += models[:models.index("enum AppStatus:")]
production += section(repo, "private final class LrclibCandidate", "private struct SpotifyTokenResponse")
production += """
// The on-disk implementation is real; its root/pruning policy is isolated here.
enum LyricsDiskCachePolicy {
    static let maxAgeMs: Int64 = 31_536_000_000
    static var rootDirectory: URL { URL(fileURLWithPath: CommandLine.arguments[1]) }
    static let lock = NSRecursiveLock()
    static func lockFileAccess() { lock.lock() }
    static func unlockFileAccess() { lock.unlock() }
    static func prune() {}
}
"""
disk = (SRC / "DiskCaches.swift").read_text()
production += disk[disk.index("nonisolated final class LyricsDiskCache:"):]
production += "\nprivate actor PlaybackProbe {\n"
production += section(repo, "    private struct ProviderVariants", "    private var cache =")
production += section(repo, "    private var activeSyncDataLoads:", "    init() {")
production += """
    private let lrclibBase = LrclibEndpoint.officialBase
    private let networkRequestTimeout: TimeInterval = 47, lrclibSignatureTimeout: TimeInterval = 18
    private let durationToleranceSeconds = 15.0, syncedFallbackScoreWindow = 0.50
    private let syncedFallbackMinTitleScore = 0.78, syncedFallbackMinArtistScore = 0.45
    private let lrclibClient: LrclibHTTPClient
    private var cache = BoundedLRUCache<String, LyricsResult>(capacity: 10)
    private let diskCache = LyricsDiskCache(namespace: "base_lyrics", maxEntries: 10)
    private let syncDataResponseCache = RawResponseDiskCache(namespace: "sync_data", maxEntries: 10)
    private var openDbClears = 0
    init(client: LrclibHTTPClient) { lrclibClient = client }
    private func ui(_ key: String, settings: AppSettings.Snapshot) -> String { key }
    private func clearOpenDbCache() { openDbClears += 1 }
    private func markSyncDataServerCacheBypass(_ isrc: String) {}
    private func syncDataCacheKeyPrefix(_ isrc: String) -> String { isrc }
    private func get(_ url: String) async throws -> String {
        // The unchanged manual-search wrapper constructs only official URLs.
        let components = URLComponents(string: url)!
        precondition(components.host == "lrclib.net")
        let params = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        return try await lrclibClient.get(base: lrclibBase, path: "search", params: params, timeout: 47)
    }
"""
for start, end in [
    ("    func updateLrclibEndpoint(", "    private func availableSyncDataProviderIds("),
    ("    private func loadLrclibVariants(", "    private func demotedResult("),
    ("    private func demoteLine(", "    func searchManualLrclib("),
    ("    private func findLrclibPlaybackCandidate(", "    func hydrateSpotifyTrackMetadata("),
    ("    private func buildSpotifyLrclibSearchTrack(", "    private func hydratedTrack("),
    ("    private func searchManualLrclibCandidates(", "    private func fetchSyncData("),
    ("    private func scoreCandidate(", "    private func buildSpotifyFieldQuery("),
    ("    private func jsonObject(", "    private func parseSyncContributors("),
    ("    private func isCancellationError(", "    private func postForm("),
    ("    private func describeParams(", "    private func extractSpotifyToken("),
]:
    production += section(repo, start, end)
production += """
    func candidate(track: TrackSnapshot, spotify: SpotifyTrackMatch? = nil, sync: SyncDataResult? = nil, custom: String = "https://mirror.test/api") async throws -> LrclibCandidate? {
        try await findLrclibPlaybackCandidate(track: track, spotifyMatch: spotify, syncData: sync.map(SyncDataCandidateContext.init), customEndpoint: custom, log: { _ in })
    }
    func karaoke(track: TrackSnapshot, sync: SyncDataResult) async throws -> LyricsResult? {
        try await loadLrclibVariants(track: track, spotifyMatch: nil, syncData: sync, isrc: "USABC1234567", spotifyTrackId: "track", settings: .init(lrclibCustomEndpoint: "https://mirror.test/api"), log: { _ in })?.karaoke
    }
    func manual() async throws { _ = try await searchManualLrclibCandidates(title: "Song", artist: "Artist", log: { _ in }) }
    func manualID() async { _ = await fetchLrclibCandidateById(42, log: { _ in }) }
    func seed(_ key: String) {
        let result = LyricsResult(lines: [.init(startTimeMs: 0, endTimeMs: 1000, text: "Cached")], providerLabel: "LRCLIB", detail: "", karaoke: false)
        cache.insert(result, forKey: key); diskCache.put(key, result: result); syncDataResponseCache.put(key, body: "old")
        let load = SyncDataLoadContext(trackKey: "track", isrc: "USABC1234567")
        activeSyncDataLoads[load.id] = load
    }
    func cached(_ key: String) -> (Bool, Bool, Bool, Bool) {
        (cache.value(forKey: key) != nil, diskCache.get(key) != nil, !syncDataResponseCache.get(key).isEmpty, activeSyncDataLoads.values.contains { $0.isValid })
    }
    func cacheKey(_ settings: AppSettings.Snapshot) -> String { lyricsCacheKey(trackKey: "track", settings: settings) }
}
"""

work_root = ROOT / "build/lrclib-validation"
work_root.mkdir(parents=True, exist_ok=True)


class TransportFixture(BaseHTTPRequestHandler):
    forbidden_hits = 0
    credential_hits = 0

    def log_message(self, *_):
        pass

    def do_GET(self):
        if any(self.headers.get(key) for key in ["Authorization", "Cookie", "Origin", "Referer"]):
            type(self).credential_hits += 1
        if self.path.startswith("/redirect/"):
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/forbidden/get")
            self.end_headers()
        elif self.path.startswith("/forbidden/"):
            type(self).forbidden_hits += 1
            self.send_response(200)
            self.end_headers()
        else:
            self.send_response(200)
            if self.path.startswith("/length/"):
                self.send_header("Content-Length", str(3 * 1024 * 1024))
                self.end_headers()
                # Keep framing alive until URLSession rejects the declared size;
                # an immediate truncated close is a transport error before headers.
                self.wfile.write(b"x" * 1024)
                self.wfile.flush()
                self.connection.settimeout(5)
                try:
                    self.connection.recv(1)
                except (TimeoutError, ConnectionResetError):
                    pass
            else:
                self.end_headers()
                try:
                    self.wfile.write(b"x" * (2 * 1024 * 1024 + 1))
                except (BrokenPipeError, ConnectionResetError):
                    pass


with tempfile.TemporaryDirectory(prefix="swift-checks-", dir=work_root) as directory:
    work = Path(directory)
    main = work / "Checks.swift"
    main.write_text(production + (ROOT / "scripts/LrclibPlaybackChecks.swift").read_text())
    sources = [SRC / name for name in ["Utilities.swift", "TinySegmenter.swift", "LrcParser.swift", "SyncDataApplier.swift", "BoundedLRUCache.swift", "LrclibEndpoint.swift", "LrclibPlaybackHTTP.swift"]]
    subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", *map(str, sources), str(main), "-o", str(work / "checks")], check=True)
    server = ThreadingHTTPServer(("127.0.0.1", 0), TransportFixture)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        subprocess.run([str(work / "checks"), str(work / "cache"), f"http://127.0.0.1:{server.server_port}"], check=True, timeout=60)
    finally:
        server.shutdown()
        server.server_close()
    assert TransportFixture.forbidden_hits == 0, "Native URLSession followed a forbidden redirect"
    assert TransportFixture.credential_hits == 0, "Native request forwarded credentials"
