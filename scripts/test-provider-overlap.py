#!/usr/bin/env python3
"""Exercise production provider parsers and overlapping-row selection with synthetic input.

No network/device required. An optional local TTML path verifies a private report
without including its lyrics in the repository or output.
"""
from pathlib import Path
import subprocess
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'ivLyrics-IOS'
models = (SRC / 'Models.swift').read_text()
production = models[models.index('enum InstrumentalBreakMarker {'):models.index('enum LyricsTextShaping {')]
production += models[models.index('struct LyricsResult:'):models.index('struct ManualLrclibCandidate:')]
unison = (SRC / 'UnisonLyricsProvider.swift').read_text()
unison = unison[:unison.index('    struct FetchOutcome:')] + unison[unison.index('    struct ExternalParsedLyrics:'):]
unison = unison[:unison.index('    static func fetch(')] + unison[unison.index('    private static func parseTtmlLyrics('):]
unison = unison[:unison.index('    private static func isExactMetadataMatch(')] + unison[unison.index('    private static func normalizeMetadata('):]
plus = (SRC / 'LyricsPlusProvider.swift').read_text()
plus = plus[:plus.index('    static func fetch(')] + plus[plus.index('    private static func decodeTwice('):]
pax = (SRC / 'PaxsenixLyricsProvider.swift').read_text()
pax = pax[:pax.index('    static func fetch(')] + pax[pax.index('    private static func parsePayload('):]
pax = pax.replace('    private struct ParsedVariants:', '    struct ParsedVariants:').replace('    private static func parsePayload(', '    static func parsePayload(')
content = (SRC / 'ContentView.swift').read_text()
timeline = content[content.index('enum LyricsTimelineDisplayItem:'):content.index('struct LyricsInterludeView:')]
pip = (SRC / 'LyricsPictureInPictureController.swift').read_text()
pip_selection = 'struct PiPSelectionProbe { var lines: [LyricsLine]; var positionMs: Int64; struct ActiveLine { var line: LyricsLine; var index: Int; var progress: CGFloat }\n'
pip_selection += pip[pip.index('        var activeLine: ActiveLine? {'):pip.index('        var usesTimedKaraoke: Bool {')] + '}\n'
# Exclude networking only; all production parsing, metadata filtering, timings,
# roles, splitting and display selection execute unchanged.
prelude = r'''
import Foundation
extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    func nfkc() -> String { precomposedStringWithCompatibilityMapping }
    func regexReplacing(_ pattern: String, with replacement: String) -> String { replacingOccurrences(of: pattern, with: replacement, options: .regularExpression) }
}
struct HTTPStatusError: Error { var statusCode: Int; var message: String }
enum IvLyricsUtilities { static func firstNonEmpty(_ values: String...) -> String { values.first(where: { !$0.isEmpty }) ?? "" } }
'''
checks = r'''
var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    if !condition() { fatalError(message) }
}
let ttml = """
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div>
<p begin="1s" end="3s" ttm:agent="v1"><span begin="1s" end="3s">Early</span></p>
<p begin="2s" end="6s" ttm:agent="v2"><span begin="2s" end="6s">Later</span><span ttm:role="x-bg" begin="2.2s" end="2.8s"><span begin="2.2s" end="2.8s">Echo</span></span></p>
<p begin="5.9s" end="7s" ttm:agent="v1"><span begin="5.9s" end="7s">Third</span></p>
<p begin="6.95s" end="8s" ttm:agent="v2"><span begin="6.95s" end="8s">Fourth</span></p>
</div></body></tt>
"""
let unison = try UnisonLyricsProvider.parseExternalLyrics(ttml, format: "ttml", durationMs: 10000)
check(unison.lines.count == 4, "TTML transitive overlap preserves every paragraph")
check(unison.lines.map(\.startTimeMs) == [1000, 2000, 5900, 6950], "TTML source chronology stays stable")
check(unison.lines.map(\.endTimeMs) == [3000, 6000, 7000, 8000], "TTML original timing is not truncated")
check(unison.lines[0].text == "Early" && unison.lines[0].vocalParts.isEmpty, "Early primary is not reassigned as background")
check(unison.lines[1].vocalParts.map(\.role) == ["lead", "background"], "Explicit TTML background retains its parent")
check(unison.lines[1].vocalParts.map(\.text) == ["Later", "Echo"], "No independent primary text concatenates into the explicit parts")
let track = TrackSnapshot(title: "Fixture song", artist: "Fixture artist", durationMs: 30000)
let paxTtml = try PaxsenixLyricsProvider.parsePayload(["ttmlContent": ttml], durationMs: 10000, track: track)!.karaoke!
check(paxTtml.count == 4 && paxTtml.map(\.startTimeMs) == unison.lines.map(\.startTimeMs) && paxTtml.map(\.vocalParts) == unison.lines.map(\.vocalParts), "Pax TTML fallback preserves the same paragraph boundaries")
let plusRows: [[String: Any]] = [
    ["time": 1000, "duration": 2000, "text": "Early", "element": ["singer": "v1"], "syllabus": [["time": 1000, "duration": 2000, "text": "Early"]]],
    ["time": 2000, "duration": 4000, "text": "Later Echo", "element": ["singer": "v2"], "syllabus": [["time": 2000, "duration": 4000, "text": "Later"], ["time": 2200, "duration": 600, "text": "Echo", "isBackground": true]]],
    ["time": 5900, "duration": 1100, "text": "Third", "element": ["singer": "v1"], "syllabus": [["time": 5900, "duration": 1100, "text": "Third"]]],
    ["time": 6950, "duration": 1050, "text": "Fourth", "element": ["singer": "v2"], "syllabus": [["time": 6950, "duration": 1050, "text": "Fourth"]]]
]
let plus = try LyricsPlusProvider.parse(data: JSONSerialization.data(withJSONObject: ["type": "Word", "lyrics": plusRows]), durationMs: 10000).karaoke!
check(plus.count == 4, "LyricsPlus singer overlaps do not collapse paragraphs")
check(plus.map(\.startTimeMs) == [1000, 2000, 5900, 6950], "LyricsPlus independent primaries keep order")
check(plus.map(\.endTimeMs) == [3000, 6000, 7000, 8000], "LyricsPlus independent end times survive")
check(plus[1].vocalParts.map(\.role) == ["lead", "background"], "LyricsPlus isBackground remains explicit")
check(plus[0].vocalParts.isEmpty && plus[2].vocalParts.isEmpty, "LyricsPlus primary singers never become background")
let paxRows: [[String: Any]] = [
    ["timestamp": 1000, "endtime": 24000, "agent": "v1", "text": [["timestamp": 1000, "endtime": 24000, "text": "Sustain", "part": false]]],
    ["timestamp": 2000, "endtime": 4000, "agent": "v2", "text": [["timestamp": 2000, "endtime": 4000, "text": "Answer", "part": false]], "backgroundText": [["timestamp": 2200, "endtime": 2800, "text": "Echo", "part": false]]]
]
let pax = try PaxsenixLyricsProvider.parsePayload(["provider": "kugou", "syncType": "syllable", "lyrics": paxRows], durationMs: 30000, track: track)!.karaoke!
check(pax.count == 2 && pax[0].text == "Sustain", "Pax structured source rows stay separate")
check(pax[0].endTimeMs == 24000, "Pax explicit long overlap is not capped to the next row")
check(pax[1].vocalParts.map(\.role) == ["lead", "background"], "Pax explicit background remains attached")
for lines in [unison.lines, plus, pax] {
    let context = LyricsTimelineContext(lines: lines)
    check(LyricsTimelineDisplayBuilder.activeLineIndices(context: context, positionMs: 2500) == [0, 1], "Compact retains both independently singing rows")
    for index in [0, 1] {
        let visual = LyricsTimelineDisplayBuilder.playbackVisualState(context: context, lineIndex: index, positionMs: 2500, trackDurationMs: 30000, autoInstrumentalBreakEnabled: true)
        check(visual.highlighted && visual.animating, "Full timeline independently animates both primaries")
    }
}
var pipProbe = PiPSelectionProbe(lines: unison.lines, positionMs: 2500)
check(pipProbe.activeLines.map(\.index) == [0, 1], "PiP displays both independent primary source rows")
check(pipProbe.nextLineText == "Third", "PiP next-line preview skips sources already singing")
pipProbe.positionMs = 3000
check(pipProbe.activeLines.map(\.index) == [1], "PiP removes finished source precisely at its end")
pipProbe.positionMs = 2500
check(pipProbe.activeLines.map(\.index) == [0, 1], "PiP reverse seek restores overlapping rows")
let pipSustain = PiPSelectionProbe(lines: pax, positionMs: 9000)
check(pipSustain.activeLines.map(\.index) == [0] && pipSustain.nextLineText == nil, "PiP retains earlier sustain without re-showing a finished next line")
let ownParts = ["duet", "lead", "background"].enumerated().map { index, role in
    LyricsLine.VocalPart(id: "saved-part-\(index)", role: role, speaker: "saved-\(index)", kind: "vocal", text: "Saved \(index)", syllables: [.init(text: "Saved \(index)", startTimeMs: 1000, endTimeMs: 4000)])
}
let ownLine = LyricsLine(startTimeMs: 1000, endTimeMs: 4000, text: "Saved explicit vocals", vocalParts: ownParts)
let ownContext = LyricsTimelineContext(lines: [ownLine])
check(LyricsTimelineDisplayBuilder.activeLineIndices(context: ownContext, positionMs: 2000) == [0], "Saved ivSync parts remain in their single explicit source row")
check(ownContext.lines[0].vocalParts == ownParts, "Compact/timeline selection never rewrites saved ivSync parts or roles")
let equalStarts = [LyricsLine(startTimeMs: 1000, endTimeMs: 2000, text: "First"), LyricsLine(startTimeMs: 1000, endTimeMs: 6000, text: "Second")]
check(LyricsTimelineDisplayBuilder.activeLineIndices(context: LyricsTimelineContext(lines: equalStarts), positionMs: 1500) == [0, 1], "Equal-start primary rows preserve source order regardless of duration")
let context = LyricsTimelineContext(lines: unison.lines)
check(LyricsTimelineDisplayBuilder.activeLineIndices(context: context, positionMs: 3000) == [1], "Compact removes finished source precisely at its end")
check(LyricsTimelineDisplayBuilder.activeLineIndices(context: context, positionMs: 2500) == [0, 1], "Compact reverse seek restores both sources")
let longOverlap = LyricsTimelineContext(lines: pax)
check(LyricsTimelineDisplayBuilder.activeLineIndices(context: longOverlap, positionMs: 9000) == [0], "Earlier sustained source survives later source completion")
if case .interlude = LyricsTimelineDisplayBuilder.previewItem(context: longOverlap, positionMs: 9000, trackDurationMs: 30000, autoInstrumentalBreakEnabled: true) {
    fatalError("Shorter overlapping source must not create an interlude over a sustained vocal")
}
check(LyricsTimelineDisplayBuilder.items(context: longOverlap, positionMs: 9000, trackDurationMs: 30000, autoInstrumentalBreakEnabled: true).allSatisfy { if case .interlude = $0 { return false }; return true }, "Timeline does not insert an automatic break over sustained vocals")
if CommandLine.arguments.count > 1 {
    let sample = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
    let parsed = try UnisonLyricsProvider.parseExternalLyrics(sample, format: "ttml", durationMs: 214884)
    check(parsed.lines.count == 40, "Private report preserves all 40 source paragraphs")
    check(parsed.lines[33...36].map(\.startTimeMs) == [172498, 180117, 182297, 187993], "Private report 2:53 preserves all four starts")
    check(parsed.lines[37].startTimeMs == 190542 && parsed.lines[38].startTimeMs == 192075, "Private report late longer source stays after earlier source")
    print("PRIVATE_TTML_PASSED sourceLines=40 parsedLines=40")
}
print("PROVIDER_OVERLAP_PASSED assertions=\(assertions)")
'''
with tempfile.TemporaryDirectory(prefix='ivlyrics-ios-provider-overlap-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(prelude + production + unison + plus + pax + timeline + pip_selection + checks)
    subprocess.run(['xcrun', 'swiftc', '-D', 'DEBUG', str(SRC / 'BoundedLRUCache.swift'), str(SRC / 'TimelineIntervalCache.swift'), str(work / 'main.swift'), '-o', str(work / 'tests')], check=True)
    subprocess.run([str(work / 'tests'), *sys.argv[1:]], check=True)
