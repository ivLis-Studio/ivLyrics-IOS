#!/usr/bin/env python3
"""Compare production PiP selection with 715ca4b, and count repeated work.

Uses the actual marker parser, lyric models, selection and annotation cache.
This verifies data/selection equivalence, not device rendering or CPU savings.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
baseline = subprocess.check_output(
    ["git", "show", "715ca4b:ivLyrics-IOS/LyricsPictureInPictureController.swift"], cwd=ROOT, text=True
)
candidate = (SRC / "LyricsPictureInPictureController.swift").read_text()
models = (SRC / "Models.swift").read_text()


def section(source, start, end):
    first = source.index(start)
    return source[first:source.index(end, first + len(start))]


production = section(models, "enum InstrumentalBreakMarker {", "struct TrackSnapshot:")
production = production.replace(
    "static func isMarkerText(_ text: String, allowEmpty: Bool = true) -> Bool {",
    "static func isMarkerText(_ text: String, allowEmpty: Bool = true) -> Bool { markerCalls += 1",
)
production += section(models, "struct LyricsLine:", "enum LyricsTextShaping {")
timeline = (SRC / "PictureInPictureLyricsTimeline.swift").read_text().replace(
    "for index in lines.indices {", "for index in lines.indices { candidateVisits += 1"
)
production += timeline
production += (SRC / "CulturalAnnotation.swift").read_text()


def probe(source, name, cached):
    code = f"struct {name} {{\n"
    code += "var lines: [LyricsLine]; var positionMs: Int64\n"
    code += "var syncedLyricsKaraokeAnimationEnabled = true; var karaokeDisplayGranularity = \"character\"\n"
    code += "struct ActiveLine { var line: LyricsLine; var index: Int; var progress: CGFloat }\n"
    if cached:
        code += "var selection: PictureInPictureLyricsTimeline.Selection\n"
    body = section(source, "        var activeLine: ActiveLine? {", "        func renderIdentity(")
    if not cached:
        body = body.replace("for candidate in lines.indices {", "for candidate in lines.indices { baselineVisits += 1")
        body = body.replace("let line = lines[index]\n                guard line.isTimed,", "baselineVisits += 1\n                let line = lines[index]\n                guard line.isTimed,")
    return code + body + "}\n"


# A controller update stores one selection; drawing and scheduling only read it.
assert candidate.count("lyricsTimeline.selection(at:") == 1
assert "nextState.selection = lyricsTimeline.selection(at: positionMs)" in candidate
assert "state.selection = debugTimeline.selection(at: state.positionMs)" in candidate
view_model = (SRC / "AppViewModel.swift").read_text()
assert "didSet { culturalAnnotationLineCache.removeAll() }" in view_model
assert "cachedTimelineContext = nil\n            culturalAnnotationLineCache.removeAll()" in view_model
assert "CulturalAnnotation.forLine(" not in (SRC / "ContentView.swift").read_text()

prelude = r'''
import Foundation
extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
enum AppSettings {
    static let karaokeDisplayLine = "line"
    static func normalizeKaraokeDisplayGranularity(_ value: String) -> String { value }
}
var markerCalls = 0, baselineVisits = 0, candidateVisits = 0
'''
checks = r'''
var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    if !condition() { fatalError(message) }
}
func line(_ start: Int64, _ end: Int64, _ text: String = "lyric") -> LyricsLine {
    LyricsLine(startTimeMs: start, endTimeMs: end, text: text,
               syllables: [.init(text: text, startTimeMs: start, endTimeMs: end)])
}
let voices = ["lead", "background", "duet"].enumerated().map { index, role in
    LyricsLine.VocalPart(id: "voice-\(index)", role: role, speaker: "vocal\(index)", kind: "wave",
                        text: "声 العربية \(index)", syllables: [.init(text: "声", startTimeMs: 1500, endTimeMs: 3500)])
}
var fixtures: [[LyricsLine]] = [
    [], [line(0, 0, "untimed")], [line(-1, 2000, "untimed interval")],
    [line(1000, 3000), line(2000, 6000), line(5900, 7000), line(6950, 8000)],
    [line(1000, 24000, "sustain"), line(2000, 4000, "answer")],
    [line(1000, 2000, "equal first"), line(1000, 6000, "equal second")],
    [line(5000, 7000, "unsorted first"), line(1000, 3000, "unsorted second"), line(0, 0)],
    [line(1000, 2000, "♪"), line(2000, 3000, "&#x266a;"), line(3000, 5000, "<i>[ ♪ ]</i>"), line(5000, 6000)],
    [line(1000, 2000, ""), line(3000, 4000, "next")],
    [LyricsLine(startTimeMs: 1000, endTimeMs: 4000, text: "声 العربية", vocalParts: voices,
                furiganaText: "<ruby>声<rt>こえ</rt></ruby>")]
]
fixtures.append((0..<200).map { index in
    let start = Int64(index * 400)
    return line(start, start + (index % 5 == 0 ? 1000 : 350), index % 17 == 0 ? "♪" : "fixture \(index)")
})
let timeline = PictureInPictureLyricsTimeline()
for lines in fixtures {
    timeline.update(lines: lines)
    let preparedMarkers = markerCalls
    timeline.update(lines: lines)
    check(markerCalls == preparedMarkers, "Unchanged source never re-parses markers")
    var positions = Array(stride(from: Int64(-10), through: 90000, by: 179))
    for line in lines { positions += [line.startTimeMs - 1, line.startTimeMs, line.startTimeMs + 1, line.endTimeMs - 1, line.endTimeMs, line.endTimeMs + 1] }
    positions += positions.reversed()
    for position in positions {
        let selection = timeline.selection(at: position)
        var old = BaselineProbe(lines: lines, positionMs: position)
        var next = CandidateProbe(lines: lines, positionMs: position, selection: selection)
        for enabled in [true, false] {
            old.syncedLyricsKaraokeAnimationEnabled = enabled
            next.syncedLyricsKaraokeAnimationEnabled = enabled
            for granularity in ["character", "word", "line"] {
                old.karaokeDisplayGranularity = granularity
                next.karaokeDisplayGranularity = granularity
                check(old.activeLine?.index == next.activeLine?.index, "Active source differs at \(position)")
                check(old.activeLine?.progress == next.activeLine?.progress, "Fallback progress differs")
                check(old.activeLines.map(\.index) == next.activeLines.map(\.index), "Overlap source order differs")
                check(old.activeLines.map(\.progress) == next.activeLines.map(\.progress), "Overlap progress differs")
                check(old.nextLineText == next.nextLineText, "Next source differs")
                check(old.preferredFrameInterval == next.preferredFrameInterval, "Frame cadence differs")
            }
        }
    }
}
// Simulate six readers in a rendered tick: identity selection, interval checks,
// drawing, sample-buffer duration, plus next preview. Selection is computed once.
let benchmarkLines = fixtures.last!
timeline.update(lines: benchmarkLines)
markerCalls = 0; baselineVisits = 0; candidateVisits = 0
for frame in 0..<600 {
    let position = Int64(30000 + frame * 33)
    let old = BaselineProbe(lines: benchmarkLines, positionMs: position)
    _ = old.activeLine; _ = old.activeLines; _ = old.preferredFrameInterval
    _ = old.activeLine; _ = old.activeLines; _ = old.nextLineText; _ = old.usesTimedKaraoke
}
let oldMarkers = markerCalls, oldVisits = baselineVisits
markerCalls = 0
for frame in 0..<600 {
    let position = Int64(30000 + frame * 33)
    timeline.update(lines: benchmarkLines)
    let next = CandidateProbe(lines: benchmarkLines, positionMs: position, selection: timeline.selection(at: position))
    _ = next.activeLine; _ = next.activeLines; _ = next.preferredFrameInterval
    _ = next.activeLine; _ = next.activeLines; _ = next.nextLineText; _ = next.usesTimedKaraoke
}
check(markerCalls == 0, "Steady playback must not re-parse markers")
check(candidateVisits == 600 * benchmarkLines.count, "One source traversal per tick")
check(candidateVisits < oldVisits, "Repeated source traversal removed")
let measuredCandidateVisits = candidateVisits
// Streaming metadata/content edits invalidate preparation even at the same index.
var streamed = benchmarkLines
streamed[0] = line(0, 50000, "changed ♪")
timeline.update(lines: streamed)
check(timeline.selection(at: 2500).activeIndices == BaselineProbe(lines: streamed, positionMs: 2500).activeLines.map(\.index), "Streamed timing/text update")

let annotationCache = CulturalAnnotationLineCache()
var annotationLookups = 0
var annotations = [CulturalAnnotation(lineIndex: 0, expression: "声", note: "voice"),
                   CulturalAnnotation(lineIndex: 0, expression: "世界", note: "world"),
                   CulturalAnnotation(lineIndex: 1, expression: "hello", note: "greeting")]
func cached(_ index: Int, _ text: String) -> [CulturalAnnotation] {
    annotationCache.value(lineIndex: index, text: text) {
        annotationLookups += 1
        return CulturalAnnotation.forLine(annotations, lineIndex: index, text: text)
    }
}
for _ in 0..<1200 {
    for (index, text) in ["世界の声", "hello", "no annotations"].enumerated() {
        check(cached(index, text) == CulturalAnnotation.forLine(annotations, lineIndex: index, text: text), "Annotation selection/order changed")
    }
}
check(annotationLookups == 3, "3600 stable queries require three searches, including empty results")
check(cached(0, "声") == CulturalAnnotation.forLine(annotations, lineIndex: 0, text: "声"), "Displayed original text changes immediately")
annotations[0].note = "streamed note"
annotationCache.removeAll()
check(cached(0, "声").first?.note == "streamed note", "Streaming annotations invalidate")
annotations = []
annotationCache.removeAll()
check(cached(0, "声").isEmpty, "Song reset removes stale annotations")
print("PIP_SELECTION_CACHE_PASSED assertions=\(assertions) frames=600 lines=200 baselineMarkerCalls=\(oldMarkers) candidateMarkerCalls=0 baselineSourceVisits=\(oldVisits) candidateSourceVisits=\(measuredCandidateVisits) stableAnnotationQueries=3600 searches=3")
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-ios-pip-selection-") as directory:
    work = Path(directory)
    main = work / "main.swift"
    main.write_text(prelude + production + probe(baseline, "BaselineProbe", False)
                    + probe(candidate, "CandidateProbe", True) + checks)
    subprocess.run(["xcrun", "swiftc", "-O", str(main), "-o", str(work / "tests")], check=True)
    subprocess.run([str(work / "tests")], check=True)
