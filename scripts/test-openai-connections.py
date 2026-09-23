#!/usr/bin/env python3
"""Compile production connection storage/snapshot/failover code in a Foundation test fixture."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
settings = (SRC / "AppSettings.swift").read_text()
repository = (SRC / "AiLyricsRepository.swift").read_text()


def section(source, start, end):
    return source[source.index(start):source.index(end, source.index(start))]


profile = section(settings, "    struct AIProviderProfile:", "    struct LyricsProvider:")
storage = section(settings, "    var openAIConnections:", "    private func syncLegacyKeylessProvider(").replace("private func saveAIProviderProfileFromPublished", "func saveAIProviderProfileFromPublished")
snapshot = section(settings, "        var hasApiKey:", "        var hasKeylessTranslationProvider:")
snapshot += section(settings, "        var openAIConnectionSnapshots:", "        var hasSpotifyCredentials:")
cache = section(settings, "                    let encoder = JSONEncoder()", "                }\n            }\n            for rule in languageRules")
helper = section(repository, "    private func withOpenAIConnections<T>", "    private func loadSupplementValuesStreamFirst(").replace("private func", "func")
fixtures = '''import Foundation
import CryptoKit
extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
enum IvLyricsUtilities {
    static func sha256(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
}
final class AppSettings {
    struct Provider: Hashable, Sendable { var id: String; var defaultBaseUrl = "https://api.openai.com/v1"; var defaultModel = "primary" }
    static func providerById(_ id: String) -> Provider { Provider(id: id) }
    var aiProviderProfiles: [String: AIProviderProfile] = [:]
    var providerId = "chatgpt", apiKeys = "primary-key", baseUrl = "https://primary.test/v1", model = "primary"
    var maxTokens = 4096, temperature = 0.7
    var isBootstrapping = false, isSwitchingAIProviderProfile = false
    // PROFILE
    // STORAGE
    struct Snapshot: Sendable {
        var provider = Provider(id: "chatgpt")
        var aiProviderProfiles: [String: AIProviderProfile] = [:]
        var apiKeys = "primary-key", baseUrl = "https://primary.test/v1", model = "primary", pollinationsAccessToken = ""
        var maxTokens = 4096, temperature = 0.7
        // SNAPSHOT
    }
}
struct Runner {
    // HELPER
    func cacheFingerprint(_ profile: AppSettings.AIProviderProfile) -> String {
        var key = ""
        // CACHE
        return key
    }
}
'''
for marker, value in [("PROFILE", profile), ("STORAGE", storage), ("SNAPSHOT", snapshot), ("HELPER", helper), ("CACHE", cache)]:
    fixtures = fixtures.replace("// " + marker, value)
checks = r'''
import Foundation
@main struct Regression {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fatalError(message) }
    }
    static func connection(_ id: String, enabled: Bool = true) -> OpenAIConnection {
        OpenAIConnection(id: id, name: id, baseUrl: "https://\(id).test/v1", apiKeys: "key-\(id)", model: id, enabled: enabled)
    }
    static func main() async throws {
        let legacy = Data(#"{"apiKeys":"legacy-secret","baseUrl":"https://legacy.test/v1","model":"legacy","maxTokens":4000,"temperature":0.5}"#.utf8)
        let profile = try JSONDecoder().decode(AppSettings.AIProviderProfile.self, from: legacy)
        check(profile.openAIConnections == nil && profile.apiKeys == "legacy-secret", "Legacy profiles decode without new property")
        let settings = AppSettings()
        settings.aiProviderProfiles["chatgpt"] = profile
        check(settings.openAIConnections.isEmpty, "Legacy connection list defaults empty")
        settings.openAIConnections = [connection("disabled", enabled: false), connection("backup"), connection("last")]
        check(settings.aiProviderProfiles["chatgpt"]!.apiKeys == "legacy-secret", "Adding connections preserves primary")
        settings.saveAIProviderProfileFromPublished()
        check(settings.openAIConnections.map(\.id) == ["disabled", "backup", "last"], "Editing primary preserves connection order")
        settings.providerId = "claude"
        settings.saveAIProviderProfileFromPublished()
        check(settings.openAIConnections.count == 3, "Other provider edits preserve connections")
        let saved = settings.aiProviderProfiles["chatgpt"]!
        let restored = try JSONDecoder().decode(AppSettings.AIProviderProfile.self, from: JSONEncoder().encode(saved))
        check(restored == saved, "Connection settings round trip through Codable")
        check(!restored.openAIConnections![0].enabled && restored.openAIConnections![1].apiKeys == "key-backup", "Enabled state and credentials persisted")
        var source = AppSettings.Snapshot()
        source.aiProviderProfiles = ["chatgpt": saved]
        let candidates = source.openAIConnectionSnapshots
        check(candidates.map(\.model) == ["primary", "backup", "last"], "Primary first, disabled skipped, order preserved")
        check(candidates[1].apiKeys == "key-backup" && candidates[1].baseUrl == "https://backup.test/v1", "Independent credentials and URLs")
        check(candidates[1].maxTokens == 4096 && candidates[1].temperature == 0.7, "Common request tuning preserved")
        check(source.model == "primary" && source.apiKeys == "primary-key", "Request snapshots cannot mutate primary")
        var different = source
        different.provider = .init(id: "claude")
        check(different.openAIConnectionSnapshots.count == 1, "Other provider does not inherit connections")
        var blank = source
        blank.apiKeys = ""; blank.model = ""
        check(blank.hasApiKey && blank.hasModel, "Ready backup supports an empty primary")
        blank.aiProviderProfiles["chatgpt"]!.openAIConnections = [connection("disabled", enabled: false)]
        check(!blank.hasApiKey && !blank.hasModel, "Disabled backups cannot satisfy readiness")

        let runner = Runner()
        var attempts: [String] = []
        var output: [String] = []
        let answer = try await runner.withOpenAIConnections(settings: source, reset: { output = [] }) { item in
            attempts.append(item.model)
            if item.model == "primary" { output.append("failed partial"); throw URLError(.timedOut) }
            check(output.isEmpty, "Failed stream text cleared before backup")
            output.append("complete")
            return item.model
        }
        check(answer == "backup" && attempts == ["primary", "backup"], "Timeout advances; success stops attempts")
        check(output == ["complete"], "No text mixed between connections")
        attempts = []
        do {
            let _: String = try await runner.withOpenAIConnections(settings: source) { item in
                attempts.append(item.model)
                throw NSError(domain: item.model, code: 503)
            }
            fatalError("All failures reported success")
        } catch { check(attempts.count == 3 && (error as NSError).domain == "last", "All providers tried; last failure retained") }
        attempts = []
        do {
            let _: String = try await runner.withOpenAIConnections(settings: source) { item in
                attempts.append(item.model); throw CancellationError()
            }
            fatalError("Cancellation ignored")
        } catch is CancellationError { check(attempts == ["primary"], "Cancellation never advances to another provider") }
        attempts = []
        do {
            let _: String = try await runner.withOpenAIConnections(settings: source) { item in
                attempts.append(item.model); throw URLError(.cancelled)
            }
            fatalError("URL cancellation ignored")
        } catch { check((error as? URLError)?.code == .cancelled && attempts == ["primary"], "Network cancellation preserved") }
        let fingerprint = runner.cacheFingerprint(saved)
        check(!fingerprint.isEmpty && !fingerprint.contains("key-backup"), "Cache key does not expose credentials")
        check((0..<100).allSatisfy { _ in runner.cacheFingerprint(saved) == fingerprint }, "Repeated encodings have deterministic cache keys")
        var reordered = saved
        reordered.openAIConnections!.swapAt(1, 2)
        check(runner.cacheFingerprint(reordered) != fingerprint, "Connection reordering invalidates cache")
        print("OpenAI connection regression: \(checks) checks passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-connections-") as directory:
    directory = Path(directory)
    (directory / "Fixtures.swift").write_text(fixtures)
    (directory / "Regression.swift").write_text(checks)
    executable = directory / "regression"
    subprocess.run(["swiftc", str(directory / "Fixtures.swift"), str(SRC / "OpenAIConnection.swift"),
                    str(directory / "Regression.swift"), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
