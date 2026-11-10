#!/usr/bin/env python3
"""Exercise the production lrc.red provider helpers, word timing and provider wiring.

No network or device required: responses are synthetic and only parsing, matching,
timing upgrades, provider order and the lookup window execute.
"""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
models = (SRC / "Models.swift").read_text()
production = models[models.index("enum InstrumentalBreakMarker {"):models.index("enum LyricsTextShaping {")]
production += models[models.index("struct LyricsResult:"):models.index("struct ManualLrclibCandidate:")]
unison = (SRC / "UnisonLyricsProvider.swift").read_text()
unison = unison[:unison.index("    struct FetchOutcome:")] + unison[unison.index("    struct ExternalParsedLyrics:"):]
unison = unison[:unison.index("    static func fetch(")] + unison[unison.index("    private static func parseTtmlLyrics("):]
unison = unison[:unison.index("    private static func isExactMetadataMatch(")] + unison[unison.index("    private static func normalizeMetadata("):]
lrcred = (SRC / "LrcRedLyricsProvider.swift").read_text()
settings = (SRC / "AppSettings.swift").read_text()
repository = (SRC / "LyricsRepository.swift").read_text()
model = (SRC / "AppViewModel.swift").read_text()


def declaration(text, marker):
    start = text.index(marker)
    end = text.index("{", start) + 1
    depth = 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


# Default order: Open Lyrics, then lrc.red, enabled by default.
providers = settings[settings.index("static let lyricsProviders"):settings.index("static let defaultLyricsProviderOrder")]
ids = re.findall(r'id: (?:"([^"]+)"|LrcRedLyricsProvider\.providerId)', providers)
ids = [value or "lrcred" for value in ids]
assert ids[:2] == ["open-lyrics", "lrcred"], ids
lrcred_entry = providers[providers.index("LrcRedLyricsProvider.providerId"):]
lrcred_entry = lrcred_entry[:lrcred_entry.index(")")]
assert "defaultEnabled: false" not in lrcred_entry
fallback = declaration(settings, "var automaticWordSyncFallback: Bool")
assert "lyricsTypeKaraoke" in fallback and "enabledLyricsProviderOrder.count > 1" in fallback
# Repository: three concurrent lookups in priority order, and the lrc.red fallback before synced lyrics.
assert "private static let maxConcurrentProviderLookups = 3" in repository
assert '"open-lyrics", LrcRedLyricsProvider.providerId, "lyricsplus", "unison"' in repository
assert "break typeSearch" in repository and "settings.preferLyricsTypeOverProviderOrder || wordSyncFallback" in repository
assert "lookup.cancel()" in repository and "defer { lookups.cancel() }" in repository
persist = declaration(repository, "private func persistWordSync(")
assert persist.count("LyricsTimingUpgrade.upgrades(") == 2
# The view model requests timing once the base shows, and drops it on every reload or track change.
pipeline = declaration(model, "private func runLyricsPipeline(")
assert pipeline.index("startWordTimingIfNeeded(track: resolvedTrack, base: baseResult)") < pipeline.index("applyLyricsSupplements(")
assert "resetWordTiming()" in declaration(model, "private func cancelLyricsLoadTask()")
did_set = model[model.index("@Published private(set) var lyricsResult"):model.index("@Published private(set) var baseLyricsResult")]
assert "LyricsTimingUpgrade.retime(lyricsResult, with: timed)" in did_set

order = declaration(settings, "static func normalizedLyricsProviderOrder(")
window = declaration(repository, "private final class ProviderLookupWindow")

prelude = r'''
import Foundation
extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    func nfkc() -> String { precomposedStringWithCompatibilityMapping }
    func regexReplacing(_ pattern: String, with replacement: String) -> String { replacingOccurrences(of: pattern, with: replacement, options: .regularExpression) }
}
struct HTTPStatusError: Error { var statusCode: Int; var message: String }
enum IvLyricsUtilities { static func firstNonEmpty(_ values: String...) -> String { values.first(where: { !$0.isEmpty }) ?? "" } }
struct ProviderVariants {}
'''
prelude += "enum OrderProbe {\n    static let defaultLyricsProviderOrder = " + str(ids).replace("'", '"') + "\n" + order + "\n}\n"
prelude += window.replace("private final class", "final class") + "\n"

checks = r'''
var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    if !condition() { fatalError(message) }
}
typealias P = LrcRedLyricsProvider

check(P.normalizeIsrc("jps-600600052") == "JPS600600052", "ISRC separators and case are normalized")
check(P.normalizeIsrc("NOT-AN-ISRC") == "", "Invalid ISRCs are rejected")
check(P.stripEnhancedLrcTags("[00:01.00]<00:01.00>Hello <00:01.50>world") == "[00:01.00]Hello world", "Enhanced LRC tags are removed")
check(P.titleMatchScore(actual: "Song", expected: "Song") == 1, "Exact titles match")
check(P.titleMatchScore(actual: "Song (Remastered 2011)", expected: "Song") == 0.9, "Version labels may differ")
check(P.titleMatchScore(actual: "Song (Part II)", expected: "Song") == 0, "Other parts are different songs")
check(P.titleMatchScore(actual: "Song - Live", expected: "Song") == 0.9, "A live suffix is a version label")
check(P.sameArtist(actual: "Artist feat. Other", expected: "Artist"), "Featured artists may be listed")
check(!P.sameArtist(actual: "Other", expected: "Artist"), "Different artists never match")
check(P.normalizeString("Beyoncé") == "beyonce", "Latin accents fold")
check(P.normalizeString("ガッツ") == "ガッツ", "Japanese voicing marks stay")
check(P.buildSearchQueries(title: "Song (feat. X)", artist: "Artist") == ["Song (feat. X) Artist", "Song (feat. X)", "Song Artist", "Song"], "Search queries")
let exact = P.scoreSearchHit(["title": "Song", "artist": "Artist", "isrc": "GBARL1901205", "duration": 200], title: "Song", artist: "Artist", durationSeconds: 200)
let far = P.scoreSearchHit(["title": "Song", "artist": "Artist", "isrc": "GBARL1901206", "duration": 260], title: "Song", artist: "Artist", durationSeconds: 200)
check(exact != nil && far != nil && exact! > far!, "Duration ranks matching hits")
check(P.scoreSearchHit(["title": "Song", "artist": "Other", "isrc": "GBARL1901205"], title: "Song", artist: "Artist", durationSeconds: 0) == nil, "Wrong artist is rejected")
check(P.parseRetryAfterMs("120") == 120_000 && P.parseRetryAfterMs(nil) == 0, "Retry-After seconds")

let response = """
{"id":"GBARL1901205","lyrics":{"timing":"word","lines":[
 {"text":"Hello world","begin":1.0,"end":2.5,"words":[[{"text":"Hello","begin":1.0,"end":1.4}],[{"text":"wor","begin":1.6,"end":1.9},{"text":"ld","begin":1.9,"end":2.2}]]},
 {"text":"日本 語","begin":3,"end":4,"words":[[{"text":"日本","begin":3,"end":3.5}],[{"text":"語","begin":3.6,"end":3.9}]]}
]}}
"""
let timed = try! P.parseWordSyncResponse(response, expectedIsrc: "GBARL1901205")
check(timed.count == 2, "Every response line is parsed")
check(timed[0].syllables.map(\.text) == ["Hello ", "world"], "Spaces stay with the previous word")
check(timed[0].syllables.map(\.startTimeMs) == [1000, 1600] && timed[0].syllables.map(\.endTimeMs) == [1400, 2200], "Word timing")
check(timed[1].syllables.map(\.text) == ["日本 ", "語"] && timed[1].startTimeMs == 3000, "CJK words and line timing")
check(timed[0].syllables.allSatisfy { $0.sourceGranularity == "word" }, "Generated timing is word granular")
check((try? P.parseWordSyncResponse(response, expectedIsrc: "GBARL1901206")) == nil, "Another recording is rejected")
check((try? P.parseWordSyncResponse(response.replacingOccurrences(of: "\"word\"", with: "\"line\""), expectedIsrc: "GBARL1901205")) == nil, "Line timing is not word timing")
check((try? P.parseWordSyncResponse(response.replacingOccurrences(of: "\"wor\"", with: "\"war\""), expectedIsrc: "GBARL1901205")) == nil, "Words must match their line")

let ttml = """
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:lrc="http://lrc.red/lyric-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" lrc:timing="Line" xml:lang="ja"><body dur="3:57.373"><div begin="14.570" end="27.741"><p begin="14.570" end="20.428" lrc:key="L1" ttm:agent="v1">Hello world</p><p begin="20.728" end="27.741" lrc:key="L2" ttm:agent="v1">日本 語</p></div></body></tt>
"""
let parsed = try! UnisonLyricsProvider.parseExternalLyrics(ttml, format: "ttml", durationMs: 237_373)
check(parsed.synced && !parsed.karaoke && parsed.lines.map(\.text) == ["Hello world", "日本 語"], "lrc.red line TTML is synced lyrics")

var base = LyricsResult(lines: parsed.lines, providerLabel: "lrc.red synced", detail: P.attribution, karaoke: false,
                        providerId: "lrcred", selectionPolicyKey: "policy")
check(LyricsTimingUpgrade.canUpgrade(base), "Line-timed lrc.red lyrics can receive word timing")
let upgraded = LyricsTimingUpgrade.upgradedBase(base, timedLines: timed)!
check(upgraded.karaoke && upgraded.providerId == "lrcred" && upgraded.selectionPolicyKey == "policy", "Upgrade keeps the selection")
check(upgraded.lines.map(\.id) == base.lines.map(\.id) && upgraded.lines.map(\.text) == base.lines.map(\.text), "Upgrade keeps line identity and text")
check(upgraded.lines[0].syllables.count == 2 && upgraded.lines[0].startTimeMs == 1000, "Upgrade applies word timing")
check(LyricsTimingUpgrade.upgrades(base, to: upgraded) && !LyricsTimingUpgrade.upgrades(upgraded, to: upgraded), "Only line timing is upgraded")
var shown = base
shown.lines = base.lines.map { $0.withSupplements(pronunciation: "pron", translation: "trans") }
let retimed = LyricsTimingUpgrade.retime(shown, with: upgraded)
check(retimed.karaoke && retimed.lines.allSatisfy { $0.translationText == "trans" && $0.pronunciationText == "pron" }, "Supplements carry over")
check(retimed.lines[1].syllables.map(\.text) == ["日本 ", "語"], "Supplemented lines take the new timing")
var other = base
other.lines[1].text = "Different"
check(LyricsTimingUpgrade.upgradedBase(other, timedLines: timed) == nil, "Different text is never retimed")
base.providerId = "open-lyrics"
check(!LyricsTimingUpgrade.canUpgrade(base), "Other sources are never retimed")

check(OrderProbe.normalizedLyricsProviderOrder(["lyricsplus", "open-lyrics", "lrclib", "unison"])
      == ["lyricsplus", "open-lyrics", "lrcred", "lrclib", "unison"], "A saved order receives lrc.red after Open Lyrics")
check(OrderProbe.normalizedLyricsProviderOrder([]) == OrderProbe.defaultLyricsProviderOrder, "Default order")

var launched: [String] = []
let lookups = ProviderLookupWindow(providerIds: ["a", "b", "c", "d", "e"], limit: 3)
lookups.launch = { id in
    launched.append(id)
    return Task { try await Task.sleep(nanoseconds: 60_000_000_000); return nil }
}
lookups.fill()
check(launched == ["a", "b", "c"], "Three lookups start in priority order")
_ = lookups.task(for: "b")
check(launched == ["a", "b", "c"], "A running lookup is reused")
lookups.finished()
check(launched == ["a", "b", "c", "d"], "A finished lookup frees its slot for the next source")
check(lookups.task(for: "x") == nil, "Sources outside the window run on their own")
lookups.cancel()
lookups.fill()
check(launched.count == 4, "Cancelled windows start nothing more")
print("LRCRED_PASSED assertions=\(assertions)")
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-ios-lrcred-") as directory:
    work = Path(directory)
    (work / "main.swift").write_text(prelude + production + unison + lrcred + checks)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-D", "DEBUG", str(SRC / "BoundedLRUCache.swift"),
                    str(work / "main.swift"), "-o", str(work / "tests")], check=True)
    subprocess.run([str(work / "tests")], check=True, timeout=60)

