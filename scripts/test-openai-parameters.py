#!/usr/bin/env python3
"""Run production OpenAI-compatible request bodies and unsupported-parameter retries with fixture HTTP.

Compiles the production body builders, connection test, HTTP helpers and retry cache from
AiLyricsRepository.swift in a Foundation fixture: no credentials, network, Xcode or iPhone.
"""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
repository = (SRC / "AiLyricsRepository.swift").read_text()
utilities = (SRC / "Utilities.swift").read_text()


def section(source, start, end):
    first = source.index(start)
    return source[first:source.index(end, first + len(start))]


# A 400 must be thrown before any stream event reaches onDelta, so a retry cannot repeat text.
sse = section(repository, "    private func postJsonSse(", "    private func jsonObject(")
status_check = sse.index("guard (200..<300).contains(http.statusCode) else {")
assert status_check < sse.index("throw HTTPStatusError(", status_check) < sse.index("onDelta?("), \
    "postJsonSse must reject HTTP errors before any text reaches onDelta"

cache = re.search(r"^    private var openAiParameterAdjustmentCache: .*$", repository, re.M).group(0)
production = (cache + "\n" + "".join(section(repository, start, end) for start, end in [
    ("    func testConnection(", "    private func callProviderRaw("),
    ("    private func callProviderRawOnce(", "    private func withOpenAIConnections<T>("),
    ("    private func callOpenAiCompatible(", "    private func claudeWebSearchTool("),
    ("    private func applyOpenAiResearchOptions(", "    private func fetchPaxsenixWebResearch("),
    ("    private func openAiCompatibleBody(", "    private func buildTranslationPrompt("),
    ("    private func providerApiKeys(", "    private func parseJsonObjectResponse("),
    ("    private func extractProviderErrorMessage(", "    private func parseStringArray("),
    ("    private func stringValue(", "    private func intValue("),
    ("    private func extractOpenAiContent(", "    private func resolveResearchMaxTokens("),
    ("    private func trimRight(", "    private func urlPath("),
])).replace("private func", "func").replace("private var", "var")
fixtures = '''import Foundation
extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
enum IvLyricsUtilities {
    static func firstNonEmpty(_ values: String?...) -> String {
        values.lazy.map { ($0 ?? "").trimmed }.first { !$0.isEmpty } ?? ""
    }
}
enum DeepLTranslationProvider {
    static func invalid(_ message: String) -> Error {
        NSError(domain: "DeepL", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
enum AppSettings {
    struct Provider: Sendable { var id: String; var label: String }
    struct Snapshot: Sendable {
        var provider: Provider
        var apiKeys = "sk-fixture-secret", pollinationsAccessToken = ""
        var baseUrl: String, model: String
        var maxTokens = 4096, temperature = 0.3
    }
}
// STATUS
actor AiLyricsRepository {
// PRODUCTION
    func translateDeepL(texts: [String], language: String, settings: AppSettings.Snapshot,
                        preserveLyricsStructure: Bool) async throws -> [String] { fatalError("DeepL is outside this regression") }
    func callGemini(prompt: String, settings: AppSettings.Snapshot, apiKey: String) async throws -> String { fatalError("Gemini is outside this regression") }
    func callClaude(prompt: String, settings: AppSettings.Snapshot, apiKey: String) async throws -> String { fatalError("Claude is outside this regression") }
}
'''
fixtures = fixtures.replace("// STATUS", section(utilities, "struct HTTPStatusError:", "extension URLSession {"))
fixtures = fixtures.replace("// PRODUCTION", production)
checks = r'''
import Foundation
final class FixtureHTTP: URLProtocol {
    struct Reply {
        var status: Int
        var body: String
        var contentType = "application/json"
    }
    struct Sent {
        var path: String
        var authorization: String
        var body: [String: Any]
    }
    private static let lock = NSLock()
    private static var handler: ([String: Any]) -> Reply = { _ in Reply(status: 500, body: "{}") }
    private static var sent: [Sent] = []
    static func serve(_ reply: @escaping ([String: Any]) -> Reply) {
        lock.lock(); defer { lock.unlock() }
        handler = reply
        sent = []
    }
    static var requests: [Sent] { lock.lock(); defer { lock.unlock() }; return sent }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer[0..<count])
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        Self.lock.lock()
        Self.sent.append(Sent(path: request.url?.path ?? "", authorization: request.value(forHTTPHeaderField: "Authorization") ?? "", body: body))
        let reply = Self.handler(body)
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": reply.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [String] = []
    func append(_ delta: String) { lock.lock(); deltas.append(delta); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return deltas }
}
func providerError(_ message: String, param: String, code: String) -> FixtureHTTP.Reply {
    let error: [String: Any] = ["error": ["message": message, "type": "invalid_request_error", "param": param, "code": code]]
    return FixtureHTTP.Reply(status: 400, body: String(decoding: try! JSONSerialization.data(withJSONObject: error), as: UTF8.self))
}
let temperatureUnsupported = "Unsupported parameter: 'temperature' is not supported with this model."
let temperatureDefaultOnly = "Unsupported value: 'temperature' does not support 0.3 with this model. Only the default (1) value is supported."
let maxTokensUnsupported = "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead."
let rejectTemperature = providerError(temperatureUnsupported, param: "temperature", code: "unsupported_parameter")
let rejectTemperatureValue = providerError(temperatureDefaultOnly, param: "temperature", code: "unsupported_value")
let rejectMaxTokens = providerError(maxTokensUnsupported, param: "max_tokens", code: "unsupported_parameter")
let chatOK = FixtureHTTP.Reply(status: 200, body: #"{"choices":[{"message":{"role":"assistant","content":"OK"}}]}"#)
func sseEvent(_ object: [String: Any], name: String? = nil) -> String {
    (name.map { "event: \($0)\n" } ?? "") + "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n\n"
}
func chatStream(_ pieces: String...) -> FixtureHTTP.Reply {
    let role = sseEvent(["choices": [["index": 0, "delta": ["role": "assistant", "content": ""]] as [String: Any]]])
    let deltas = pieces.map { sseEvent(["choices": [["index": 0, "delta": ["content": $0]] as [String: Any]]]) }.joined()
    let finish = sseEvent(["choices": [["index": 0, "delta": [String: Any](), "finish_reason": "stop"] as [String: Any]]])
    return FixtureHTTP.Reply(status: 200, body: role + deltas + finish + "data: [DONE]\n\n", contentType: "text/event-stream")
}
func responsesStream(_ pieces: String...) -> FixtureHTTP.Reply {
    let text = pieces.joined()
    let event = { (type: String, fields: [String: Any]) in sseEvent(fields.merging(["type": type]) { $1 }, name: type) }
    let completed: [String: Any] = ["status": "completed", "output": [["content": [["type": "output_text", "text": text]]]]]
    let body = event("response.created", ["response": ["status": "in_progress"]])
        + pieces.map { event("response.output_text.delta", ["delta": $0]) }.joined()
        + event("response.output_text.done", ["text": text])
        + event("response.completed", ["response": completed])
    return FixtureHTTP.Reply(status: 200, body: body, contentType: "text/event-stream")
}
@main struct Regression {
    typealias Adjustments = AiLyricsRepository.OpenAiParameterAdjustments
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fatalError(message) }
    }
    static func snapshot(_ provider: String, _ model: String, base: String = "https://fixture.test/v1") -> AppSettings.Snapshot {
        AppSettings.Snapshot(provider: .init(id: provider, label: provider), baseUrl: base, model: model)
    }
    static func expectStatus(_ status: Int, _ message: String, _ request: () async throws -> Void) async {
        do {
            try await request()
            fatalError("\(message): request succeeded")
        } catch let error as HTTPStatusError {
            check(error.statusCode == status && error.message.hasPrefix("HTTP \(status)"), message)
        } catch {
            fatalError("\(message): \(error)")
        }
    }
    static func same(_ left: [String: Any], _ right: [String: Any]) -> Bool {
        NSDictionary(dictionary: left).isEqual(to: right)
    }
    static func main() async throws {
        URLProtocol.registerClass(FixtureHTTP.self)
        let key = "sk-fixture-secret"
        for model in ["gpt-6.1-sol", "gpt-5.5", "gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-5.1-codex", "gpt-5-2025-08-07",
                      "gpt-7", "gpt-10-preview", "GPT-5.5", " gpt-5.5 ", "openai/gpt-5.5", "openai/gpt-6.1-sol",
                      "o1", "o1-mini", "o3", "o3-mini", "o3-pro", "o4-mini", "o4-mini-deep-research", "openai/o3", "OpenAI/O4-Mini"] {
            check(AiLyricsRepository.isOpenAiReasoningModel(model), "\(model) is an OpenAI reasoning model")
        }
        for model in ["gpt-4.1", "gpt-4.1-mini", "gpt-4o", "gpt-4o-mini", "gpt-4", "gpt-3.5-turbo", "gpt-5-chat-latest",
                      "gpt-5.1-chat-latest", "openai/gpt-5-chat", "chatgpt-4o-latest", "gpt-oss-120b", "openai/gpt-oss-20b",
                      "gpt-35-turbo", "azure/gpt-35-turbo-16k", "GPT-35-Turbo-Instruct",
                      "llama-3.3-70b-versatile", "anthropic/claude-3.5-sonnet", "openai", "gemini-search", "groq/compound",
                      "sonar-pro", "omni-moderation-latest", "o", "gpt-", "", "future-reasoner"] {
            check(!AiLyricsRepository.isOpenAiReasoningModel(model), "\(model) keeps sampling parameters")
        }
        let classify = { AiLyricsRepository.openAiParameterAdjustments(forErrorMessage: "HTTP 400: " + $0) }
        check(classify(temperatureUnsupported) == .omitSampling, "Unsupported temperature parameter")
        check(classify(temperatureDefaultOnly) == .omitSampling, "Default-only temperature value")
        check(classify("Unsupported parameter: 'top_p' is not supported with this model.") == .omitSampling, "Unsupported top_p")
        check(classify(maxTokensUnsupported) == .maxCompletionTokens, "Unsupported max_tokens")
        check(classify("Invalid value for 'temperature': expected a number between 0 and 2.") == [], "Range errors are not unsupported parameters")
        check(classify("max_tokens is too large: 200000. This model supports at most 128000 completion tokens.") == [], "Token limits are not renames")
        check(AiLyricsRepository.openAiParameterAdjustments(forErrorMessage: "HTTP 400") == [], "Bare status has no adjustment")

        let repository = AiLyricsRepository()
        for model in ["gpt-6.1-sol", "gpt-5.5", "o3"] {
            let chat = await repository.openAiCompatibleBody(prompt: "fixture", settings: snapshot("chatgpt", model))
            check(chat["temperature"] == nil && chat["top_p"] == nil, "\(model) Chat Completions body omits sampling")
            check(chat["max_completion_tokens"] as? Int == 4096 && chat["max_tokens"] == nil, "\(model) keeps the ChatGPT token field")
            check(chat["model"] as? String == model && chat["messages"] != nil, "\(model) keeps model and messages")
            let responses = await repository.openAiResponsesBody(prompt: "fixture", settings: snapshot("chatgpt", model))
            check(responses["temperature"] == nil && responses["top_p"] == nil, "\(model) Responses body omits sampling")
            check(responses["max_output_tokens"] as? Int == 4096 && responses["max_tokens"] == nil
                  && responses["max_completion_tokens"] == nil, "\(model) Responses token field unchanged")
        }
        let legacy = await repository.openAiCompatibleBody(prompt: "fixture", settings: snapshot("chatgpt", "gpt-4.1"))
        check(legacy["temperature"] as? Double == 0.3 && legacy["max_completion_tokens"] as? Int == 4096, "gpt-4.1 keeps temperature")
        let legacyResponses = await repository.openAiResponsesBody(prompt: "fixture", settings: snapshot("chatgpt", "gpt-4.1"))
        check(legacyResponses["temperature"] as? Double == 0.3 && legacyResponses["tool_choice"] as? String == "required"
              && legacyResponses["store"] as? Bool == false, "gpt-4.1 Responses body unchanged")
        let routed = await repository.openAiCompatibleBody(prompt: "fixture", settings: snapshot("openrouter", "openai/gpt-5.5"))
        check(routed["temperature"] == nil && routed["max_tokens"] as? Int == 4096 && routed["max_completion_tokens"] == nil,
              "OpenRouter openai/gpt-5.5 omits temperature and keeps max_tokens")
        let routedOther = await repository.openAiCompatibleBody(prompt: "fixture", settings: snapshot("openrouter", "anthropic/claude-3.5-sonnet"))
        check(routedOther["temperature"] as? Double == 0.3 && routedOther["max_tokens"] as? Int == 4096, "Other routed models unchanged")
        for model in ["gpt-35-turbo", "azure/gpt-35-turbo-16k"] {
            let azureChat = await repository.openAiCompatibleBody(prompt: "fixture", settings: snapshot("chatgpt", model))
            let azureResponses = await repository.openAiResponsesBody(prompt: "fixture", settings: snapshot("chatgpt", model))
            check(azureChat["temperature"] as? Double == 0.3 && azureResponses["temperature"] as? Double == 0.3, "Azure \(model) keeps temperature")
        }

        // The reported failure: the connection test with GPT-5.5+ and o-series models.
        for model in ["gpt-6.1-sol", "gpt-5.5", "o3"] {
            FixtureHTTP.serve { $0["temperature"] != nil ? rejectTemperature : chatOK }
            try await repository.testConnection(settings: snapshot("chatgpt", model))
            let sent = FixtureHTTP.requests
            check(sent.count == 1 && sent[0].path == "/v1/chat/completions", "\(model) connection test needs one request")
            check(sent[0].body["temperature"] == nil && sent[0].body["max_completion_tokens"] as? Int == 4096
                  && sent[0].body["max_tokens"] == nil, "\(model) connection test body")
            check(sent[0].authorization == "Bearer \(key)", "Key stays in the Authorization header")
        }
        for model in ["gpt-4.1", "gpt-35-turbo", "azure/gpt-35-turbo-16k"] {
            FixtureHTTP.serve { $0["temperature"] as? Double == 0.3 ? chatOK : rejectTemperature }
            try await repository.testConnection(settings: snapshot("chatgpt", model))
            check(FixtureHTTP.requests.count == 1, "\(model) connection test still sends temperature")
        }

        // Streams for reasoning models need no retry either; other models keep temperature.
        FixtureHTTP.serve { $0["temperature"] != nil ? rejectTemperature : chatStream("stream", "ed") }
        var text = try await repository.callOpenAiCompatibleStream(prompt: "p", settings: snapshot("chatgpt", "gpt-5.5"), apiKey: key)
        var sent = FixtureHTTP.requests
        check(text == "streamed" && sent.count == 1 && sent[0].body["temperature"] == nil && sent[0].body["stream"] as? Bool == true
              && sent[0].body["max_completion_tokens"] as? Int == 4096 && sent[0].body["max_tokens"] == nil, "gpt-5.5 stream body")
        FixtureHTTP.serve { $0["temperature"] != nil ? rejectTemperature : chatStream("research", "ed") }
        text = try await repository.callOpenAiCompatibleStream(prompt: "p", settings: snapshot("openrouter", "openai/gpt-5.5"),
                                                               apiKey: key, webSearch: true, maxTokens: 16000)
        sent = FixtureHTTP.requests
        check(text == "researched" && sent.count == 1 && sent[0].body["temperature"] == nil && sent[0].body["max_tokens"] as? Int == 16000
              && sent[0].body["tool_choice"] as? String == "required", "OpenRouter web-search stream for openai/gpt-5.5")
        FixtureHTTP.serve { _ in chatStream("leg", "acy") }
        _ = try await repository.callOpenAiCompatibleStream(prompt: "p", settings: snapshot("chatgpt", "gpt-4.1"), apiKey: key)
        check(FixtureHTTP.requests.first?.body["temperature"] as? Double == 0.3, "gpt-4.1 stream keeps temperature")
        FixtureHTTP.serve { $0["temperature"] != nil ? rejectTemperatureValue : responsesStream("sear", "ched") }
        text = try await repository.callOpenAiResponsesStream(prompt: "p", settings: snapshot("chatgpt", "gpt-6.1-sol"), apiKey: key)
        sent = FixtureHTTP.requests
        check(text == "searched" && sent.count == 1 && sent[0].path == "/v1/responses" && sent[0].body["temperature"] == nil,
              "gpt-6.1-sol web search needs no retry")

        // Unknown model names: one retry without temperature, then the adjustment is reused.
        let future = snapshot("chatgpt", "future-reasoner")
        FixtureHTTP.serve { $0["temperature"] != nil ? rejectTemperature : chatOK }
        try await repository.testConnection(settings: future)
        sent = FixtureHTTP.requests
        check(sent.count == 2, "Unsupported temperature triggers exactly one retry")
        check(sent[0].body["temperature"] as? Double == 0.3 && sent[1].body["temperature"] == nil, "Retry drops temperature")
        check(same(sent[0].body.filter { $0.key != "temperature" }, sent[1].body), "Retry changes nothing else")
        var learned = await repository.openAiParameterAdjustmentCache["https://fixture.test/v1|future-reasoner"]
        check(learned == .omitSampling, "Adjustment cached by base URL and model")
        FixtureHTTP.serve { $0["temperature"] != nil ? rejectTemperature : chatOK }
        text = try await repository.callOpenAiCompatible(prompt: "p", settings: snapshot("chatgpt", "future-reasoner", base: "https://fixture.test/v1/"), apiKey: key)
        check(text == "OK" && FixtureHTTP.requests.count == 1 && FixtureHTTP.requests[0].body["temperature"] == nil,
              "Cached adjustment skips temperature immediately")
        let cachedSink = Sink()
        FixtureHTTP.serve { $0["temperature"] != nil ? rejectTemperature : chatStream("cach", "ed") }
        text = try await repository.callOpenAiCompatibleStream(prompt: "p", settings: future, apiKey: key, onDelta: { cachedSink.append($0) })
        check(text == "cached" && cachedSink.values == ["cach", "ed"] && FixtureHTTP.requests.count == 1, "Streams reuse the learned adjustment")
        FixtureHTTP.serve { _ in chatOK }
        _ = try await repository.callOpenAiCompatible(prompt: "p", settings: snapshot("chatgpt", "future-other"), apiKey: key)
        _ = try await repository.callOpenAiCompatible(prompt: "p", settings: snapshot("chatgpt", "future-reasoner", base: "https://mirror.fixture.test/v1"), apiKey: key)
        check(FixtureHTTP.requests.map { $0.body["temperature"] as? Double } == [0.3, 0.3], "Other models and base URLs keep temperature")

        // Stream: max_tokens moves to max_completion_tokens and the text reaches the sink once.
        let routedFuture = snapshot("openrouter", "vendor/future-max")
        let streamSink = Sink()
        FixtureHTTP.serve { $0["max_tokens"] != nil ? rejectMaxTokens : chatStream("stream", "ed") }
        text = try await repository.callOpenAiCompatibleStream(prompt: "p", settings: routedFuture, apiKey: key, onDelta: { streamSink.append($0) })
        sent = FixtureHTTP.requests
        check(text == "streamed" && streamSink.values == ["stream", "ed"], "Retried stream text is not duplicated")
        check(sent.count == 2 && sent[0].body["max_tokens"] as? Int == 4096 && sent[0].body["max_completion_tokens"] == nil, "First stream uses max_tokens")
        check(sent[1].body["max_tokens"] == nil && sent[1].body["max_completion_tokens"] as? Int == 4096, "Retry moves the token limit")
        check(same(sent[0].body.filter { $0.key != "max_tokens" }, sent[1].body.filter { $0.key != "max_completion_tokens" }), "Stream retry changes nothing else")
        learned = await repository.openAiParameterAdjustmentCache["https://fixture.test/v1|vendor/future-max"]
        check(learned == .maxCompletionTokens, "Token field adjustment cached")
        FixtureHTTP.serve { $0["max_tokens"] != nil ? rejectMaxTokens : chatOK }
        _ = try await repository.callOpenAiCompatible(prompt: "p", settings: routedFuture, apiKey: key)
        check(FixtureHTTP.requests.count == 1 && FixtureHTTP.requests[0].body["max_completion_tokens"] as? Int == 4096
              && FixtureHTTP.requests[0].body["max_tokens"] == nil, "Later requests send max_completion_tokens directly")

        // Responses stream: a default-only temperature is retried once without it.
        let searchSink = Sink()
        FixtureHTTP.serve { $0["temperature"] != nil ? rejectTemperatureValue : responsesStream("sear", "ched") }
        text = try await repository.callOpenAiResponsesStream(prompt: "p", settings: snapshot("chatgpt", "future-search"), apiKey: key,
                                                              onDelta: { searchSink.append($0) })
        sent = FixtureHTTP.requests
        check(text == "searched" && searchSink.values == ["sear", "ched"], "Retried Responses text is not duplicated")
        check(sent.count == 2 && sent.allSatisfy { $0.path == "/v1/responses" }, "Responses request retried once")
        check(sent[0].body["temperature"] as? Double == 0.3 && sent[1].body["temperature"] == nil, "Responses retry drops temperature")
        check(same(sent[0].body.filter { $0.key != "temperature" }, sent[1].body), "Responses retry changes nothing else")

        // Each adjustment kind is tried once, so two rejections need two retries.
        FixtureHTTP.serve { body in
            if body["temperature"] != nil { return rejectTemperature }
            return body["max_tokens"] != nil ? rejectMaxTokens : chatOK
        }
        text = try await repository.callOpenAiCompatible(prompt: "p", settings: snapshot("perplexity", "future-both"), apiKey: key)
        sent = FixtureHTTP.requests
        check(text == "OK" && sent.count == 3, "One retry per adjustment kind")
        check(sent[2].body["temperature"] == nil && sent[2].body["max_tokens"] == nil && sent[2].body["max_completion_tokens"] as? Int == 4096,
              "Both adjustments applied")
        learned = await repository.openAiParameterAdjustmentCache["https://fixture.test/v1|future-both"]
        check(learned == [.omitSampling, .maxCompletionTokens] as Adjustments, "Both adjustments cached")

        // Errors the fallback cannot fix are reported as before.
        FixtureHTTP.serve { _ in rejectTemperature }
        await expectStatus(400, "Repeated rejection is reported") {
            _ = try await repository.callOpenAiCompatible(prompt: "p", settings: snapshot("chatgpt", "future-stubborn"), apiKey: key)
        }
        check(FixtureHTTP.requests.count == 2, "An adjustment is never retried twice")
        FixtureHTTP.serve { _ in providerError("Invalid 'messages[0].content': string too long.", param: "messages", code: "string_above_max_length") }
        let failedSink = Sink()
        await expectStatus(400, "Unrelated 400 is reported") {
            _ = try await repository.callOpenAiCompatibleStream(prompt: "p", settings: snapshot("chatgpt", "gpt-4.1"), apiKey: key,
                                                                onDelta: { failedSink.append($0) })
        }
        check(FixtureHTTP.requests.count == 1 && failedSink.values.isEmpty, "Unrelated 400 is not retried and streams nothing")
        for status in [401, 403, 429] {
            FixtureHTTP.serve { _ in FixtureHTTP.Reply(status: status, body: #"{"error":{"message":"Unsupported parameter: 'temperature' is not supported with this model."}}"#) }
            await expectStatus(status, "HTTP \(status) is reported") {
                _ = try await repository.callOpenAiCompatible(prompt: "p", settings: snapshot("chatgpt", "future-\(status)"), apiKey: key)
            }
            learned = await repository.openAiParameterAdjustmentCache["https://fixture.test/v1|future-\(status)"]
            check(FixtureHTTP.requests.count == 1 && learned == nil, "HTTP \(status) is not retried or cached")
        }

        // Web-research helpers keep their fixed non-reasoning models and temperature.
        FixtureHTTP.serve { _ in chatOK }
        _ = try await repository.collectGroqWebResearch(title: "Song", artist: "Artist", settings: snapshot("groq", "gpt-5.5"), apiKey: key)
        _ = try await repository.collectPollinationsWebResearch(title: "Song", artist: "Artist",
                                                                settings: snapshot("pollinations", "gpt-5.5", base: "https://gen.fixture.test"), apiKey: key)
        sent = FixtureHTTP.requests
        check(sent.count == 2 && sent[0].body["model"] as? String == "groq/compound" && sent[0].body["temperature"] as? Double == 0.3
              && sent[0].body["max_tokens"] as? Int == 4096 && sent[0].body["compound_custom"] != nil, "Groq dossier body unchanged")
        check(sent[1].path == "/v1/chat/completions" && sent[1].body["model"] as? String == "gemini-search"
              && sent[1].body["temperature"] as? Double == 0.3, "Pollinations dossier body unchanged")

        // The in-memory cache stays bounded.
        for index in 0..<70 {
            FixtureHTTP.serve { $0["temperature"] != nil ? rejectTemperature : chatOK }
            _ = try await repository.callOpenAiCompatible(prompt: "p", settings: snapshot("chatgpt", "bounded-\(index)"), apiKey: key)
        }
        let cacheSize = await repository.openAiParameterAdjustmentCache.count
        check(cacheSize <= 64, "Adjustment cache is bounded")
        print("OpenAI parameter regression: \(checks) checks passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-openai-parameters-") as directory:
    directory = Path(directory)
    (directory / "Fixtures.swift").write_text(fixtures)
    (directory / "Regression.swift").write_text(checks)
    executable = directory / "regression"
    subprocess.run(["swiftc", str(directory / "Fixtures.swift"), str(directory / "Regression.swift"), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)

