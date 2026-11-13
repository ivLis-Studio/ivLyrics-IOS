#!/usr/bin/env python3
"""Run the production pronunciation-first and pronunciation fill logic with synthetic lyrics.

No network or device: AI responses are synthetic. Wiring of the app, view model and views is
checked from source; drawing on a device still needs a visual check.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"


def declaration(text, marker):
    start = text.index(marker)
    end = text.index("{", start) + 1
    depth = 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


models = (SRC / "Models.swift").read_text()
lrcred = (SRC / "LrcRedLyricsProvider.swift").read_text()
upgrade = "enum LyricsTimingUpgrade {\n" + declaration(lrcred, "    static func retime(") + "\n" \
    + declaration(lrcred, "    private static func retimed(") + "\n}\n"
with tempfile.TemporaryDirectory(prefix="ivlyrics-pronunciation-first-") as directory:
    work = Path(directory)
    main = work / "Checks.swift"
    main.write_text(models[:models.index("enum AppStatus:")] + upgrade
                    + (ROOT / "scripts/PronunciationFirstChecks.swift").read_text())
    sources = [SRC / name for name in ["Utilities.swift", "TinySegmenter.swift", "PronunciationFirst.swift", "PronunciationSlots.swift"]]
    subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", *map(str, sources), str(main), "-o", str(work / "checks")], check=True)
    subprocess.run([str(work / "checks")], check=True)


# Wiring: views draw what the view model resolves for the current lyrics only.
model = (SRC / "AppViewModel.swift").read_text()
view = (SRC / "ContentView.swift").read_text()
repository = (SRC / "AiLyricsRepository.swift").read_text()
assert "lines: displayLyricsResult.lines," in model, "the timeline shows the pronunciation-first copy"
assert "lyrics: displayLyricsResult," in model, "picture in picture shows the same copy"
assert "return !signature.isEmpty && signature == pronunciationTimedSignature ? pronunciationTimedParts : nil" in model, \
    "AI timing is used only for the lyrics it was made for (late lrc.red word timing re-requests)"
assert "guard currentTrack?.stableKey == trackKey, pronunciationTimingRequestSignature == signature else { return }" in model
assert "resetWordTiming()\n        resetPronunciationTiming()" in model, "a new track drops the previous timing"
assert "guard settings.pronunciationFirstEnabled || settings.pronunciationKaraokeFillEnabled," in model, \
    "with both displays off a lyrics update does no pronunciation work"
assert view.count("PronunciationFirst.Fill.matching(pronunciationFill.") == 2, "line and voice pronunciation rows fill"
fill_row = view[view.index("    private func pronunciationFillText("):view.index("struct SyllableKaraokeText: View")]
assert "bounceEnabled: false" in fill_row and 'kind: "vocal"' in fill_row, "the fill row has no bounce or effect"
assert "pronunciationFill: pronunciationFill.lineFill(line)," in view
assert "model.setPronunciationFirst(!enabled)" in view and "isOn: pronunciationFillBinding)" in view
assert "PronunciationFirst.parse(try await callProviderRaw(prompt: prompt, settings: connection), items: chunk)" in repository
assert "PronunciationFirst.chunks(missing, maxUnits: 200, maxItems: 8)" in repository, "one smaller repair pass"
# Karaoke pronunciation is made per sung unit; timing for those lines is derived locally.
assert "if baseResult.karaoke {\n                    slots = await loadPronunciationSlots(" in repository
assert "let missing = requests.indices.filter { !requests[$0].text.trimmed.isEmpty && combined[$0].trimmed.isEmpty }" in repository, \
    "lines without exact slots fall back to the line request"
assert "restorePronunciationSlots(trackKey: trackKey, cacheKey: pronunciationCacheKey)" in repository, \
    "cached pronunciation brings its slots back"
assert "let items = PronunciationFirst.timingItems(result).filter { derived[$0.key] == nil }" in repository, \
    "only lines without slots ask AI for unit timing"
assert "await run(PronunciationSlots.chunks(missing), repair: true)" in repository
print("PRONUNCIATION_FIRST_WIRING_PASSED")


# View model: the production pronunciation timing code runs in a probe with the same members.
probe_start = model.index("    // AI unit timing for the pronunciation (pronunciation-first and the pronunciation fill).")
stored = model[probe_start:model.index("    @Published private(set) var lyricsFocusRequestRevision", probe_start)]
methods = model[model.index("    // MARK: - Pronunciation-first and pronunciation fill"):model.index("    private func aiProviderLoadingText(")]
status = model[model.index("    var lyricsGenerationLoadingText: String? {"):model.index("    private var supplementGenerationLoadingText")]
probe = r'''
import Combine
struct RuleStub { var pronunciationEnabled = true }
struct SnapshotStub: Sendable {
    var enabled = true
    var pronunciation = true
    func ruleForSource(_ source: String) -> RuleStub { RuleStub(pronunciationEnabled: pronunciation) }
    func resolveTargetLanguage(sourceLang: String) -> String { "ko" }
}
@MainActor final class SettingsStub {
    var pronunciationFirstEnabled = false
    var pronunciationKaraokeFillEnabled = false
    var snapshot = SnapshotStub()
    func t(_ key: String) -> String { key }
}
actor AiLyricsRepository {
    struct TimedPronunciationResponse: Sendable {
        var requestKey: String
        var parts: [String: [String]]
        var logs: [String]
        var announced: Bool
        var hadError: Bool
        var errorMessage: String
    }
    var calls = 0
    var fails = false
    func setFails(_ value: Bool) { fails = value }
    // Puts each reading on its first unit, so a split from AI is recognizable.
    func loadTimedPronunciation(track: TrackSnapshot, result: LyricsResult, settings: SnapshotStub, sourceLang: String,
                                onStarted: @escaping @MainActor @Sendable () -> Void = {}) async -> TimedPronunciationResponse {
        calls += 1
        await onStarted()
        try? await Task.sleep(nanoseconds: 50_000_000)
        if fails { return .init(requestKey: "", parts: [:], logs: [], announced: true, hadError: true, errorMessage: "x") }
        var parts: [String: [String]] = [:]
        for item in PronunciationFirst.timingItems(result) {
            parts[item.key] = [item.pronunciation] + Array(repeating: "", count: item.units.count - 1)
        }
        return .init(requestKey: "", parts: parts, logs: [], announced: true, hadError: false, errorMessage: "")
    }
}
@MainActor final class ViewModelProbe {
    var settings = SettingsStub()
    var lyricsResult = LyricsResult.empty("") {
        didSet {
            lyricsResultRevision &+= 1
            schedulePronunciationTiming()
        }
    }
    var currentTrack: TrackSnapshot? = TrackSnapshot(title: "Song", artist: "Artist")
    var effectiveSelectedRuleSourceLang = "ja"
    var lyricsSupplementPronunciationLoading = false
    var lyricsSupplementLayoutRevision = 0
    var supplementGenerationLoadingText: String? = nil
    var lyricsWordSyncLoading = false
    var lyricsWordSyncFailed = false
    let aiRepository = AiLyricsRepository()
    var logs: [String] = []
    var pipUpdates = 0
    func appendLogs(_ messages: [String]) { logs += messages }
    func appendLog(_ message: String) { logs.append(message) }
    func updatePictureInPictureState() { pipUpdates += 1 }
''' + stored + methods + status + r'''
    var hasPendingSchedule: Bool { pronunciationTimingDebounceTask != nil }
}
'''
model_checks = r'''
private var modelAssertions = 0
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    modelAssertions += 1
    if !condition() { fatalError(message) }
}
private func syl(_ text: String, _ start: Int64, _ end: Int64) -> LyricsLine.Syllable {
    LyricsLine.Syllable(text: text, startTimeMs: start, endTimeMs: end)
}
private func settle() async { try? await Task.sleep(nanoseconds: 1_000_000_000) }

@main struct ViewModelChecks {
    @MainActor static func main() async {
        let probe = ViewModelProbe()
        let lineTimed = LyricsResult(lines: [LyricsLine(startTimeMs: 1000, endTimeMs: 2200, text: "許される",
            pronunciationText: "유루사레루", translationText: "용서받다")], providerLabel: "lrc.red", detail: "", karaoke: false)
        var wordTimed = lineTimed
        wordTimed.karaoke = true
        wordTimed.lines[0].syllables = [syl("許", 1000, 1400), syl("さ", 1400, 1600), syl("れ", 1600, 1800), syl("る", 1800, 2200)]

        // Both displays off: a lyrics update schedules nothing.
        probe.lyricsResult = wordTimed
        expect(!probe.hasPendingSchedule && probe.pronunciationFill.isEmpty, "off: no work")
        expect(probe.displayLyricsResult == probe.lyricsResult, "off: lyrics shown as they are")

        // Fill on, line-timed lrc.red lyrics: nothing to time yet.
        probe.lyricsResult = lineTimed
        probe.setPronunciationKaraokeFill(true)
        await settle()
        let callsBefore = await probe.aiRepository.calls
        expect(callsBefore == 0 && probe.pronunciationFill.isEmpty, "line timing asks AI for nothing")

        // Late word timing arrives: the view model asks AI once and fills with the AI split.
        probe.lyricsResult = wordTimed
        let before = probe.pronunciationFill.lineFill(probe.lyricsResult.lines[0]).line?.map(\.text) ?? []
        expect(before.joined() == "유루사레루" && before.count == 4 && !before.contains(""), "proportional fill right after the upgrade")
        await settle()
        let callsAfterUpgrade = await probe.aiRepository.calls
        expect(callsAfterUpgrade == 1, "one AI request after the upgrade")
        let after = probe.pronunciationFill.lineFill(probe.lyricsResult.lines[0]).line?.map(\.text) ?? []
        expect(after == ["유루사레루"], "the AI split fills the row: \(after)")
        expect(!probe.pronunciationSyncLoading && probe.lyricsGenerationLoadingText == nil, "loading cleared")

        // New unit timing for the same lyrics: the old split is not used, a new request runs.
        var retimed = wordTimed
        retimed.lines[0].syllables = [syl("許さ", 1000, 1600), syl("れる", 1600, 2200)]
        probe.lyricsResult = retimed
        let stale = probe.pronunciationFill.lineFill(probe.lyricsResult.lines[0]).line?.map(\.text) ?? []
        expect(stale.count == 2 && stale.joined() == "유루사레루", "a split for other units is never shown")
        await settle()
        let callsAfterRetime = await probe.aiRepository.calls
        expect(callsAfterRetime == 2, "re-timed lyrics ask again")

        // Pronunciation-first takes precedence and shows the swapped copy with the same split.
        probe.setPronunciationFirst(true)
        expect(probe.pronunciationFill.isEmpty, "the fill is off while pronunciation-first is on")
        let shown = probe.displayLyricsResult.lines[0]
        expect(shown.text == "유루사레루" && shown.pronunciationText == "許される" && shown.syllables.map(\.text) == ["유루사레루", ""],
               "pronunciation-first uses the current AI split")
        expect(probe.displayLyricsResult.lines[0].id == probe.lyricsResult.lines[0].id, "same row identity")
        expect(probe.pipUpdates >= 2, "picture in picture follows the setting")

        // A failed request says so and keeps the approximate timing.
        await probe.aiRepository.setFails(true)
        var another = retimed
        another.lines[0].pronunciationText = "유루사레루요"
        probe.lyricsResult = another
        try? await Task.sleep(nanoseconds: 760_000_000)
        expect(probe.pronunciationSyncLoading && probe.lyricsGenerationLoadingText == "loading.pronunciation_sync", "loading shown while AI works")
        await settle()
        expect(probe.pronunciationSyncFailed && probe.lyricsGenerationStatus?.failed == true
               && probe.lyricsGenerationStatus?.text == "status.pronunciation_sync_failed", "failure is shown")
        expect(probe.displayLyricsResult.lines[0].syllables.map(\.text).joined() == "유루사레루요", "approximate timing stays")

        // Pronunciation not shown for this language: no toggle and no work.
        probe.settings.snapshot.pronunciation = false
        expect(!probe.pronunciationFirstAvailable && !probe.pronunciationFirstActive, "toggle hidden without pronunciation")
        print("PRONUNCIATION_VIEW_MODEL_PASSED assertions=\(modelAssertions)")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-pronunciation-model-") as directory:
    work = Path(directory)
    main = work / "Checks.swift"
    main.write_text(models[:models.index("enum AppStatus:")] + probe + model_checks)
    sources = [SRC / name for name in ["Utilities.swift", "TinySegmenter.swift", "PronunciationFirst.swift"]]
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", *map(str, sources), str(main), "-o", str(work / "checks")], check=True)
    subprocess.run([str(work / "checks")], check=True)
