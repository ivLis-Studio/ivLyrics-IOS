#!/usr/bin/env python3
"""Test the Pronunciation Lab provider without a device, simulator or account.

Checks the AppSettings provider list, order and capability gates (compiled from the production
source), the cache key and dispatch rules in the source, and PronunciationLabRepository in a real
macOS WKWebView: against a fixture page (ready queue, side-by-side requests, request shape, error
codes, late answers, timeout, cancellation) and against the bundled Resources/PronunciationLabPage.html
for the answers it gives without network. IVLYRICS_PRONUNCIATION_LAB_LIVE=1 also converts through
the live jsDelivr CDN (猫 -> 네코).
"""
from pathlib import Path
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
settings = (SRC / "AppSettings.swift").read_text(encoding="utf-8")
repository = (SRC / "AiLyricsRepository.swift").read_text(encoding="utf-8")
lab = (SRC / "PronunciationLabRepository.swift").read_text(encoding="utf-8")
harness = (SRC / "DebugSettingsUIHarness.swift").read_text(encoding="utf-8")
content_view = (SRC / "ContentView.swift").read_text(encoding="utf-8")


def section(source, start, end):
    first = source.index(start)
    return source[first:source.index(end, first + len(start))]


# Keys shared with translation, metadata, research and notes never contain Pronunciation Lab...
cache_key = section(settings, "        var cacheKey: String {", "        var linePronunciationCacheKey:")
assert "if AppSettings.aiProviderById(providerId)?.pronunciationOnly == true { continue }" in cache_key
# ...only the results that can hold its line pronunciation are keyed with it, and only while it
# writes that pronunciation (it comes before every ready AI provider). Behind an AI provider the
# keys stay the ones from before it existed, so the pronunciation the AI wrote stays cached.
line_key = section(settings, "        var linePronunciationCacheKey: String {", "        var localAIConfiguration:")
assert "guard let writer = linePronunciationProviderIds.first," in line_key
assert "pronunciationOnly == true else {\n                return cacheKey" in line_key
supplements = section(repository, "    func loadSupplements(", "    private func loadSupplementTask(")
assert '+ "|\\(needsPronunciation ? settings.linePronunciationCacheKey : settings.cacheKey)"' in supplements
task_key = section(repository, "    private func supplementTaskCacheKey(", "    private func buildTaskResult(")
assert "task == supplementTaskPronunciation ? settings.linePronunciationCacheKey : settings.cacheKey" in task_key
for start, end in [("    func loadMetadataTranslation(", "    func loadTmi("), ("    func loadTmi(", "    private func generateTmiForConnection("),
                   ("    func loadCulturalAnnotations(", "    func clearCache(")]:
    assert "linePronunciationCacheKey" not in section(repository, start, end), start

# Plain line pronunciation is the only task that reaches it.
task = section(repository, "    private func loadSupplementTask(", "    private func emitSupplementPartial(")
line_pronunciation = section(task, "                func loadLinePronunciation(", "                // With synced pronunciation on")
assert "for providerId in settings.linePronunciationProviderIds {" in line_pronunciation
assert "if provider.pronunciationOnly {" in line_pronunciation and "loadPronunciationLabLines(" in line_pronunciation
translation = section(task, "            } else {\n                let prompt = buildTranslationPrompt(", "            await liveState.finish(")
assert "if provider.pronunciationOnly { continue }" in translation, "lyrics translation must skip it"
metadata = section(repository, "    func loadMetadataTranslation(", "    func loadTmi(")
assert "if provider.pronunciationOnly { continue }" in metadata, "metadata translation must skip it"
slots = section(repository, "    private func loadPronunciationSlots(", "    private struct SlotJob:")
assert "settings.readyAIProviderSnapshots" in slots and "linePronunciation" not in slots, "pronunciation by unit stays AI-only"
timed = section(repository, "    func loadTimedPronunciation(", "    private func timedPronunciationFromDisk(")
assert "PronunciationLab" not in timed and "linePronunciation" not in timed, "pronunciation timing stays AI-only"
owners = section(content_view, "    private var aiTaskOwners:", "    private var languageRulesGroup:")
assert "if provider.pronunciationOnly { continue }" in owners and "linePronunciationProviderIds.first" in owners

# The page contract and the test harness.
assert 'messageHandlerName = "ivLyricsPronunciationLab"' in lab
assert 'URL(string: "https://cdn.jsdelivr.net/")' in lab and "requestTimeout: Duration = .seconds(90)" in lab
assert '\\"pronunciation-lab\\":false' in harness, "UI tests keep it off and offline"
bundle = json.loads((SRC / "Resources/AppI18nStrings.json").read_text(encoding="utf-8"))
for code, strings in bundle.items():
    for key in ["provider.desc.pronunciation-lab", "pronunciation_lab.error.unsupported_source",
                "pronunciation_lab.error.unsupported_target", "pronunciation_lab.error.load_failed"]:
        assert strings.get(key, "").strip(), f"{code}: missing {key}"
    assert "Pronunciation Lab" in strings["pronunciation_lab.error.load_failed"], f"{code}: product name"
assert bundle["en"]["pronunciation_lab.error.unsupported_source"] == "Pronunciation Lab can't read this song's language."

helpers = r'''import Foundation
extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
enum PaxsenixAIProvider { static let baseURL = "https://fixture.test", dashboardURL = "https://fixture.test" }
enum KeylessTranslationProviders {
    static let bingId = "bing-translate", googleId = "google-translate"
    static let bingLabel = "Bing Translate", googleLabel = "Google Translate"
}
enum LocalAI { static let providerId = "local-ai", label = "Local AI" }
enum AppI18n {
    static func t(_ language: String?, _ key: String) -> String { "\(language ?? ""):\(key)" }
}
enum AppSettings {
// PROVIDERS
// LOOKUP
// ORDER
// ENABLED
// PROVIDER
    struct Snapshot {
        var apiKeys = "", model = ""
        var aiProviderEnabled: [String: Bool] = [:]
        var aiProviderOrder: [String] = []
        var profiles: [String: (String, String)] = [:]
        var hasApiKey: Bool { !apiKeys.isEmpty }
        var hasModel: Bool { !model.isEmpty }
        func selectingAIProvider(_ id: String) -> Snapshot? {
            guard let selected = AppSettings.aiProviderById(id), !selected.isKeyless else { return nil }
            var copy = self
            let profile = profiles[id] ?? ("", "")
            copy.apiKeys = profile.0
            copy.model = profile.1
            return copy
        }
// GATES
    }
}
'''
helpers = helpers.replace("// PROVIDERS", section(settings, "    static let providers: [Provider] = [", "    static let languages: [Language] = ["))
helpers = helpers.replace("// LOOKUP", section(settings, "    static func providerById(", "    static func normalizedAIProviderOrder("))
helpers = helpers.replace("// ORDER", section(settings, "    static func normalizedAIProviderOrder(", "    private static func normalizedAIProviderEnabled("))
helpers = helpers.replace("// ENABLED", section(settings, "    private static func normalizedAIProviderEnabled(", "    private static func loadAIProviderOrder(")
                          .replace("private static func", "static func"))
helpers = helpers.replace("// PROVIDER", section(settings, "    struct Provider:", "    struct AIProviderProfile:"))
helpers = helpers.replace("// GATES", section(settings, "        var hasKeylessTranslationProvider:", "        func selectingAIProvider("))

FIXTURE_PAGE = """<!doctype html>
<html><head><meta charset="utf-8"></head><body><script>
(() => {
  const post = (message) => window.webkit.messageHandlers.ivLyricsPronunciationLab.postMessage(message);
  const cancelled = [];
  const bridge = {
    convert(id, request) {
      const r = typeof request === "string" ? JSON.parse(request) : request;
      const answer = (message, delay) => setTimeout(() => post(Object.assign({ id }, message)), delay || 0);
      const error = (code) => answer({ type: "error", code, message: "fixture " + code });
      switch (r.lang) {
        case "never": return new Promise(() => {});
        case "late": return answer({ type: "result", lines: r.lines, version: "late" }, 1500);
        case "short": return answer({ type: "result", lines: r.lines.slice(1), version: "fixture" });
        case "report-cancelled": return answer({ type: "result", lines: [cancelled.join(",")], version: "fixture" });
        case "error-source": return error("PRONUNCIATION_LAB_UNSUPPORTED_SOURCE");
        case "error-target": return error("PRONUNCIATION_LAB_UNSUPPORTED_TARGET");
        case "error-load": return error("PRONUNCIATION_LAB_LOAD_FAILED");
        case "error-new": return error("SOMETHING_NEW");
        default:
          // Streaming rows are never requested; one that arrives anyway is ignored.
          post({ type: "line", id, index: 0, text: "stray" });
          return answer({ type: "result", version: "fixture",
            lines: r.lines.map((line) => [line, r.sourceLang, r.lang, r.notation, "stream" in r].join("|")) });
      }
    },
    cancel(id) { cancelled.push(id); },
  };
  // "ready" arrives after the first requests, which must wait for it.
  setTimeout(() => { window.ivLyricsPronunciationLab = bridge; post({ type: "ready" }); }, 300);
})();
</script></body></html>
"""

checks = r'''
import AppKit
import Foundation
import WebKit

@main
struct Regression {
    @MainActor static var count = 0

    @MainActor static func check(_ value: Bool, _ message: String) {
        guard value else { fatalError(message) }
        count += 1
    }

    @MainActor static func main() {
        _ = NSApplication.shared
        // WebKit answers through the main run loop, which a command-line tool must run itself.
        DispatchQueue.main.asyncAfter(deadline: .now() + 150) { fatalError("Pronunciation Lab regression timed out") }
        Task { @MainActor in
            do {
                gates()
                messages()
                try await fixturePage()
                try await bundledPage()
                if ProcessInfo.processInfo.environment["IVLYRICS_PRONUNCIATION_LAB_LIVE"] == "1" {
                    try await liveCDN()
                } else {
                    print("live CDN conversion skipped (set IVLYRICS_PRONUNCIATION_LAB_LIVE=1)")
                }
                print("Pronunciation Lab regression: \(count) checks passed")
                exit(0)
            } catch {
                fatalError("Pronunciation Lab regression failed: \(error)")
            }
        }
        RunLoop.main.run()
    }

    @MainActor static func gates() {
        let order = AppSettings.defaultAIProviderOrder
        check(order.last == "pronunciation-lab", "last on fresh installs")
        let saved = ["claude", "gemini", "google-translate", "bing-translate"]
        let normalized = AppSettings.normalizedAIProviderOrder(saved)
        check(Array(normalized.prefix(4)) == saved && normalized.last == "pronunciation-lab", "appended to a saved order")
        check(Array(AppSettings.normalizedAIProviderOrder(["pronunciation-lab", "gemini"]).prefix(2)) == ["pronunciation-lab", "gemini"],
              "a saved position is kept")
        let lab = AppSettings.aiProviderById("pronunciation-lab")!
        check(lab.label == "Pronunciation Lab" && lab.isKeyless && lab.pronunciationOnly && lab.defaultEnabled && !lab.isLocal,
              "keyless, pronunciation-only, on by default")
        check(!lab.translationOnly && !lab.answersPrompts, "neither a translator nor an AI provider")
        check(AppSettings.providerById("pronunciation-lab").id == "gemini", "never the selected key provider (research, notes, motion)")
        for provider in AppSettings.allAIProviders where provider.id != lab.id {
            check(!provider.pronunciationOnly && provider.answersPrompts == !provider.translationOnly, "\(provider.id): capabilities unchanged")
        }
        check(AppSettings.allAIProviders.filter(\.translationOnly).map(\.id) == ["bing-translate", "google-translate", "deepl", "local-ai"],
              "translation-only providers unchanged")
        let fresh = AppSettings.normalizedAIProviderEnabled([:])
        check(fresh.filter(\.value).keys.sorted() == ["bing-translate", "google-translate", "pronunciation-lab"], "on by default with the keyless translators")
        check(AppSettings.normalizedAIProviderEnabled(["pronunciation-lab": false])["pronunciation-lab"] == false, "a stored choice wins")

        var snapshot = AppSettings.Snapshot()
        snapshot.aiProviderOrder = order
        snapshot.aiProviderEnabled = fresh
        check(snapshot.linePronunciationProviderIds == ["pronunciation-lab"] && snapshot.hasLinePronunciationProvider,
              "a fresh install writes line pronunciation with it")
        check(!snapshot.hasReadyAIProvider && !snapshot.hasEnabledAIProvider && snapshot.readyAIProviderSnapshots.isEmpty,
              "never an AI provider")
        check(snapshot.hasAnyTranslationProvider, "Bing and Google still translate")
        snapshot.aiProviderEnabled["bing-translate"] = false
        snapshot.aiProviderEnabled["google-translate"] = false
        check(!snapshot.hasAnyTranslationProvider && !snapshot.hasKeylessTranslationProvider, "never a translation provider")
        check(snapshot.selectingAIProvider("pronunciation-lab") == nil, "no AI profile, so AI requests never reach it")
        for id in ["gemini", "claude", "deepl", "local-ai"] { snapshot.aiProviderEnabled[id] = true }
        snapshot.profiles = ["gemini": ("key", "model"), "claude": ("key", ""), "deepl": ("key", ""), "local-ai": ("key", "model")]
        check(snapshot.linePronunciationProviderIds == ["gemini", "pronunciation-lab"], "ready AI first; unready AI, DeepL, Local AI never")
        check(snapshot.readyAIProviderSnapshots.count == 1 && snapshot.hasEnabledAIProvider, "AI readiness unchanged")
        snapshot.aiProviderOrder = ["pronunciation-lab"] + order.filter { $0 != "pronunciation-lab" }
        check(snapshot.linePronunciationProviderIds == ["pronunciation-lab", "gemini"], "the user's order decides")
        snapshot.aiProviderEnabled["pronunciation-lab"] = false
        check(snapshot.linePronunciationProviderIds == ["gemini"], "turned off, it is skipped")
        snapshot.aiProviderEnabled["gemini"] = false
        check(!snapshot.hasLinePronunciationProvider, "nothing writes pronunciation")
    }

    @MainActor static func messages() {
        check(PronunciationLabError(code: "PRONUNCIATION_LAB_UNSUPPORTED_SOURCE", message: "m") == .unsupportedSource("m"), "source code")
        check(PronunciationLabError(code: "PRONUNCIATION_LAB_UNSUPPORTED_TARGET", message: "m") == .unsupportedTarget("m"), "target code")
        check(PronunciationLabError(code: "PRONUNCIATION_LAB_LOAD_FAILED", message: "m") == .loadFailed("m"), "load code")
        check(PronunciationLabError(code: "PRONUNCIATION_LAB_ABORTED", message: "m") == .aborted("m"), "aborted code")
        check(PronunciationLabError(code: "PRONUNCIATION_LAB_BAD_REQUEST", message: "m") == .badRequest("m"), "bad request code")
        check(PronunciationLabError(code: "PRONUNCIATION_LAB_FAILED", message: "m") == .failed("m"), "failed code")
        check(PronunciationLabError(code: "SOMETHING_NEW", message: "m") == .failed("SOMETHING_NEW: m"), "unknown codes are failures")
        check(PronunciationLabError.unsupportedSource("m").message(uiLanguage: "ja") == "ja:pronunciation_lab.error.unsupported_source", "source message")
        check(PronunciationLabError.unsupportedTarget("m").message(uiLanguage: "ko") == "ko:pronunciation_lab.error.unsupported_target", "target message")
        check(PronunciationLabError.loadFailed("m").message(uiLanguage: "en") == "en:pronunciation_lab.error.load_failed", "load message")
        check(PronunciationLabError.timedOut.message(uiLanguage: "en") == "en:pronunciation_lab.error.load_failed", "a timeout was still downloading")
        check(PronunciationLabError.failed("detail").message(uiLanguage: "en") == "detail", "other failures keep their detail")
        check(PronunciationLabError.webContentTerminated.localizedDescription == "The Pronunciation Lab web view stopped.", "English description")
    }

    @MainActor static func expectFailure(_ expected: PronunciationLabError, _ message: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            fatalError("\(message): no error")
        } catch let error as PronunciationLabError {
            check(error == expected, "\(message): \(error)")
        } catch {
            fatalError("\(message): \(error)")
        }
    }

    @MainActor static func fixturePage() async throws {
        let html = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        var loads = 0
        let repository = PronunciationLabRepository(timeout: .seconds(1), keepsHTTPCache: false) {
            loads += 1
            return html
        }
        let empty = try await repository.convert(lines: [], sourceLang: "ja", lang: "ko", notation: "translation")
        check(empty == .init(lines: [], version: "") && loads == 0, "nothing to convert needs no web view")

        async let first = repository.convert(lines: ["夢", ""], sourceLang: "ja", lang: "ko", notation: "translation")
        async let second = repository.convert(lines: ["君"], sourceLang: "auto", lang: "en", notation: "latin")
        let (one, two) = try await (first, second)
        check(one == .init(lines: ["夢|ja|ko|translation|false", "|ja|ko|translation|false"], version: "fixture"),
              "the request carries lines, sourceLang, lang and notation without streaming: \(one)")
        check(two.lines == ["君|auto|en|latin|false"], "requests made before ready wait for it and run side by side")

        await expectFailure(.failed("The page answered with a different number of lines"), "line count") {
            _ = try await repository.convert(lines: ["a", "b"], sourceLang: "ja", lang: "short", notation: "translation")
        }
        await expectFailure(.unsupportedSource("fixture PRONUNCIATION_LAB_UNSUPPORTED_SOURCE"), "source") {
            _ = try await repository.convert(lines: ["a"], sourceLang: "ru", lang: "error-source", notation: "translation")
        }
        await expectFailure(.unsupportedTarget("fixture PRONUNCIATION_LAB_UNSUPPORTED_TARGET"), "target") {
            _ = try await repository.convert(lines: ["a"], sourceLang: "ja", lang: "error-target", notation: "translation")
        }
        await expectFailure(.loadFailed("fixture PRONUNCIATION_LAB_LOAD_FAILED"), "load") {
            _ = try await repository.convert(lines: ["a"], sourceLang: "ja", lang: "error-load", notation: "translation")
        }
        await expectFailure(.failed("SOMETHING_NEW: fixture SOMETHING_NEW"), "unknown code") {
            _ = try await repository.convert(lines: ["a"], sourceLang: "ja", lang: "error-new", notation: "translation")
        }

        let clock = ContinuousClock()
        var started = clock.now
        await expectFailure(.timedOut, "timeout") {
            _ = try await repository.convert(lines: ["a"], sourceLang: "ja", lang: "never", notation: "translation")
        }
        check(clock.now - started >= .milliseconds(900), "the timeout waits for its duration")
        await expectFailure(.timedOut, "an answer after the timeout") {
            _ = try await repository.convert(lines: ["a"], sourceLang: "ja", lang: "late", notation: "translation")
        }
        // The late answer arrives now and must be ignored (a second resume would crash).
        try await Task.sleep(for: .milliseconds(800))

        started = clock.now
        let waiting = Task { try await repository.convert(lines: ["a"], sourceLang: "ja", lang: "never", notation: "translation") }
        try await Task.sleep(for: .milliseconds(100))
        waiting.cancel()
        do {
            _ = try await waiting.value
            fatalError("cancelled request answered")
        } catch is CancellationError {
            check(clock.now - started < .milliseconds(800), "cancellation ends the request at once")
        }
        let precancelled = Task { () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await repository.convert(lines: ["a"], sourceLang: "ja", lang: "ko", notation: "translation"); return nil }
            catch { return error }
        }
        check(await precancelled.value is CancellationError, "an already cancelled task does not start a request")

        let report = try await repository.convert(lines: ["?"], sourceLang: "ja", lang: "report-cancelled", notation: "translation")
        let cancelled = report.lines[0].split(separator: ",")
        check(cancelled.count == 3 && Set(cancelled).count == 3 && cancelled.allSatisfy { $0.hasPrefix("ivlyrics-") },
              "timeouts and cancellation stop the page's request: \(report.lines)")
        check(loads == 1, "one web view serves every request")

        let missing = PronunciationLabRepository(keepsHTTPCache: false) { nil }
        await expectFailure(.pageMissing, "missing page") {
            _ = try await missing.convert(lines: ["a"], sourceLang: "ja", lang: "ko", notation: "translation")
        }
    }

    @MainActor static func bundledPage() async throws {
        let html = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        let repository = PronunciationLabRepository(keepsHTTPCache: false) { html }
        let kept = try await repository.convert(lines: ["♪", "", "  [Chorus]  ", "♪ ♪"], sourceLang: "ja", lang: "ko", notation: "translation")
        check(kept == .init(lines: ["♪", "", "[Chorus]", "♪ ♪"], version: ""), "lines without sounds come back without the library: \(kept)")
        for lang in ["zh-CN", "ru", "hi", "th"] {
            await expectFailure(.unsupportedTarget("[Pronunciation Lab] Cannot write pronunciation for language \(lang)"), "target \(lang)") {
                _ = try await repository.convert(lines: ["猫"], sourceLang: "ja", lang: lang, notation: "translation")
            }
        }
        await expectFailure(.unsupportedSource("[Pronunciation Lab] Cannot read lyrics in language ru"), "Russian source") {
            _ = try await repository.convert(lines: ["Привет, мир"], sourceLang: "ru", lang: "ko", notation: "translation")
        }
    }

    @MainActor static func liveCDN() async throws {
        let html = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        let repository = PronunciationLabRepository(keepsHTTPCache: false) { html }
        let clock = ContinuousClock()
        let started = clock.now
        let cat = try await repository.convert(lines: ["猫"], sourceLang: "ja", lang: "ko", notation: "translation")
        print("live: 猫 -> \(cat.lines[0]) with pronunciation-lab \(cat.version) in \(clock.now - started)")
        check(cat.lines == ["네코"], "connection test reading: \(cat.lines)")
        check(!cat.version.isEmpty, "release reported")
        let line = try await repository.convert(lines: ["夢ならばどれほどよかったでしょう", "", "♪"], sourceLang: "ja", lang: "ko",
                                                notation: "translation")
        check(line.lines == ["유메나라바 도레호도 요캇타데쇼", "", "♪"], "the reference line: \(line.lines)")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="ivlyrics-pronunciation-lab-") as directory:
    directory = Path(directory)
    (directory / "Helpers.swift").write_text(helpers, encoding="utf-8")
    (directory / "Regression.swift").write_text(checks, encoding="utf-8")
    fixture = directory / "fixture.html"
    fixture.write_text(FIXTURE_PAGE, encoding="utf-8")
    executable = directory / "regression"
    subprocess.run(["swiftc", str(directory / "Helpers.swift"), str(SRC / "PerplexityAgentAPI.swift"),
                    str(SRC / "PronunciationLabRepository.swift"), str(directory / "Regression.swift"),
                    "-o", str(executable)], check=True)
    subprocess.run([str(executable), str(fixture), str(SRC / "Resources/PronunciationLabPage.html")], check=True, timeout=200)

