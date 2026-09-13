#!/usr/bin/env python3
"""Compare cached production timeline queries with their original scans, without an iOS device."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
content = (ROOT / "ivLyrics-IOS/ContentView.swift").read_text()
models = (ROOT / "ivLyrics-IOS/Models.swift").read_text()
production = models[models.index("enum InstrumentalBreakMarker {"):models.index("struct TrackSnapshot:")]
production += models[models.index("struct LyricsLine:"):models.index("enum LyricsTextShaping {")]
production += content[content.index("enum LyricsTimelineDisplayItem:"):content.index("struct LyricsInterludeView:")]
checks = r'''
var assertions = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    if !value() { fatalError(message) }
}
func line(_ start: Int64, _ end: Int64, _ text: String = "lyric") -> LyricsLine {
    LyricsLine(startTimeMs: start, endTimeMs: end, text: text)
}
var voices: [LyricsLine.VocalPart] = []
for index in 0..<4 {
    let start = Int64(2000 + index * 200)
    let end = Int64(5000 + index * 200)
    let syllable = LyricsLine.Syllable(text: "voice\(index)", startTimeMs: start, endTimeMs: end)
    voices.append(LyricsLine.VocalPart(id: "v\(index)", role: index == 0 ? "lead" : "duet", speaker: "vocal\(index)", kind: "vocal", text: "voice\(index)", syllables: [syllable]))
}
let duet = LyricsLine(startTimeMs: 2000, endTimeMs: 5000, text: "日本語 العربية", vocalParts: voices, furiganaText: "<ruby>日本語<rt>にほんご</rt></ruby>")
var fixtures: [[LyricsLine]] = [
    [], [line(0, 0, "untimed")], [line(1500, 2500), line(2600, 2650), line(2700, 2900), line(3000, 6000)],
    [line(1500, 12000, "overlap"), line(2500, 6000), line(15000, 17000)],
    [line(0, 500, "♪"), duet, line(6000, 6100, "♪"), line(10000, 12000), line(16000, 17000)],
    [line(2000, 3000), line(6500, 7500, "♪"), line(15000, 16000)],
    [line(2000, 6000), line(2000, 6500, "equal start"), line(15000, 15001), line(16000, 17000)],
    [line(5000, 6000), line(0, 0, "mixed untimed"), line(8000, 9500)],
    [line(1000, 2000), line(2400, 3000, "♪"), line(2600, 3600, "♪"), line(15000, 17000)]
]
var longLyrics: [LyricsLine] = []
for index in 0..<160 {
    let start = Int64(index * 180)
    longLyrics.append(line(start, start + 150, index % 17 == 0 ? "♪" : "long lyric \(index)"))
}
fixtures.append(longLyrics)
for lines in fixtures {
    for cacheEnds in [false, true] {
        let context = LyricsTimelineContext(lines: lines, cacheLyricEndTimes: cacheEnds)
        for automatic in [false, true] {
            for duration: Int64 in [17000, 24000, 42000] {
                var positions = Array(stride(from: Int64(-10), through: 44000, by: 97))
                for boundary in LyricsTimelineDisplayBuilder.queryBoundaries(lines: lines, markers: context.markerInterludeInfos, lyricEndTimes: context.lastLyricEndTimes) + [duration] {
                    positions += [boundary - 1, boundary, boundary + 1, boundary - 300, boundary + 300]
                }
                // Forward playback, look-ahead, reverse seek and cache evictions.
                positions = positions.sorted() + positions.reversed()
                for position in positions {
                    for queryPosition in [position, position + 300] {
                        let cached = LyricsTimelineDisplayBuilder.items(context: context, positionMs: queryPosition, trackDurationMs: duration, autoInstrumentalBreakEnabled: automatic)
                        let snapshot = LyricsTimelineDisplayBuilder.displaySnapshot(context: context, positionMs: queryPosition, trackDurationMs: duration, autoInstrumentalBreakEnabled: automatic)
                        check(snapshot === LyricsTimelineDisplayBuilder.displaySnapshot(context: context, positionMs: queryPosition, trackDurationMs: duration, autoInstrumentalBreakEnabled: automatic), "Repeated interval returns the same indexed snapshot")
                        let original = LyricsTimelineDisplayBuilder.uncachedItems(context: context, positionMs: queryPosition, trackDurationMs: duration, autoInstrumentalBreakEnabled: automatic)
                        check(cached.map(\.id) == original.map(\.id), "Items diverged at \(queryPosition), auto=\(automatic)")
                        let preview = LyricsTimelineDisplayBuilder.previewItem(context: context, positionMs: queryPosition, trackDurationMs: duration, autoInstrumentalBreakEnabled: automatic)
                        let expected = LyricsTimelineDisplayBuilder.uncachedPreviewItem(context: context, positionMs: queryPosition, trackDurationMs: duration, autoInstrumentalBreakEnabled: automatic)
                        check(snapshot.firstIndex(id: preview?.id) == preview.flatMap { value in original.firstIndex { $0.id == value.id } }, "Current/anticipated ID index follows actual item membership")
                        check(snapshot.firstIndex(id: original.last?.id) == original.last.flatMap { value in original.firstIndex { $0.id == value.id } }, "Last ID preserves first occurrence")
                        check(snapshot.firstIndex(lineIndex: 0) == original.firstIndex { if case .line(let index, _, _) = $0 { return index == 0 }; return false }, "Source index fallback follows actual item membership")
                        check(preview?.id == expected?.id, "Preview diverged at \(queryPosition)")
                    }
                }
            }
        }
    }
}
let duplicates = LyricsTimelineDisplaySnapshot(items: [
    .line(index: 7, line: line(100, 200), id: "duplicate"),
    .line(index: 8, line: line(200, 300), id: "duplicate"),
    .line(index: 7, line: line(300, 400), id: "later"),
    .interlude(.init(startTimeMs: 400, endTimeMs: 600, kind: "break", automatic: true)),
    .interlude(.init(startTimeMs: 400, endTimeMs: 600, kind: "break", automatic: false))
])
check(duplicates.firstIndex(id: "duplicate") == 0 && duplicates.firstIndex(lineIndex: 7) == 0, "Duplicate ID and source indices keep first occurrence")
check(duplicates.firstIndex(id: duplicates.items[3].id) == 3, "Duplicate interlude IDs keep first occurrence")
check(duplicates.firstIndex(id: nil) == nil && duplicates.firstIndex(id: "missing") == nil && duplicates.firstIndex(lineIndex: 999) == nil, "Absent targets remain absent")
let replacement = LyricsTimelineContext(lines: [line(900, 1000, "replacement")])
let replacementSnapshot = LyricsTimelineDisplayBuilder.displaySnapshot(context: replacement, positionMs: 950, trackDurationMs: 2000, autoInstrumentalBreakEnabled: false)
check(replacementSnapshot.firstIndex(id: "duplicate") == nil && replacementSnapshot.items.first?.startTimeMs == 900, "New lyric context replaces all indices")
let queryCache = TimelineIntervalCache<Int?>(boundaries: [0, 1000, 2000])
var scans = 0
for position in 0..<700 {
    for query in [position, position + 300] {
        let value = queryCache.value(position: Int64(query), duration: 5000, automaticInterludes: true) { scans += 1; return nil }
        check(value == nil, "Empty preview is cached correctly")
    }
}
check(scans == 1, "1400 unchanged/current/look-ahead queries require one scan")
_ = queryCache.value(position: 1000, duration: 5000, automaticInterludes: true) { scans += 1; return 1 }
check(scans == 2, "Exact semantic boundary recomputes once")
print("TIMELINE_CACHE_PASSED assertions=\(assertions) unchangedQueries=1400 scans=1")
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-ios-timeline-") as path:
    work = Path(path)
    (work / "main.swift").write_text('import Foundation\nextension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }\n' + production + checks)
    subprocess.run(["xcrun", "swiftc", "-O", str(ROOT / "ivLyrics-IOS/BoundedLRUCache.swift"), str(ROOT / "ivLyrics-IOS/TimelineIntervalCache.swift"), str(work / "main.swift"), "-o", str(work / "regression")], check=True)
    subprocess.run([str(work / "regression")], check=True)
