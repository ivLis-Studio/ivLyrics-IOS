import Foundation

enum AIProviderModels {
    struct Model: Identifiable, Hashable, Sendable {
        var id: String
        var name: String
        var displayName: String { name.isEmpty || name == id ? id : "\(name) · \(id)" }
    }

    struct Configuration: Hashable, Sendable {
        var provider: String
        var baseURL: String
        var apiKeys: String
        var pollinationsAccessToken: String

        var apiKey: String {
            if provider == "pollinations", !pollinationsAccessToken.trimmed.isEmpty {
                return pollinationsAccessToken.trimmed
            }
            if let data = apiKeys.data(using: .utf8),
               let values = try? JSONSerialization.jsonObject(with: data) as? [String] {
                return values.map(\.trimmed).first(where: { !$0.isEmpty }) ?? ""
            }
            return apiKeys.split { $0 == "\n" || $0 == "," }
                .map { String($0).trimmed }.first(where: { !$0.isEmpty }) ?? ""
        }

        var usesSonarCatalog: Bool {
            guard provider == "perplexity", let url = URL(string: baseURL) else { return false }
            return url.host?.lowercased() == "api.perplexity.ai" && (url.path.isEmpty || url.path == "/")
        }
    }

    struct Catalog: Sendable {
        var models: [Model]
        var builtIn = false
    }

    static func fetch(_ configuration: Configuration, session: URLSession = .shared) async throws -> Catalog {
        // Sonar's /chat/completions cannot use the Agent models listed by /v1/models.
        if configuration.usesSonarCatalog {
            return Catalog(models: ["sonar", "sonar-pro", "sonar-reasoning-pro", "sonar-deep-research"]
                .map { Model(id: $0, name: $0) }, builtIn: true)
        }
        var models: [String: Model] = [:]
        var cursors = Set<String>()
        var cursor = ""
        for _ in 0..<100 {
            try Task.checkCancellation()
            let request = try request(configuration, cursor: cursor)
            let (data, _) = try await session.ivLyricsData(for: request)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            for model in try parse(provider: configuration.provider, root: root) where models[model.id] == nil {
                models[model.id] = model
            }
            cursor = try nextCursor(provider: configuration.provider, root: root)
            if cursor.isEmpty {
                return Catalog(models: models.values.sorted {
                    $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
                })
            }
            guard cursors.insert(cursor).inserted else { throw CocoaError(.fileReadCorruptFile) }
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    static func request(_ configuration: Configuration, cursor: String = "") throws -> URLRequest {
        var base = configuration.baseURL.trimmed
        while base.hasSuffix("/") { base.removeLast() }
        if configuration.provider == "pollinations", !base.hasSuffix("/v1") { base += "/v1" }
        guard var components = URLComponents(string: base + "/models") else { throw URLError(.badURL) }
        if configuration.provider == "gemini" {
            components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
            if !cursor.isEmpty { components.queryItems?.append(URLQueryItem(name: "pageToken", value: cursor)) }
        } else if configuration.provider == "claude" {
            components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
            if !cursor.isEmpty { components.queryItems?.append(URLQueryItem(name: "after_id", value: cursor)) }
        }
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch configuration.provider {
        case "gemini":
            request.setValue(configuration.apiKey, forHTTPHeaderField: "x-goog-api-key")
        case "claude":
            request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        default:
            if !configuration.apiKey.isEmpty {
                request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        return request
    }

    static func parse(provider: String, root: [String: Any]) throws -> [Model] {
        let gemini = provider == "gemini"
        guard let rows = root[gemini ? "models" : "data"] as? [[String: Any]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var seen = Set<String>()
        return rows.compactMap { row in
            var id = string(row[gemini ? "name" : "id"])
            if gemini, id.hasPrefix("models/") { id = String(id.dropFirst(7)) }
            guard !id.isEmpty else { return nil }
            if gemini, !contains(row["supportedGenerationMethods"], "generateContent", ifAbsent: false) { return nil }
            guard isTextChatModel(row, id: id), seen.insert(id).inserted else { return nil }
            let name = [gemini ? "displayName" : "display_name", "name", "title"]
                .map { string(row[$0]) }.first(where: { !$0.isEmpty }) ?? id
            return Model(id: id, name: name)
        }
    }

    static func nextCursor(provider: String, root: [String: Any]) throws -> String {
        if provider == "gemini" { return string(root["nextPageToken"]) }
        if provider == "claude", root["has_more"] as? Bool == true {
            let cursor = string(root["last_id"])
            guard !cursor.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            return cursor
        }
        return ""
    }

    private static func isTextChatModel(_ row: [String: Any], id: String) -> Bool {
        let type = string(row["type"]).lowercased()
        if !type.isEmpty && type != "model" && type != "chat.completions" { return false }
        let endpoint = string(row["endpoint"])
        if !endpoint.isEmpty && !endpoint.hasSuffix("/chat/completions") { return false }
        let status = string(row["status"]).lowercased()
        if !status.isEmpty && status != "available" && status != "active" { return false }
        if row["active"] as? Bool == false { return false }
        let category = string(row["category"])
        if !category.isEmpty && category != "text" { return false }
        guard contains(row["supported_endpoints"], "/v1/chat/completions") else { return false }
        var input = row["input_modalities"]
        var output = row["output_modalities"]
        if let architecture = row["architecture"] as? [String: Any] {
            input = architecture["input_modalities"]
            output = architecture["output_modalities"]
        } else if let modalities = row["modalities"] as? [String: Any] {
            input = modalities["input"]
            output = modalities["output"]
        }
        guard contains(input, "text"), contains(output, "text") else { return false }
        // Older OpenAI-compatible catalogs do not expose capabilities.
        return output != nil || id.range(
            of: "embedding|whisper|tts|dall-e|realtime|moderation|transcribe|image|video|audio|music|midijourney",
            options: .caseInsensitive.union(.regularExpression)) == nil
    }

    private static func contains(_ value: Any?, _ expected: String, ifAbsent: Bool = true) -> Bool {
        guard let values = value as? [String] else { return ifAbsent }
        return values.contains { $0.caseInsensitiveCompare(expected) == .orderedSame }
    }

    private static func string(_ value: Any?) -> String { (value as? String)?.trimmed ?? "" }
}
