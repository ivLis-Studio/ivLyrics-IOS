import Foundation

/// Translation-only API. URLSession calls DeepL directly without a CORS proxy.
enum DeepLTranslationProvider {
    static func invalid(_ message: String) -> NSError {
        NSError(domain: "ivLyrics.DeepL", code: -1, userInfo: [NSLocalizedDescriptionKey: "DeepL: \(message)"])
    }

    static func targetLanguage(_ language: String) -> String {
        let code = language.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-").uppercased()
        return ["EN": "EN-US", "PT": "PT-PT", "ZH-CN": "ZH-HANS", "ZH-TW": "ZH-HANT"][code] ?? code
    }

    static func translate(texts: [String], targetLanguage: String, apiKey: String,
                          preserveLyricsStructure: Bool = true, session: URLSession = .shared) async throws -> [String] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw invalid("API key is required") }
        let host = key.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
        let endpoint = URL(string: "https://\(host)/v2/translate")!
        var rows: [[String]] = []
        var pending: [String] = []
        var positions: [(Int, Int)] = []
        for text in texts {
            let parts = preserveLyricsStructure ? text.components(separatedBy: " / ") : [text]
            let row = rows.count
            rows.append(parts)
            for (column, part) in parts.enumerated() {
                if part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                if preserveLyricsStructure && part.range(of: #"^\s*(?:♪+|\[[^\]\r\n]+\]|\([^()\r\n]+\))\s*$"#, options: .regularExpression) != nil { continue }
                positions.append((row, column))
                pending.append(part)
            }
        }
        var start = 0
        while start < pending.count {
            try Task.checkCancellation()
            let batchStart = start
            var batch: [String] = []
            var bytes = 0
            while start < pending.count && batch.count < 50 {
                let text = pending[start]
                let size = try JSONSerialization.data(withJSONObject: [text]).count
                guard size <= 120_000 else { throw invalid("Lyric line is too large") }
                if !batch.isEmpty && bytes + size > 120_000 { break }
                batch.append(text)
                bytes += size
                start += 1
            }
            var request = URLRequest(url: endpoint, timeoutInterval: 35)
            request.httpMethod = "POST"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.httpShouldHandleCookies = false
            request.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "text": batch, "target_lang": Self.targetLanguage(targetLanguage), "preserve_formatting": true
            ])
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw invalid("Invalid HTTP response") }
            guard (200..<300).contains(http.statusCode) else {
                throw HTTPStatusError(statusCode: http.statusCode, message: "DeepL HTTP \(http.statusCode)")
            }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let translations = root?["translations"] as? [[String: Any]], translations.count == batch.count else {
                throw invalid("Invalid translation response")
            }
            for (index, item) in translations.enumerated() {
                guard let value = item["text"] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw invalid("Invalid translation response")
                }
                let (row, column) = positions[batchStart + index]
                rows[row][column] = value.replacingOccurrences(of: #"\r\n?|\n"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return rows.map { $0.joined(separator: " / ") }
    }
}
