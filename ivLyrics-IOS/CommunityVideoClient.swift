import Foundation

/// A value captured when Share is pressed, before authentication or networking can yield.
struct CommunityVideoSubmission: Encodable, Equatable, Sendable {
    let action = "submit"
    let isrc: String
    let trackId: String
    let title: String
    let artist: String
    let album: String
    let videoId: String
    let videoTitle: String
    let startTime: Double
    // The native video player does not apply skip segments.
    let skipSegments: [String] = []

    static func capture(
        track: TrackSnapshot,
        lyricsISRC: String,
        video: YouTubeVideoInfo,
        firstLyricTimeMs: Int64?,
        videoOffsetMs: Int
    ) -> Self? {
        let isrc = TrackSnapshot.normalizeIsrc(IvLyricsUtilities.firstNonEmpty(lyricsISRC, track.isrc))
        guard isrc.range(of: #"^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$"#, options: .regularExpression) != nil,
              let firstLyricTimeMs, firstLyricTimeMs >= 0,
              YouTubeVideoSelection.extractId(video.youtubeVideoId) == video.youtubeVideoId else { return nil }
        let videoISRC = TrackSnapshot.normalizeIsrc(video.isrc)
        guard videoISRC.isEmpty || videoISRC == isrc else { return nil }
        guard video.spotifyTrackId.isEmpty || track.trackId.isEmpty || video.spotifyTrackId == track.trackId else { return nil }
        let base = video.hasCaptionStartTime && !video.isAutoMatchedUnknownCaptionStart
            ? video.captionStartTimeSeconds : Double(firstLyricTimeMs) / 1000
        let startTime = base + Double(videoOffsetMs) / 1000
        guard base.isFinite, startTime.isFinite, (0...86_400).contains(startTime) else { return nil }
        return Self(isrc: isrc, trackId: track.trackId, title: track.title, artist: track.artist,
                    album: track.album, videoId: video.youtubeVideoId,
                    videoTitle: video.youtubeTitle, startTime: startTime)
    }
}

final class CommunityVideoClient: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func submit(_ submission: CommunityVideoSubmission, bearerToken: String, language: String) async throws {
        guard !bearerToken.trimmed.isEmpty else {
            throw HTTPStatusError(statusCode: 401, message: "Discord login is required")
        }
        var request = URLRequest(url: URL(string: "https://lyrics.api.ivl.is/lyrics/youtube/community")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 18
        request.httpBody = try JSONEncoder().encode(submission)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("https://xpui.app.spotify.com", forHTTPHeaderField: "Origin")
        request.setValue("https://xpui.app.spotify.com/", forHTTPHeaderField: "Referer")
        request.setValue("ios", forHTTPHeaderField: "X-ivLyrics-Client")
        request.setValue(language, forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPStatusError(statusCode: 0, message: "Invalid HTTP response")
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode), object?["success"] as? Bool == true else {
            throw HTTPStatusError(statusCode: http.statusCode, message: "Video timing could not be shared")
        }
    }
}
