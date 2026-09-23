#!/usr/bin/env python3
"""Run production model discovery with fixture HTTP responses, without Xcode or credentials."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
helpers = '''import Foundation
extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
enum IvLyricsUtilities { static func compactBody(_ body: String) -> String { body } }
'''
utilities = (SRC / "Utilities.swift").read_text()
helpers += utilities[utilities.index("struct HTTPStatusError:"):]
auth = (SRC / "PollinationsAuthClient.swift").read_text().replace("private func buildAuthorizeURL", "func buildAuthorizeURL")
checks = r'''
import Foundation
final class FixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, String))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.handler(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct Regression {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        count += 1
        if !value() { fatalError(message) }
    }
    static func parse(_ provider: String, _ json: String) throws -> [AIProviderModels.Model] {
        try AIProviderModels.parse(provider: provider, root: JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])
    }
    static func configuration(_ provider: String, _ base: String = "https://fixture.test/v1", _ keys: String = "fixture") -> AIProviderModels.Configuration {
        .init(provider: provider, baseURL: base, apiKeys: keys, pollinationsAccessToken: "")
    }
    static func main() async throws {
        for provider in ["chatgpt", "groq", "openrouter", "perplexity", "pollinations", "paxsenix"] {
            let models = try parse(provider, #"{"data":[{"id":"text-model"},{"id":"text-model"},{"id":"whisper-large"},{"id":"text-embedding-3"},{"id":""}]}"#)
            check(models.map(\.id) == ["text-model"], "\(provider) filtering and duplicate IDs")
        }
        let gemini = try parse("gemini", #"{"models":[{"name":"models/gemini-test","displayName":"Test Gemini","supportedGenerationMethods":["generateContent"]},{"name":"models/embedding","supportedGenerationMethods":["embedContent"]}]}"#)
        check(gemini.count == 1 && gemini[0].id == "gemini-test" && gemini[0].name == "Test Gemini", "Gemini capability and resource name")
        let claude = try parse("claude", #"{"data":[{"id":"claude-test","type":"model","display_name":"Test Claude"}]}"#)
        check(claude[0].name == "Test Claude", "Claude display name")
        let router = try parse("openrouter", #"{"data":[{"id":"image-only","architecture":{"output_modalities":["image"]}},{"id":"text-and-audio","architecture":{"input_modalities":["text"],"output_modalities":["text","audio"]}}]}"#)
        check(router.map(\.id) == ["text-and-audio"], "Capabilities override ID heuristic")
        let pollen = try parse("pollinations", #"{"data":[{"id":"anthropic/claude-test","title":"Claude Test","category":"text","supported_endpoints":["/v1/chat/completions"]},{"id":"openai/image","category":"image"},{"id":"responses-only","supported_endpoints":["/v1/responses"]}]}"#)
        check(pollen.count == 1 && pollen[0].name == "Claude Test", "Pollinations other providers and text endpoints")
        let pax = try parse("paxsenix", #"{"data":[{"id":"available","status":"Available","type":"chat.completions","endpoint":"/v1/chat/completions","modalities":{"input":["text"],"output":["text"]}},{"id":"down","status":"Unavailable"},{"id":"image","type":"images.generations"}]}"#)
        check(pax.map(\.id) == ["available"], "Paxsenix availability")
        let pollinationsRequest = try AIProviderModels.request(.init(provider: "pollinations", baseURL: "https://fixture.test/v1/", apiKeys: "manual", pollinationsAccessToken: "login-token"))
        check(pollinationsRequest.url!.absoluteString == "https://fixture.test/v1/models", "Do not duplicate v1")
        check(pollinationsRequest.value(forHTTPHeaderField: "Authorization") == "Bearer login-token", "Pollinations login token takes priority")
        let rotated = try AIProviderModels.request(configuration("chatgpt", "https://proxy.test/api/v1/", #"["", "first", "second"]"#))
        check(rotated.url!.absoluteString == "https://proxy.test/api/v1/models" && rotated.value(forHTTPHeaderField: "Authorization") == "Bearer first", "Custom base and key arrays")
        let geminiRequest = try AIProviderModels.request(configuration("gemini"), cursor: "a/b&c")
        check(geminiRequest.value(forHTTPHeaderField: "x-goog-api-key") == "fixture", "Gemini key header")
        check(URLComponents(url: geminiRequest.url!, resolvingAgainstBaseURL: false)!.queryItems!.contains(URLQueryItem(name: "pageToken", value: "a/b&c")), "Opaque page cursor encoding")
        let claudeRequest = try AIProviderModels.request(configuration("claude"))
        check(claudeRequest.value(forHTTPHeaderField: "x-api-key") == "fixture" && claudeRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "Claude headers")
        let sonar = try await AIProviderModels.fetch(configuration("perplexity", "https://api.perplexity.ai"))
        check(sonar.builtIn && sonar.models.contains(where: { $0.id == "sonar-pro" }), "Sonar fallback is explicit")
        check(!configuration("perplexity", "https://api.perplexity.ai/router/v1").usesSonarCatalog, "Router retains live catalog")
        do { _ = try parse("chatgpt", #"{"error":"denied"}"#); fatalError("Invalid response accepted") }
        catch { count += 1 }
        do { _ = try AIProviderModels.nextCursor(provider: "claude", root: ["has_more": true]); fatalError("Missing cursor accepted") }
        catch { count += 1 }
        let authURL = try PollinationsAuthClient().buildAuthorizeURL(userCode: "AB CD")
        let params = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!.queryItems!
        check(!params.contains(where: { $0.name == "models" }) && params.contains(URLQueryItem(name: "user_code", value: "AB CD")), "All-model authorization preserves device code")

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        var pages = 0
        FixtureProtocol.handler = { request in
            pages += 1
            check(request.value(forHTTPHeaderField: "x-goog-api-key") == "fixture", "Network key header")
            if pages == 1 {
                return (200, #"{"models":[{"name":"models/z","supportedGenerationMethods":["generateContent"]}],"nextPageToken":"next/page"}"#)
            }
            check(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.contains(URLQueryItem(name: "pageToken", value: "next/page")), "Network page cursor")
            return (200, #"{"models":[{"name":"models/a","supportedGenerationMethods":["generateContent"]},{"name":"models/z","supportedGenerationMethods":["generateContent"]}]}"#)
        }
        let catalog = try await AIProviderModels.fetch(configuration("gemini"), session: session)
        check(pages == 2 && catalog.models.map(\.id) == ["a", "z"], "Pages merged, deduplicated and sorted")
        FixtureProtocol.handler = { _ in (401, #"{"error":"denied"}"#) }
        do { _ = try await AIProviderModels.fetch(configuration("chatgpt"), session: session); fatalError("401 accepted") }
        catch let error as HTTPStatusError { check(error.statusCode == 401, "HTTP status propagated") }
        FixtureProtocol.handler = { _ in (200, #"{"data":[],"has_more":true,"last_id":"same"}"#) }
        do { _ = try await AIProviderModels.fetch(configuration("claude"), session: session); fatalError("Repeated cursor accepted") }
        catch { count += 1 }
        print("AI model regression: \(count) checks passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-ai-models-") as directory:
    directory = Path(directory)
    (directory / "Helpers.swift").write_text(helpers)
    (directory / "PollinationsAuthClient.swift").write_text(auth)
    (directory / "Regression.swift").write_text(checks)
    executable = directory / "regression"
    subprocess.run(["swiftc", str(directory / "Helpers.swift"), str(SRC / "AIProviderModels.swift"),
                    str(directory / "PollinationsAuthClient.swift"), str(directory / "Regression.swift"),
                    "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
