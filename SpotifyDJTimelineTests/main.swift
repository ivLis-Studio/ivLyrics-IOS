import Foundation

var failures: [String] = []

func expectEqual(_ actual: Int64, _ expected: Int64, _ name: String) {
    if actual != expected {
        failures.append("\(name): expected \(expected), got \(actual)")
    }
}

func update(
    _ timeline: inout SpotifyDJLyricsTimeline,
    trackKey: String,
    positionMs: Int64,
    playing: Bool = true,
    djContext: Bool = false,
    djSegment: Bool = false,
    uptime: TimeInterval
) -> Int64 {
    timeline.update(
        trackKey: trackKey,
        playerPositionMs: positionMs,
        playing: playing,
        spotifyDJContext: djContext,
        spotifyDJSegment: djSegment,
        uptime: uptime
    )
}

do {
    var timeline = SpotifyDJLyricsTimeline()
    expectEqual(update(&timeline, trackKey: "track-a", positionMs: 0, uptime: 0), 0, "regular start")
    expectEqual(update(&timeline, trackKey: "track-a", positionMs: 2_500, uptime: 2.5), 2_500, "regular progress")
    expectEqual(update(&timeline, trackKey: "track-a", positionMs: 100, uptime: 2.6), 100, "regular seek")
    expectEqual(timeline.offsetMs, 0, "regular offset")
}

do {
    var timeline = SpotifyDJLyricsTimeline()
    _ = update(&timeline, trackKey: "track-a", positionMs: 150_000, djContext: true, uptime: 0)
    expectEqual(update(&timeline, trackKey: "track-b", positionMs: 10, djContext: true, uptime: 0.1), 10, "DJ handoff start")
    expectEqual(update(&timeline, trackKey: "track-b", positionMs: 2_500, djContext: true, uptime: 2.59), 2_500, "DJ overlap progress")
    expectEqual(update(&timeline, trackKey: "track-b", positionMs: 40, djContext: true, uptime: 2.69), 2_600, "DJ clock reset continuity")
    expectEqual(timeline.offsetMs, 2_560, "DJ clock reset offset")
}

do {
    var timeline = SpotifyDJLyricsTimeline()
    _ = update(&timeline, trackKey: "dj-segment", positionMs: 0, djSegment: true, uptime: 0)
    expectEqual(update(&timeline, trackKey: "track-a", positionMs: 3_441, djContext: true, uptime: 7), 3_441, "DJ narration handoff")
    expectEqual(update(&timeline, trackKey: "track-a", positionMs: 50, djContext: true, uptime: 7.1), 3_541, "DJ narration reset continuity")
}

do {
    var timeline = SpotifyDJLyricsTimeline()
    _ = update(&timeline, trackKey: "track-a", positionMs: 1_000, djContext: true, uptime: 0)
    _ = update(&timeline, trackKey: "track-b", positionMs: 5, uptime: 180)
    _ = update(&timeline, trackKey: "track-b", positionMs: 2_405, uptime: 182.4)
    expectEqual(update(&timeline, trackKey: "track-b", positionMs: 100, uptime: 182.5), 2_505, "DJ session metadata fallback")
}

if failures.isEmpty {
    print("Spotify DJ timeline tests passed")
} else {
    for failure in failures {
        fputs("FAIL: \(failure)\n", stderr)
    }
    exit(1)
}
