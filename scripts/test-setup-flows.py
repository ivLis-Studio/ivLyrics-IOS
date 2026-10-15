#!/usr/bin/env python3
"""Execute production setup callbacks and prompt identity guards against controlled services.

This checks behavior, not rendered acceptance. Run SetupFlowUITests for native UI,
real AppSettings persistence, input reachability and screenshots.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "ivLyrics-IOS/AppViewModel.swift").read_text()
welcome_source = (ROOT / "ivLyrics-IOS/SetupViews.swift").read_text()
workflow = (ROOT / ".github/workflows/ios-validation.yml").read_text()
for path in ["ivLyrics-IOS/SetupViews.swift", "ivLyrics-IOSUITests/SetupFlowUITests.swift", "scripts/test-setup-flows.py"]:
    assert workflow.count(f"      - '{path}'") == 2, f"Both push and PR filters must cover {path}"
assert "python3 scripts/test-setup-flows.py" in workflow
assert "-only-testing:" not in workflow, "CI's native action must run the whole UITest target, including SetupFlowUITests"


def declaration(prefix, text=source):
    start = text.index(prefix)
    end = text.index("{", start) + 1
    depth = 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end].replace("private ", "")


code = r'''
import Foundation
extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
struct Track { var stableKey: String; var hasUsableMetadata = true }
struct AppSettings {
    var spotifyClientId = "", spotifyClientSecret = "", uiLang = "en"
    var spotifyWebAPIEnabled = false
    var rules: [String: (Bool, Bool)] = [:]
    var snapshot: Snapshot { Snapshot(hasSpotifyClientId: !spotifyClientId.trimmed.isEmpty) }
    struct Snapshot { var hasSpotifyClientId: Bool }
    func t(_ key: String) -> String { key }
    func tf(_ key: String, _ value: String) -> String { key + ":" + value }
    mutating func setLanguageRule(sourceLang: String, translationEnabled: Bool, pronunciationEnabled: Bool) {
        rules[sourceLang] = (translationEnabled, pronunciationEnabled)
    }
}
@MainActor final class Repository {
    struct Validation { let logs = [String](); let expiresInSeconds = 3600 }
    var calls = 0, clears = 0
    var pending: [CheckedContinuation<Validation, Error>] = []
    var onClear: (() -> Void)?
    func validateSpotifyCredentials(clientId: String, clientSecret: String, uiLanguage: String) async throws -> Validation {
        calls += 1
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func clearCache() async { clears += 1; onClear?() }
    func complete(_ succeeds: Bool) {
        let continuation = pending.removeFirst()
        if succeeds { continuation.resume(returning: Validation()) }
        else { continuation.resume(throwing: NSError(domain: "fixture", code: 1)) }
    }
}
'''
code += declaration("struct FirstLanguagePrompt:") + "\n" + declaration("enum FirstLanguagePromptChoice")
code += r'''
@MainActor final class Flow {
    var settings = AppSettings()
    var status = Status.idle
    enum Status { case idle, setupRequired }
    var onboardingStep = 2, reloads = 0, connections = 0
    var initialSetupPresented = true
    var initialSetupComplete: Bool { settings.snapshot.hasSpotifyClientId }
    var spotifyCredentialsValidationInFlight = false, spotifyCredentialsValidationFailed = false
    var spotifyValidationStatus = ""
    var firstLanguagePrompt: FirstLanguagePrompt?
    var currentTrack: Track? = Track(stableKey: "track-a")
    let lyricsRepository = Repository()
    let suite = "ivlyrics-setup-host-" + UUID().uuidString
    var defaults: UserDefaults!
    let keyInitialSetupDismissed = "initial_setup_dismissed"
    let keySpotifyValidatedSourceKey = "spotify_validated_source_key"
    var spotifyArtworkURLsByTrackId: [String: String] = [:]
    var spotifyMetadataHydrationRetryAfter: [String: Int] = [:]
    init() { defaults = UserDefaults(suiteName: suite)! }
    deinit { UserDefaults().removePersistentDomain(forName: suite) }
    func setSpotifyValidationStatus(_ text: (AppSettings) -> String) { spotifyValidationStatus = text(settings) }
    func appendLog(_ text: String) {}
    func appendLogs(_ texts: [String]) {}
    func showSavedToast(_ text: String) {}
    func connectSpotifyUserAndStartPolling() { connections += 1 }
    func reloadLyrics(bypassCache: Bool) { reloads += 1 }
    func spotifyCredentialsSourceKey(clientId: String, clientSecret: String) -> String { clientId + "|" + clientSecret }
    func errorMessageText(_ error: Error) -> (AppSettings) -> String { { _ in "offline failure" } }
'''
for prefix in ["func advanceOnboarding()", "func retreatOnboarding()", "func finishInitialSetup(",
               "func validateSpotifyApiCredentials(", "func applyFirstLanguagePromptChoice(",
               "func dismissFirstLanguagePrompt("]:
    code += declaration(prefix) + "\n"
code += "}\n"
code += declaration("struct SetupWelcomeGreeting", welcome_source) + "\n"
code += r'''
@MainActor func pump() async { for _ in 0..<100 { await Task.yield() } }
@MainActor var checks = 0
@MainActor func check(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    precondition(value(), message)
}
@main struct Checks {
    @MainActor static func main() async {
        check(SetupWelcomeGreeting.interval == .milliseconds(3500), "Welcome rotates every 3.5 seconds")
        for language in ["ko", "en", "zh-CN", "zh-TW", "ja", "hi", "es", "fr", "ar", "fa", "de",
                         "ru", "sv", "pt", "bn", "cs", "it", "th", "vi", "id", "ms", "tr"] {
            var greeting = SetupWelcomeGreeting()
            let initial = language == "ko" ? "안녕하세요" : "Hello"
            check(greeting.title(uiLanguage: language) == initial, "Korean greeting or English fallback for all 22 languages")
            greeting.advance(uiLanguage: language)
            check(greeting.title(uiLanguage: language) != initial, "Only the greeting alternates")
            greeting.advance(uiLanguage: language)
            check(greeting.title(uiLanguage: language) == initial, "Second tick returns to the initial greeting")
            greeting.stop(uiLanguage: language)
            var rebuilt = greeting
            rebuilt.advance(uiLanguage: language)
            check(rebuilt.stopped && rebuilt.title(uiLanguage: language) == initial,
                  "Picker interaction/phase exit stays locked across Back or a view rebuild")
            check(!rebuilt.canRotate(phase: 0, visible: true, active: true, reduceMotion: false, voiceOver: false),
                  "Locked setup sessions never schedule another timer")
            rebuilt.stop(uiLanguage: "ko")
            check(rebuilt.title(uiLanguage: "ko") == "안녕하세요", "Explicit selection updates the locked greeting")
        }
        let greeting = SetupWelcomeGreeting()
        for phase in 0...2 {
            for visible in [false, true] {
                for active in [false, true] {
                    for reduceMotion in [false, true] {
                        for voiceOver in [false, true] {
                            check(greeting.canRotate(phase: phase, visible: visible, active: active,
                                                     reduceMotion: reduceMotion, voiceOver: voiceOver)
                                  == (phase == 0 && visible && active && !reduceMotion && !voiceOver),
                                  "Only the visible, active first phase can rotate; accessibility stays static")
                        }
                    }
                }
            }
        }
        let blank = Flow()
        blank.finishInitialSetup()
        check(blank.status == .setupRequired && blank.spotifyCredentialsValidationFailed, "ID is required")
        check(blank.initialSetupPresented && blank.connections == 0, "No handoff without ID")
        blank.settings.spotifyClientId = "  client  "
        blank.finishInitialSetup()
        check(!blank.initialSetupPresented && blank.connections == 1, "ID-only App Remote handoff")
        check(blank.lyricsRepository.calls == 0, "Optional secret does not block App Remote")
        for webAPI in [false, true] {
            let optional = Flow()
            optional.settings.spotifyClientId = "client"
            optional.settings.spotifyClientSecret = "stale-secret"
            optional.settings.spotifyWebAPIEnabled = webAPI
            optional.finishInitialSetup(validateMetadata: false)
            check(optional.connections == 1 && optional.lyricsRepository.calls == 0, "Old optional Secret never blocks playback authorization")
            check(optional.settings.spotifyClientSecret == "stale-secret" && optional.settings.spotifyWebAPIEnabled == webAPI,
                  "Skip inactive metadata validation without changing saved credentials or Web API preference")
        }

        let retry = Flow()
        retry.settings.spotifyClientId = "client"; retry.settings.spotifyClientSecret = "secret"
        retry.finishInitialSetup(); retry.finishInitialSetup()
        await pump()
        check(retry.lyricsRepository.calls == 1 && retry.spotifyCredentialsValidationInFlight, "No duplicate validation")
        retry.lyricsRepository.complete(false); await pump()
        check(retry.spotifyCredentialsValidationFailed && !retry.spotifyCredentialsValidationInFlight, "Failure exposes retry")
        check(retry.initialSetupPresented && retry.connections == 0, "Failure keeps the form open")
        retry.retreatOnboarding(); retry.advanceOnboarding()
        check(retry.settings.spotifyClientId == "client" && retry.settings.spotifyClientSecret == "secret", "Back retains drafts")
        retry.finishInitialSetup(); await pump()
        retry.lyricsRepository.complete(true); await pump()
        check(!retry.initialSetupPresented && retry.connections == 1, "Retry succeeds before auth handoff")
        check(retry.lyricsRepository.clears == 1 && !retry.spotifyCredentialsValidationFailed, "Validated change clears stale metadata")

        for success in [false, true] {
            let stale = Flow()
            stale.settings.spotifyClientId = "old"; stale.settings.spotifyClientSecret = "secret"
            stale.finishInitialSetup(); await pump()
            stale.settings.spotifyClientId = "new"
            stale.lyricsRepository.complete(success); await pump()
            check(stale.initialSetupPresented && stale.connections == 0, "Stale validation cannot close new draft")
            check(stale.defaults.string(forKey: stale.keySpotifyValidatedSourceKey) == nil, "Stale credentials never marked validated")
            check(stale.spotifyValidationStatus.isEmpty && !stale.spotifyCredentialsValidationFailed, "Stale result never labels the new draft")
        }
        let duringClear = Flow()
        duringClear.settings.spotifyClientId = "old"; duringClear.settings.spotifyClientSecret = "secret"
        duringClear.lyricsRepository.onClear = {
            duringClear.finishInitialSetup()
            duringClear.settings.spotifyClientId = "new"
        }
        duringClear.finishInitialSetup(); await pump()
        duringClear.lyricsRepository.complete(true); await pump()
        check(duringClear.connections == 0 && duringClear.reloads == 0, "Draft edits during awaited cache work cannot trigger handoff or reload")
        check(duringClear.initialSetupPresented && duringClear.spotifyValidationStatus.isEmpty, "Late draft remains open without stale success")
        check(duringClear.lyricsRepository.calls == 1, "Cache work remains part of the in-flight validation")
        duringClear.lyricsRepository.onClear = nil
        let wentBack = Flow()
        wentBack.settings.spotifyClientId = "client"; wentBack.settings.spotifyClientSecret = "secret"
        wentBack.finishInitialSetup(); await pump()
        wentBack.retreatOnboarding()
        wentBack.lyricsRepository.complete(true); await pump()
        check(wentBack.initialSetupPresented && wentBack.onboardingStep == 1 && wentBack.connections == 0,
              "Back during validation never launches Spotify or closes another phase")

        for (choice, translation, pronunciation) in [
            (FirstLanguagePromptChoice.original, false, false), (.translation, true, false),
            (.pronunciation, false, true), (.both, true, true)
        ] {
            let flow = Flow()
            let prompt = FirstLanguagePrompt(sourceLang: "ja", languageName: "Japanese", trackKey: "track-a")
            flow.firstLanguagePrompt = prompt
            flow.applyFirstLanguagePromptChoice(choice, prompt: prompt)
            check(flow.settings.rules["ja"]?.0 == translation && flow.settings.rules["ja"]?.1 == pronunciation, "Independent language choices")
            check(flow.reloads == 1 && flow.firstLanguagePrompt == nil, "Apply reloads only the original track")
            flow.applyFirstLanguagePromptChoice(.both, prompt: prompt)
            check(flow.reloads == 1, "Duplicate callback is ignored")
        }
        let changed = Flow()
        let old = FirstLanguagePrompt(sourceLang: "ja", languageName: "Japanese", trackKey: "track-a")
        let newer = FirstLanguagePrompt(sourceLang: "fr", languageName: "French", trackKey: "track-b")
        changed.currentTrack = Track(stableKey: "track-b")
        changed.firstLanguagePrompt = newer
        changed.applyFirstLanguagePromptChoice(.both, prompt: old)
        changed.dismissFirstLanguagePrompt(prompt: old)
        check(changed.firstLanguagePrompt == newer && changed.settings.rules.isEmpty, "Old callbacks cannot replace/dismiss a newer prompt")
        changed.firstLanguagePrompt = old
        changed.applyFirstLanguagePromptChoice(.translation, prompt: old)
        check(changed.settings.rules["ja"]?.0 == true && changed.reloads == 0, "Remember old language without reloading replacement track")
        changed.firstLanguagePrompt = old
        changed.dismissFirstLanguagePrompt(prompt: old)
        check(changed.reloads == 0, "Not now also respects track identity")
        for _ in 0..<10 { changed.advanceOnboarding() }
        check(changed.onboardingStep == 2, "Three phases only")
        for _ in 0..<10 { changed.retreatOnboarding() }
        check(changed.onboardingStep == 0, "Back stays in bounds")
        print("Setup flow regression: \(checks) production callback/choice and welcome policy checks passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-setup-host-") as temp:
    path = Path(temp)
    (path / "Checks.swift").write_text(code)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(path / "Checks.swift"), "-o", str(path / "checks")], check=True)
    subprocess.run([str(path / "checks")], check=True)
