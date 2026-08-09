import Foundation

actor KeylessTranslationProviders {
    static let bingId = "bing-translate"
    static let googleId = "google-translate"
    static let bingLabel = "Bing Translate"
    static let googleLabel = "Google Translate"

    struct TranslationResult: Sendable {
        let values: [String]
        let providerId: String
        let providerLabel: String
    }

    private struct BingConfiguration: Sendable {
        let ig: String
        let iid: String
        let key: Int64
        let token: String
        let expiresAt: Date
        let origin: String
        var sequence: Int
    }

    private enum TranslationError: LocalizedError {
        case noProvider
        case invalidResponse(String)
        case httpStatus(String, Int)

        var errorDescription: String? {
            switch self {
            case .noProvider:
                return "No keyless translation provider is enabled."
            case let .invalidResponse(provider):
                return "Invalid response from \(provider)."
            case let .httpStatus(provider, status):
                return "\(provider) request failed (\(status))."
            }
        }
    }

    private static let googleEndpoint = unpack(seed: 0x47, length: 51, words: [
        0x728b, 0x2045, 0xed59, 0xef8e, 0x6685, 0xcd63, 0x9527,
        0x49fd, 0x2fc1, 0xe34a, 0xa1f4, 0x5cb4, 0x0377, 0xd52e,
        0xd8f8, 0x57b4, 0xd52b, 0xc674, 0x10b0, 0x4ce0, 0x8632,
        0xd38c, 0x69d8, 0x6107, 0x8d63, 0xc100
    ])
    private static let bingOrigin = unpack(seed: 0x6d, length: 20, words: [
        0x58a1, 0x0a6f, 0xc773, 0xc5a4, 0x4faa,
        0xf109, 0xae08, 0x6cc4, 0x4ea6, 0xc162
    ])
    private static let bingTranslatorPath = unpack(seed: 0x31, length: 11, words: [
        0x43fd, 0x5022, 0x8666, 0xdab6, 0x10ee, 0xa800
    ])
    private static let bingTranslatePath = unpack(seed: 0x52, length: 27, words: [
        0x209e, 0x3552, 0xea18, 0xa6d8, 0x6696, 0xdc6e, 0xc061,
        0x54ef, 0x099f, 0xe344, 0xb2e5, 0x44a8, 0x4a23, 0x8f00
    ])
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"
    private static let protectedLineRegex = try? NSRegularExpression(
        pattern: #"^\s*(?:♪+|\[[^\]\r\n]+\]|\([^()\r\n]+\))\s*$"#
    )

    private let session: URLSession
    private var bingConfiguration: BingConfiguration?

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpShouldSetCookies = true
        session = URLSession(configuration: configuration)
    }

    func translate(
        texts: [String],
        targetLanguage: String,
        bingEnabled: Bool,
        googleEnabled: Bool
    ) async throws -> TranslationResult {
        var lastError: Error?
        if bingEnabled {
            do {
                let values = try await translateBatched(texts, targetLanguage: targetLanguage, maxCharacters: 2_800) { text, language in
                    try await self.translateBing(text, targetLanguage: language)
                }
                return TranslationResult(values: values, providerId: "bing-translate", providerLabel: "Bing Translate")
            } catch {
                lastError = error
            }
        }
        if googleEnabled {
            do {
                let values = try await translateBatched(texts, targetLanguage: targetLanguage, maxCharacters: 3_500) { text, language in
                    try await self.translateGoogle(text, targetLanguage: language)
                }
                return TranslationResult(values: values, providerId: "google-translate", providerLabel: "Google Translate")
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        throw TranslationError.noProvider
    }

    func translate(
        providerId: String,
        texts: [String],
        targetLanguage: String,
        preserveLyricsStructure: Bool = true
    ) async throws -> TranslationResult {
        switch providerId {
        case Self.bingId:
            let values = try await translateBatched(
                texts,
                targetLanguage: targetLanguage,
                maxCharacters: 2_800,
                preserveLyricsStructure: preserveLyricsStructure
            ) { text, language in
                try await self.translateBing(text, targetLanguage: language)
            }
            return TranslationResult(values: values, providerId: Self.bingId, providerLabel: Self.bingLabel)
        case Self.googleId:
            let values = try await translateBatched(
                texts,
                targetLanguage: targetLanguage,
                maxCharacters: 3_500,
                preserveLyricsStructure: preserveLyricsStructure
            ) { text, language in
                try await self.translateGoogle(text, targetLanguage: language)
            }
            return TranslationResult(values: values, providerId: Self.googleId, providerLabel: Self.googleLabel)
        default:
            throw TranslationError.noProvider
        }
    }

    private func translateBatched(
        _ source: [String],
        targetLanguage: String,
        maxCharacters: Int,
        preserveLyricsStructure: Bool = true,
        translator: (String, String) async throws -> String
    ) async throws -> [String] {
        var output = Array(repeating: "", count: source.count)
        var start = 0
        while start < source.count {
            var end = start
            var characters = 0
            while end < source.count, end - start < 40 {
                let next = source[end].count + (end > start ? 1 : 0)
                if end > start, characters + next > maxCharacters { break }
                characters += next
                end += 1
            }
            end = max(start + 1, end)
            let translated = try await translateAligned(
                Array(source[start..<end]),
                targetLanguage: targetLanguage,
                preserveLyricsStructure: preserveLyricsStructure,
                translator: translator
            )
            for (offset, value) in translated.enumerated() {
                output[start + offset] = value
            }
            start = end
        }
        return output
    }

    private func translateAligned(
        _ lines: [String],
        targetLanguage: String,
        preserveLyricsStructure: Bool,
        translator: (String, String) async throws -> String
    ) async throws -> [String] {
        guard !lines.isEmpty else { return [] }
        if lines.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return lines
        }
        let translatedText = try await translator(lines.joined(separator: "\n"), targetLanguage)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var split = translatedText.components(separatedBy: "\n")
        if split.count == lines.count + 1, split.last?.isEmpty == true {
            split.removeLast()
        }
        if split.count == lines.count {
            var output: [String] = []
            for index in lines.indices {
                let source = lines[index]
                let value = source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || (preserveLyricsStructure && Self.isProtectedLine(source))
                    ? source
                    : split[index]
                output.append(preserveLyricsStructure
                    ? try await repairVocalParts(source: source, translated: value, targetLanguage: targetLanguage, translator: translator)
                    : value)
            }
            return output
        }
        if lines.count == 1 { return [translatedText] }
        let middle = (lines.count + 1) / 2
        let first = try await translateAligned(
            Array(lines[..<middle]),
            targetLanguage: targetLanguage,
            preserveLyricsStructure: preserveLyricsStructure,
            translator: translator
        )
        let second = try await translateAligned(
            Array(lines[middle...]),
            targetLanguage: targetLanguage,
            preserveLyricsStructure: preserveLyricsStructure,
            translator: translator
        )
        return first + second
    }

    private func repairVocalParts(
        source: String,
        translated: String,
        targetLanguage: String,
        translator: (String, String) async throws -> String
    ) async throws -> String {
        let sourceParts = source.components(separatedBy: " / ")
        guard sourceParts.count > 1,
              translated.components(separatedBy: " / ").count != sourceParts.count else {
            return translated
        }
        var translatedParts: [String] = []
        for part in sourceParts {
            translatedParts.append(try await translator(part, targetLanguage))
        }
        return translatedParts.joined(separator: " / ")
    }

    private func translateGoogle(_ text: String, targetLanguage: String) async throws -> String {
        guard let url = URL(string: Self.googleEndpoint) else { throw TranslationError.invalidResponse("Google Translate") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form([
            ("client", "gtx"), ("sl", "auto"), ("tl", Self.normalizeGoogleLanguage(targetLanguage)),
            ("dt", "t"), ("q", text)
        ])
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, provider: "Google Translate")
        guard let root = try JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = root.first as? [Any] else {
            throw TranslationError.invalidResponse("Google Translate")
        }
        let value = segments.compactMap { ($0 as? [Any])?.first as? String }.joined()
        if value.isEmpty, !text.isEmpty { throw TranslationError.invalidResponse("Google Translate") }
        return value
    }

    private func translateBing(_ text: String, targetLanguage: String) async throws -> String {
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                var configuration = try await ensureBingConfiguration(forceRefresh: attempt > 0)
                configuration.sequence += 1
                bingConfiguration = configuration
                return try await postBing(configuration, text: text, targetLanguage: Self.normalizeBingLanguage(targetLanguage))
            } catch {
                lastError = error
                if case let TranslationError.httpStatus(_, status) = error, status == 401 || status == 403 {
                    continue
                }
                throw error
            }
        }
        throw lastError ?? TranslationError.invalidResponse("Bing Translate")
    }

    private func ensureBingConfiguration(forceRefresh: Bool) async throws -> BingConfiguration {
        if forceRefresh { bingConfiguration = nil }
        if let cached = bingConfiguration, cached.expiresAt > Date().addingTimeInterval(30) {
            return cached
        }
        guard let url = URL(string: Self.bingOrigin + Self.bingTranslatorPath) else {
            throw TranslationError.invalidResponse("Bing Translate")
        }
        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, provider: "Bing Translate")
        guard let html = String(data: data, encoding: .utf8),
              let ig = Self.firstMatch(in: html, pattern: #"IG:\s*\"([^\"]+)\""#),
              let iid = Self.firstMatch(in: html, pattern: #"data-iid=\"([^\"]+)\""#),
              let tupleText = Self.firstMatch(in: html, pattern: #"params_AbusePreventionHelper\s*=\s*(\[[^\]]+\])"#),
              let tupleData = tupleText.data(using: .utf8),
              let tuple = try JSONSerialization.jsonObject(with: tupleData) as? [Any],
              tuple.count >= 2,
              let key = (tuple[0] as? NSNumber)?.int64Value,
              let token = tuple[1] as? String,
              !token.isEmpty else {
            throw TranslationError.invalidResponse("Bing Translate")
        }
        let expiryMilliseconds = (tuple.count > 2 ? (tuple[2] as? NSNumber)?.doubleValue : nil) ?? 600_000
        let finalOrigin: String
        if let finalURL = response.url,
           finalURL.scheme?.lowercased() == "https",
           let host = finalURL.host,
           let canonicalHost = URL(string: Self.bingOrigin)?.host,
           host == canonicalHost || host.hasSuffix("." + canonicalHost) {
            finalOrigin = "https://" + (finalURL.host ?? canonicalHost)
        } else {
            finalOrigin = Self.bingOrigin
        }
        let configuration = BingConfiguration(
            ig: ig,
            iid: iid,
            key: key,
            token: token,
            expiresAt: Date().addingTimeInterval(max(60, expiryMilliseconds / 1_000)),
            origin: finalOrigin,
            sequence: 0
        )
        bingConfiguration = configuration
        return configuration
    }

    private func postBing(_ configuration: BingConfiguration, text: String, targetLanguage: String) async throws -> String {
        let endpoint = configuration.origin + Self.bingTranslatePath
            + "&IG=" + Self.percentEncode(configuration.ig)
            + "&IID=" + Self.percentEncode(configuration.iid)
            + "&SFX=\(configuration.sequence)&ref=TThis&edgepdftranslator=1"
        guard let url = URL(string: endpoint) else { throw TranslationError.invalidResponse("Bing Translate") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.origin, forHTTPHeaderField: "Origin")
        request.setValue(configuration.origin + Self.bingTranslatorPath, forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Self.form([
            ("fromLang", "auto-detect"), ("text", text), ("token", configuration.token),
            ("key", String(configuration.key)), ("to", targetLanguage),
            ("tryFetchingGenderDebiasedTranslations", "false")
        ])
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, provider: "Bing Translate")
        guard let root = try JSONSerialization.jsonObject(with: data) as? [Any],
              let first = root.first as? [String: Any],
              let translations = first["translations"] as? [[String: Any]],
              let value = translations.first?["text"] as? String,
              !value.isEmpty || text.isEmpty else {
            throw TranslationError.invalidResponse("Bing Translate")
        }
        return value
    }

    private static func validate(_ response: URLResponse, provider: String) throws {
        guard let http = response as? HTTPURLResponse else { throw TranslationError.invalidResponse(provider) }
        guard (200..<300).contains(http.statusCode) else { throw TranslationError.httpStatus(provider, http.statusCode) }
    }

    private static func form(_ values: [(String, String)]) -> Data {
        values.map { percentEncode($0.0) + "=" + percentEncode($0.1) }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private static func percentEncode(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func firstMatch(in source: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[range])
    }

    private static func isProtectedLine(_ value: String) -> Bool {
        guard let regex = protectedLineRegex else { return false }
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    private static func normalizeGoogleLanguage(_ language: String) -> String {
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-")
        return normalized.isEmpty ? "en" : normalized
    }

    private static func normalizeBingLanguage(_ language: String) -> String {
        let normalized = normalizeGoogleLanguage(language)
        if ["zh-cn", "zh-hans"].contains(normalized.lowercased()) { return "zh-Hans" }
        if ["zh-tw", "zh-hant"].contains(normalized.lowercased()) { return "zh-Hant" }
        if normalized.caseInsensitiveCompare("pt-PT") == .orderedSame { return "pt-PT" }
        return normalized.split(separator: "-").first.map { String($0).lowercased() } ?? "en"
    }

    private static func unpack(seed: Int, length: Int, words: [Int]) -> String {
        let scalars = (0..<length).compactMap { index -> UnicodeScalar? in
            let packed = words[index >> 1]
            let masked = (packed >> (index.isMultiple(of: 2) ? 8 : 0)) & 0xff
            let lane = (seed ^ ((index + 1) * 0x5d) ^ (index << 1)) & 0xff
            return UnicodeScalar(masked ^ lane)
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
