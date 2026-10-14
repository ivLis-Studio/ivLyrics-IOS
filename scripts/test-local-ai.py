#!/usr/bin/env python3
"""Run the Local AI provider with a fixture engine and fixture HTTP: no model, network or device.

Compiles the production LocalAI.swift and LocalAIService.swift with the AppSettings provider list,
order and gates. Covers tiers and URLs, block splitting, protected and vocal parts, deduplication,
language names, immediate not-downloaded and unsupported-language failures, idle release options,
on-screen-first scheduling, memory warnings, background GPU gating and resumable downloads.
"""
from pathlib import Path
import json
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
settings = (SRC / "AppSettings.swift").read_text(encoding="utf-8")
repository = (SRC / "AiLyricsRepository.swift").read_text(encoding="utf-8")


def section(source, start, end):
    first = source.index(start)
    return source[first:source.index(end, first + len(start))]


# Paths that need the whole app are checked in the source.
metadata = section(repository, "    func loadMetadataTranslation(", "    func loadTmi(")
assert "if provider.isLocal { continue }" in metadata, "metadata translation must skip Local AI"
supplement = section(repository, "    private func loadSupplementTask(", "    private func emitSupplementPartial(")
pronunciation = section(supplement, "            if pronunciation {", "            } else {")
assert "readyAIProviderSnapshots" in pronunciation and "LocalAI" not in pronunciation, "pronunciation must not use Local AI"
assert "LocalAIService.shared.translate(" in supplement, "lyrics translation must reach Local AI"
assert "priority: partialUpdate == nil ? .background : .interactive" in supplement, "prefetch must run after lyrics on screen"
cache_key = section(settings, "        var cacheKey: String {", "        var localAIConfiguration:")
assert re.search(r"if providerId == LocalAI\.providerId \{\s*//[^\n]*\n\s*if isAIProviderEnabled\(providerId\) \{", cache_key), \
    "a disabled Local AI must leave cache keys unchanged"
languages = re.findall(r'Language\(code: "([^"]+)"', section(settings, "    static let languages: [Language] = [", "    static let typographySlots"))
assert len(languages) == 22, languages
content_view = (SRC / "ContentView.swift").read_text(encoding="utf-8")
provider_card = section(content_view, "    private func aiProviderSettingsCard(", "    private func aiProviderDescription(")
assert re.search(r'if provider\.isLocal \{\s*//[^\n]*\n\s*Text\(settings\.t\("local_ai\.performance_note"\)\)', provider_card), \
    "the Local AI card must say that it needs a high-end device"
bundle = json.loads((SRC / "Resources/AppI18nStrings.json").read_text(encoding="utf-8"))
assert sorted(bundle) == sorted(languages), sorted(bundle)
for code, strings in bundle.items():
    assert strings.get("local_ai.performance_note", "").strip(), f"{code}: missing the Local AI performance note"
    assert not re.search(r"(?i)click|clic|cliqu|klick|klik", strings["local_ai.confirm_remove"]), f"{code}: say tap, not click"
assert bundle["ko"]["local_ai.performance_note"] == "기기 성능에 따라 속도와 안정성이 크게 달라집니다. 고사양 기기가 아니라면 사용을 권장하지 않습니다."

helpers = '''import Foundation
extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
enum PaxsenixAIProvider { static let baseURL = "https://fixture.test", dashboardURL = "https://fixture.test" }
enum KeylessTranslationProviders {
    static let bingId = "bing-translate", googleId = "google-translate"
    static let bingLabel = "Bing Translate", googleLabel = "Google Translate"
}
enum AppSettings {
// PROVIDERS
// LOOKUP
// ORDER
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
helpers = helpers.replace("// PROVIDER", section(settings, "    struct Provider:", "    struct AIProviderProfile:"))
helpers = helpers.replace("// GATES", section(settings, "        var hasKeylessTranslationProvider:", "        func selectingAIProvider("))

# The chat template stored in Hy-MT2-1.8B-*.gguf (tokenizer.chat_template).
HY_MT2_TEMPLATE = "{% if messages[0]['role'] == 'system' %}{% set loop_messages = messages[1:] %}{% set system_message = messages[0]['content'] %}<｜hy_begin▁of▁sentence｜>{{ system_message }}<｜hy_place▁holder▁no▁3｜>{% else %}{% set loop_messages = messages %}<｜hy_begin▁of▁sentence｜>{% endif %}{% for message in loop_messages %}{% if message['role'] == 'user' %}<｜hy_User｜>{{ message['content'] }}{% elif message['role'] == 'assistant' %}<｜hy_Assistant｜>{{ message['content'] }}<｜hy_place▁holder▁no▁2｜>{% endif %}{% endfor %}{% if add_generation_prompt %}<｜hy_Assistant｜>{% else %}<｜hy_place▁holder▁no▁8｜>{% endif %}"

checks = r'''
import Foundation

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var prompts: [String] = []
    private var budgets: [Int] = []
    private var loads: [String] = []
    private var lines: [Int: String] = [:]
    func prompt(_ value: String, _ budget: Int) { lock.lock(); prompts.append(value); budgets.append(budget); lock.unlock() }
    func load(_ value: String) { lock.lock(); loads.append(value); lock.unlock() }
    func line(_ index: Int, _ text: String) { lock.lock(); lines[index] = text; lock.unlock() }
    var allPrompts: [String] { lock.lock(); defer { lock.unlock() }; return prompts }
    var allBudgets: [Int] { lock.lock(); defer { lock.unlock() }; return budgets }
    var allLoads: [String] { lock.lock(); defer { lock.unlock() }; return loads }
    var reported: [Int: String] { lock.lock(); defer { lock.unlock() }; return lines }
}

/// Holds the first engine call until the test releases it.
final class Hold: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let gate = DispatchSemaphore(value: 0)
    func waitStarted() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { self.started.wait(); continuation.resume() }
        }
    }
    func release() { gate.signal() }
}

let blockMarker = "retain the exact same number of delimiters"

/// The source text follows the blank line that ends either prompt.
func source(_ prompt: String) -> String {
    guard let range = prompt.range(of: "\n\n", options: .backwards) else { return prompt }
    return String(prompt[range.upperBound...])
}

func koreanReply(_ prompt: String) throws -> LocalAI.Completion {
    LocalAI.Completion(text: source(prompt).components(separatedBy: "\n").map { "KO:" + $0 }.joined(separator: "\n"), stoppedAtLimit: false)
}

final class FixtureEngine: LocalAIInferenceEngine, @unchecked Sendable {
    let usesGPU: Bool
    var deviceLabel: String { usesGPU ? "GPU" : "CPU" }
    let recorder: Recorder
    let reply: @Sendable (String) throws -> LocalAI.Completion
    let hold: Hold?
    private var held = false
    init(usesGPU: Bool, recorder: Recorder, reply: @escaping @Sendable (String) throws -> LocalAI.Completion, hold: Hold?) {
        self.usesGPU = usesGPU
        self.recorder = recorder
        self.reply = reply
        self.hold = hold
    }
    func complete(prompt: String, maxTokens: Int, shouldStop: () -> Bool) throws -> LocalAI.Completion {
        if shouldStop() { throw CancellationError() }
        if let hold, !held {
            held = true
            hold.started.signal()
            hold.gate.wait()
        }
        // A real engine checks between tokens.
        if shouldStop() { throw CancellationError() }
        recorder.prompt(prompt, maxTokens)
        return try reply(prompt)
    }
}

func makeLoader(_ recorder: Recorder, hold: Hold? = nil,
                reply: @escaping @Sendable (String) throws -> LocalAI.Completion = { try koreanReply($0) }) -> LocalAIEngineLoader {
    { url, processor in
        recorder.load(url.lastPathComponent + ":" + processor.rawValue)
        return FixtureEngine(usesGPU: processor == .auto, recorder: recorder, reply: reply, hold: hold)
    }
}

final class IdleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancelled = Set<UUID>()
    private var requests: [Double] = []
    var requested: [Double] { lock.lock(); defer { lock.unlock() }; return requests }
    func sleep(_ seconds: Double) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                requests.append(seconds)
                if cancelled.contains(id) {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    pending[id] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            cancelled.insert(id)
            let continuation = pending.removeValue(forKey: id)
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }
    }
    func fire() {
        lock.lock()
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        for continuation in waiting.values { continuation.resume() }
    }
}

final class FixtureHTTP: URLProtocol {
    struct Reply {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
        var finish = true
    }
    static var handler: (URLRequest) -> Reply = { _ in Reply(status: 404) }
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let reply = Self.handler(request)
        // Like the model host; without a content type URLSession holds short bodies for sniffing.
        let headers = reply.headers.merging(["Content-Type": "application/octet-stream"]) { current, _ in current }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        if reply.finish { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}

func fixtureSession() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FixtureHTTP.self]
    return configuration
}

@main
struct Regression {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        count += 1
        if !value() { fatalError(message) }
    }

    static func expect<T>(_ expected: LocalAIError, _ message: String, _ body: () async throws -> T) async {
        do {
            _ = try await body()
            fatalError("\(message): no error")
        } catch let error as LocalAIError {
            check(error == expected, "\(message): \(error)")
        } catch {
            fatalError("\(message): \(error)")
        }
    }

    static func waitUntil(_ message: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<2000 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("Timed out: \(message)")
    }

    static var base = URL(fileURLWithPath: CommandLine.arguments[1])

    /// A model directory with sparse files of the published sizes.
    static func directory(_ tiers: [LocalAI.Tier]) throws -> URL {
        let url = base.appendingPathComponent("models-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for tier in tiers {
            let file = url.appendingPathComponent(tier.fileName)
            FileManager.default.createFile(atPath: file.path, contents: Data("GGUF".utf8))
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: UInt64(tier.byteCount))
            try handle.close()
        }
        return url
    }

    static let messages = LocalAI.Messages(notReady: "NOT READY", downloadBusy: "BUSY",
                                           unsupportedLanguage: "cannot translate into {language}", uiLanguage: "en")
    static let light = LocalAI.Configuration(tier: .light, processor: .auto, idleMinutes: 10)

    static func main() async throws {
        tiersAndOptions()
        algorithm()
        providerList()
        try await translation()
        try await failuresAndGates()
        try await idleAndMemory()
        try await downloads()
        print("Local AI regression: \(count) checks passed")
    }

    static func tiersAndOptions() {
        check(LocalAI.providerId == "local-ai" && LocalAI.label == "Local AI", "provider id and product name")
        check(LocalAI.Tier.mobileDefault == .light, "mobile default is Local Light")
        check(LocalAI.Tier.stored(nil) == .light && LocalAI.Tier.stored("bogus") == .light && LocalAI.Tier.stored(" HIGH ") == .high, "stored tier")
        check(LocalAI.Configuration().tier == .light, "default configuration uses Local Light")
        let base = "https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/main/"
        check(LocalAI.Tier.light.downloadURL.absoluteString == base + "Hy-MT2-1.8B-Q4_K_M.gguf" && LocalAI.Tier.light.byteCount == 1_133_080_448, "light file")
        check(LocalAI.Tier.medium.downloadURL.absoluteString == base + "Hy-MT2-1.8B-Q6_K.gguf" && LocalAI.Tier.medium.byteCount == 1_474_785_120, "medium file")
        check(LocalAI.Tier.high.downloadURL.absoluteString == base + "Hy-MT2-1.8B-Q8_0.gguf" && LocalAI.Tier.high.byteCount == 1_908_528_192, "high file")
        check(LocalAI.Tier.allCases.map(\.sliderIndex) == [0, 1, 2], "slider steps")
        check(LocalAI.Tier(sliderIndex: -3) == .light && LocalAI.Tier(sliderIndex: 1) == .medium && LocalAI.Tier(sliderIndex: 9) == .high, "slider clamps")
        check(LocalAI.Tier.allCases.map(\.titleKey) == ["local_ai.tier_light", "local_ai.tier_medium", "local_ai.tier_high"], "tier titles")
        check(LocalAI.Tier.allCases.map { LocalAI.formatGigabytes($0.byteCount) } == ["1.13GB", "1.47GB", "1.91GB"], "sizes under the steps")
        check(LocalAI.idleMinuteOptions == [10, 30, 60, 0] && LocalAI.defaultIdleMinutes == 10, "idle options")
        check(LocalAI.normalizedIdleMinutes(nil) == 10 && LocalAI.normalizedIdleMinutes(45) == 10, "unknown idle falls back to 10 min")
        check(LocalAI.normalizedIdleMinutes(0) == 0 && LocalAI.normalizedIdleMinutes(60) == 60 && LocalAI.normalizedIdleMinutes(30) == 30, "idle choices")
        check(LocalAI.Processor.stored(nil) == .auto && LocalAI.Processor.stored("cpu") == .cpu, "processor")
        check(LocalAI.format("Ready · {device}", ["device": "GPU"]) == "Ready · GPU", "device placeholder")
        check(LocalAI.format("{percent}% · {loaded} / {total} MB", ["percent": "50", "loaded": "567", "total": "1133"]) == "50% · 567 / 1133 MB", "progress text")
        check(LocalAI.format("{unknown} stays", [:]) == "{unknown} stays", "unknown placeholders stay")
        check(LocalAI.downloadPercent(loaded: 566_540_224, total: 1_133_080_448) == 50 && LocalAI.megabytes(1_133_080_448) == 1133, "progress numbers")
        check(LocalAI.testSample(targetLanguage: "ko") == "今夜はまだ始まったばかり" && LocalAI.testSample(targetLanguage: "ja") == "The night is still young.", "test samples")
    }

    static func algorithm() {
        check(LocalAI.blockPrompt(["a", "b"], language: "Korean") == "Please accurately translate the following text into Korean.\nYou must retain the exact same number of delimiters in the translation. Strictly do not omit, escape, or translate these symbols, and pay close attention to their placement.\n\na\nb", "block prompt")
        check(LocalAI.linePrompt("a", language: "English") == "Translate the following text into English. Note that you should only output the translated result without any additional explanation:\n\na", "line prompt")
        check(LocalAI.outputBudget(for: "abc") == 57 && LocalAI.outputBudget(for: String(repeating: "a", count: 600)) == 1536, "output budget")
        check(LocalAI.outputBudget(for: "🎵") == 54, "characters counted like JavaScript")

        let short = (0..<20).map { "p\($0)" }
        check(LocalAI.buildBlocks(short).map(\.count) == [8, 8, 4], "8 parts per block")
        let hundred = (0..<6).map { String(repeating: "\($0)", count: 100) }
        check(LocalAI.buildBlocks(hundred).map(\.count) == [4, 2], "480 characters per block")
        check(LocalAI.buildBlocks(["s", String(repeating: "l", count: 700), "t"]).map(\.count) == [1, 1, 1], "a long part gets its own block")

        check(LocalAI.isProtectedPart("[Instrumental]") && LocalAI.isProtectedPart("  [Chorus]  "), "markers stay")
        check(!LocalAI.isProtectedPart("[a] b") && !LocalAI.isProtectedPart("♪"), "other text is translated")
        check(!LocalAI.isTranslatablePart("   ") && LocalAI.isTranslatablePart("君"), "blank parts stay blank")

        var job = LocalAI.LineJob(lines: ["君の声", "", "[Instrumental]", "夜明け / まで", "君の声", "  [Chorus]  ", "まで / 君の声", "夜 /   / 朝"])
        check(job.pending == ["君の声", "夜明け", "まで", "夜", "朝"], "each unique part once, in order: \(job.pending)")
        let early = job.takeReadyRows().map(\.index)
        check(early == [1, 2, 5], "blank and marker rows are ready at once")
        job.fill(["君の声", "夜明け", "まで"], with: ["A", "B", "C"])
        check(job.takeReadyRows().map(\.index) == [0, 3, 4, 6], "rows finish as their parts arrive")
        job.fill(["夜", "朝"], with: ["N", "M"])
        check(job.result == ["A", "", "[Instrumental]", "B / C", "A", "  [Chorus]  ", "C / A", "N /  / M"], "rows rebuilt: \(job.result)")
        check(LocalAI.LineJob(text: "一\r\n二\r三").rows.count == 3, "text splits on newlines")

        check(LocalAI.acceptedBlockLines(" A \n B \n", partCount: 2, stoppedAtLimit: false) == ["A", "B"], "block reply accepted")
        check(LocalAI.acceptedBlockLines("A\nB", partCount: 2, stoppedAtLimit: true) == nil, "token limit rejects the block")
        check(LocalAI.acceptedBlockLines("A\n\nB", partCount: 2, stoppedAtLimit: false) == nil, "a lost line rejects the block")
        check(LocalAI.acceptedBlockLines("A B", partCount: 2, stoppedAtLimit: false) == nil, "merged lines reject the block")
        check(LocalAI.singleLine(" 첫째 \n\n 둘째 ") == "첫째 둘째", "single reply newlines collapse")

        let names: [String: String?] = ["ko": "Korean", "en": "English", "ja": "Japanese", "zh": "Chinese", "zh-CN": "Chinese",
            "zh_CN": "Chinese", "zh-Hans": "Chinese", "zh-TW": "Traditional Chinese", "zh-HK": "Traditional Chinese",
            "zh-Hant": "Traditional Chinese", "pt-BR": "Portuguese", "tl": "Filipino", "fil": "Filipino", "yue": "Cantonese",
            "my": "Burmese", "bo": "Tibetan", "ug": "Uyghur", "he": "Hebrew", "": "English", "sv": nil, "ko-KR": "Korean", "xx": nil]
        for (code, name) in names { check(LocalAI.targetLanguageName(for: code) == name, "language name for \(code)") }
        let appLanguages = /*LANGUAGES*/
        check(appLanguages.filter { LocalAI.targetLanguageName(for: $0) == nil } == ["sv"], "every app language except Swedish")

        let hyTemplate = /*HY_TEMPLATE*/
        check(LocalAI.chatTemplateChoice(modelTemplate: hyTemplate) == .init(template: "hunyuan-dense", prefix: "<｜hy_begin▁of▁sentence｜>"),
              "Hy-MT2 renders like its Jinja template")
        let chatml = "{% for message in messages %}<|im_start|>{{ message['role'] }}\n{{ message['content'] }}<|im_end|>\n{% endfor %}"
        check(LocalAI.chatTemplateChoice(modelTemplate: chatml) == .init(template: chatml, prefix: ""), "other templates stay as stored")
    }

    static func providerList() {
        let order = AppSettings.defaultAIProviderOrder
        check(order.last == "local-ai", "Local AI is last")
        check(Array(order.dropLast()) == ["bing-translate", "google-translate", "gemini", "chatgpt", "claude", "openrouter", "groq",
                                          "perplexity", "pollinations", "paxsenix", "deepl"], "existing order unchanged")
        let saved = ["deepl", "gemini", "google-translate"]
        let normalized = AppSettings.normalizedAIProviderOrder(saved)
        check(Array(normalized.prefix(3)) == saved && normalized.last == "local-ai", "saved order kept, Local AI appended")
        let local = AppSettings.aiProviderById("local-ai")!
        check(local.label == "Local AI" && local.isLocal && local.translationOnly && !local.isKeyless && !local.defaultEnabled,
              "translation-only, disabled by default")
        check(AppSettings.providerById("local-ai").id == "gemini", "never the selected key provider used for research and notes")
        var snapshot = AppSettings.Snapshot()
        snapshot.aiProviderOrder = order
        snapshot.aiProviderEnabled = ["local-ai": true]
        snapshot.profiles = ["local-ai": ("key", "model")]
        check(snapshot.hasAnyTranslationProvider, "Local AI alone translates")
        check(!snapshot.hasReadyAIProvider && !snapshot.hasEnabledAIProvider && snapshot.readyAIProviderSnapshots.isEmpty,
              "never used for pronunciation")
        snapshot.aiProviderEnabled = ["local-ai": false]
        check(!snapshot.hasAnyTranslationProvider, "disabled Local AI does not translate")
    }

    static func translation() async throws {
        let recorder = Recorder()
        let service = LocalAIService(directory: try directory([.light]), loader: makeLoader(recorder))
        let lines = ["君の声", "", "[Instrumental]", "夜明け / まで", "君の声"]
        let result = try await service.translate(lines: lines, targetLanguage: "ko", configuration: light,
                                                 priority: .interactive, messages: messages) { index, text in recorder.line(index, text) }
        check(result == ["KO:君の声", "", "[Instrumental]", "KO:夜明け / KO:まで", "KO:君の声"], "lyrics translated: \(result)")
        check(recorder.allPrompts.count == 1, "one block covers every unique part")
        check(recorder.allPrompts[0].contains("into Korean.") && recorder.allPrompts[0].contains(blockMarker), "block prompt")
        check(source(recorder.allPrompts[0]).components(separatedBy: "\n") == ["君の声", "夜明け", "まで"], "unique parts")
        check(recorder.allBudgets == [LocalAI.outputBudget(for: "君の声\n夜明け\nまで")], "token budget")
        check(recorder.reported.keys.sorted() == [0, 1, 2, 3, 4] && recorder.reported[3] == "KO:夜明け / KO:まで", "lines reported as they finish")
        check(recorder.allLoads == ["Hy-MT2-1.8B-Q4_K_M.gguf:auto"], "the selected tier loads once")
        let ready = await service.currentState()
        check(ready.phase(for: .light) == .ready && ready.device == "GPU", "Ready · GPU")

        let fallback = Recorder()
        let lineService = LocalAIService(directory: try directory([.light]), loader: makeLoader(fallback) { prompt in
            prompt.contains(blockMarker) ? LocalAI.Completion(text: "merged line only", stoppedAtLimit: false)
                : LocalAI.Completion(text: "EN:" + source(prompt), stoppedAtLimit: false)
        })
        let english = try await lineService.translate(lines: ["一行目", "二行目", "三行目"], targetLanguage: "en", configuration: light,
                                                      priority: .interactive, messages: messages)
        check(english == ["EN:一行目", "EN:二行目", "EN:三行目"], "a block that lost a line is translated line by line")
        check(fallback.allPrompts.filter { $0.contains(blockMarker) }.count == 1 && fallback.allPrompts.filter { !$0.contains(blockMarker) }.count == 3,
              "one block prompt, then three line prompts")

        let limited = Recorder()
        let limitService = LocalAIService(directory: try directory([.light]), loader: makeLoader(limited) { prompt in
            var reply = try koreanReply(prompt)
            reply.stoppedAtLimit = prompt.contains(blockMarker)
            return reply
        })
        _ = try await limitService.translate(lines: ["一", "二"], targetLanguage: "ko", configuration: light, priority: .interactive, messages: messages)
        check(limited.allPrompts.count == 3, "a block cut by the token limit is translated line by line")

        let collapse = LocalAIService(directory: try directory([.light]), loader: makeLoader(Recorder()) { _ in
            LocalAI.Completion(text: "첫째\n\n 둘째", stoppedAtLimit: false)
        })
        let collapsed = try await collapse.translate(lines: ["一"], targetLanguage: "ko", configuration: light, priority: .interactive, messages: messages)
        check(collapsed == ["첫째 둘째"], "a single reply keeps one line")
        let empty = LocalAIService(directory: try directory([.light]), loader: makeLoader(Recorder()) { _ in
            LocalAI.Completion(text: " \n ", stoppedAtLimit: false)
        })
        await expect(.emptyReply, "empty reply") {
            try await empty.translate(lines: ["一"], targetLanguage: "ko", configuration: light, priority: .interactive, messages: messages)
        }

        let test = try await service.testTranslation(targetLanguage: "ko", configuration: light, messages: messages)
        check(test.sample == "今夜はまだ始まったばかり" && test.line == "KO:今夜はまだ始まったばかり" && test.seconds >= 0, "test translation")

        // Lyrics on screen run before prefetching for upcoming songs.
        let order = Recorder()
        let hold = Hold()
        let busy = LocalAIService(directory: try directory([.light]), loader: makeLoader(order, hold: hold))
        let prefetch = Task {
            try await busy.translate(lines: (0..<24).map { "bg\($0)" }, targetLanguage: "ko", configuration: light,
                                     priority: .background, messages: messages)
        }
        await hold.waitStarted()
        let onScreen = Task {
            try await busy.translate(lines: ["fg0", "fg1"], targetLanguage: "ko", configuration: light,
                                     priority: .interactive, messages: messages) { _, _ in }
        }
        try await waitUntil("on-screen block queued") { await busy.queuedBlockCounts.interactive == 1 }
        hold.release()
        _ = try await (prefetch.value, onScreen.value)
        let sequence = order.allPrompts.map { source($0).components(separatedBy: "\n")[0] }
        check(sequence == ["bg0", "fg0", "bg8", "bg16"], "on-screen lyrics first: \(sequence)")
    }

    static func failuresAndGates() async throws {
        // Not downloaded: fail at once, never download or load.
        FixtureHTTP.requests = []
        let missing = Recorder()
        let empty = LocalAIService(directory: try directory([]), loader: makeLoader(missing), sessionConfiguration: fixtureSession())
        await expect(.notReady("NOT READY"), "not downloaded") {
            try await empty.translate(lines: ["君の声"], targetLanguage: "ko", configuration: light, priority: .interactive, messages: messages)
        }
        check(missing.allLoads.isEmpty && missing.allPrompts.isEmpty && FixtureHTTP.requests.isEmpty, "no load, no download")
        let state = await empty.currentState()
        check(state.downloadingTier == nil && state.phase(for: .light) == .missing, "still not downloaded")

        // Another tier is not a substitute.
        let lightOnly = LocalAIService(directory: try directory([.light]), loader: makeLoader(missing))
        await expect(.notReady("NOT READY"), "selected tier missing") {
            try await lightOnly.translate(lines: ["君の声"], targetLanguage: "ko", configuration: .init(tier: .high),
                                          priority: .interactive, messages: messages)
        }

        // Unsupported target language: fail so the next provider translates.
        let recorder = Recorder()
        let service = LocalAIService(directory: try directory([.light]), loader: makeLoader(recorder))
        await expect(.unsupportedLanguage("cannot translate into Swedish"), "unsupported language") {
            try await service.translate(lines: ["君の声"], targetLanguage: "sv", configuration: light, priority: .interactive, messages: messages)
        }
        check(recorder.allPrompts.isEmpty && recorder.allLoads.isEmpty, "nothing ran for an unsupported language")
        for language in ["zh-TW", "zh-CN", "pt", "ja"] {
            let lines = try await service.translate(lines: ["Hello"], targetLanguage: language, configuration: light,
                                                    priority: .interactive, messages: messages)
            check(lines.count == 1, "translated into \(language)")
        }
        check(recorder.allPrompts[0].contains("into Traditional Chinese.") && recorder.allPrompts[1].contains("into Chinese."), "Chinese variants")

        // No engine in this build (iOS Simulator).
        let unavailable = LocalAIService(directory: try directory([.light]), loader: nil)
        await expect(.unavailable, "no engine") {
            try await unavailable.translate(lines: ["君の声"], targetLanguage: "ko", configuration: light, priority: .interactive, messages: messages)
        }

        // A native failure releases the engine; the next request loads it again.
        let failing = Recorder()
        let failOnce = FailOnce()
        let crashy = LocalAIService(directory: try directory([.light]), loader: makeLoader(failing) { prompt in
            if failOnce.take() { throw LocalAIError.engine("boom") }
            return try koreanReply(prompt)
        })
        await expect(.engine("boom"), "native failure") {
            try await crashy.translate(lines: ["一"], targetLanguage: "ko", configuration: light, priority: .interactive, messages: messages)
        }
        let releasedAfterFailure = !(await crashy.isEngineLoaded)
        check(releasedAfterFailure, "released after a native failure")
        let recovered = try await crashy.translate(lines: ["一"], targetLanguage: "ko", configuration: light, priority: .interactive, messages: messages)
        check(recovered == ["KO:一"], "loads again afterwards")
        check(failing.allLoads.count == 2, "two loads")

        // No GPU work in the background; CPU only still runs.
        let gated = Recorder()
        let gpu = LocalAIService(directory: try directory([.light]), loader: makeLoader(gated))
        gpu.setAppActive(false)
        await expect(.background, "GPU load in the background") {
            try await gpu.translate(lines: ["一"], targetLanguage: "ko", configuration: light, priority: .background, messages: messages)
        }
        check(gated.allLoads.isEmpty, "not loaded in the background")
        let cpu = LocalAI.Configuration(tier: .light, processor: .cpu, idleMinutes: 0)
        let cpuLines = try await gpu.translate(lines: ["一"], targetLanguage: "ko", configuration: cpu, priority: .background, messages: messages)
        check(cpuLines == ["KO:一"], "CPU only runs in the background")
        gpu.setAppActive(true)
        _ = try await gpu.translate(lines: ["二"], targetLanguage: "ko", configuration: light, priority: .interactive, messages: messages)
        check(gated.allLoads == ["Hy-MT2-1.8B-Q4_K_M.gguf:cpu", "Hy-MT2-1.8B-Q4_K_M.gguf:auto"], "processor change reloads")
        gpu.setAppActive(false)
        await expect(.background, "loaded GPU engine in the background") {
            try await gpu.translate(lines: ["三"], targetLanguage: "ko", configuration: light, priority: .background, messages: messages)
        }
        let keptLoaded = await gpu.isEngineLoaded
        check(keptLoaded, "kept for the return to the foreground")
        gpu.setAppActive(true)

        // Free memory, tier changes and deleting a tier.
        let files = try directory([.light, .high])
        let manager = LocalAIService(directory: files, loader: makeLoader(Recorder()))
        await manager.refresh()
        var current = await manager.currentState()
        check(current.downloadedTiers == [.light, .high] && current.phase(for: .medium) == .missing, "downloaded marks")
        _ = try await manager.translate(lines: ["一"], targetLanguage: "ko", configuration: light, priority: .interactive, messages: messages)
        await manager.releaseEngine()
        current = await manager.currentState()
        let freed = !(await manager.isEngineLoaded)
        check(freed && current.phase(for: .light) == .downloaded, "Free memory returns to Downloaded")
        _ = try await manager.translate(lines: ["一"], targetLanguage: "ko", configuration: light, priority: .interactive, messages: messages)
        await manager.configurationChanged(.init(tier: .high))
        let releasedForTier = !(await manager.isEngineLoaded)
        check(releasedForTier, "another tier releases the loaded model")
        try await manager.delete(.light)
        current = await manager.currentState()
        check(!FileManager.default.fileExists(atPath: files.appendingPathComponent(LocalAI.Tier.light.fileName).path)
              && current.downloadedTiers == [.high], "Delete model removes the selected tier only")
        await expect(.notReady("NOT READY"), "deleted tier") {
            try await manager.translate(lines: ["一"], targetLanguage: "ko", configuration: light, priority: .interactive, messages: messages)
        }
    }

    static func idleAndMemory() async throws {
        let clock = IdleClock()
        let recorder = Recorder()
        let service = LocalAIService(directory: try directory([.light]), loader: makeLoader(recorder), sleeper: { try await clock.sleep($0) })
        _ = try await service.translate(lines: ["君の声"], targetLanguage: "ko", configuration: light, priority: .interactive, messages: messages)
        try await waitUntil("idle timer") { clock.requested == [600] }
        let loadedBeforeIdle = await service.isEngineLoaded
        check(loadedBeforeIdle, "loaded until the idle time")
        clock.fire()
        try await waitUntil("idle release") { !(await service.isEngineLoaded) }
        _ = try await service.translate(lines: ["夜明け"], targetLanguage: "ko", configuration: light, priority: .interactive, messages: messages)
        check(recorder.allLoads.count == 2, "reloaded on the next request")
        try await waitUntil("idle timer again") { clock.requested.count == 2 }
        await service.setIdleMinutes(60)
        try await waitUntil("one hour") { clock.requested.last == 3600 }

        let neverClock = IdleClock()
        let never = LocalAIService(directory: try directory([.light]), loader: makeLoader(Recorder()), sleeper: { try await neverClock.sleep($0) })
        _ = try await never.translate(lines: ["君の声"], targetLanguage: "ko", configuration: .init(tier: .light, processor: .auto, idleMinutes: 0),
                                      priority: .interactive, messages: messages)
        try await Task.sleep(nanoseconds: 50_000_000)
        let neverLoaded = await never.isEngineLoaded
        check(neverClock.requested.isEmpty && neverLoaded, "Never keeps the model")

        // Memory warning: the running block stops, queued work fails and the model is released.
        let hold = Hold()
        let pressured = LocalAIService(directory: try directory([.light]), loader: makeLoader(Recorder(), hold: hold))
        let running = Task {
            try await pressured.translate(lines: ["a1", "a2"], targetLanguage: "ko", configuration: light, priority: .interactive, messages: messages)
        }
        await hold.waitStarted()
        let queued = Task {
            try await pressured.translate(lines: ["b1"], targetLanguage: "ko", configuration: light, priority: .background, messages: messages)
        }
        try await waitUntil("prefetch queued") { await pressured.queuedBlockCounts.background == 1 }
        pressured.handleMemoryWarning()
        try await waitUntil("queued work failed") { await pressured.queuedBlockCounts.background == 0 }
        hold.release()
        await expect(.memoryPressure, "running block") { try await running.value }
        await expect(.memoryPressure, "queued block") { try await queued.value }
        let releasedForMemory = !(await pressured.isEngineLoaded)
        check(releasedForMemory, "memory released")
    }

    static func downloads() async throws {
        let payload = Data("GGUF".utf8) + Data((0..<60).map { UInt8($0) })
        let folder = base.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("model.gguf")
        let partial = folder.appendingPathComponent("model.gguf.part")
        let url = URL(string: "https://fixture.test/model.gguf")!
        func reset() {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: partial)
            FixtureHTTP.requests = []
        }
        func download() async throws {
            try await LocalAIDownloader(configuration: fixtureSession())
                .download(from: url, to: destination, partialURL: partial, expectedBytes: 64) { _, _ in }
        }
        func contents(_ file: URL) -> Data? { try? Data(contentsOf: file) }

        reset()
        FixtureHTTP.handler = { _ in .init(status: 200, headers: ["Content-Length": "64"], body: payload) }
        try await download()
        check(contents(destination) == payload && !FileManager.default.fileExists(atPath: partial.path), "fresh download")
        check(FixtureHTTP.requests.first?.value(forHTTPHeaderField: "Range") == nil, "no range without a partial file")
        check((try? destination.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true, "excluded from backup")

        reset()
        try payload.prefix(20).write(to: partial)
        FixtureHTTP.handler = { request in
            guard request.value(forHTTPHeaderField: "Range") == "bytes=20-" else { return .init(status: 400) }
            return .init(status: 206, headers: ["Content-Range": "bytes 20-63/64", "Content-Length": "44"], body: Data(payload.suffix(from: 20)))
        }
        try await download()
        check(contents(destination) == payload, "resumed with an HTTP Range request")

        reset()
        try Data(repeating: 9, count: 20).write(to: partial)
        FixtureHTTP.handler = { _ in .init(status: 200, headers: ["Content-Length": "64"], body: payload) }
        try await download()
        check(contents(destination) == payload, "a server without ranges starts over")

        reset()
        try payload.prefix(20).write(to: partial)
        FixtureHTTP.handler = { request in
            request.value(forHTTPHeaderField: "Range") == nil
                ? .init(status: 200, headers: ["Content-Length": "64"], body: payload)
                : .init(status: 416)
        }
        try await download()
        check(FixtureHTTP.requests.count == 2 && contents(destination) == payload, "an unusable range restarts once")

        reset()
        FixtureHTTP.handler = { _ in .init(status: 200, headers: ["Content-Length": "65"], body: payload + Data([0])) }
        await expectDownload(.sizeMismatch(expected: 64, actual: 65), "wrong size") { try await download() }
        check(!FileManager.default.fileExists(atPath: destination.path) && !FileManager.default.fileExists(atPath: partial.path), "wrong size discarded")

        reset()
        FixtureHTTP.handler = { _ in .init(status: 200, headers: ["Content-Length": "60"], body: Data(payload.prefix(60))) }
        await expectDownload(.sizeMismatch(expected: 64, actual: 60), "short file") { try await download() }
        check(!FileManager.default.fileExists(atPath: destination.path), "a short file is never marked ready")

        reset()
        FixtureHTTP.handler = { _ in .init(status: 200, headers: ["Content-Length": "64"], body: Data(repeating: 1, count: 64)) }
        await expectDownload(.invalidFile, "not a model file") { try await download() }
        check(!FileManager.default.fileExists(atPath: destination.path) && !FileManager.default.fileExists(atPath: partial.path), "invalid file discarded")

        reset()
        try payload.prefix(20).write(to: partial)
        FixtureHTTP.handler = { _ in .init(status: 503) }
        await expectDownload(.httpStatus(503), "server error") { try await download() }
        check(contents(partial) == payload.prefix(20), "a server error keeps the partial file")

        reset()
        FixtureHTTP.handler = { _ in .init(status: 200, headers: ["Content-Length": "64"], body: Data(payload.prefix(30)), finish: false) }
        let stalled = Task { try await download() }
        try await waitUntil("partial data written") {
            ((try? FileManager.default.attributesOfItem(atPath: partial.path))?[.size] as? NSNumber)?.intValue == 30
        }
        stalled.cancel()
        do {
            try await stalled.value
            fatalError("cancel ignored")
        } catch is CancellationError {
            count += 1
        }
        check(contents(partial) == payload.prefix(30) && !FileManager.default.fileExists(atPath: destination.path),
              "Cancel keeps the partial file for resuming")

        // The service reports download failures and blocks translation while its tier downloads.
        FixtureHTTP.handler = { _ in .init(status: 404) }
        let service = LocalAIService(directory: base.appendingPathComponent("service-models", isDirectory: true),
                                     loader: makeLoader(Recorder()), sessionConfiguration: fixtureSession())
        await service.startDownload(.medium)
        await service.waitForDownload()
        var state = await service.currentState()
        check(state.phase(for: .medium) == .error && state.downloadingTier == nil && (state.error ?? "").contains("404"), "download error shown")
        await service.refresh()
        state = await service.currentState()
        check(state.phase(for: .medium) == .missing, "the error clears when the card reopens")

        FixtureHTTP.handler = { _ in .init(status: 200, headers: ["Content-Length": "\(LocalAI.Tier.medium.byteCount)"], body: Data("GGUF".utf8), finish: false) }
        await service.startDownload(.medium)
        state = await service.currentState()
        check(state.phase(for: .medium) == .downloading && state.totalBytes == LocalAI.Tier.medium.byteCount, "downloading")
        await expect(.downloadBusy("BUSY"), "translate while downloading") {
            try await service.translate(lines: ["一"], targetLanguage: "ko", configuration: .init(tier: .medium),
                                        priority: .interactive, messages: messages)
        }
        await service.cancelDownload()
        await service.waitForDownload()
        state = await service.currentState()
        check(state.downloadingTier == nil && state.phase(for: .medium) == .missing, "Cancel returns to Not downloaded")
    }

    static func expectDownload(_ expected: LocalAIDownloadError, _ message: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            fatalError("\(message): no error")
        } catch let error as LocalAIDownloadError {
            check(error == expected, "\(message): \(error)")
        } catch {
            fatalError("\(message): \(error)")
        }
    }
}

final class FailOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}
'''
checks = checks.replace("/*LANGUAGES*/", json.dumps(languages))
checks = checks.replace("/*HY_TEMPLATE*/", json.dumps(HY_MT2_TEMPLATE, ensure_ascii=False))

with tempfile.TemporaryDirectory(prefix="ivlyrics-local-ai-") as directory:
    directory = Path(directory)
    (directory / "Helpers.swift").write_text(helpers, encoding="utf-8")
    (directory / "Regression.swift").write_text(checks, encoding="utf-8")
    executable = directory / "regression"
    subprocess.run(["swiftc", str(directory / "Helpers.swift"), str(SRC / "LocalAI.swift"), str(SRC / "LocalAIService.swift"),
                    str(directory / "Regression.swift"), "-o", str(executable)], check=True)
    work = directory / "work"
    work.mkdir()
    subprocess.run([str(executable), str(work)], check=True, timeout=300)

