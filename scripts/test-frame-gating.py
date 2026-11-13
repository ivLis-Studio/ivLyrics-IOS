#!/usr/bin/env python3
"""Frame gating: the lyric list and the progress bar skip frames only when nothing they draw changes.

Sweeps playback positions at 120 Hz steps over the production timeline queries. Whenever
LyricsDisplayKey is unchanged (LyricsDisplayClock does not publish), every row that does not follow
the playback clock must keep the visual state it had at the last publish, and so must the preview,
scroll target, interlude entry and display rows. Whenever PlaybackProgressClock skips a position, the
elapsed/remaining labels must read the same and the bar must have moved less than half a pixel.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
content = (ROOT / "ivLyrics-IOS/ContentView.swift").read_text()
models = (ROOT / "ivLyrics-IOS/Models.swift").read_text()
model = (ROOT / "ivLyrics-IOS/AppViewModel.swift").read_text()
production = models[models.index("enum InstrumentalBreakMarker {"):models.index("struct TrackSnapshot:")]
production += models[models.index("struct LyricsLine:"):models.index("enum LyricsTextShaping {")]
production += content[content.index("enum LyricsTimelineDisplayItem:"):content.index("struct LyricsInterludeView:")]
production += model[model.index("struct LyricsDisplayKey: Equatable {"):model.index("/// Coarse companion of PlaybackClock")]
progress_start = model.index("    nonisolated static func changesOnScreen(")
progress = model[progress_start:model.index("\n}\n", progress_start)].replace("nonisolated ", "")
production += "enum ProgressGate {\n" + progress + "\n}\n"
production += "enum PronunciationFirst { struct LineFill: Equatable { static let empty = LineFill() } }\n"
for name in ("BoundedLRUCache.swift", "TimelineIntervalCache.swift", "InterludeTransition.swift"):
    assert (ROOT / "ivLyrics-IOS" / name).exists()

checks = r'''
import CoreGraphics
var assertions = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    if !value() { fatalError(message) }
}
func line(_ start: Int64, _ end: Int64, _ text: String = "lyric", timed: Bool = false) -> LyricsLine {
    let syllables = timed
        ? [LyricsLine.Syllable(text: "ly", startTimeMs: start, endTimeMs: (start + end) / 2),
           LyricsLine.Syllable(text: "ric", startTimeMs: (start + end) / 2, endTimeMs: end)]
        : []
    return LyricsLine(startTimeMs: start, endTimeMs: end, text: text, syllables: syllables)
}
/// AppViewModel.activeLineIndex(at:)
func activeLineIndex(_ lines: [LyricsLine], _ position: Int64) -> Int {
    guard !lines.isEmpty else { return -1 }
    var candidate = 0
    for index in lines.indices {
        let line = lines[index]
        if position >= line.startTimeMs { candidate = index }
        if line.endTimeMs > line.startTimeMs, position >= line.startTimeMs, position < line.endTimeMs { return index }
    }
    return candidate
}
var fixtures: [[LyricsLine]] = [
    [], [line(0, 0, "untimed")],
    [line(1500, 2500), line(2600, 2650), line(2700, 2900), line(3000, 6000)],
    [line(1500, 12000, "overlap"), line(2500, 6000, timed: true), line(15000, 17000)],
    [line(0, 500, "♪"), line(2000, 5000, timed: true), line(6000, 6100, "♪"), line(10000, 12000), line(16000, 17000)],
    [line(2000, 3000), line(6500, 7500, "♪"), line(15000, 16000, timed: true)],
    [line(2000, 6000), line(2000, 6500, "equal start"), line(15000, 15001), line(16000, 17000)],
    [line(5000, 6000), line(0, 0, "mixed untimed"), line(8000, 9500)],
    [line(1000, 2000), line(2400, 3000, "♪"), line(2600, 3600, "♪"), line(15000, 17000)]
]
var store: [LyricsLine] = []
var cursor: Int64 = 1500
for index in 0..<14 {
    let duration = 3200 + Int64(index % 3) * 200
    store.append(line(cursor, cursor + duration, "store \(index)", timed: index % 2 == 0))
    cursor += duration + (index == 5 ? 1200 : 300)
}
fixtures.append(store)
var publishes = 0
var frames = 0
for lines in fixtures {
    for cacheEnds in [false, true] {
        let context = LyricsTimelineContext(lines: lines, cacheLyricEndTimes: cacheEnds)
        for automatic in [false, true] {
            for synced in [false, true] {
                for duration: Int64 in [17000, 42000, 60000] {
                    var publishedKey: LyricsDisplayKey?
                    var publishedStates: [LyricsLinePlaybackVisualState] = []
                    var follows: [Bool] = []
                    var publishedEntry = 1.0
                    for position in stride(from: Int64(-100), through: duration + 2000, by: 8) {
                        frames += 1
                        let key = LyricsTimelineDisplayBuilder.displayKey(
                            context: context, positionMs: position, trackDurationMs: duration,
                            autoInstrumentalBreakEnabled: automatic, syncedLyricsKaraokeAnimation: synced,
                            vocalPartAnchorsEnabled: true, activeLineIndex: activeLineIndex(lines, position))
                        let states = context.lines.indices.map {
                            LyricsTimelineDisplayBuilder.playbackVisualState(
                                context: context, lineIndex: $0, positionMs: position,
                                trackDurationMs: duration, autoInstrumentalBreakEnabled: automatic)
                        }
                        let preview = LyricsTimelineDisplayBuilder.previewItem(
                            context: context, positionMs: position, trackDurationMs: duration,
                            autoInstrumentalBreakEnabled: automatic)
                        var entry = 1.0
                        if case .interlude(let info)? = preview {
                            entry = InterludeTransition.entryOpacity(positionMs: Double(position), startMs: info.startTimeMs, enabled: synced)
                        }
                        if key != publishedKey {
                            publishes += 1
                            publishedKey = key
                            publishedStates = states
                            publishedEntry = entry
                            follows = context.lines.indices.map {
                                LyricsTimelineDisplayBuilder.lineFollowsPlaybackClock(
                                    line: context.lines[$0], visualState: states[$0],
                                    syncedLyricsKaraokeAnimation: synced, pronunciationFill: .empty)
                            }
                            continue
                        }
                        for index in states.indices where !follows[index] {
                            check(states[index].highlighted == publishedStates[index].highlighted
                                && states[index].animating == publishedStates[index].animating
                                && states[index].completedColorOpacity == publishedStates[index].completedColorOpacity,
                                  "A row that does not follow the clock keeps its state until the key changes (line \(index) at \(position))")
                        }
                        // Interlude rows follow the clock only while they enter.
                        check(key.interludeEntering || entry == publishedEntry, "Interlude entry is static unless entering (\(position))")
                    }
                }
            }
        }
    }
}
check(publishes * 4 < frames, "The key changes on a small share of frames (\(publishes)/\(frames))")

func label(_ ms: Int64) -> Int { max(0, Int(ms / 1000)) }
var progressPublishes = 0
for duration: Int64 in [57_000, 210_000, 600_000] {
    for width: CGFloat? in [nil, 780, 1_206, 2_853] {
        var published: Int64 = 0
        var count = 0
        for position in stride(from: Int64(0), through: duration + 500, by: 1) {
            if ProgressGate.changesOnScreen(from: published, to: position, durationMs: duration, widestTrackPixels: width) {
                published = position
                count += 1
                continue
            }
            check(label(position) == label(published) && label(duration - position) == label(duration - published),
                  "Labels never lag a skipped position")
            if let width {
                let move = Double(abs(min(duration, position) - min(duration, published))) / Double(duration) * Double(width)
                check(move < 0.5, "The bar never lags half a pixel")
            }
        }
        progressPublishes += count
        // Two label boundaries per second at most, plus about two bar steps per pixel.
        let bound = Int(duration / 1000) * 2 + Int((width ?? 0) * 2) + 4
        check(count <= bound, "Progress publishes stay near the visible change rate (\(count) <= \(bound))")
    }
}
print("FRAME_GATING_PASSED assertions=\(assertions) frames=\(frames) keyPublishes=\(publishes) progressPublishes=\(progressPublishes)")
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-ios-frame-gating-") as path:
    work = Path(path)
    (work / "main.swift").write_text('import Foundation\nextension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }\n' + production + checks)
    sources = [str(ROOT / "ivLyrics-IOS" / name) for name in ("BoundedLRUCache.swift", "TimelineIntervalCache.swift", "InterludeTransition.swift")]
    subprocess.run(["xcrun", "swiftc", "-O", *sources, str(work / "main.swift"), "-o", str(work / "regression")], check=True)
    subprocess.run([str(work / "regression")], check=True)
