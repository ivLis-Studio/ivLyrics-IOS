import Foundation

/// Perplexity's Agent API. Sonar Chat Completions support ended on September 27, 2026: model ids
/// now carry a provider prefix (perplexity/sonar, openai/...), there is no sonar-pro, and the
/// model list is GET /v1/models.
/// https://docs.perplexity.ai/docs/agent-api/migrate-from-sonar/overview
enum PerplexityAgentAPI {
    static let providerID = "perplexity"
    /// The migration guide's successor for sonar and sonar-pro when the contract is a model id.
    static let defaultModel = "perplexity/sonar"

    /// A saved id without a provider prefix is a retired Sonar name and becomes the default.
    static func normalizeModel(_ model: String) -> String {
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.contains("/") ? id : defaultModel
    }

    static func normalizeModel(providerID: String, _ model: String) -> String {
        providerID == self.providerID ? normalizeModel(model) : model
    }

    static func agentEndpoint(_ baseURL: String) -> String {
        versionedBase(baseURL) + "/agent"
    }

    static func modelsEndpoint(_ baseURL: String) -> String {
        versionedBase(baseURL) + "/models"
    }

    private static func versionedBase(_ baseURL: String) -> String {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        return base.hasSuffix("/v1") ? base : base + "/v1"
    }

    /// The default model first, then Perplexity's own models, then the rest by id.
    static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        let rank = { (id: String) in id == defaultModel ? 0 : id.hasPrefix("perplexity/") ? 1 : 2 }
        if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
        return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }

    /// The Agent API rejects any field it does not know with a 400, so the body carries only
    /// mapped fields. It searches only when offered the web_search tool.
    static func requestBody(
        prompt: String,
        model: String,
        maxOutputTokens: Int,
        temperature: Double,
        stream: Bool,
        webSearch: Bool
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": normalizeModel(model),
            "input": prompt,
            "max_output_tokens": maxOutputTokens,
            "temperature": temperature,
            "store": false
        ]
        if webSearch { body["tools"] = [["type": "web_search"]] }
        if stream { body["stream"] = true }
        return body
    }

    /// Failed and cancelled runs arrive as HTTP 200, so the status decides.
    static func responseText(_ response: [String: Any]) throws -> String {
        let status = string(response["status"]).lowercased()
        if status.isEmpty, let failure = response["error"], !(failure is NSNull) {
            throw error(errorMessage(failure, fallback: "API response error"))
        }
        if status == "failed" || status == "cancelled" {
            throw error(errorMessage(response["error"], fallback: "Response \(status)"))
        }
        if status == "incomplete" {
            let reason = string((response["incomplete_details"] as? [String: Any])?["reason"])
            throw error("Response incomplete (\(reason.isEmpty ? "incomplete" : reason))")
        }
        guard status == "completed" else {
            throw error("Response rejected (\(status.isEmpty ? "missing_status" : status))")
        }
        var text = ""
        for item in response["output"] as? [[String: Any]] ?? [] where string(item["type"]) == "message" {
            for part in item["content"] as? [[String: Any]] ?? [] {
                switch string(part["type"]) {
                case "refusal":
                    throw error("Response refused: \(errorMessage(part["refusal"], fallback: "Request refused"))")
                case "output_text":
                    // Text keeps its whitespace: newlines separate lyric rows.
                    text += part["text"] as? String ?? ""
                default:
                    break
                }
            }
        }
        if text.isEmpty { text = response["output_text"] as? String ?? "" }
        return text
    }

    /// Grounded answers cite as [web:1][web:2]; nothing in ivLyrics resolves those markers.
    static func stripWebCitations(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[web:\d+\]"#, with: "", options: .regularExpression)
    }

    /// One stream: exactly one terminal event (completed, failed, incomplete, cancelled) or an error.
    final class StreamState {
        private(set) var completed = false
        private var receivedDelta = false

        /// The text an event adds. Failed, incomplete, cancelled, refusal and error events throw.
        func consume(eventName: String, data: String) throws -> String {
            let value = data.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value != "[DONE]",
                  let event = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else { return "" }
            let named = PerplexityAgentAPI.string(event["type"])
            let type = named.isEmpty ? eventName : named
            switch type {
            case "response.output_text.delta":
                let delta = event["delta"] as? String ?? ""
                if !delta.isEmpty { receivedDelta = true }
                return delta
            case "response.output_text.done":
                let text = event["text"] as? String ?? ""
                guard !receivedDelta, !text.isEmpty else { return "" }
                receivedDelta = true
                return text
            case "response.refusal.done":
                throw PerplexityAgentAPI.error(
                    "Response refused: \(PerplexityAgentAPI.errorMessage(event["refusal"], fallback: "Request refused"))"
                )
            case "response.completed":
                completed = true
                guard !receivedDelta, let response = event["response"] as? [String: Any] else { return "" }
                return try PerplexityAgentAPI.responseText(response)
            case "response.failed", "response.incomplete", "response.cancelled":
                let status = String(type.dropFirst("response.".count))
                var response = event["response"] as? [String: Any] ?? [:]
                if PerplexityAgentAPI.string(response["status"]).isEmpty { response["status"] = status }
                _ = try PerplexityAgentAPI.responseText(response)
                throw PerplexityAgentAPI.error("Response \(status)")
            case "error":
                throw PerplexityAgentAPI.error(
                    PerplexityAgentAPI.errorMessage(event["error"] ?? event["message"], fallback: "Stream error")
                )
            default:
                return ""
            }
        }
    }

    fileprivate static func error(_ message: String) -> NSError {
        NSError(domain: "ivLyrics.AI", code: -5, userInfo: [NSLocalizedDescriptionKey: "[Perplexity] \(message)"])
    }

    fileprivate static func string(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    fileprivate static func errorMessage(_ value: Any?, fallback: String) -> String {
        if let object = value as? [String: Any] {
            let message = string(object["message"])
            if !message.isEmpty { return message }
            let type = string(object["type"])
            return type.isEmpty ? fallback : type
        }
        let text = string(value)
        return text.isEmpty ? fallback : text
    }
}
