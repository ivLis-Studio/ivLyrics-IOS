import Foundation

struct SpotifyPlaybackRateLimitError: LocalizedError {
    let retryAfterSeconds: TimeInterval
    var errorDescription: String? { "Spotify playback rate limited; retrying in \(String(format: "%.0f", retryAfterSeconds))s" }
}

/// A suppressed refresh is not a new network failure and must not extend its deadline.
struct SpotifyPlaybackPollDeferred: Error {}

struct SpotifyPlaybackRetryPolicy {
    private var failures = 0
    private var emptyResponses = 0
    private var retryAt: TimeInterval = 0
    private var rateLimitedUntil: TimeInterval = 0

    func remainingDelay(now: TimeInterval) -> TimeInterval {
        max(0, max(retryAt, rateLimitedUntil) - now)
    }

    mutating func receivedPlayback(hasTrack: Bool, now: TimeInterval) {
        failures = 0
        // A poll and a user-triggered refresh can overlap. A response that began
        // before a newer 429 must not erase its still-active server deadline.
        if rateLimitedUntil <= now { rateLimitedUntil = 0 }
        if hasTrack {
            emptyResponses = 0
            retryAt = 0
        } else {
            emptyResponses = min(4, emptyResponses + 1)
            retryAt = now + min(15, 3 * pow(2, Double(emptyResponses - 1)))
        }
    }

    mutating func receivedFailure(now: TimeInterval, retryAfter: TimeInterval? = nil) {
        emptyResponses = 0
        if let retryAfter, retryAfter.isFinite {
            rateLimitedUntil = max(rateLimitedUntil, now + max(1, retryAfter))
        } else {
            failures = min(5, failures + 1)
            retryAt = now + min(30, 3 * pow(2, Double(failures - 1)))
        }
    }

    /// Foreground and explicit commands may bypass idle/network backoff, never HTTP 429.
    mutating func requestImmediateRefresh() {
        failures = 0
        emptyResponses = 0
        retryAt = 0
    }

    static func retryAfterSeconds(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let header else { return nil }
        let raw = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(raw), seconds.isFinite { return max(1, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw).map { max(1, $0.timeIntervalSince(now)) }
    }
}
