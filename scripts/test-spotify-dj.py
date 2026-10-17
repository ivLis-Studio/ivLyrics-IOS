#!/usr/bin/env python3
"""Replay production DJ handoffs/context changes and optimistic seeks on host Swift.

No Spotify account, network or device is used; this is timing/propagation evidence.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
models = (SRC / "Models.swift").read_text()
production = models[models.index("struct TrackSnapshot:"):models.index("struct LyricsLine:")]
production += models[models.index("struct SpotifyPlaybackSnapshot:"):models.index("enum AppStatus:")]


def declaration(source, prefix):
    start = source.index(prefix)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end].replace("private ", "")


# Execute the actual HTTP response JSON decode/parse tail, omitting only the
# request, status and authorization handling. No replacement decoder is used.
service = (SRC / "SpotifyUserPlaybackService.swift").read_text()
request = declaration(service, "private func requestPlaybackSnapshot(")
decode = request[request.index("        guard let root = try JSONSerialization.jsonObject(with: data)"):request.rfind("\n    }")]
production += "struct WebPlaybackDecodeProbe {\nfunc decode(data: Data) throws -> SpotifyPlaybackSnapshot? {\n" + decode + "\n}\n"
for prefix in ["private func parseTrack(", "private func bestArtworkURL(", "private func stringValue(",
               "private func int64Value(", "private func intValue(", "private func boolValue("]:
    production += declaration(service, prefix) + "\n"
production += "}\n"

model = (SRC / "AppViewModel.swift").read_text()
seek = model[model.index("    private func seekPlayer("):model.index("    func skip(by")]
skip = model[model.index("    func skip(by"):model.index("    func skipToNextTrack()")]
assert seek.index("spotifyDJLyricsTimeline.registerExplicitSeek(") < seek.index("guard shouldSendSeekCommand")
assert "seekPlayer(to: target, track: &track)" in skip
assert model.count("spotifyContextKnown: playback.spotifyContextKnown") == 2
assert "spotifyContextKnown: currentSpotifyContextKnown" in model
assert "currentSpotifyContextKnown = false" in model
assert "spotifyContextKnown: !contextTitle.isEmpty || !contextURI.trimmed.isEmpty" in (SRC / "SpotifyAppRemotePlaybackService.swift").read_text()

checks = r'''
var count = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    count += 1
    if !value() { fatalError(label) }
}
func sample(_ state: inout SpotifyDJLyricsTimeline, _ key: String, _ position: Int64, _ time: Double,
            dj: Bool = false, segment: Bool = false, known: Bool = false, playing: Bool = true) -> Int64 {
    state.update(trackKey: key, playerPositionMs: position, playing: playing,
                 spotifyDJContext: dj, spotifyDJSegment: segment, spotifyContextKnown: known, uptime: time)
}
func handoff() -> SpotifyDJLyricsTimeline {
    var state = SpotifyDJLyricsTimeline()
    _ = sample(&state, "intro", 0, 100, dj: true, segment: true, known: true)
    _ = sample(&state, "song", 6000, 101)
    return state
}
var state = handoff()
check(sample(&state, "song", 7000, 102) == 7000, "Unknown context retains the DJ handoff window")
check(sample(&state, "song", 1000, 103) == 8000 && state.offsetMs == 7000, "Genuine DJ reset keeps the lyric timeline continuous")
check(sample(&state, "song", 2000, 104) == 9000, "Corrected timeline keeps advancing")
state.registerExplicitSeek(trackKey: "song", playerPositionMs: 10000, uptime: 104)
check(sample(&state, "song", 11000, 105) == 18000, "Explicit seek preserves an established DJ lyric mapping")
check(sample(&state, "song", 12000, 106, known: true) == 12000 && state.offsetMs == 0, "Known non-DJ context clears the offset on the same track")
_ = sample(&state, "next", 8000, 107)
check(sample(&state, "next", 0, 108) == 0, "Known non-DJ context also clears retained session state")

for target: Int64 in [0, 2000, 20000] {
    state = handoff()
    state.registerExplicitSeek(trackKey: "song", playerPositionMs: target, uptime: 102)
    check(sample(&state, "song", target + 1000, 103) == target + 1000 && state.offsetMs == 0,
          "Backward/forward explicit seeks and relative skips cannot create a handoff correction")
}
state = handoff()
state.registerExplicitSeek(trackKey: "old-song", playerPositionMs: 0, uptime: 102)
check(sample(&state, "song", 0, 103) == 8000, "A stale seek for another song cannot suppress a genuine DJ reset")
state = handoff()
_ = sample(&state, "song", 7000, 102, dj: true, known: true)
check(sample(&state, "song", 1000, 103, dj: true, known: true) == 8000, "Known DJ context still permits correction")
state = handoff()
check(sample(&state, "song", 0, 117) == 0 && state.offsetMs == 0, "Expired handoff does not reinterpret a late backward jump")
state = handoff()
_ = sample(&state, "song", 6000, 102, playing: false)
check(sample(&state, "song", 6000, 110, playing: false) == 6000 && state.offsetMs == 0, "Pausing does not introduce drift")
state = handoff()
check(sample(&state, "other", 8000, 102, known: true) == 8000, "Known non-DJ track change clears the handoff")
check(sample(&state, "other", 0, 103) == 0, "The next unknown snapshot cannot revive the cleared handoff")
state.reset()
check(sample(&state, "fresh", -100, -1) == 0 && state.offsetMs == 0, "Reset and negative input are safe")

let track = TrackSnapshot(title: "Track", artist: "Artist", durationMs: 60000,
                          positionMs: 20000, lastPositionUpdateUptime: 100, playing: true)
var guardState = SpotifyPlaybackInteractionGuard()
guardState.registerSeek(trackKey: track.stableKey, positionMs: 20000, uptime: 100)
let playback = SpotifyPlaybackSnapshot(track: track, progressMs: 0, playing: true,
    fetchedAt: Date(), deviceName: "fixture", spotifyDJContext: false, spotifyContextKnown: true)
let reconciled = guardState.reconcile(playback, currentTrack: track, uptime: 101)
check(reconciled.progressMs == 21000, "Old player sample cannot immediately undo a seek")
check(reconciled.spotifyContextKnown && !reconciled.spotifyDJContext, "Optimistic reconciliation preserves authoritative context")
check(!SpotifyPlaybackSnapshot(track: track, progressMs: 0, playing: true, fetchedAt: Date(), deviceName: "fixture").spotifyContextKnown,
      "Missing context remains unknown")
check(SpotifyPlaybackSnapshot.detectsSpotifyDJContext(title: "Spotify DJ", uri: ""), "DJ title detection is unchanged")

let decoder = WebPlaybackDecodeProbe()
let baseJSON: [String: Any] = [
    "item": ["id": "0123456789012345678901", "type": "track", "name": "Fixture",
             "artists": [["name": "Fixture artist"]], "duration_ms": 60000],
    "progress_ms": 2000, "is_playing": true
]
let contexts: [(String, Any?, Bool, Bool)] = [
    ("missing", nil, false, false),
    ("explicit null", NSNull(), true, false),
    ("empty object", [String: Any](), true, false),
    ("DJ playlist", ["uri": "spotify:playlist:37i9dQZF1EYkqdzj48dyYq"], true, true),
    ("regular playlist", ["uri": "spotify:playlist:regular"], true, false),
    ("malformed string", "invalid", false, false),
    ("malformed array", [Any](), false, false)
]
for (label, context, expectedKnown, expectedDJ) in contexts {
    var root = baseJSON
    if let context { root["context"] = context }
    let data = try JSONSerialization.data(withJSONObject: root)
    let decoded = try decoder.decode(data: data)!
    check(decoded.spotifyContextKnown == expectedKnown, "Actual Web API JSON decode preserves known-context contract: \(label)")
    check(decoded.spotifyDJContext == expectedDJ, "Actual Web API JSON decode preserves DJ detection: \(label)")
    check(decoded.track.title == "Fixture" && decoded.progressMs == 2000 && decoded.playing,
          "Context handling retains the production track/playback decode")
    var timeline = handoff()
    _ = sample(&timeline, "song", 7000, 102)
    _ = sample(&timeline, "song", 1000, 103)
    let corrected = sample(&timeline, "song", decoded.progressMs, 104,
                           dj: decoded.spotifyDJContext, known: decoded.spotifyContextKnown)
    check(corrected == (expectedKnown && !expectedDJ ? 2000 : 9000),
          "Decoded explicit null clears DJ correction while missing context retains it: \(label)")
    if expectedKnown && !expectedDJ {
        _ = sample(&timeline, "next", 6000, 105)
        check(sample(&timeline, "next", 0, 106) == 0, "Decoded non-DJ context clears retained session state")
    }
}
print("SPOTIFY_DJ_PASSED assertions=\(count)")
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-ios-dj-") as directory:
    work = Path(directory)
    main = work / "main.swift"
    main.write_text('import Foundation\nextension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }\n' + production + checks)
    subprocess.run(["xcrun", "swiftc", str(SRC / "SpotifyDJLyricsTimeline.swift"), str(main), "-o", str(work / "checks")], check=True)
    subprocess.run([str(work / "checks")], check=True)
