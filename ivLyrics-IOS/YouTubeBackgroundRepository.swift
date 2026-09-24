import Foundation

actor YouTubeBackgroundRepository {
    private let endpoint = "https://ivlis.kr/ivLyrics/openvideo/youtube"
    private let spotifyOrigin = "https://xpui.app.spotify.com"
    private let spotifyReferer = "https://xpui.app.spotify.com/"
    private let diskCache = YouTubeVideoDiskCache()
    private let clientVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

    struct LoadedVideo: Sendable {
        var info: YouTubeVideoInfo
        var fromCache: Bool
        var logs: [String]
    }

    func load(track: TrackSnapshot, lyricsResult: LyricsResult) async throws -> LoadedVideo {
        if let selected = selectedVideo(trackKey: track.stableKey) {
            return LoadedVideo(info: selected, fromCache: true, logs: ["youtube background: track selection"])
        }
        let isrc = IvLyricsUtilities.firstNonEmpty(lyricsResult.isrc, track.isrc)
        guard !isrc.isEmpty else {
            throw NSError(domain: "ivLyrics.YouTube", code: -1, userInfo: [NSLocalizedDescriptionKey: "youtube background: missing ISRC"])
        }
        if let cached = diskCache.get(isrc) {
            return LoadedVideo(info: cached, fromCache: true, logs: ["youtube background cache hit: isrc=\(isrc)"])
        }

        let spotifyTrackId = IvLyricsUtilities.firstNonEmpty(lyricsResult.spotifyTrackId, track.trackId)
        var params = [
            "isrc": isrc,
            "useCommunity": "true",
            "client": "ivLyrics",
            "clientVersion": clientVersion,
            "requestVersion": "2"
        ]
        if !spotifyTrackId.isEmpty { params["trackId"] = spotifyTrackId }
        if !track.title.isEmpty { params["trackName"] = track.title }
        if !track.artist.isEmpty { params["trackArtists"] = track.artist }
        if !track.album.isEmpty { params["album"] = track.album }

        let url = endpoint + "?" + IvLyricsUtilities.encodeParams(params)
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 16
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(spotifyOrigin, forHTTPHeaderField: "Origin")
        request.setValue(spotifyReferer, forHTTPHeaderField: "Referer")
        request.setValue("ivLyrics", forHTTPHeaderField: "X-ivLyrics-Client")
        request.setValue("2", forHTTPHeaderField: "X-ivLyrics-Request-Version")
        request.setValue(clientVersion, forHTTPHeaderField: "X-ivLyrics-Client-Version")

        let (data, _) = try await URLSession.shared.ivLyricsData(for: request)
        let root = try jsonObject(data)
        guard boolValue(root["success"]) else {
            throw NSError(domain: "ivLyrics.YouTube", code: -2, userInfo: [NSLocalizedDescriptionKey: "youtube background: video not found"])
        }
        guard let object = root["data"] as? [String: Any], let info = YouTubeVideoInfo.fromJson(fallbackIsrc: isrc, object: object) else {
            throw NSError(domain: "ivLyrics.YouTube", code: -3, userInfo: [NSLocalizedDescriptionKey: "youtube background: invalid response"])
        }
        diskCache.put(info)
        return LoadedVideo(
            info: info,
            fromCache: false,
            logs: ["youtube background request: isrc=\(isrc)" + (spotifyTrackId.isEmpty ? "" : " / trackId=\(spotifyTrackId)")]
        )
    }

    func selectedVideo(trackKey: String) -> YouTubeVideoInfo? {
        guard !trackKey.isEmpty,
              let data = UserDefaults.standard.data(forKey: "youtube_background_selection." + trackKey) else { return nil }
        return try? JSONDecoder().decode(YouTubeVideoInfo.self, from: data)
    }

    func selectVideo(_ info: YouTubeVideoInfo?, trackKey: String) {
        guard !trackKey.isEmpty else { return }
        let key = "youtube_background_selection." + trackKey
        if let info, let data = try? JSONEncoder().encode(info) { UserDefaults.standard.set(data, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    func communityVideos(track: TrackSnapshot, lyricsResult: LyricsResult) async throws -> [YouTubeVideoInfo] {
        let isrc = IvLyricsUtilities.firstNonEmpty(lyricsResult.isrc, track.isrc)
        guard !isrc.isEmpty else { return [] }
        let params = ["isrc": isrc, "trackId": track.trackId, "trackName": track.title, "trackArtists": track.artist, "album": track.album]
        let url = "https://ivlis.kr/ivLyrics/openvideo/community?" + IvLyricsUtilities.encodeParams(params)
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 16
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(spotifyOrigin, forHTTPHeaderField: "Origin")
        request.setValue(spotifyReferer, forHTTPHeaderField: "Referer")
        let (data, _) = try await URLSession.shared.ivLyricsData(for: request)
        let root = try jsonObject(data)
        guard boolValue(root["success"]), let payload = root["data"] as? [String: Any],
              let videos = payload["videos"] as? [[String: Any]] else {
            throw NSError(domain: "ivLyrics.YouTube", code: -3)
        }
        var seen = Set<String>()
        return videos.compactMap { YouTubeVideoInfo.fromJson(fallbackIsrc: isrc, object: $0) }
            .filter { seen.insert($0.youtubeVideoId).inserted }
    }

    func clearCache() {
        diskCache.clear()
    }

    func clearCacheForIsrc(_ isrc: String) {
        diskCache.remove(isrc)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "ivLyrics.YouTube", code: -4, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON"])
        }
        return object
    }

    private func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? String { return value.caseInsensitiveCompare("true") == .orderedSame || value == "1" }
        if let value = value as? NSNumber { return value.boolValue }
        return false
    }
}

nonisolated final class YouTubeVideoDiskCache: @unchecked Sendable {
    private let defaults = UserDefaults.standard
    private let keyPrefix = "youtube_background_cache."

    func get(_ isrc: String) -> YouTubeVideoInfo? {
        let key = TrackSnapshot.normalizeIsrc(isrc)
        guard !key.isEmpty, let raw = defaults.string(forKey: keyPrefix + key), let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(YouTubeVideoInfo.self, from: data)
    }

    func put(_ info: YouTubeVideoInfo) {
        let key = TrackSnapshot.normalizeIsrc(info.isrc)
        guard !key.isEmpty, !info.youtubeVideoId.isEmpty, let data = try? JSONEncoder().encode(info), let raw = String(data: data, encoding: .utf8) else {
            return
        }
        defaults.set(raw, forKey: keyPrefix + key)
    }

    func remove(_ isrc: String) {
        let key = TrackSnapshot.normalizeIsrc(isrc)
        guard !key.isEmpty else { return }
        defaults.removeObject(forKey: keyPrefix + key)
    }

    func clear() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}

extension YouTubeVideoInfo {
    static func fromJson(fallbackIsrc: String, object: [String: Any]) -> YouTubeVideoInfo? {
        let isrc = TrackSnapshot.normalizeIsrc(firstNonEmpty(stringValue(object["isrc"]), fallbackIsrc))
        let videoId = firstNonEmpty(stringValue(object["youtubeVideoId"]), stringValue(object["videoId"]))
        guard validYouTubeId(videoId) else { return nil }
        let rawStart = object["captionStartTime"] is NSNull ? object["startTime"] : (object["captionStartTime"] ?? object["startTime"])
        let hasCaption = rawStart != nil && !(rawStart is NSNull)
        let start = doubleValue(rawStart)
        return YouTubeVideoInfo(
            isrc: isrc,
            spotifyTrackId: firstNonEmpty(stringValue(object["spotifyTrackId"]), stringValue(object["trackId"])),
            youtubeVideoId: videoId.trimmed,
            youtubeTitle: firstNonEmpty(stringValue(object["youtubeTitle"]), stringValue(object["title"])),
            hasCaptionStartTime: hasCaption,
            captionStartTimeSeconds: hasCaption && start.isFinite ? max(0, start) : 0,
            autoGenerated: boolValue(object["isAutoGenerated"]),
            submitterId: stringValue(object["submitterId"])
        )
    }

    var isAutoMatchedUnknownCaptionStart: Bool {
        autoGenerated && hasCaptionStartTime && abs(captionStartTimeSeconds) < 0.001
    }

    private static func validYouTubeId(_ value: String) -> Bool {
        value.trimmed.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil
    }

    private static func firstNonEmpty(_ values: String...) -> String {
        for value in values {
            let trimmed = value.trimmed
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    private static func stringValue(_ value: Any?) -> String {
        if let value = value as? String { return value.trimmed }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private static func doubleValue(_ value: Any?) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value.trimmed) ?? 0 }
        return 0
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return value.caseInsensitiveCompare("true") == .orderedSame || value == "1" }
        return false
    }
}

nonisolated enum YouTubeVideoSelection {
    static func extractId(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        func valid(_ id: String) -> String? {
            id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) == nil ? nil : id
        }
        if let id = valid(text) { return id }
        guard let url = URLComponents(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased() else { return nil }
        let path = url.path.split(separator: "/").map(String.init)
        if host == "youtu.be" { return path.count == 1 ? valid(path[0]) : nil }
        guard ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"].contains(host) else { return nil }
        if path.count == 2, ["shorts", "embed", "live"].contains(path[0]) { return valid(path[1]) }
        guard url.path == "/watch", let id = url.queryItems?.first(where: { $0.name == "v" })?.value else { return nil }
        return valid(id)
    }
}
