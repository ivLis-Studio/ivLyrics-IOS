#!/usr/bin/env python3
"""Execute production language-rule/detection caches with disposable host preferences.

Counts parser/detector calls and checks edits, legacy fallback and source replacement.
This does not measure device CPU use or rendered layout.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
settings = (SRC / "AppSettings.swift").read_text()
model = (SRC / "AppViewModel.swift").read_text()
models = (SRC / "Models.swift").read_text()
content = (SRC / "ContentView.swift").read_text()


def declaration(source, prefix):
    start = source.index(prefix)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end].replace("private(set) ", "").replace("private ", "").replace("@Published ", "")


code = 'import Foundation\nextension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }\n'
code += 'var parses = 0, detections = 0\n'
code += models[models.index("enum InstrumentalBreakMarker {"):models.index("struct TrackSnapshot:")]
code += models[models.index("struct LyricsLine:"):models.index("enum LyricsTextShaping {")]
code += content[content.index("enum LyricsTimelineDisplayItem:"):content.index("struct LyricsInterludeView:")]
code += '''
final class AppSettings {
    let defaults: UserDefaults
    var cachedRuleConfig: (raw: RuleConfigRawSignature, value: RuleConfig)?
    let ruleConfigCacheLock = NSLock()
    var cachedSnapshot: Int?
    init(defaults: UserDefaults) { self.defaults = defaults }
'''
for name in ["outputLangSameUI", "defaultSourceLang"]:
    code += next(line for line in settings.splitlines() if line.strip().startswith(f"static let {name} =")) + "\n"
start = settings.index("    static let languages:")
code += settings[start:settings.index("\n    ]", start) + 6] + "\n"
for prefix in ["struct Language:", "struct LanguageRule:", "private struct RuleConfigRawSignature:",
               "private struct RuleConfig {", "static func normalizeLanguageCode(",
               "static func normalizeSourceLanguageKey(", "static func normalizeOutputLanguage(",
               "private static func loadRuleConfig(", "private func ruleConfig()",
               "private func invalidateRuleConfigCache()", "private func saveRuleConfig(",
               "private static func parseRule(", "private static func ruleJson(",
               "private static func normalizeTargetRules(", "private static func parseTargetRules(",
               "private static func firstNonEmpty("]:
    value = declaration(settings, prefix)
    if prefix == "private static func loadRuleConfig(":
        value = value.replace("-> RuleConfig {", "-> RuleConfig { parses += 1")
    code += value + "\n"
code += "}\n"
ai = (SRC / "AiLyricsRepository.swift").read_text()
detector = declaration(ai, "static func detectLanguage(").replace("-> String {", "-> String { detections += 1; return")
code += "enum AiLyricsRepository {\n" + detector + "}\n"
code += '''
struct LyricsResult {
    var lines: [LyricsLine]
    static func empty(_ message: String) -> Self { .init(lines: []) }
}
struct AnnotationCache { func removeAll() {} }
final class DetectionProbe {
    var cachedTimelineContext: Int?
    var culturalAnnotationLineCache = AnnotationCache()
    var cachedCurrentLyricsSourceLang: String?
    var selectedRuleSourceLang = "auto"
    func refreshCreatorSupportPresentations(for result: LyricsResult) {}
'''
for prefix in ["@Published private(set) var lyricsResult =", "@Published private(set) var baseLyricsResult =",
               "var effectiveDetectedLyricsSourceLang:", "var effectiveSelectedRuleSourceLang:",
               "private func currentLyricsSourceLang()", "private func detectedSourceLang(",
               "private func supplementDetectionPayload("]:
    code += declaration(model, prefix) + "\n"
code += "}\n"
assert "invalidateRuleConfigCache()" in declaration(settings, "func importCloudSettings(")

checks = r'''
var count = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    count += 1
    if !value() { fatalError(label) }
}
let suite = "ivlyrics-rule-cache-" + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let settings = AppSettings(defaults: defaults)
for _ in 0..<1000 {
    check(!settings.ruleConfig().defaultRule.translationEnabled, "Default rules stay disabled")
}
check(parses == 1, "Repeated stable reads parse once")
defaults.set("unrelated", forKey: "ui_lang")
_ = settings.ruleConfig()
check(parses == 1, "Unrelated settings do not reparse rules")
defaults.set(true, forKey: "translation_enabled")
check(settings.ruleConfig().defaultRule.translationEnabled && parses == 2, "Legacy translation change invalidates")
defaults.set(true, forKey: "pronunciation_enabled")
check(settings.ruleConfig().defaultRule.pronunciationEnabled && parses == 3, "Legacy pronunciation change invalidates")
defaults.set("ja=ko;default=en", forKey: "target_lang")
check(settings.ruleConfig().languageRules["ja"]?.targetLang == "ko" && parses == 4, "Legacy language targets invalidate")
defaults.set("not JSON", forKey: "language_rules_v2")
check(settings.ruleConfig().defaultRule.targetLang == "en" && parses == 5, "Malformed JSON keeps legacy fallback")
let ja = AppSettings.LanguageRule(sourceLang: "jp", translationEnabled: false, pronunciationEnabled: true, targetLang: "ko")
settings.saveRuleConfig(defaultRule: ja, rules: ["ja": ja])
let saved = settings.ruleConfig()
check(!saved.defaultRule.translationEnabled && saved.languageRules["ja"]?.pronunciationEnabled == true && parses == 6,
      "Saving new rules invalidates and preserves opt-ins")
check(saved.withTarget("en").languageRules["ja"]?.targetLang == "en" && parses == 6,
      "Output-language resolution does not need another parse")
settings.invalidateRuleConfigCache()
_ = settings.ruleConfig()
check(parses == 7, "Cloud reload invalidation re-reads stored rules")
defaults.removeObject(forKey: "language_rules_v2")
check(settings.ruleConfig().defaultRule.translationEnabled && parses == 8, "Removing stored JSON restores legacy rules")

func lines(_ text: String) -> LyricsResult {
    .init(lines: (0..<3).map { .init(startTimeMs: Int64($0 * 1000), endTimeMs: Int64(($0 + 1) * 1000), text: text) })
}
let probe = DetectionProbe()
probe.lyricsResult = lines("こんにちは世界の歌")
for _ in 0..<1000 {
    check(probe.effectiveDetectedLyricsSourceLang == "ja" && probe.effectiveSelectedRuleSourceLang == "ja", "Repeated automatic language selection stays Japanese")
}
check(detections == 1, "2000 unchanged getters detect once")
probe.baseLyricsResult = probe.lyricsResult
probe.lyricsResult = lines("이것은 번역된 가사입니다")
check(probe.effectiveSelectedRuleSourceLang == "ja" && detections == 2, "Supplements cannot replace base-source language")
probe.baseLyricsResult = lines("안녕하세요 세상의 노래입니다")
check(probe.effectiveSelectedRuleSourceLang == "ko" && detections == 3, "Replacing base lyrics invalidates detection")
probe.selectedRuleSourceLang = "jp"
check(probe.effectiveSelectedRuleSourceLang == "ja" && detections == 3, "Manual override is normalized without detecting again")
probe.selectedRuleSourceLang = "auto"
probe.baseLyricsResult = .empty("")
probe.lyricsResult = .empty("")
check(probe.effectiveSelectedRuleSourceLang == "en" && detections == 4, "Track reset cannot keep stale source language")
print("LYRIC_RUNTIME_CACHE_PASSED assertions=\(count) ruleParses=\(parses) detections=\(detections)")
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-ios-runtime-") as directory:
    work = Path(directory)
    main = work / "main.swift"
    main.write_text(code + checks)
    subprocess.run(["xcrun", "swiftc", str(SRC / "BoundedLRUCache.swift"), str(SRC / "TimelineIntervalCache.swift"), str(SRC / "LyricsLanguageDetector.swift"), str(main), "-o", str(work / "checks")], check=True)
    subprocess.run([str(work / "checks")], check=True)
