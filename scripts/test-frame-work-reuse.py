#!/usr/bin/env python3
"""Pin the per-frame work removed from the lyric renderers against 5e20c0e, on host Swift.

Compiles the 5e20c0e and the current production code side by side: karaoke segment assembly and
its continuous-effect checks (SyllableKaraokeText), the pronunciation row comparison (lyric rows and
PiP frames), TimelineIntervalCache and the Spotify DJ segment check. Every output must be identical;
the counters show the work that no longer repeats on every display frame. Colors are deterministic
test tokens; rasterization is not claimed here (compare simulator screenshots for that).
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
BASELINE = "5e20c0e"


def baseline(name):
    return subprocess.check_output(["git", "show", f"{BASELINE}:ivLyrics-IOS/{name}"], cwd=ROOT, text=True)


def section(source, start, end):
    first = source.index(start)
    return source[first:source.index(end, first + len(start))]


def declaration(source, prefix):
    start = source.index(prefix)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def inject(source, anchor, statement):
    assert source.count(anchor) == 1, anchor
    return source.replace(anchor, anchor + statement)


view = (SRC / "ContentView.swift").read_text()
old_view = baseline("ContentView.swift")
models = (SRC / "Models.swift").read_text()
ruby = (SRC / "FuriganaRepository.swift").read_text()
pip = (SRC / "LyricsPictureInPictureController.swift").read_text()
old_pip = baseline("LyricsPictureInPictureController.swift")
view_model = (SRC / "AppViewModel.swift").read_text()
old_view_model = baseline("AppViewModel.swift")

# Production call sites use the shared helpers measured below.
assert "LyricsPronunciationDisplay.distinct(value, original: original)" in view
assert "LyricsPronunciationDisplay.distinct(line.pronunciationText, original: line.text)" in pip
assert "IvLyricsUtilities.lyricsTextsEquivalent" not in section(pip, "    private struct ActiveLine {", "    private struct PictureInPictureSupplementLine")
assert "spotifyDJSegment: spotifyDJSegment(track)," in view_model
assert view.count("let continuousKinds: Set<String> = [") == 0 and view.count("let effectKinds: Set<String> = [") == 0
# The next-line hint height is reused only for the same text, width, alignment and font.
measured = declaration(pip, "    private func measuredTextHeight(")
for term in ("last.text == text", "last.width == width", "last.alignment == alignment", "last.font.isEqual(font)",
             "alignment: alignment, lineLimit: 0"):
    assert term in measured, term
# The main-page preview row reads typography and speaker colors once per evaluation.
row = section(view, "private struct MainLyricPreviewRowView: View {", "private struct MainLyricPreviewInterludeIcon")
assert row.count("let typography = self.typography") == 1 and row.count("let speakerColors = self.speakerColors") == 1
assert "previewTextView(typography: typography)" in row

utilities = inject((SRC / "Utilities.swift").read_text(),
                   "    static func uncachedDistinct(_ pronunciation: String, original: String) -> String {\n",
                   "        pronunciationComparisons += 1\n") + "\nvar pronunciationComparisons = 0\n"
lru = inject((SRC / "BoundedLRUCache.swift").read_text(),
             "    mutating func value(forKey key: Key) -> Value? {\n", "        lruLookups += 1\n") + "\nvar lruLookups = 0\n"
old_timeline = baseline("TimelineIntervalCache.swift").replace("final class TimelineIntervalCache<Value>",
                                                                "final class BaselineTimelineIntervalCache<Value>")
assert "BaselineTimelineIntervalCache" in old_timeline

prelude = r'''
import Foundation
struct Color: Equatable {
    var token: String
    func opacity(_ value: Double) -> Color { Color(token: token + "@\(value)") }
}
enum KaraokeSyllableTimingNormalizer {
    struct FillTiming { var startTimeMs: Int64; var endTimeMs: Int64 }
}
var shapingScans = 0
'''
prelude += "struct LyricsLine {\n" + section(models, "    struct Syllable:", "    struct VocalPart:") + "}\n"
prelude += "enum FuriganaRepository {\n" + section(ruby, "    struct RubyAnnotation:", "    private static func containsKanji(") + "}\n"
prelude += (SRC / "CulturalAnnotation.swift").read_text()
prelude += inject(section(models, "enum LyricsTextShaping {", "enum LyricsWordSegmenter {"),
                  "    static func requiresContinuousShaping(_ text: String) -> Bool {\n",
                  "        shapingScans += 1\n        return").replace("        return        text.", "        return text.")
prelude += section(view, "private struct KaraokeBounceMetrics", "private struct KaraokeWhitespaceLayoutKey").replace("private ", "").replace(
    "struct KaraokeSyllableSegment: Identifiable", "struct KaraokeSyllableSegment: Identifiable, Equatable")
prelude += section(view, "final class KaraokeRenderPreparationCache", "private struct KaraokeBounceMetrics")
prelude += r'''
protocol KaraokeProbe {
    var positionMs: Int64 { get set }
    var continuousPositionMs: Double? { get set }
    var active: Bool { get set }
    var bounceEnabled: Bool { get set }
    var accessibilityReduceMotion: Bool { get set }
    var karaokeExpressiveMotion: Bool { get set }
    var completedColorOpacity: CGFloat { get set }
    var bounceTextSize: CGFloat { get set }
    var activeColor: Color { get set }
    var baseColor: Color { get set }
    var granularity: String { get set }
    var kindValue: String { get set }
}
'''


def probe(source, name, current):
    code = f"struct {name}: KaraokeProbe {{\n"
    code += "static var kindVisits = 0, granularityVisits = 0\n"
    if current:
        code += section(source, "    private static let continuousEffectKinds", "    @State private var preparationCache")
    code += r'''
    var cache = KaraokeRenderPreparationCache()
    var text: String, syllables: [LyricsLine.Syllable]
    var ruby: [FuriganaRepository.RubyAnnotation] = []
    var culturalAnnotations: [CulturalAnnotation] = []
    var granularity = "character", locale = "en", markup = "", kindValue = "vocal"
    var startTimeMs: Int64 = 0, endTimeMs: Int64 = 2400
    var positionMs: Int64 = 0
    var continuousPositionMs: Double? = nil
    var active = true, bounceEnabled = true, accessibilityReduceMotion = false, karaokeExpressiveMotion = false
    var activeColor = Color(token: "active"), baseColor = Color(token: "inactive")
    var completedColorOpacity: CGFloat = 1, bounceTextSize: CGFloat = 22
    var normalizedKind: String { Self.kindVisits += 1; return kindValue }
    var isWordDisplayGranularity: Bool { Self.granularityVisits += 1; return granularity == "word" }
    var isLineDisplayGranularity: Bool { Self.granularityVisits += 1; return granularity == "line" }
    func segmentBaseColor(for syllable: LyricsLine.Syllable) -> Color { Color(token: baseColor.token + "|\(syllable.styleSpeaker ?? "")") }
    func segmentActiveColor(for syllable: LyricsLine.Syllable) -> Color { Color(token: activeColor.token + "|\(syllable.styleSpeakerColor ?? "")") }
    var preparedKaraoke: KaraokeRenderPreparationCache.Value {
        let key = KaraokeRenderPreparationCache.Key(text: text, ruby: markup, syllables: syllables, granularity: granularity,
            locale: locale, annotations: culturalAnnotations, start: startTimeMs, end: endTimeMs, synthetic: false)
        let source = syllables, granularity = granularity, ruby = ruby, text = text, annotations = culturalAnnotations
        return cache.value(for: key) {
            let timings = source.map { KaraokeSyllableTimingNormalizer.FillTiming(startTimeMs: $0.startTimeMs, endTimeMs: $0.endTimeMs) }
            let units = source.map { KaraokeMotionProfile.Unit(text: $0.text, startMs: Double($0.startTimeMs), endMs: Double($0.endTimeMs)) }
            let expressive = granularity == "line" ? [] : KaraokeExpressiveMotion.units(
                for: source.map { KaraokeExpressiveMotion.Segment(text: $0.text, startMs: Double($0.startTimeMs), endMs: Double($0.endTimeMs)) },
                wordGranularity: granularity == "word")
            return .init(source: source, display: CulturalAnnotation.annotateSyllables(text: text, syllables: source, annotations: annotations),
                         fillTimings: timings, annotations: ruby,
                         motionProfiles: KaraokeMotionProfile.prepare(source: units, display: units), expressiveUnits: expressive)
        }
    }
'''
    code += section(source, "    private var karaokeSegments:", "    private var rubyAnnotations:")
    code += section(source, "    private var hasInlineEffects: Bool {", "    private func segmentKind(for")
    code += section(source, "    private func segmentKind(for", "    private func segmentActiveColor(")
    code += section(source, "    private func requiresContinuousEffect(", "    private var preparedKaraoke:")
    code += section(source, "    private var expressiveMotionActive: Bool {", "\n}\n\n/// One preparation")
    return (code + "}\n").replace("private ", "")


production = prelude + probe(old_view, "BaselineKaraoke", False) + probe(view, "CurrentKaraoke", True)

# Pronunciation rows: the 5e20c0e lyric-row and PiP comparisons as free functions.
production += declaration(old_view, "    private func distinctPronunciation(_ value: String, original: String) -> String {").replace(
    "private func distinctPronunciation", "func baselineRowPronunciation") + "\n"
production += "struct PiPLine { var pronunciationText: String; var text: String }\n"
production += "func baselinePiPPronunciation(_ line: PiPLine) -> String {\n"
production += section(old_pip, "            let rawPronunciation = line.pronunciationText.trimmed", "            let translation = line.translationText.trimmed")
production += "    return pronunciation\n}\n"

# Spotify DJ segment: the 5e20c0e static check, and the current per-frame wrapper around the same check.
production += "struct TrackSnapshot { var title: String; var artist: String }\nvar djDerivations = 0\n"
production += "final class BaselineDJ {\n" + declaration(old_view_model, "    private static func isSpotifyDJSegment(_ track: TrackSnapshot) -> Bool {") + "\n}\n"
current_dj = inject(declaration(view_model, "    private static func isSpotifyDJSegment(_ track: TrackSnapshot) -> Bool {"),
                    "    private static func isSpotifyDJSegment(_ track: TrackSnapshot) -> Bool {\n", "        djDerivations += 1\n")
production += "final class CurrentDJ {\n" + current_dj + "\n"
production += section(view_model, "    private var spotifyDJSegmentCheck:", "    private func spotifyDJSegment(")
production += declaration(view_model, "    private func spotifyDJSegment(") + "\n}\n"
production = production.replace("    private static func isSpotifyDJSegment", "    static func isSpotifyDJSegment").replace(
    "    private func spotifyDJSegment(", "    func spotifyDJSegment(")

checks = r'''
var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    if !condition() { fatalError(message) }
}
func units(_ texts: [String], spacing: Int64, styled: Bool = false) -> [LyricsLine.Syllable] {
    texts.enumerated().map { index, text in
        LyricsLine.Syllable(text: text, startTimeMs: Int64(index) * spacing,
            endTimeMs: Int64(index) * spacing + (index % 5 == 4 ? 0 : spacing),
            inlineStyle: styled && index % 3 == 0 ? true : nil,
            styleKind: styled ? [" Wave ", "GLOW", "", "sway"][index % 4] : nil,
            styleSpeaker: styled ? "voice\(index % 2)" : nil, styleSpeakerColor: styled ? "color\(index % 2)" : nil)
    }
}
func configure<P: KaraokeProbe>(_ probe: inout P, position: Int64, mode: Int, granularity: String, kind: String) {
    probe.positionMs = position
    probe.continuousPositionMs = mode % 5 == 0 ? nil : Double(position) + Double(mode) * 0.17
    probe.active = mode % 2 == 0
    probe.bounceEnabled = mode % 3 != 0
    probe.accessibilityReduceMotion = mode % 7 == 6
    probe.karaokeExpressiveMotion = mode % 4 < 2
    probe.completedColorOpacity = CGFloat(mode) / 9
    probe.bounceTextSize = CGFloat(17 + mode * 2)
    probe.activeColor = Color(token: "active\(mode)")
    probe.baseColor = Color(token: "base\(mode)")
    probe.granularity = granularity
    probe.kindValue = kind
}

// 1. Karaoke segment assembly and continuous-effect checks.
let rows: [(String, [LyricsLine.Syllable])] = [
    ("Morning light is spilling", units(["Morning ", "light ", "is ", "spilling"], spacing: 420)),
    ("너의 목소리가 들려", units(["너", "의", " ", "목", "소", "리", "가", " ", "들", "려"], spacing: 180)),
    ("夢の GO!", units(["夢", "の", " GO", "!"], spacing: 300, styled: true)),
    ("مرحبا بالعالم", units(["مر", "حبا", " ", "بالعالم"], spacing: 400, styled: true)),
    ("untimed", [])
]
var karaokePairs = 0
for (text, syllables) in rows {
    for granularity in ["character", "word", "line", " Word "] {
        for kind in ["vocal", "wave", "glow", "effect"] {
            var before = BaselineKaraoke(text: text, syllables: syllables)
            var after = CurrentKaraoke(text: text, syllables: syllables)
            for position in stride(from: Int64(-90), through: 4300, by: 53) {
                for mode in 0..<12 {
                    configure(&before, position: position, mode: mode, granularity: granularity, kind: kind)
                    configure(&after, position: position, mode: mode, granularity: granularity, kind: kind)
                    check(before.karaokeSegments == after.karaokeSegments, "Segments differ: \(text) \(granularity) \(kind) \(position) \(mode)")
                    check(before.hasInlineEffects == after.hasInlineEffects, "Inline effect check differs: \(text)")
                    for displayKind in [kind, "vocal", "sparkle", "GLOW"] {
                        check(before.requiresContinuousEffect(displayKind) == after.requiresContinuousEffect(displayKind),
                              "Continuous effect check differs: \(text) \(displayKind) \(mode)")
                    }
                    karaokePairs += 1
                }
            }
        }
    }
}
// One active Korean row painted for 600 frames: settings derivations per frame, then per evaluation.
let korean = rows[1]
var paintedBefore = BaselineKaraoke(text: korean.0, syllables: korean.1)
var paintedAfter = CurrentKaraoke(text: korean.0, syllables: korean.1)
BaselineKaraoke.kindVisits = 0; BaselineKaraoke.granularityVisits = 0
CurrentKaraoke.kindVisits = 0; CurrentKaraoke.granularityVisits = 0
for frame in 0..<600 {
    let position = Int64(frame * 3)
    configure(&paintedBefore, position: position, mode: 2, granularity: "character", kind: "vocal")
    configure(&paintedAfter, position: position, mode: 2, granularity: "character", kind: "vocal")
    paintedBefore.karaokeExpressiveMotion = true; paintedAfter.karaokeExpressiveMotion = true
    check(paintedBefore.karaokeSegments == paintedAfter.karaokeSegments, "Expressive frame differs at \(frame)")
}
let paintedUnits = korean.1.count
check(BaselineKaraoke.kindVisits == 600 * paintedUnits, "5e20c0e derives the row kind once per unit and frame")
check(CurrentKaraoke.kindVisits == 600, "The row kind is derived once per evaluation")
check(BaselineKaraoke.granularityVisits >= 600 * (paintedUnits + 1), "5e20c0e derives the granularity per unit")
check(CurrentKaraoke.granularityVisits == 600 * 2, "Granularity is derived twice per evaluation")
// Rows that are not active never animate and no longer scan their text for that answer.
shapingScans = 0
var inactiveBefore = BaselineKaraoke(text: korean.0, syllables: korean.1)
inactiveBefore.active = false
for _ in 0..<1_000 { check(!inactiveBefore.requiresContinuousEffect("wave"), "Inactive 5e20c0e row is static") }
let baselineInactiveScans = shapingScans
shapingScans = 0
var inactiveAfter = CurrentKaraoke(text: korean.0, syllables: korean.1)
inactiveAfter.active = false
for _ in 0..<1_000 { check(!inactiveAfter.requiresContinuousEffect("wave"), "Inactive row is static") }
check(baselineInactiveScans == 1_000 && shapingScans == 0, "Inactive rows skip the text scan")

// 2. Pronunciation rows: identical to the 5e20c0e row and PiP comparisons, compared once per pair.
let originals = ["너의 목소리가 들려", "Hello, World!", "ＨＥＬＬＯ　world", "夜明けの街を走り出す", "Light it up", " spaced  out ", "", "Ooooh"]
let pronunciations = ["neoui moksoriga deullyeo", "hello world", "HELLO WORLD", "hello, world!!", "요아케노 마치오 하시리다스",
                      "light it up", "Light it up ", "  ", "", "spaced out", "Ooooh~", "oooh", "너의 목소리가 들려"]
var pronunciationPairs = 0
for _ in 0..<2 {
    for original in originals {
        for pronunciation in pronunciations {
            let expected = baselineRowPronunciation(pronunciation, original: original)
            check(LyricsPronunciationDisplay.distinct(pronunciation, original: original) == expected, "Row pronunciation differs: \(pronunciation) / \(original)")
            check(LyricsPronunciationDisplay.distinct(pronunciation, original: original) == baselinePiPPronunciation(PiPLine(pronunciationText: pronunciation, text: original)),
                  "PiP pronunciation differs: \(pronunciation) / \(original)")
            pronunciationPairs += 1
        }
    }
}
check(pronunciationComparisons == originals.count * pronunciations.count, "Each pair is compared once")
// 600 frames of three rows that follow the clock, then a cache overflow and recomputation.
pronunciationComparisons = 0
for _ in 0..<600 {
    for index in 0..<3 {
        _ = LyricsPronunciationDisplay.distinct("row pronunciation \(index)", original: "row original \(index)")
    }
}
let frameComparisons = pronunciationComparisons
for index in 0..<700 {
    check(LyricsPronunciationDisplay.distinct("p\(index)", original: "P\(index)!") == "", "Equivalent overflow pair hides")
}
check(LyricsPronunciationDisplay.distinct("hello world", original: "Hello, World!") == "", "Pairs recompute correctly after overflow")
check(LyricsPronunciationDisplay.distinct("neoui", original: "너의") == "neoui", "Distinct pronunciation survives overflow")
check(frameComparisons == 3, "1800 row evaluations compare three pairs")

// 3. TimelineIntervalCache: same values and the same computations (LRU contents) as 5e20c0e.
var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
func random(_ bound: UInt64) -> UInt64 {
    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return (seed >> 33) % bound
}
let boundaries: [Int64] = [0, 1500, 4700, 4700, 8000, 9100, 12000, 20000, 30500]
var frameQueries: [(Int64, Int64, Bool)] = []
var position: Int64 = -200
while position < 31_000 {
    frameQueries.append((position, 30_000, true))
    frameQueries.append((position + 300, 30_000, true))
    position += 16
}
var queries = frameQueries
for _ in 0..<8_000 {
    queries.append((Int64(random(34_000)) - 600, [30_000, 18_000, 0][Int(random(3))], random(2) == 0))
}
queries += frameQueries.reversed()
let oldCache = BaselineTimelineIntervalCache<Int>(boundaries: boundaries)
let newCache = TimelineIntervalCache<Int>(boundaries: boundaries)
var oldComputes: [Int] = [], newComputes: [Int] = []
for (index, query) in queries.enumerated() {
    let old = oldCache.value(position: query.0, duration: query.1, automaticInterludes: query.2) { oldComputes.append(index); return index }
    let new = newCache.value(position: query.0, duration: query.1, automaticInterludes: query.2) { newComputes.append(index); return index }
    check(old == new, "Interval value differs at query \(index)")
}
check(oldComputes == newComputes, "The same queries compute, in the same order (identical LRU contents)")
lruLookups = 0
let oldFrames = BaselineTimelineIntervalCache<Int>(boundaries: boundaries)
for query in frameQueries { _ = oldFrames.value(position: query.0, duration: query.1, automaticInterludes: query.2) { 0 } }
let oldFrameLookups = lruLookups
lruLookups = 0
let newFrames = TimelineIntervalCache<Int>(boundaries: boundaries)
for query in frameQueries { _ = newFrames.value(position: query.0, duration: query.1, automaticInterludes: query.2) { 0 } }
let newFrameLookups = lruLookups
check(oldFrameLookups == frameQueries.count && newFrameLookups * 5 < oldFrameLookups, "Repeated intervals skip the LRU")

// 4. Spotify DJ segment: the same answer on every frame, derived once per title and artist.
let tracks = [TrackSnapshot(title: "Welcome", artist: "DJ X"), TrackSnapshot(title: " up next ", artist: "dj x"),
              TrackSnapshot(title: "Song", artist: "Artist"), TrackSnapshot(title: "Welcome", artist: "DJ X "),
              TrackSnapshot(title: "UP NEXT", artist: "Dj X"), TrackSnapshot(title: "welcome", artist: "DJ  X"),
              TrackSnapshot(title: "Welcome", artist: "DJ X")]
let dj = CurrentDJ()
djDerivations = 0
var djFrames = 0
for track in tracks {
    for _ in 0..<120 {
        check(dj.spotifyDJSegment(track) == BaselineDJ.isSpotifyDJSegment(track), "DJ segment differs: \(track)")
        djFrames += 1
    }
}
check(djDerivations == tracks.count, "One derivation per title and artist change")

print("FRAME_WORK_REUSE_PASSED assertions=\(assertions) karaokePairs=\(karaokePairs) kindDerivations=\(BaselineKaraoke.kindVisits)->\(CurrentKaraoke.kindVisits) granularityDerivations=\(BaselineKaraoke.granularityVisits)->\(CurrentKaraoke.granularityVisits) inactiveTextScans=\(baselineInactiveScans)->0 pronunciationPairs=\(pronunciationPairs) pronunciationComparisons=1800->\(frameComparisons) intervalLookups=\(oldFrameLookups)->\(newFrameLookups) djDerivations=\(djFrames)->\(djDerivations)")
'''

with tempfile.TemporaryDirectory(prefix="ivlyrics-ios-frame-work-") as path:
    work = Path(path)
    (work / "Utilities.swift").write_text(utilities)
    (work / "BoundedLRUCache.swift").write_text(lru)
    (work / "BaselineTimelineIntervalCache.swift").write_text(old_timeline)
    (work / "main.swift").write_text(production + checks)
    subprocess.run(["xcrun", "swiftc", "-O", str(work / "Utilities.swift"), str(work / "BoundedLRUCache.swift"),
                    str(SRC / "TimelineIntervalCache.swift"), str(work / "BaselineTimelineIntervalCache.swift"),
                    str(SRC / "KaraokeMotionProfile.swift"), str(SRC / "KaraokeExpressiveMotion.swift"),
                    str(work / "main.swift"), "-o", str(work / "regression")], check=True)
    subprocess.run([str(work / "regression")], check=True)

