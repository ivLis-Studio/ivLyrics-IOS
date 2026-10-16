
private struct FixtureReply {
    var status = 200
    var body = "[]"
    var error: URLError?
}

private final class LrclibFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recorded: [URLRequest] = []
    private static var reply: (URLRequest) -> FixtureReply = { _ in .init(status: 404) }

    static func reset(_ handler: @escaping (URLRequest) -> FixtureReply) {
        lock.lock(); defer { lock.unlock() }
        recorded = []; reply = handler
    }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let handler = Self.reply
        Self.lock.unlock()
        let reply = handler(request)
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let data = Data(reply.body.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json", "Content-Length": "\(data.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private var assertionCount = 0
private func check(_ value: @autoclosure () -> Bool, _ description: String) {
    assertionCount += 1
    if !value() { fatalError(description) }
}

private func query(_ request: URLRequest) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

private func label(_ request: URLRequest) -> String {
    let path = request.url!.path
    if path.contains("/get/") { return "id" }
    if path.hasSuffix("/get") { return "metadata" }
    let params = query(request)
    let english = (params["track_name"] ?? params["q"] ?? "").hasPrefix("English")
    let prefix = english ? "en:" : ""
    if let q = params["q"] { return prefix + (q.contains("Artist") ? "q:both" : "q:title") }
    return prefix + (params["album_name"] == nil ? "no-album" : "structured")
}

private func candidateBody(id: Int64 = 42, plain: String = "Alpha\nBeta", synced: String? = "[00:01.00]Alpha\n[00:05.00]Beta",
                           title: String = "Song", artist: String = "Artist", duration: Double = 120) -> String {
    var body: [String: Any] = ["id": id, "trackName": title, "artistName": artist, "albumName": "Album", "duration": duration,
                               "plainLyrics": plain]
    if let synced { body["syncedLyrics"] = synced }
    return String(data: try! JSONSerialization.data(withJSONObject: body), encoding: .utf8)!
}

private func savedSource(id: Int64 = 42, text: String = "Alpha\nBeta", fingerprint: String? = nil,
                         counts: [Int]? = nil, preferred: String = "synced", includeConstraints: Bool = true) -> SyncDataResult {
    let lines = text.components(separatedBy: "\n")
    var source: [String: Any] = ["provider": "lrclib", "lrclibId": id, "preferredLyricsSource": preferred]
    if includeConstraints {
        source["lyricsFingerprint"] = fingerprint ?? IvLyricsUtilities.lyricsFingerprint(text)
        source["lineCharCounts"] = counts ?? IvLyricsUtilities.lineCharCounts(lines)
    }
    var offset = 0
    let syncLines: [[String: Any]] = includeConstraints ? lines.enumerated().map { index, line in
        let length = IvLyricsUtilities.splitChars(line).count
        defer { offset += length }
        return ["start": offset, "end": offset + length - 1, "chars": (0..<length).map { Double(index * 5 + 1) + Double($0) * 0.1 }]
    } : []
    return SyncDataResult(syncBody: ["version": 2, "source": source, "lines": syncLines], provider: "lrclib", contributors: [])
}

@main
private struct LrclibPlaybackChecks {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LrclibFixtureProtocol.self]
        // Deliberately poisoned configuration: production must strip these headers.
        config.httpAdditionalHeaders = ["Authorization": "Bearer synthetic-spotify-token", "Cookie": "session=synthetic",
                                        "Origin": "https://xpui.app.spotify.com", "Referer": "https://xpui.app.spotify.com/"]
        let client = LrclibHTTPClient(configuration: config)
        let repo = PlaybackProbe(client: client)
        let track = TrackSnapshot(title: "Song", artist: "Artist", album: "Album", isrc: "USABC1234567", durationMs: 120_000)
        let pinned = savedSource()
        var spotify = SpotifyTrackMatch(json: ["name": "Song", "artists": [["name": "Artist"]]], requireIsrc: false)!
        spotify.englishTitle = "English Song"; spotify.englishArtist = "Artist"

        // Every miss in the entire custom stage precedes the first official ID GET.
        LrclibFixtureProtocol.reset { request in
            request.url!.host == "lrclib.net" ? .init(body: candidateBody()) : .init(status: 404)
        }
        let fallback = try await repo.candidate(track: track, spotify: spotify, sync: pinned)
        let ordered = LrclibFixtureProtocol.requests
        check(fallback?.canonicalLrclibId == 42, "Official fallback preserves the pinned ID")
        check(ordered.map(label) == ["id", "metadata", "structured", "no-album", "q:both", "q:title", "en:no-album", "en:q:both", "en:q:title", "id"], "Full ordered custom stage precedes official /get/{id}")
        check(ordered.prefix(9).allSatisfy { $0.url!.host == "mirror.test" } && ordered.last!.url!.host == "lrclib.net", "Hosts never interleave")
        check(ordered.prefix(9).allSatisfy { $0.timeoutInterval > 0 && $0.timeoutInterval <= 5 }, "Every custom native request is bounded to five seconds")
        for request in ordered {
            check(request.httpMethod == "GET" && request.httpBody == nil, "Playback is read-only")
            for name in ["Authorization", "Cookie", "Origin", "Referer"] {
                check(request.value(forHTTPHeaderField: name) == nil, "No credential or Spotify context forwarded: \(name)")
            }
        }

        LrclibFixtureProtocol.reset { _ in .init(body: candidateBody(id: 9001)) }
        let direct = try await repo.candidate(track: track, sync: pinned)
        check(LrclibFixtureProtocol.requests.count == 1 && label(LrclibFixtureProtocol.requests[0]) == "id", "Known source is attempted by ID first")
        check(direct?.id == 9001 && direct?.canonicalLrclibId == 42, "Content-validated saved identity survives mirror ID aliases")
        let karaoke = try await repo.karaoke(track: track, sync: pinned)
        check(karaoke?.karaoke == true && karaoke?.lines.map(\.text) == ["Alpha", "Beta"], "Real sync applier renders the validated revision")

        // Same ID and exact line counts are insufficient when the fingerprint disagrees.
        LrclibFixtureProtocol.reset { request in
            let body = candidateBody(plain: "Omega\nZeta", synced: "[00:01.00]Omega\n[00:05.00]Zeta")
            return .init(body: request.url!.host == "lrclib.net" ? candidateBody() : (request.url!.path.hasSuffix("/search") ? "[\(body)]" : body))
        }
        let corrected = try await repo.candidate(track: track, sync: pinned)
        check(corrected?.plainLyrics == "Alpha\nBeta", "Matching metadata/ID cannot override a conflicting mirror fingerprint")
        check(LrclibFixtureProtocol.requests.count == 7 && LrclibFixtureProtocol.requests.prefix(6).allSatisfy { $0.url!.host == "mirror.test" }, "Rejected revisions exhaust custom fallbacks before official")

        LrclibFixtureProtocol.reset { request in .init(body: request.url!.path.hasSuffix("/search") ? "[\(candidateBody())]" : candidateBody()) }
        let shapeMismatch = try await repo.candidate(track: track, sync: savedSource(counts: [4, 5]))
        check(shapeMismatch?.canonicalLrclibId == 42 && LrclibFixtureProtocol.requests.last!.url!.host == "lrclib.net", "Contradictory saved counts reject mirror content even when its fingerprint matches")
        LrclibFixtureProtocol.reset { _ in .init(body: candidateBody()) }
        let idOnly = try await repo.candidate(track: track, sync: savedSource(includeConstraints: false))
        check(idOnly?.canonicalLrclibId == 42 && LrclibFixtureProtocol.requests.count == 1 && LrclibFixtureProtocol.requests.last!.url!.host == "mirror.test", "A trusted legacy pinned ID is accepted from the mirror when no content constraints exist")
        LrclibFixtureProtocol.reset { request in
            let body = candidateBody(id: request.url!.host == "lrclib.net" ? 42 : 9001)
            return .init(body: request.url!.path.hasSuffix("/search") ? "[\(body)]" : body)
        }
        let legacyAlias = try await repo.candidate(track: track, sync: savedSource(includeConstraints: false))
        check(legacyAlias?.canonicalLrclibId == 42 && LrclibFixtureProtocol.requests.count == 7, "A legacy ID mismatch exhausts the mirror before official fallback")
        LrclibFixtureProtocol.reset { request in
            let body = request.url!.host == "lrclib.net" ? candidateBody() : candidateBody(id: 9001, plain: "Omega\nZeta", synced: "[00:01.00]Omega\n[00:05.00]Zeta")
            return .init(body: request.url!.path.hasSuffix("/search") ? "[\(body)]" : body)
        }
        let countsOnlyAlias = try await repo.candidate(track: track, sync: savedSource(fingerprint: ""))
        check(countsOnlyAlias?.canonicalLrclibId == 42 && countsOnlyAlias?.plainLyrics == "Alpha\nBeta" && LrclibFixtureProtocol.requests.count == 7, "Equal counts with a different private ID cannot inherit the pinned identity")
        LrclibFixtureProtocol.reset { _ in .init(body: candidateBody(id: 9001)) }
        var merged = pinned
        merged.syncBody["lines"] = [["start": 0, "end": 8, "chars": (0..<9).map { Double($0 + 1) }]]
        let sourceShape = try await repo.candidate(track: track, sync: merged)
        check(sourceShape?.canonicalLrclibId == 42 && LrclibFixtureProtocol.requests.count == 1, "Saved source row counts take precedence over merged timing/display counts")

        LrclibFixtureProtocol.reset { _ in .init(body: candidateBody(id: 777)) }
        let unpinned = try await repo.candidate(track: track)
        check(unpinned?.id == 777 && unpinned?.canonicalLrclibId == 0, "Arbitrary mirror IDs never acquire authoring identity")
        let fingerprintOnly = try await repo.candidate(track: track, sync: savedSource(id: 0))
        check(fingerprintOnly?.canonicalLrclibId == 0, "Fingerprint matching without a saved canonical ID cannot invent one")

        LrclibFixtureProtocol.reset { _ in .init(body: candidateBody(plain: "Plain\nOnly", synced: "[00:01.00]Other\n[00:05.00]Text")) }
        let plain = try await repo.candidate(track: track, sync: savedSource(text: "Plain\nOnly", preferred: "plain"))
        check(plain?.preferredLyricsSource == "plain" && plain?.useSyncedLyrics() == false, "Saved plain/synced revision preference is preserved")
        let alternate = try await repo.candidate(track: track, sync: savedSource(text: "Plain\nOnly", preferred: "synced"))
        check(alternate?.preferredLyricsSource == "plain" && alternate?.canonicalLrclibId == 42, "The other variant can satisfy the saved canonical fingerprint and shape")

        // The pre-existing official-only fingerprint compatibility path remains available.
        LrclibFixtureProtocol.reset { _ in .init(body: candidateBody()) }
        let official = try await repo.candidate(track: track, sync: pinned, custom: "")!
        let officialBase = LrcParser.parseSynced(official.syncedLyrics, durationMs: track.durationMs)
        let compatibility = SyncDataApplier.applyWithDiagnostics(baseLyrics: officialBase,
            syncBody: savedSource(fingerprint: "old-official-fingerprint").syncBody, track: track,
            currentProvider: "lrclib", currentLrclibId: official.canonicalLrclibId)
        check(!compatibility.lines.isEmpty, "Existing official ID/exact-shape compatibility is retained")
        let untrusted = SyncDataApplier.applyWithDiagnostics(baseLyrics: officialBase,
            syncBody: savedSource(fingerprint: "old-official-fingerprint").syncBody, track: track,
            currentProvider: "lrclib", currentLrclibId: unpinned!.canonicalLrclibId)
        check(untrusted.lines.isEmpty, "Untrusted mirror ID cannot enable fingerprint compatibility")

        for failure in ["empty", "malformed", "network", "rate-limit", "server"] {
            LrclibFixtureProtocol.reset { request in
                if request.url!.host == "lrclib.net" { return .init(body: candidateBody()) }
                switch failure {
                case "empty": return .init(body: request.url!.path.hasSuffix("/search") ? "[]" : "{}")
                case "malformed": return .init(body: "{broken JSON")
                case "network": return .init(error: URLError(.notConnectedToInternet))
                case "rate-limit": return .init(status: 429)
                default: return .init(status: 503)
                }
            }
            let result = try await repo.candidate(track: track)
            check(result?.canonicalLrclibId == 42, "Official fallback after \(failure)")
            let customCount = LrclibFixtureProtocol.requests.filter { $0.url!.host == "mirror.test" }.count
            check(customCount == (["empty", "malformed"].contains(failure) ? 5 : 1), "404/empty/malformed continue; fatal failures may end only their host stage")
        }

        LrclibFixtureProtocol.reset { request in
            if label(request) == "no-album" { return .init(body: "[\(candidateBody(id: 77))]") }
            return .init(status: 404)
        }
        let noAlbum = try await repo.candidate(track: track)
        check(noAlbum?.id == 77 && LrclibFixtureProtocol.requests.map(label) == ["metadata", "structured", "no-album"], "No-album fallback is tried before free text")

        LrclibFixtureProtocol.reset { request in
            if label(request) == "en:q:title" { return .init(body: "[\(candidateBody(id: 88, title: "English Song"))]") }
            return .init(status: 404)
        }
        let english = try await repo.candidate(track: track, spotify: spotify)
        check(english?.id == 88 && LrclibFixtureProtocol.requests.count == 8, "English fallback runs inside the custom stage")
        check(LrclibFixtureProtocol.requests.allSatisfy { $0.url!.host == "mirror.test" }, "English custom success makes no official lyric request")

        LrclibFixtureProtocol.reset { request in
            if request.url!.host == "lrclib.net", label(request) == "q:title" { return .init(body: "[\(candidateBody())]") }
            return .init(status: 404)
        }
        let officialSearch = try await repo.candidate(track: track)
        check(officialSearch != nil && LrclibFixtureProtocol.requests.map(label) == ["metadata", "structured", "no-album", "q:both", "q:title", "metadata", "structured", "no-album", "q:both", "q:title"], "Official host repeats the full playback fallback chain")

        LrclibFixtureProtocol.reset { _ in .init(status: 404) }
        let absent = try await repo.candidate(track: track, spotify: spotify)
        check(absent == nil && LrclibFixtureProtocol.requests.count == 16, "Only after both complete stages miss can the caller try other providers")

        LrclibFixtureProtocol.reset { request in .init(body: request.url!.path.hasSuffix("/search") ? "[]" : candidateBody()) }
        try await repo.manual(); await repo.manualID()
        check(LrclibFixtureProtocol.requests.count == 4 && LrclibFixtureProtocol.requests.allSatisfy { $0.url!.host == "lrclib.net" }, "Manual/editor search and selection remain official-only")

        let stage = LrclibLookupStage(base: "https://mirror.test/api", startedAt: 100)
        let firstTimeout = try stage.timeout(default: 47, now: 100), remainingTimeout = try stage.timeout(default: 47, now: 118)
        check(firstTimeout == 5, "Custom per-request budget is five seconds")
        check(remainingTimeout == 2, "All requests share the remaining twenty-second stage budget")
        do { _ = try stage.timeout(default: 47, now: 120); fatalError("Expired stage accepted") }
        catch LrclibLookupError.stageExhausted { assertionCount += 1 }
        LrclibFixtureProtocol.reset { _ in .init(body: candidateBody()) }
        let cancelled = Task { try await repo.candidate(track: track) }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancelled load completed") }
        catch is CancellationError { assertionCount += 1 }
        check(LrclibFixtureProtocol.requests.isEmpty, "Cancellation starts neither custom nor official requests")

        for (input, expected) in [("", ""), (" \n", ""), ("HTTPS://MIRROR.TEST:443/", "https://mirror.test/api"),
                                   ("https://mirror.test/api///", "https://mirror.test/api"),
                                   ("http://127.0.0.1:8080", "http://127.0.0.1:8080/api"),
                                   ("http://100.100.100.100:8080/api/", "http://100.100.100.100:8080/api"),
                                   ("http://server.local/api", "http://server.local/api"),
                                   ("http://[::1]:8080/lyrics/api", "http://[::1]:8080/lyrics/api"),
                                   ("https://lrclib.net/api/", "")] {
            check(LrclibEndpoint.normalized(input) == expected, "Normalize \(input)")
        }
        for input in ["mirror.test", "http://mirror.test/api", "http://8.8.8.8/api", "http://100.63.255.255/api", "http://100.128.0.1/api", "http://192.168.0.1.evil.test/api", "file:///etc/passwd", "javascript:alert(1)", "ftp://mirror.test", "https://", "https://user:pass@mirror.test/api",
                      "https://mirror.test?key=test", "https://mirror.test/api#key", "https://mirror.test/api?", "https://mirror.test/api#",
                      "https://mirror.test:0", "https://mirror.test:65536", "https://mirror.test/a/../api", "https://mirror.test/%2e%2e/api",
                      "https://mirror.test/has space", "https://mirror.test/a\\b", "https://mirror.test/%0aapi"] {
            check(LrclibEndpoint.normalized(input) == nil, "Reject invalid or credential-bearing URL")
        }

        let suite = "ivLyrics.lrclib-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        check(settings.lrclibCustomEndpoint.isEmpty, "Old defaults have an empty endpoint")
        settings.importCloudSettings(["ui_lang": "ko"])
        check(settings.lrclibCustomEndpoint.isEmpty, "Old config imports decode without a new field")
        check(settings.setLrclibCustomEndpoint("HTTPS://MIRROR.TEST:443/"), "Save valid endpoint")
        let reloaded = AppSettings(defaults: defaults)
        check(reloaded.lrclibCustomEndpoint == "https://mirror.test/api", "Normalized endpoint survives reinitialization")
        let exported = reloaded.exportCloudSettings()
        check(exported[LrclibEndpoint.settingsKey] as? String == reloaded.lrclibCustomEndpoint, "Export includes normalized endpoint")
        settings.importCloudSettings(["ui_lang": "en"])
        check(settings.lrclibCustomEndpoint == reloaded.lrclibCustomEndpoint, "Old config import preserves an existing endpoint")
        for invalid: Any in [42, NSNull(), "https://user:secret@bad.test"] {
            settings.importCloudSettings([LrclibEndpoint.settingsKey: invalid])
            check(settings.lrclibCustomEndpoint == reloaded.lrclibCustomEndpoint, "Invalid imports cannot overwrite a valid endpoint")
        }
        settings.importCloudSettings([LrclibEndpoint.settingsKey: "https://second.test/"])
        check(settings.lrclibCustomEndpoint == "https://second.test/api", "Import normalizes a new endpoint")
        settings.importCloudSettings([LrclibEndpoint.settingsKey: ""])
        check(settings.lrclibCustomEndpoint.isEmpty && AppSettings(defaults: defaults).lrclibCustomEndpoint.isEmpty, "Explicit blank imports persist clearing")
        defaults.set("https://user:secret@bad.test", forKey: LrclibEndpoint.settingsKey)
        check(settings.exportCloudSettings()[LrclibEndpoint.settingsKey] == nil, "Exports cannot leak invalid legacy URL credentials")
        let migrated = AppSettings(defaults: defaults)
        check(migrated.lrclibCustomEndpoint.isEmpty && defaults.string(forKey: LrclibEndpoint.settingsKey) == "", "Unsafe old defaults migrate to official-only")

        var first = AppSettings.Snapshot(lrclibCustomEndpoint: "https://first.test/api")
        var second = first; second.lrclibCustomEndpoint = "https://second.test/api"
        let firstKey = await repo.cacheKey(first), secondKey = await repo.cacheKey(second)
        check(firstKey != secondKey, "Endpoint is part of disk and provider-selection cache identity")
        first.lrclibCustomEndpoint = ""; let emptyKey = await repo.cacheKey(first)
        check(emptyKey != firstKey && emptyKey != secondKey, "Clearing endpoint cannot resurrect another host's cached selection")
        await repo.updateLrclibEndpoint("https://first.test/api")
        await repo.seed(firstKey)
        let seeded = await repo.cached(firstKey)
        check(seeded.0 && seeded.1 && seeded.2 && seeded.3, "Real disk/memory/sync caches and active load are seeded")
        await repo.updateLrclibEndpoint("https://FIRST.test:443/api/")
        let same = await repo.cached(firstKey)
        check(same.0 && same.1 && same.2 && same.3, "Equivalent normalized URL preserves valid cache")
        await repo.updateLrclibEndpoint("https://second.test/api")
        let cleared = await repo.cached(firstKey)
        check(!cleared.0 && !cleared.1 && !cleared.2 && !cleared.3, "Endpoint changes clear real disk/memory/sync caches and invalidate in-flight loads")
        await repo.seed(secondKey); await repo.updateLrclibEndpoint("")
        let reset = await repo.cached(secondKey)
        check(!reset.0 && !reset.1 && !reset.2 && !reset.3, "Clearing endpoint invalidates every prior selection")

        // Real loopback HTTP checks the session delegate and streaming byte limit,
        // including responses without Content-Length. No URLProtocol is involved.
        let native = LrclibHTTPClient()
        let fixture = CommandLine.arguments[2]
        do {
            _ = try await native.get(base: fixture + "/redirect", path: "get", timeout: 5)
            fatalError("Redirect was accepted")
        } catch let error as HTTPStatusError {
            check(error.statusCode == 302, "Native transport refuses redirects before following them")
        }
        for path in ["length", "stream"] {
            do {
                _ = try await native.get(base: fixture + "/" + path, path: "get", timeout: 5)
                fatalError("Oversized response was accepted")
            } catch let error as URLError {
                check(error.code == .dataLengthExceedsMaximum, "Native transport bounds \(path) payloads; error=\(error.code.rawValue)")
            }
        }

        print("PASS \(assertionCount) optimized Swift LRCLIB checks: native GET order, pinned revisions, fallback, trust, budgets, cancellation, cache invalidation, URL validation, defaults/import/export")
    }
}
