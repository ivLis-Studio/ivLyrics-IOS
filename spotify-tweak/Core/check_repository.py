#!/usr/bin/env python3
"""Run the unchanged lookup algorithm with isolated storage and loopback LRCLIB.

The full production repository, parser, sync applier and caches are compiled.
Only local HTTP fixture traffic is expected; no Spotify credentials are supplied.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import subprocess
import tempfile
import threading
from urllib.parse import parse_qs, urlsplit

CORE = Path(__file__).resolve().parent
ROOT = CORE.parents[1]
manifest = json.loads((CORE / "sources.json").read_text())
sources = [ROOT / path for path in manifest["sources"]]
assert all(path.is_file() and path.resolve().is_relative_to(ROOT.resolve()) for path in sources)
for required in ["LyricsRepository.swift", "SyncDataApplier.swift", "DiskCaches.swift", "LocalLyricsStore.swift"]:
    assert ROOT / "ivLyrics-IOS" / required in sources

requests = []


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        parts = urlsplit(self.path)
        requests.append(parts.path)
        assert parts.path in ("/api/get", "/api/get/41"), self.path
        title = parse_qs(parts.query).get("track_name", ["Sync"])[0]
        payload = json.dumps({"id": 41, "trackName": title, "artistName": "Artist", "albumName": "Album",
                              "duration": 4, "plainLyrics": "ABC\nDEF", "syncedLyrics": "[00:01]ABC\n[00:02]DEF"}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


checks = r'''
import Foundation

@main private struct Checks {
    static func main() async throws {
        var assertions = 0
        func check(_ value: Bool, _ message: String) {
            assertions += 1
            precondition(value, message)
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let endpoint = CommandLine.arguments[2]
        func expiredFile(_ directory: URL) throws -> URL {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("expired.json")
            try Data("{}".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -366 * 24 * 60 * 60)], ofItemAtPath: file.path)
            return file
        }
        func waitForRemoval(_ file: URL) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while FileManager.default.fileExists(atPath: file.path) {
                precondition(ProcessInfo.processInfo.systemUptime < deadline, "Cache prune did not finish")
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        let pruneA = root.appendingPathComponent("prune-a"), pruneB = root.appendingPathComponent("prune-b")
        let staleA = try expiredFile(pruneA), staleB = try expiredFile(pruneB)
        LyricsDiskCachePolicy.prune(rootDirectory: pruneA)
        try await waitForRemoval(staleA)
        check(!FileManager.default.fileExists(atPath: staleA.path), "Injected roots run the existing expiry pruning algorithm")
        check(FileManager.default.fileExists(atPath: staleB.path), "Pruning one root never enumerates another root")
        LyricsDiskCachePolicy.prune(rootDirectory: pruneB)
        try await waitForRemoval(staleB)
        check(!FileManager.default.fileExists(atPath: staleB.path), "Pruning/throttling are independent for different roots")
        let throttled = try expiredFile(pruneA)
        LyricsDiskCachePolicy.prune(rootDirectory: pruneA)
        try await Task.sleep(nanoseconds: 50_000_000)
        check(FileManager.default.fileExists(atPath: throttled.path), "The existing throttle still applies within each root")
        let defaultsName = "ivlyrics-core-repository-fixture." + UUID().uuidString
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let secure = SecureStringStore(service: defaultsName)
        defer { secure.remove(forKey: "spotify_token_cache_access_token") }
        let storageA = root.appendingPathComponent("a"), storageB = root.appendingPathComponent("b")
        let localA = LocalLyricsStore(root: storageA.appendingPathComponent("local"))
        let localB = LocalLyricsStore(root: storageB.appendingPathComponent("local"))
        let diskA = LyricsDiskCache(namespace: "base_lyrics", maxEntries: 10, rootDirectory: storageA)
        let diskB = LyricsDiskCache(namespace: "base_lyrics", maxEntries: 10, rootDirectory: storageB)
        let rawA = RawResponseDiskCache(namespace: "sync_data_api", maxEntries: 10, formatVersion: 2, rootDirectory: storageA)
        let rawB = RawResponseDiskCache(namespace: "sync_data_api", maxEntries: 10, formatVersion: 2, rootDirectory: storageB)
        let repository = LyricsRepository(localLyricsStore: localA, diskCache: diskA,
                                          syncDataResponseCache: rawA, defaults: defaults, secureStore: secure)
        let settings = CoreLocalization.Snapshot(enabledLyricsProviderOrder: ["lrclib"], lrclibCustomEndpoint: endpoint)
        let track = TrackSnapshot(title: "Local", artist: "Artist", album: "Album", durationMs: 4000)
        try localA.save(key: track.stableKey, text: "[00:01]Imported")
        check(await repository.hasLocalLyrics(for: track), "The injected local store is used by hasLocalLyrics")
        check(!localB.contains(key: track.stableKey), "Different storage roots do not share imports")
        let local = try await repository.loadLyrics(track: track, settings: settings)
        check(local.result.providerId == "local" && local.result.lines.first?.text == "Imported", "The original repository returns the injected import before providers")
        check(local.logs == ["Using imported local lyrics"], "No metadata/provider work precedes a local override")
        diskA.put("fixture", result: local.result)
        rawA.put("fixture", body: "A")
        check(diskA.get("fixture") != nil && rawA.get("fixture") == "A", "Isolated parsed and raw caches round trip")
        check(diskB.get("fixture") == nil && rawB.get("fixture").isEmpty, "Cache roots are separate even with the same namespace and key")
        diskB.put("fixture", result: local.result)
        rawB.put("fixture", body: "B")
        await repository.clearCache()
        check(diskA.get("fixture") == nil && rawA.get("fixture").isEmpty, "Repository clear targets its injected caches")
        check(diskB.get("fixture") != nil && rawB.get("fixture") == "B", "Clear does not touch another host's cache")
        check(localA.contains(key: track.stableKey), "Cache clearing does not remove imported lyrics")
        let remote = TrackSnapshot(title: "Remote", artist: "Artist", album: "Album", durationMs: 4000)
        let loaded = try await repository.loadLyrics(track: remote, settings: settings)
        check(loaded.result.providerId == "lrclib" && loaded.result.lines.map(\.text) == ["ABC", "DEF"], "The original full repository selects LRCLIB lyrics")
        check(loaded.result.lines.first?.startTimeMs == 1000 && !loaded.result.karaoke, "Original LRC parser timing survives selection")
        check(loaded.result.selectionPolicyKey == settings.lyricsProviderPolicySignature, "Repository uses the module's read-only selection policy")

        let coreStorage = root.appendingPathComponent("module")
        let coreDomain = CoreRepository.persistenceDomain(for: coreStorage)
        defer { UserDefaults(suiteName: coreDomain)?.removePersistentDomain(forName: coreDomain) }
        let adapter = CoreRepository(store: LocalLyricsStore(root: coreStorage), storageDirectory: coreStorage, settings: settings)
        let loader = IVLCoreLoader(storageDirectory: coreStorage, fetchLyrics: { try await adapter.load($0) })
        let coreTrack = IVLCoreTrack(title: "Core", artist: "Artist", album: "Album", durationMs: 4000)
        check(try await loader.load(track: coreTrack) == nil, "Module repository remains behind per-load opt-in")
        check(!FileManager.default.fileExists(atPath: coreStorage.appendingPathComponent("ProviderCache").path), "No provider cache is created before opt-in")
        let document = try await loader.load(track: coreTrack, allowNetwork: true)!
        let result = try JSONDecoder().decode(LyricsResult.self, from: document.lyricsJSON)
        check(document.providerID == "lrclib" && result.lines.first?.text == "ABC", "Core uses the real repository result without converting to LyricsPlus")
        check(document.trackKey == coreTrack.trackKey && document.lineCount == 2, "Original document identity/schema is retained")
        check(FileManager.default.fileExists(atPath: coreStorage.appendingPathComponent("ProviderCache/base_lyrics").path), "Module repository caches stay inside the selected storage directory")
        check(try coreStorage.appendingPathComponent("ProviderCache").resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
              "Redownloadable provider cache is excluded from backups")
        check(try coreStorage.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup != true,
              "The local import directory remains eligible for backups")

        // A fresh cached provider map and cached timing payload keep ivSync
        // offline; the underlying pinned LRCLIB source comes from loopback.
        defaults.set(endpoint, forKey: LrclibEndpoint.settingsKey)
        defaults.set("{\"lrclib\":[\"USABC1234567\"]}", forKey: "sync_data_opendb_provider_map")
        defaults.set(Date().timeIntervalSince1970 * 1000, forKey: "sync_data_opendb_fetched_at_ms")
        defaults.removeObject(forKey: "sync_data_opendb_unavailable_until_ms")
        let syncPayload = #"{"data":{"provider":"lrclib","syncType":"character","syncPoints":6,"syncData":{"version":2,"trackDurationMs":4000,"source":{"provider":"lrclib","lrclibId":41,"preferredLyricsSource":"synced","lineCharCounts":[3,3]},"lines":[{"start":0,"end":2,"chars":[1.1,1.2,1.3],"granularity":"character"},{"start":3,"end":5,"chars":[2.1,2.2,2.3],"granularity":"character"}]}}}"#
        rawA.put("sync-data-api-v2|isrc:USABC1234567|provider:lrclib", body: syncPayload)
        let syncRepository = LyricsRepository(localLyricsStore: localA, diskCache: diskA,
                                              syncDataResponseCache: rawA, defaults: defaults, secureStore: secure)
        let syncTrack = TrackSnapshot(title: "Sync", artist: "Artist", album: "Album", isrc: "USABC1234567", durationMs: 4000)
        let synced = try await syncRepository.loadLyrics(track: syncTrack, settings: settings)
        check(synced.result.karaoke && synced.result.providerId == "lrclib", "Original repository applies ivSync to the LRCLIB source")
        check(synced.result.lines.first?.startTimeMs == 1100 && synced.result.lines.first?.syllables.isEmpty == false, "SyncDataApplier character timing is preserved")
        check(synced.result.syncPoints == 6 && synced.result.syncType == "character", "Sync metadata is retained")
        check(synced.logs.contains(where: { $0.contains("sync-data cache hit") }), "ivSync fixture uses the injected timing cache")
        let defaultsPolicy = CoreLocalization.Snapshot()
        check(defaultsPolicy.enabledLyricsProviderOrder == ["lrclib", "lyricsplus"] && defaultsPolicy.preferSyncDataProvider,
              "Default module policy enables LRCLIB, LyricsPlus and registered ivSync")
        check(defaultsPolicy.spotifyClientId.isEmpty && defaultsPolicy.spotifyClientSecret.isEmpty, "Host credentials are never read implicitly")
        print("CORE_REPOSITORY_CHECKS_PASSED assertions=\(assertions); loopback LRCLIB and isolated ivSync fixtures only")
    }
}
'''

server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
worker = threading.Thread(target=server.serve_forever, daemon=True)
worker.start()
try:
    with tempfile.TemporaryDirectory(prefix="ivlyrics-core-repository-") as directory:
        work = Path(directory)
        fixture = work / "Checks.swift"
        fixture.write_text(checks)
        binary = work / "checks"
        subprocess.run(["xcrun", "swiftc", "-swift-version", manifest["swift_version"], "-parse-as-library",
                        *map(str, sources), str(fixture), "-o", str(binary)], check=True)
        subprocess.run([str(binary), str(work), f"http://127.0.0.1:{server.server_port}/api"], check=True, timeout=30)
    assert requests == ["/api/get", "/api/get", "/api/get/41"], requests
finally:
    server.shutdown()
    server.server_close()
