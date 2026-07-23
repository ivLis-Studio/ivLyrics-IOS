import Foundation

struct SpotifyDJLyricsTimeline {
    private static let discontinuityThresholdMs: Int64 = 1_500
    private static let handoffWindowSeconds: TimeInterval = 15
    private static let sessionRetentionSeconds: TimeInterval = 30 * 60

    private var trackKey = ""
    private var lastPlaying = false
    private var handoffPending = false
    private var handoffStartedAt: TimeInterval = 0
    private var djSessionActiveUntil: TimeInterval = 0
    private var lyricsOffsetMs: Int64 = 0
    private var lastPlayerPositionMs: Int64 = 0
    private var lastLyricsPositionMs: Int64 = 0
    private var lastSampleAt: TimeInterval?

    mutating func update(
        trackKey incomingTrackKey: String,
        playerPositionMs: Int64,
        playing: Bool,
        spotifyDJContext: Bool,
        spotifyDJSegment: Bool,
        uptime: TimeInterval
    ) -> Int64 {
        let safePlayerPositionMs = max(0, playerPositionMs)
        let safeUptime = max(0, uptime)

        if spotifyDJContext || spotifyDJSegment {
            djSessionActiveUntil = safeUptime + Self.sessionRetentionSeconds
        }
        let djSessionActive = spotifyDJContext
            || spotifyDJSegment
            || (djSessionActiveUntil > 0 && safeUptime <= djSessionActiveUntil)
        let trackChanged = incomingTrackKey != trackKey

        if trackChanged {
            lyricsOffsetMs = 0
            handoffPending = djSessionActive && !spotifyDJSegment
            handoffStartedAt = safeUptime
            trackKey = incomingTrackKey
        } else if let lastSampleAt {
            let elapsedMs = max(0, Int64(((safeUptime - lastSampleAt) * 1_000).rounded()))
            let expectedElapsedMs = playing && lastPlaying ? elapsedMs : 0
            let driftMs = safePlayerPositionMs - lastPlayerPositionMs - expectedElapsedMs
            let withinHandoff = handoffPending
                && safeUptime - handoffStartedAt <= Self.handoffWindowSeconds

            if withinHandoff && driftMs <= -Self.discontinuityThresholdMs {
                lyricsOffsetMs = max(
                    0,
                    lastLyricsPositionMs + expectedElapsedMs - safePlayerPositionMs
                )
                handoffPending = false
            }
        }

        if handoffPending
            && safeUptime - handoffStartedAt > Self.handoffWindowSeconds {
            handoffPending = false
        }

        lastPlaying = playing
        lastPlayerPositionMs = safePlayerPositionMs
        lastLyricsPositionMs = safePlayerPositionMs + lyricsOffsetMs
        lastSampleAt = safeUptime
        return lastLyricsPositionMs
    }

    var offsetMs: Int64 {
        lyricsOffsetMs
    }

    mutating func reset() {
        trackKey = ""
        lastPlaying = false
        handoffPending = false
        handoffStartedAt = 0
        djSessionActiveUntil = 0
        lyricsOffsetMs = 0
        lastPlayerPositionMs = 0
        lastLyricsPositionMs = 0
        lastSampleAt = nil
    }
}
