import Foundation

enum PaxsenixAIProvider {
    static let baseURL = "https://api.paxsenix.org/v1"
    static let dashboardURL = "https://api.paxsenix.org/dashboard"

    struct Model: Identifiable, Hashable, Sendable {
        var id: String
        var name: String

        var displayName: String {
            name.trimmed.isEmpty || name == id ? id : "\(name) · \(id)"
        }
    }

    static func fetchModels(apiKeys: String) async throws -> [Model] {
        guard let url = URL(string: baseURL + "/models") else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey = parseApiKeys(apiKeys).first {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, _) = try await URLSession.shared.ivLyricsData(for: request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [[String: Any]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var seen = Set<String>()
        return rows.compactMap { row -> Model? in
            let id = string(row["id"]).trimmed
            guard !id.isEmpty,
                  seen.insert(id).inserted,
                  string(row["type"]).caseInsensitiveCompare("chat.completions") == .orderedSame,
                  string(row["endpoint"]) == "/v1/chat/completions",
                  string(row["status"]).caseInsensitiveCompare("Available") == .orderedSame,
                  let modalities = row["modalities"] as? [String: Any],
                  containsText(modalities["input"]),
                  containsText(modalities["output"]) else { return nil }
            return Model(id: id, name: string(row["name"]).trimmed)
        }
        .sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private static func containsText(_ value: Any?) -> Bool {
        (value as? [String])?.contains { $0.caseInsensitiveCompare("text") == .orderedSame } == true
    }

    private static func parseApiKeys(_ raw: String) -> [String] {
        let value = raw.trimmed
        guard !value.isEmpty else { return [] }
        if value.hasPrefix("["),
           let data = value.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            return array.compactMap { item in
                if let item = item as? String { return item.trimmed }
                if let item = item as? NSNumber { return item.stringValue.trimmed }
                return nil
            }.filter { !$0.isEmpty }
        }
        return value
            .split { $0 == "\n" || $0 == "," }
            .map { String($0).trimmed }
            .filter { !$0.isEmpty }
    }

    private static func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }
}
