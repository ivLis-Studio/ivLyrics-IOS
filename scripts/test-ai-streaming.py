#!/usr/bin/env python3
"""Stream multi-event SSE responses through the production AI request code with fixture HTTP.

Compiles postJsonSse and every caller (OpenAI chat completions, OpenAI Responses web search, Anthropic
Messages, Gemini streamGenerateContent) from AiLyricsRepository.swift in a Foundation fixture and serves
provider-shaped streams through URLSession.shared in controlled chunks: no credentials, network or Xcode.
Also checks JSON null content in streamed and non-stream OpenAI-compatible replies. Each case is
reported separately, so a failing run lists every broken case.
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


cache = re.search(r"^    private var openAiParameterAdjustmentCache: .*$", repository, re.M).group(0)
production = (cache + "\n" + "".join(section(repository, start, end) for start, end in [
    ("    private func callGemini(", "    private func collectPollinationsWebResearch("),
    ("    private func openAiCompatibleBody(", "    private func buildTranslationPrompt("),
    ("    private func postJson(", "    private func parseJsonObjectResponse("),
    ("    private func extractProviderErrorMessage(", "    private func parseStringArray("),
    ("    private func stringValue(", "    private func intValue("),
    ("    private func extractOpenAiContent(", "    private func resolveResearchMaxTokens("),
    ("    private func trimRight(", "    nonisolated private func stripCodeFences("),
])).replace("private func", "func").replace("private var", "var")
fixtures = '''import Foundation
extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
enum IvLyricsUtilities {
// UTILITIES
}
enum AppSettings {
    struct Provider: Sendable { var id: String; var label: String }
    struct Snapshot: Sendable {
        var provider: Provider
        var baseUrl: String, model: String
        var maxTokens = 4096, temperature = 0.3
    }
}
// STATUS
actor AiLyricsRepository {
// PRODUCTION
}
'''
fixtures = fixtures.replace("// UTILITIES", section(utilities, "    static func urlEncode(", "    static func compactBody("))
fixtures = fixtures.replace("// STATUS", section(utilities, "struct HTTPStatusError:", "extension URLSession {"))
fixtures = fixtures.replace("// PRODUCTION", production)
checks = r'''
import Foundation
final class FixtureHTTP: URLProtocol {
    struct Reply {
        var status = 200
        var contentType = "text/event-stream"
        var chunks: [[UInt8]]
        /// Before each chunk after the first, wait until the client reports a delta: the parser has then
        /// read the previous chunk, so the split really falls between two deliveries.
        var gated = false
    }
    struct Sent {
        var url: URL
        var body: [String: Any]
    }
    private static let lock = NSLock()
    private static var reply = Reply(chunks: [])
    private static var sent: [Sent] = []
    private static var gate = DispatchSemaphore(value: 0)
    private static var missedGates = 0
    static func serve(_ next: Reply) {
        lock.lock(); defer { lock.unlock() }
        reply = next
        sent = []
        gate = DispatchSemaphore(value: 0)
        missedGates = 0
    }
    static func deltaReceived() {
        lock.lock(); let current = gate; lock.unlock()
        current.signal()
    }
    static var requests: [Sent] { lock.lock(); defer { lock.unlock() }; return sent }
    static var gateTimeouts: Int { lock.lock(); defer { lock.unlock() }; return missedGates }
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
        Self.lock.lock()
        Self.sent.append(Sent(url: request.url!, body: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]))
        let reply = Self.reply, gate = Self.gate
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": reply.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for (index, chunk) in reply.chunks.enumerated() {
            if index > 0, reply.gated, gate.wait(timeout: .now() + 3) == .timedOut {
                Self.lock.lock(); Self.missedGates += 1; Self.lock.unlock()
            }
            client?.urlProtocol(self, didLoad: Data(chunk))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [String] = []
    func append(_ delta: String) {
        lock.lock(); deltas.append(delta); lock.unlock()
        FixtureHTTP.deltaReceived()
    }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return deltas }
}
typealias JSON = [String: Any]
struct Event {
    var name: String? = nil
    var data: [String]
}
func json(_ object: JSON) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}
func encode(_ events: [Event], newline: String = "\n") -> String {
    events.map { event in
        let lines = (event.name.map { ["event: " + $0] } ?? []) + event.data.map { "data: " + $0 }
        return lines.joined(separator: newline) + newline + newline
    }.joined()
}
func chunks(_ text: String, size: Int) -> [[UInt8]] {
    let bytes = Array(text.utf8)
    return stride(from: 0, to: bytes.count, by: size).map { Array(bytes[$0..<min($0 + size, bytes.count)]) }
}
func split(_ text: String, at offsets: [Int]) -> [[UInt8]] {
    let bytes = Array(text.utf8)
    let bounds = [0] + offsets + [bytes.count]
    return zip(bounds, bounds.dropFirst()).map { Array(bytes[$0..<$1]) }
}
func offset(of needle: String, in text: String) -> Int {
    let bytes = Array(text.utf8), pattern = Array(needle.utf8)
    guard let index = (0...(bytes.count - pattern.count)).first(where: { Array(bytes[$0..<$0 + pattern.count]) == pattern }) else {
        fatalError("\(needle) not found")
    }
    return index
}
func chatChunk(_ delta: JSON, finish: String? = nil) -> Event {
    let choice: JSON = ["index": 0, "delta": delta, "finish_reason": finish.map { $0 as Any } ?? NSNull()]
    return Event(data: [json(["id": "chatcmpl-fixture", "object": "chat.completion.chunk", "choices": [choice]])])
}
func chatText(_ content: String) -> Event { chatChunk(["content": content]) }
let chatRole = chatChunk(["role": "assistant", "content": ""])
let chatFinish = chatChunk([:], finish: "stop")
let chatDone = Event(data: ["[DONE]"])
func typedEvent(_ type: String, _ fields: JSON = [:]) -> Event {
    var object = fields
    object["type"] = type
    return Event(name: type, data: [json(object)])
}
func claudeText(_ text: String) -> Event {
    typedEvent("content_block_delta", ["index": 0, "delta": ["type": "text_delta", "text": text]])
}
let claudeStart: [Event] = [
    typedEvent("message_start", ["message": ["id": "msg_fixture", "type": "message", "role": "assistant", "content": [JSON](),
                                             "model": "claude-sonnet-4-5", "usage": ["input_tokens": 12, "output_tokens": 1]] as JSON]),
    typedEvent("content_block_start", ["index": 0, "content_block": ["type": "text", "text": ""]]),
    typedEvent("ping"),
]
func geminiText(_ text: String, finish: Bool = false) -> Event {
    var candidate: JSON = ["content": ["parts": [["text": text]], "role": "model"] as JSON, "index": 0]
    if finish { candidate["finishReason"] = "STOP" }
    return Event(data: [json(["candidates": [candidate], "modelVersion": "gemini-2.5-flash"])])
}
@main struct Regression {
    struct Failure: Error, CustomStringConvertible { var description: String }
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !value() { throw Failure(description: message) }
    }
    static func expectStream(_ name: String, _ text: String, _ sink: Sink, _ pieces: [String]) throws {
        try expect(text == pieces.joined(), "\(name) text \(text.debugDescription)")
        try expect(sink.values == pieces, "\(name) deltas \(sink.values.debugDescription)")
    }
    static func snapshot(_ provider: String, _ model: String, base: String = "https://fixture.test/v1") -> AppSettings.Snapshot {
        AppSettings.Snapshot(provider: .init(id: provider, label: provider), baseUrl: base, model: model)
    }
    static func main() async {
        URLProtocol.registerClass(FixtureHTTP.self)
        let repository = AiLyricsRepository()
        let key = "fixture-key"
        let chat = snapshot("chatgpt", "gpt-4.1")
        let claude = snapshot("claude", "claude-sonnet-4-5")
        let gemini = snapshot("gemini", "gemini-2.5-flash", base: "https://fixture.test/v1beta")
        let rows = ["L0001\tHello", " world", "\nL0002\t노래", " 🎵"]
        func chatStream(_ newline: String, size: Int) async throws {
            let text = encode([chatRole, chatText(rows[0])], newline: newline) + ": OPENROUTER PROCESSING" + newline + newline
                + encode(rows.dropFirst().map(chatText) + [chatFinish, chatDone], newline: newline)
            FixtureHTTP.serve(.init(chunks: chunks(text, size: size)))
            let sink = Sink()
            let result = try await repository.callOpenAiCompatibleStream(prompt: "p", settings: chat, apiKey: key, onDelta: { sink.append($0) })
            try expectStream("OpenAI chat", result, sink, rows)
            let sent = FixtureHTTP.requests
            try expect(sent.count == 1 && sent[0].url.path == "/v1/chat/completions" && sent[0].body["stream"] as? Bool == true, "OpenAI chat request")
        }
        let streams: [(String, () async throws -> Void)] = [
            ("OpenAI chat completions: data events, keep-alive comment, [DONE]", { try await chatStream("\n", size: 7) }),
            ("OpenAI chat completions: CRLF line endings", { try await chatStream("\r\n", size: 3) }),
            ("OpenAI chat completions: lone CR line endings", { try await chatStream("\r", size: 4) }),
            ("OpenAI Responses web search: event: lines, done and completed", {
                let pieces = ["{\"summary\":", " \"A song", " about rain\",\n", "\"facts\": []}"]
                let full = pieces.joined()
                let completed: JSON = ["id": "resp_fixture", "status": "completed",
                                       "output": [["type": "message", "content": [["type": "output_text", "text": full]]] as JSON]]
                let events = [
                    typedEvent("response.created", ["response": ["id": "resp_fixture", "status": "in_progress"]]),
                    typedEvent("response.in_progress", ["response": ["id": "resp_fixture", "status": "in_progress"]]),
                    typedEvent("response.output_item.added", ["output_index": 0, "item": ["type": "web_search_call", "id": "ws_1"]]),
                    typedEvent("response.web_search_call.searching", ["output_index": 0, "item_id": "ws_1"]),
                    typedEvent("response.web_search_call.completed", ["output_index": 0, "item_id": "ws_1"]),
                    typedEvent("response.content_part.added", ["item_id": "msg_1", "output_index": 1, "content_index": 0,
                                                               "part": ["type": "output_text", "text": ""]]),
                ] + pieces.map { typedEvent("response.output_text.delta", ["item_id": "msg_1", "output_index": 1, "content_index": 0, "delta": $0]) } + [
                    typedEvent("response.output_text.done", ["item_id": "msg_1", "output_index": 1, "content_index": 0, "text": full]),
                    typedEvent("response.completed", ["response": completed]),
                ]
                FixtureHTTP.serve(.init(chunks: chunks(encode(events), size: 11)))
                let sink = Sink()
                let result = try await repository.callOpenAiResponsesStream(prompt: "p", settings: chat, apiKey: key, onDelta: { sink.append($0) })
                try expectStream("Responses", result, sink, pieces)
                try expect(FixtureHTTP.requests.first?.url.path == "/v1/responses", "Responses endpoint")
            }),
            ("Anthropic Messages: event: lines, ping, text deltas", {
                let pieces = Array(rows.prefix(3))
                let events = claudeStart + pieces.map(claudeText) + [
                    typedEvent("content_block_stop", ["index": 0]),
                    typedEvent("message_delta", ["delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 9]]),
                    typedEvent("message_stop"),
                ]
                FixtureHTTP.serve(.init(chunks: chunks(encode(events), size: 5)))
                let sink = Sink()
                let result = try await repository.callClaudeStream(prompt: "p", settings: claude, apiKey: key, onDelta: { sink.append($0) })
                try expectStream("Claude", result, sink, pieces)
                let sent = FixtureHTTP.requests
                try expect(sent.count == 1 && sent[0].url.path == "/v1/messages" && sent[0].body["stream"] as? Bool == true, "Claude request")
            }),
            ("Anthropic Messages: type from the event: line, reset after each event", {
                let delta = { (text: String) in json(["index": 0, "delta": ["type": "text_delta", "text": text]]) }
                let events = [Event(name: "content_block_delta", data: [delta("from event")]), Event(data: [delta(" ignored")]),
                              Event(name: "content_block_delta", data: [delta(" line")])]
                FixtureHTTP.serve(.init(chunks: chunks(encode(events), size: 9)))
                let sink = Sink()
                let result = try await repository.callClaudeStream(prompt: "p", settings: claude, apiKey: key, onDelta: { sink.append($0) })
                try expectStream("Claude event names", result, sink, ["from event", " line"])
            }),
            ("Anthropic Messages: error event after text", {
                let events = claudeStart + [claudeText("Hel"),
                                            typedEvent("error", ["error": ["type": "overloaded_error", "message": "Overloaded"]])]
                FixtureHTTP.serve(.init(chunks: chunks(encode(events), size: 8)))
                let sink = Sink()
                do {
                    _ = try await repository.callClaudeStream(prompt: "p", settings: claude, apiKey: key, onDelta: { sink.append($0) })
                } catch {
                    try expect(error.localizedDescription == "[Claude] Overloaded", "Claude error \(error.localizedDescription)")
                    try expect(sink.values == ["Hel"], "Claude error deltas \(sink.values)")
                    return
                }
                throw Failure(description: "Claude error event was ignored")
            }),
            ("Gemini streamGenerateContent: CRLF events, last one unterminated", {
                let pieces = ["L0001\tHello", " world\nL0002\t", "끝"]
                let text = encode(pieces.dropLast().map { geminiText($0) }, newline: "\r\n") + "data: " + geminiText(pieces[2], finish: true).data[0]
                FixtureHTTP.serve(.init(chunks: chunks(text, size: 13)))
                let sink = Sink()
                let result = try await repository.callGeminiStream(prompt: "p", settings: gemini, apiKey: key, onDelta: { sink.append($0) })
                try expectStream("Gemini", result, sink, pieces)
                let url = FixtureHTTP.requests.first?.url
                try expect(url?.path == "/v1beta/models/gemini-2.5-flash:streamGenerateContent" && url?.query == "alt=sse&key=fixture-key", "Gemini endpoint")
            }),
            ("CRLF split between deliveries inside a multi-line data event", {
                let first = encode([chatText("L0001\tA")], newline: "\r\n") + "data: {\"choices\":[{\"delta\":\r"
                let second = "\ndata: {\"content\":\" B\"},\"index\":0}]}\r\n\r\n" + encode([chatDone], newline: "\r\n")
                FixtureHTTP.serve(.init(chunks: [Array(first.utf8), Array(second.utf8)], gated: true))
                let sink = Sink()
                let result = try await repository.callOpenAiCompatibleStream(prompt: "p", settings: chat, apiKey: key, onDelta: { sink.append($0) })
                try expectStream("CRLF split", result, sink, ["L0001\tA", " B"])
                try expect(FixtureHTTP.gateTimeouts == 0, "CRLF split was not between deliveries")
            }),
            ("Multi-byte characters split between deliveries", {
                let pieces = ["가", "🎵", "é", "끝"]
                let text = encode(pieces.map(chatText) + [chatDone])
                let cuts = [offset(of: "🎵", in: text) + 2, offset(of: "é", in: text) + 1, offset(of: "끝", in: text) + 2]
                FixtureHTTP.serve(.init(chunks: split(text, at: cuts), gated: true))
                let sink = Sink()
                let result = try await repository.callOpenAiCompatibleStream(prompt: "p", settings: chat, apiKey: key, onDelta: { sink.append($0) })
                try expectStream("UTF-8 split", result, sink, pieces)
                try expect(FixtureHTTP.gateTimeouts == 0, "UTF-8 splits were not between deliveries")
            }),
            ("Stream without text still reports no text", {
                FixtureHTTP.serve(.init(chunks: chunks(encode([chatRole, chatFinish, chatDone]), size: 16)))
                do {
                    _ = try await repository.callOpenAiCompatibleStream(prompt: "p", settings: chat, apiKey: key)
                } catch {
                    let error = error as NSError
                    try expect(error.domain == "ivLyrics.AI" && error.code == -6, "No-text error \(error)")
                    return
                }
                throw Failure(description: "Empty stream returned text")
            }),
            ("OpenAI chat completions: null content in role and reasoning chunks", {
                // DeepSeek reasoner streams reasoning_content with "content": null before the answer.
                let pieces = ["L0001\tHello", " world"]
                let reasoning = { (text: String) in chatChunk(["content": NSNull(), "reasoning_content": text]) }
                let events = [chatChunk(["role": "assistant", "content": NSNull(), "reasoning_content": ""]), reasoning("Thinking"), reasoning(" more")]
                    + pieces.map { chatChunk(["content": $0, "reasoning_content": NSNull()]) } + [chatFinish, chatDone]
                FixtureHTTP.serve(.init(chunks: chunks(encode(events), size: 9)))
                let sink = Sink()
                let result = try await repository.callOpenAiCompatibleStream(prompt: "p", settings: chat, apiKey: key, onDelta: { sink.append($0) })
                try expectStream("Null content stream", result, sink, pieces)
            }),
        ]
        // The non-2xx path is unchanged: these pass before and after the parser change.
        let errors: [(String, () async throws -> Void)] = [
            ("HTTP 400 JSON error body over CRLF chunks", {
                let body = "{\r\n  \"type\": \"error\",\r\n  \"error\": {\r\n    \"type\": \"invalid_request_error\",\r\n"
                    + "    \"message\": \"max_tokens: 100000 > 64000, which is the maximum allowed\"\r\n  }\r\n}\r\n"
                FixtureHTTP.serve(.init(status: 400, contentType: "application/json", chunks: chunks(body, size: 6)))
                let sink = Sink()
                do {
                    _ = try await repository.callClaudeStream(prompt: "p", settings: claude, apiKey: key, onDelta: { sink.append($0) })
                } catch let error as HTTPStatusError {
                    try expect(error.statusCode == 400 && error.message == "HTTP 400: max_tokens: 100000 > 64000, which is the maximum allowed",
                               "400 message \(error.message)")
                    try expect(sink.values.isEmpty, "400 body reached onDelta")
                    return
                }
                throw Failure(description: "HTTP 400 succeeded")
            }),
            ("HTTP 500 with an SSE-shaped body", {
                FixtureHTTP.serve(.init(status: 500, chunks: chunks(encode([geminiText("leak"), geminiText("ed")]), size: 10)))
                let sink = Sink()
                do {
                    _ = try await repository.callGeminiStream(prompt: "p", settings: gemini, apiKey: key, onDelta: { sink.append($0) })
                } catch let error as HTTPStatusError {
                    try expect(error.statusCode == 500 && error.message == "HTTP 500", "500 message \(error.message)")
                    try expect(sink.values.isEmpty, "500 body reached onDelta")
                    return
                }
                throw Failure(description: "HTTP 500 succeeded")
            }),
            ("HTTP 429 from an OpenAI-compatible stream", {
                FixtureHTTP.serve(.init(status: 429, contentType: "application/json",
                                        chunks: chunks(#"{"error":{"message":"Rate limit reached","type":"requests"}}"#, size: 7)))
                do {
                    _ = try await repository.callOpenAiCompatibleStream(prompt: "p", settings: chat, apiKey: key)
                } catch let error as HTTPStatusError {
                    try expect(error.statusCode == 429 && error.message == "HTTP 429: Rate limit reached", "429 message \(error.message)")
                    try expect(FixtureHTTP.requests.count == 1, "429 retried")
                    return
                }
                throw Failure(description: "HTTP 429 succeeded")
            }),
        ]
        // Non-stream OpenAI-compatible replies go through the same content extraction.
        let replies: [(String, () async throws -> Void)] = [
            ("OpenAI chat completions: null message content is an empty response", {
                let message: JSON = ["role": "assistant", "content": NSNull(), "reasoning_content": "Thinking"]
                let reply: JSON = ["choices": [["index": 0, "message": message, "finish_reason": "stop"] as JSON]]
                FixtureHTTP.serve(.init(contentType: "application/json", chunks: [Array(json(reply).utf8)]))
                do {
                    let text = try await repository.callOpenAiCompatible(prompt: "p", settings: chat, apiKey: key)
                    throw Failure(description: "Null content returned \(text.debugDescription)")
                } catch let error as Failure {
                    throw error
                } catch {
                    let error = error as NSError
                    try expect(error.domain == "ivLyrics.AI" && error.code == -5 && error.localizedDescription == "[chatgpt] Empty response from API",
                               "Null content error \(error)")
                }
            }),
            ("OpenAI chat completions: null items in a content array", {
                let parts: [Any] = [NSNull(), ["type": "text", "text": "Hello"], ["type": "text", "text": NSNull()] as JSON, ["type": "text", "text": "!"]]
                let reply: JSON = ["choices": [["index": 0, "message": ["role": "assistant", "content": parts] as JSON] as JSON]]
                FixtureHTTP.serve(.init(contentType: "application/json", chunks: [Array(json(reply).utf8)]))
                let text = try await repository.callOpenAiCompatible(prompt: "p", settings: chat, apiKey: key)
                try expect(text == "Hello!", "Content array text \(text.debugDescription)")
            }),
        ]
        let cases = streams + errors + replies
        var failures: [String] = []
        for (name, run) in cases {
            do { try await run() } catch { failures.append("\(name): \(error)") }
        }
        guard failures.isEmpty else {
            for failure in failures { print("FAIL \(failure)") }
            print("AI streaming regression: \(failures.count) of \(cases.count) cases failed")
            exit(1)
        }
        print("AI streaming regression: \(checks) checks passed across \(cases.count) cases")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-ai-streaming-") as directory:
    directory = Path(directory)
    (directory / "Fixtures.swift").write_text(fixtures)
    (directory / "Regression.swift").write_text(checks)
    executable = directory / "regression"
    subprocess.run(["swiftc", str(directory / "Fixtures.swift"), str(directory / "Regression.swift"), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)

