#!/usr/bin/env python3
"""Replay production timeline handoffs and fade retention; preserve shipped timing/anchor queries."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
content = (SRC / "ContentView.swift").read_text()
models = (SRC / "Models.swift").read_text()
start = "enum LyricsTimelineDisplayItem:"
end = "struct LyricsInterludeView:"
production = content[content.index(start):content.index(end)]
baseline = subprocess.check_output(["git", "show", "6076918:ivLyrics-IOS/ContentView.swift"], cwd=ROOT, text=True)
assert production == baseline[baseline.index(start):baseline.index(end)], "Presentation must not change timing, membership, overlap or anchor queries"
production = models[models.index("enum InstrumentalBreakMarker {"):models.index("struct TrackSnapshot:")] + models[models.index("struct LyricsLine:"):models.index("enum LyricsTextShaping {")] + production
checks = r'''
var count = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    count += 1; if !value() { fatalError(message) }
}
func segment(_ context: LyricsTimelineContext, _ position: Int64, _ auto: Bool) -> InterludeTransition.Segment? {
    guard let item = LyricsTimelineDisplayBuilder.previewItem(context: context, positionMs: position,
        trackDurationMs: 20000, autoInstrumentalBreakEnabled: auto), case .interlude(let info) = item else { return nil }
    return .init(id: item.id, startMs: info.startTimeMs, endMs: info.endTimeMs, kind: info.kind, automatic: info.automatic)
}
func line(_ start: Int64, _ end: Int64, _ text: String) -> LyricsLine {
    .init(startTimeMs: start, endTimeMs: end, text: text)
}
let fixtures = [
    [line(1000, 2000, "前の歌詞"), line(10000, 14000, "戻る歌詞")],
    [line(0, 1, "♪"), line(7000, 8000, "歌詞")],
    [line(1000, 2000, "歌詞"), line(3000, 9000, "♪"), line(10000, 14000, "次の歌詞")],
    [line(1000, 14000, "重なり"), line(3000, 4000, "♪"), line(7000, 8000, "別の歌声")]
]
var handoffs = 0
for lines in fixtures {
    let context = LyricsTimelineContext(lines: lines)
    for auto in [false, true] {
        var transition = InterludeTransition()
        for position: Int64 in stride(from: 0, through: 20000, by: 8) {
            let next = segment(context, position, auto)
            let previous = transition.active
            let now = Double(position) / 1000
            transition.update(next: next, positionMs: position, now: now, scope: "same-track", enabled: true)
            if let previous, next != previous, position >= previous.endMs, position - previous.endMs <= 120 {
                handoffs += 1
                check(transition.outgoing?.segment == previous, "Departing indicator retained at first lyric frame")
                check(transition.outgoing?.startedAt == now, "Fade begins at observed handoff")
                let firstFrame = InterludeTransition.exitAppearance(elapsed: 1.0 / 120)
                check(firstFrame.opacity > 0.99 && firstFrame.scale > 0.99, "No first-frame snap")
            }
            if let outgoing = transition.outgoing {
                check(next?.id != outgoing.segment.id, "Ghost never becomes active lyric/timeline item")
                check(now - outgoing.startedAt < InterludeTransition.exitSeconds, "Exit lifetime bounded")
            }
        }
    }
}
check(handoffs >= 3, "Replay explicit/automatic breaks and prelude")
let gap = InterludeTransition.Segment(id: "gap", startMs: 1000, endMs: 4000, kind: "break", automatic: true)
func active() -> InterludeTransition {
    var state = InterludeTransition()
    state.update(next: gap, positionMs: 2000, now: 1, scope: "track", enabled: true)
    return state
}
var state = active()
state.update(next: nil, positionMs: 4000, now: 3, scope: "track", enabled: true)
check(state.outgoing?.segment == gap, "Exact handoff retains view")
state.update(next: nil, positionMs: 4241, now: 3.241, scope: "track", enabled: true)
check(state.outgoing == nil, "Retired view disposed")
for (position, scope, enabled) in [(Int64(8000), "track", true), (0, "track", true), (4000, "replacement", true), (4000, "track", false)] {
    var state = active()
    state.update(next: nil, positionMs: position, now: 3, scope: scope, enabled: enabled)
    check(state.outgoing == nil, "Seek/track change/reduced or disabled motion cancels ghost")
}
state = active()
state.update(next: nil, positionMs: 4000, now: 3, scope: "track", enabled: true)
state.update(next: gap, positionMs: 2000, now: 3.02, scope: "track", enabled: true)
check(state.active == gap && state.outgoing == nil, "Reverse seek during fade cancels old ghost")
for ms in 0...240 {
    let appearance = InterludeTransition.exitAppearance(elapsed: Double(ms) / 1000)
    check((0...1).contains(appearance.opacity) && (0.94...1).contains(appearance.scale), "Fade/scale bounds")
    if ms > 0 {
        check(appearance.opacity <= InterludeTransition.exitAppearance(elapsed: Double(ms - 1) / 1000).opacity, "Smooth monotonic exit")
    }
}
check(InterludeTransition.exitAppearance(elapsed: 0).opacity == 1 && InterludeTransition.exitAppearance(elapsed: 0.24).opacity == 0, "Continuous lifetime endpoints")
check(InterludeTransition.entryOpacity(positionMs: 1000, startMs: 1000, enabled: true) == 0, "Smooth entry begins transparent")
check(InterludeTransition.entryOpacity(positionMs: 1180, startMs: 1000, enabled: true) == 1, "Entry settles in 180 ms")
check(InterludeTransition.entryOpacity(positionMs: 1000, startMs: 1000, enabled: false) == 1, "Motion disabled is immediately visible")
print("Interlude regression: \(count) checks passed, \(handoffs) timeline handoffs")
'''
# Exits live outside the stack; both LP/main preview and scrolling portrait/landscape use it.
assert content.count(".task(id: interludeTransition.outgoing)") == 2
assert content.count("InterludeExitOverlay(startedAt:") == 2
assert "proxy.frame(in: .named(\"lyrics-interlude-viewport\"))" in content
assert ".allowsHitTesting(false)\n        .accessibilityHidden(true)" in content
assert "animationsEnabled: settings.vinylAnimationsEnabled" in (SRC / "VinylPlayerModeView.swift").read_text()
with tempfile.TemporaryDirectory(prefix="ivlyrics-interlude-") as temp:
    path = Path(temp)
    (path / "main.swift").write_text('import Foundation\nextension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }\n' + production + checks)
    sources = [SRC / "BoundedLRUCache.swift", SRC / "TimelineIntervalCache.swift", SRC / "InterludeTransition.swift", path / "main.swift"]
    subprocess.run(["xcrun", "swiftc", "-O", *map(str, sources), "-o", str(path / "checks")], check=True)
    subprocess.run([str(path / "checks")], check=True)
