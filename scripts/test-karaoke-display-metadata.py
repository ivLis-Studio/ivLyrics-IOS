#!/usr/bin/env python3
"""Compare production segment output and preparation counts with a99ba5a.

Executes the original and current Swift segment assembly, ruby-overlap and fill/
motion functions. No network, playback clock replacement or device is required.
Color values are deterministic test tokens; UIKit/SwiftUI rasterization is not
claimed by this test. The normal Debug build separately compiles the real view.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
current = (SRC / "ContentView.swift").read_text()
baseline = subprocess.check_output(
    ["git", "show", "a99ba5a:ivLyrics-IOS/ContentView.swift"], cwd=ROOT, text=True
)


def section(source, start, end):
    first = source.index(start)
    return source[first:source.index(end, first + len(start))]


models = (SRC / "Models.swift").read_text()
ruby = (SRC / "FuriganaRepository.swift").read_text()
prelude = r'''
import Foundation
extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
struct Color: Equatable {
    var token: String
    func opacity(_ value: Double) -> Color { Color(token: token + "@\(value)") }
}
enum KaraokeSyllableTimingNormalizer {
    struct FillTiming { var startTimeMs: Int64; var endTimeMs: Int64 }
}
var legacyMetadataVisits = 0, cachedMetadataVisits = 0
var legacyRubyVisits = 0, cachedRubyVisits = 0
'''
prelude += "struct LyricsLine {\n" + section(models, "    struct Syllable:", "    struct VocalPart:") + "}\n"
prelude += "enum FuriganaRepository {\n" + section(ruby, "    struct RubyAnnotation:", "    private static func containsKanji(") + "}\n"
prelude += (SRC / "CulturalAnnotation.swift").read_text()
prelude += section(current, "private struct KaraokeBounceMetrics", "private struct KaraokeWhitespaceLayoutKey").replace("private ", "").replace(
    "struct KaraokeSyllableSegment: Identifiable", "struct KaraokeSyllableSegment: Identifiable, Equatable"
)


def cache_source(source, name, counter):
    code = section(source, "final class KaraokeRenderPreparationCache", "private struct KaraokeBounceMetrics")
    code = code.replace("KaraokeRenderPreparationCache", name)
    if counter == "cached":
        assert code.count("let sourceLength =") == 1
        code = code.replace("let sourceLength =", "cachedMetadataVisits += 1\n                let sourceLength =")
        code = code.replace("return annotations.compactMap { annotation in", "return annotations.compactMap { annotation in\n                cachedRubyVisits += 1")
    else:
        # Only the current PiP store is needed; keep both cache implementations.
        code = code[:code.index("/// A PiP frame")]
    return code


def probe(source, name, cache_name, original):
    code = f"struct {name} {{\n"
    code += f"var cache = {cache_name}()\n"
    code += r'''
    var text: String, source: [LyricsLine.Syllable], display: [LyricsLine.Syllable]
    var ruby: [FuriganaRepository.RubyAnnotation]
    var culturalAnnotations: [CulturalAnnotation] = []
    var granularity = "character", locale = "ja", markup = "ruby"
    var sourceStart: Int64 = 0, sourceEnd: Int64 = 2400
    var synthetic = false
    var positionMs: Int64 = 0
    var active = true, bounceEnabled = true, accessibilityReduceMotion = false
    var activeColor = Color(token: "active"), baseColor = Color(token: "inactive")
    var completedColorOpacity: CGFloat = 1, bounceTextSize: CGFloat = 22
    var normalizedKind = "vocal", creatorColors = true
    var isWordDisplayGranularity: Bool { granularity == "word" }
    func segmentBaseColor(for syllable: LyricsLine.Syllable) -> Color {
        Color(token: baseColor.token + "|\(syllable.styleSpeaker ?? "")|\(creatorColors)")
    }
    func segmentActiveColor(for syllable: LyricsLine.Syllable) -> Color {
        Color(token: activeColor.token + "|\(syllable.styleSpeakerColor ?? "")|\(creatorColors)")
    }
    func segmentKind(for syllable: LyricsLine.Syllable) -> String {
        syllable.inlineStyle == true ? syllable.styleKind ?? normalizedKind : normalizedKind
    }
'''
    code += f"var preparedKaraoke: {cache_name}.Value {{\n"
    code += f"let key = {cache_name}.Key(text: text, ruby: markup, syllables: source, granularity: granularity, locale: locale, annotations: culturalAnnotations, start: sourceStart, end: sourceEnd, synthetic: synthetic)\n"
    code += r'''
        return cache.value(for: key) {
            let timings = source.map { KaraokeSyllableTimingNormalizer.FillTiming(startTimeMs: $0.startTimeMs, endTimeMs: $0.endTimeMs) }
            let units = source.map { KaraokeMotionProfile.Unit(text: $0.text, startMs: Double($0.startTimeMs), endMs: Double($0.endTimeMs)) }
            return .init(source: source, display: display, fillTimings: timings, annotations: ruby,
                motionProfiles: KaraokeMotionProfile.prepare(source: units, display: units))
        }
    }
'''
    assembly = section(source, "    private var karaokeSegments:", "    private var rubyAnnotations:")
    if original:
        assert assembly.count("let sourceLength =") == 1
        assembly = assembly.replace("let sourceLength =", "legacyMetadataVisits += 1\n            let sourceLength =")
        reading = section(source, "    private func rubyReading(", "    private var effectiveSyllables:")
        code += reading.replace("return annotations.compactMap { annotation in", "return annotations.compactMap { annotation in\n            legacyRubyVisits += 1")
    code += assembly
    code += section(source, "    private func fillFraction(", "    private var preparedKaraoke:")
    code += section(source, "    private func karaokeBounce(", "\n}\n\n/// One preparation")
    return (code + "}\n").replace("private ", "")


checks = r'''
var assertions = 0, outputPairs = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    if !condition() { fatalError(message) }
}
func syllables(_ values: [String]) -> [LyricsLine.Syllable] {
    values.enumerated().map { index, text in
        .init(text: text, startTimeMs: Int64(index * 80), endTimeMs: Int64(index * 80 + (index % 3 == 0 ? 1 : 240)),
            inlineStyle: index % 3 == 0, styleKind: index % 3 == 0 ? "wave" : nil,
            styleSpeaker: "voice\(index % 4)", styleSpeakerColor: "color\(index % 4)")
    }
}
let texts = ["日本語の歌が続く", "한글 가사\t테스트", "a\u{301} 👨‍👩‍👧‍👦 ไทย", "مَرْحَبًا بالعالم", "שלום עולם", "中文，歌词", "hello  world\nagain", " "]
let positions: [Int64] = [-1, 0, 1, 79, 80, 81, 159, 240, 241, 499, 800, 1200, 2300, 3000, 1200, 1200, 0]
for text in texts {
    for granularity in ["character", "word", "line"] {
        let chunks = granularity == "word" ? text.split(separator: " ", omittingEmptySubsequences: false).map(String.init) : text.map(String.init)
        let source = granularity == "line" ? [] : syllables(chunks)
        let annotations = [CulturalAnnotation(lineIndex: 0, expression: String(text.prefix(2)), note: "reference")]
        let display = CulturalAnnotation.annotateSyllables(text: text, syllables: source, annotations: annotations)
        let ruby = [FuriganaRepository.RubyAnnotation(start: 0, length: max(1, text.count / 2), reading: "よみかた"),
                    .init(start: 1, length: max(1, text.count - 1), reading: "ふりがな")]
        var before = BaselineProbe(text: text, source: source, display: display, ruby: ruby, culturalAnnotations: annotations)
        var after = CurrentProbe(text: text, source: source, display: display, ruby: ruby, culturalAnnotations: annotations)
        before.granularity = granularity; after.granularity = granularity
        for position in positions {
            for mode in 0..<8 {
                before.positionMs = position; after.positionMs = position
                before.active = mode % 2 == 0; after.active = before.active
                before.bounceEnabled = mode % 3 != 0; after.bounceEnabled = before.bounceEnabled
                before.accessibilityReduceMotion = mode % 4 == 0; after.accessibilityReduceMotion = before.accessibilityReduceMotion
                before.completedColorOpacity = CGFloat(mode) / 7; after.completedColorOpacity = before.completedColorOpacity
                before.bounceTextSize = CGFloat(18 + mode * 4); after.bounceTextSize = before.bounceTextSize
                before.creatorColors = mode % 2 == 0; after.creatorColors = before.creatorColors
                before.activeColor = Color(token: "active\(mode)"); after.activeColor = before.activeColor
                before.baseColor = Color(token: "base\(mode)"); after.baseColor = before.baseColor
                check(before.karaokeSegments == after.karaokeSegments, "Segment output drift: \(text), \(granularity), \(position), \(mode)")
                outputPairs += 1
            }
        }
    }
}
// Empty display units retain source offsets; a fallback display index may extend
// beyond the source. These boundary shapes must retain the old ruby clipping.
do {
    let source = syllables(["日", "本", "語"])
    let display = syllables(["日[1]", "", "語", "!", "\u{00a0}"])
    let ruby = [FuriganaRepository.RubyAnnotation(start: 0, length: 3, reading: "にほんご")]
    let before = BaselineProbe(text: "日本語!", source: source, display: display, ruby: ruby)
    let after = CurrentProbe(text: "日本語!", source: source, display: display, ruby: ruby)
    check(before.karaokeSegments == after.karaokeSegments, "Empty units/source offset/fallback timing preserve output")
}
// Every cache input remains an invalidation boundary; live presentation values
// were exercised above without adding them to the static cache key.
do {
    let cache = KaraokeRenderPreparationCache()
    var key = KaraokeRenderPreparationCache.Key(text: "日本", ruby: "reading", syllables: syllables(["日本"]), granularity: "word", locale: "ja", annotations: [], start: 0, end: 500, synthetic: false)
    var builds = 0
    func fetch() -> KaraokeRenderPreparationCache.Value {
        cache.value(for: key) {
            builds += 1
            let display = CulturalAnnotation.annotateSyllables(text: key.text, syllables: key.syllables, annotations: key.annotations)
            return .init(source: key.syllables, display: display, fillTimings: [],
                annotations: [.init(start: 0, length: 2, reading: key.ruby)], motionProfiles: [])
        }
    }
    _ = fetch(); _ = fetch(); check(builds == 1, "Repeated and paused frames reuse metadata")
    key.ruby = "new"; check(fetch().displayMetadata.first?.rubyText == "new", "Late furigana invalidates ruby metadata")
    key.text = "日本語"; _ = fetch()
    key.syllables[0].text = " "; check(fetch().displayMetadata.first?.isWhitespace == true, "Text update invalidates whitespace")
    key.syllables[0].startTimeMs = 10; _ = fetch()
    key.syllables[0].styleKind = "glow"; _ = fetch()
    key.granularity = "character"; _ = fetch()
    key.locale = "ar"; _ = fetch()
    key.annotations = [.init(lineIndex: 0, expression: " ", note: "test")]; _ = fetch()
    key.start = 10; _ = fetch(); key.end = 800; _ = fetch(); key.synthetic = true; _ = fetch()
    check(builds == 12, "All 11 text/timing/settings mutations invalidate once")
}
// Production PiP store survives fresh roots and isolates eight simultaneous
// voices. Count actual production loop entries, not elapsed wall time.
legacyMetadataVisits = 0; cachedMetadataVisits = 0; legacyRubyVisits = 0; cachedRubyVisits = 0
let pipStore = KaraokeRenderPreparationStore()
let source = syllables(Array(repeating: "日本語の歌", count: 12).joined().map(String.init))
let text = source.map(\.text).joined()
let ruby = (0..<12).map { FuriganaRepository.RubyAnnotation(start: $0 * 5, length: 5, reading: "にほんごのうた") }
var originals = (0..<8).map { _ in BaselineProbe(text: text, source: source, display: source, ruby: ruby) }
for frame in 0..<180 {
    for voice in 0..<8 {
        originals[voice].positionMs = Int64(frame * 17)
        var fresh = CurrentProbe(cache: pipStore.cache(for: "voice:\(voice)"), text: text, source: source, display: source, ruby: ruby)
        fresh.positionMs = originals[voice].positionMs
        check(originals[voice].karaokeSegments == fresh.karaokeSegments, "Fresh PiP root output differs")
        outputPairs += 1
    }
}
check(legacyMetadataVisits == 180 * 8 * 60 && cachedMetadataVisits == 8 * 60, "Static segment scans drop from every frame to once per voice")
check(legacyRubyVisits == 180 * 8 * 60 * 12 && cachedRubyVisits == 8 * 60 * 12, "Ruby overlap tests drop by 180x")
let retained = pipStore.cache(for: "voice:0")
pipStore.removeAll()
check(retained !== pipStore.cache(for: "voice:0"), "PiP track replacement releases prepared display metadata")
print("KARAOKE_DISPLAY_METADATA_PASSED assertions=\(assertions) outputPairs=\(outputPairs) staticVisits=\(legacyMetadataVisits)->\(cachedMetadataVisits) rubyOverlapVisits=\(legacyRubyVisits)->\(cachedRubyVisits)")
'''

production = prelude
production += cache_source(baseline, "BaselineKaraokeRenderPreparationCache", "legacy")
production += cache_source(current, "KaraokeRenderPreparationCache", "cached")
production += probe(baseline, "BaselineProbe", "BaselineKaraokeRenderPreparationCache", True)
production += probe(current, "CurrentProbe", "KaraokeRenderPreparationCache", False)
with tempfile.TemporaryDirectory(prefix="ivlyrics-ios-display-metadata-") as path:
    work = Path(path)
    (work / "main.swift").write_text(production + checks)
    subprocess.run(["xcrun", "swiftc", "-O", str(SRC / "BoundedLRUCache.swift"),
                    str(SRC / "KaraokeMotionProfile.swift"), str(work / "main.swift"),
                    "-o", str(work / "regression")], check=True)
    subprocess.run([str(work / "regression")], check=True)
