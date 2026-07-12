import CryptoKit
import Foundation

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func nfc() -> String {
        precomposedStringWithCanonicalMapping
    }

    func nfkc() -> String {
        precomposedStringWithCompatibilityMapping
    }

    func regexReplacing(_ pattern: String, with replacement: String) -> String {
        replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    func urlQueryEscaped() -> String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    }
}

extension Array where Element == String {
    func joinedLines() -> String {
        joined(separator: "\n")
    }
}

enum IvLyricsUtilities {
    private static let lowercaseHexDigits = Array("0123456789abcdef".utf8)
    private static let leadingLrcTimestampPattern = #"^\[\d+:\d+(?:[.,]\d+)?\]\s*"#
    private static let leadingLrcTimestampRegex = try? NSRegularExpression(
        pattern: leadingLrcTimestampPattern
    )

    static func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        var encoded = [UInt8](repeating: 0, count: SHA256.Digest.byteCount * 2)
        var offset = 0
        for byte in digest {
            encoded[offset] = lowercaseHexDigits[Int(byte >> 4)]
            encoded[offset + 1] = lowercaseHexDigits[Int(byte & 0x0f)]
            offset += 2
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    static func encodeParams(_ params: [String: String]) -> String {
        params.compactMap { key, value in
            let trimmed = value.trimmed
            guard !trimmed.isEmpty else { return nil }
            return "\(urlEncode(key))=\(urlEncode(trimmed))"
        }
        .joined(separator: "&")
    }

    static func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            let next = (value ?? "").trimmed
            if !next.isEmpty {
                return next
            }
        }
        return ""
    }

    static func compactBody(_ body: String) -> String {
        let compact = body.trimmed.regexReplacing(#"\s+"#, with: " ")
        return compact.count <= 300 ? compact : String(compact.prefix(300)) + "..."
    }

    static func normalizeComparable(_ value: String?) -> String {
        (value ?? "")
            .nfkc()
            .lowercased()
            .trimmed
            .regexReplacing("[\\u{2018}\\u{2019}]", with: "'")
            .regexReplacing("[\\u{201c}\\u{201d}]", with: "\"")
            .regexReplacing("[()\\[\\]{}]", with: "")
            .regexReplacing(#"\s+"#, with: " ")
    }

    static func sameSearchMetadata(_ left: String, _ right: String) -> Bool {
        let lhs = normalizeComparable(left)
        let rhs = normalizeComparable(right)
        return !lhs.isEmpty && lhs == rhs
    }

    static func titleScore(_ expected: String, _ candidate: String) -> Double {
        let left = normalizeComparable(expected)
        let right = normalizeComparable(candidate)
        if left.isEmpty || right.isEmpty { return 0 }
        if left == right { return 1 }
        if left.contains(right) || right.contains(left) { return 0.96 }
        return jaroWinkler(left, right)
    }

    static func albumScore(_ expected: String, _ candidate: String) -> Double {
        let left = normalizeComparable(expected)
        let right = normalizeComparable(candidate)
        if left.isEmpty || right.isEmpty || right == "null" { return 0 }
        if left == right { return 1 }
        if isAlbumExpansion(left, right) || isAlbumExpansion(right, left) { return 0.72 }
        let similarity = jaroWinkler(left, right)
        if similarity >= 0.92 { return 0.55 }
        if similarity >= 0.84 { return 0.25 }
        return 0
    }

    static func bestArtistScore(_ expectedArtists: String, _ candidateArtists: String) -> Double {
        let expected = splitArtists(expectedArtists)
        let candidates = splitArtists(candidateArtists)
        var best = 0.0
        for left in expected {
            for right in candidates {
                best = max(best, jaroWinkler(left, right))
            }
        }
        return best
    }

    static func durationScore(expectedDurationMs: Int64, candidateDurationSeconds: Double, tolerance: Double) -> Double {
        if expectedDurationMs <= 0 || candidateDurationSeconds <= 0 {
            return 0.5
        }
        let diff = abs(Double(expectedDurationMs) / 1000.0 - candidateDurationSeconds)
        return max(0, 1.0 - min(1.0, diff / tolerance))
    }

    static func codePointLength(_ value: String) -> Int {
        value.nfc().unicodeScalars.count
    }

    static func splitChars(_ value: String) -> [String] {
        value.nfc().unicodeScalars.map { String($0) }
    }

    static func lyricsFingerprint(_ text: String) -> String {
        var hash: UInt64 = 2_166_136_261
        let chars = splitChars(text)
        for character in chars {
            for scalar in character.unicodeScalars {
                hash ^= UInt64(scalar.value)
                hash = (hash * 16_777_619) & 0xffff_ffff
            }
        }
        return "lrclib-\(String(hash, radix: 36))-\(String(chars.count, radix: 36))"
    }

    static func comparableLyricsLines(_ text: String?, stripTimestamps: Bool, normalizeParentheticalLines: Bool = false) -> [String] {
        guard let text, !text.trimmed.isEmpty else { return [] }
        var lines: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var line = stripTimestamps ? stripLeadingLrcTimestamp(rawLine) : rawLine.trimmed
            line = line.nfc().trimmed
            if line.isEmpty || line.range(of: #"^\s*\[(?:ar|al|ti|au|length|by|offset|re|ve):[^\]]*\]\s*$"#, options: .regularExpression) != nil {
                continue
            }
            lines.append(line)
        }
        if normalizeParentheticalLines {
            return normalizeStandaloneParentheticalBlocks(lines).map { $0.nfc().trimmed }.filter { !$0.isEmpty }
        }
        return lines
    }

    static func stripLeadingLrcTimestamp(_ text: String) -> String {
        guard let regex = leadingLrcTimestampRegex else {
            return text.replacingOccurrences(
                of: leadingLrcTimestampPattern,
                with: "",
                options: .regularExpression
            )
        }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text),
            withTemplate: ""
        )
    }

    static func stripLrcTimestamps(_ text: String?) -> String {
        (text ?? "").replacingOccurrences(of: #"(?m)^\[\d+:\d+(?:[.,]\d+)?\]\s*"#, with: "", options: .regularExpression).trimmed
    }

    static func lineCharCounts(_ lines: [String]) -> [Int] {
        lines.map { codePointLength($0) }
    }

    static func joinLinesForFingerprint(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    static func stripStandaloneParentheticalLine(_ text: String) -> String {
        var value = text.nfc().trimmed
        while isStandaloneParentheticalLine(value) {
            let chars = splitChars(value)
            if chars.count <= 2 { return "" }
            value = chars[1..<(chars.count - 1)].joined().trimmed
        }
        return value
    }

    static func normalizeStandaloneParentheticalBlocks(_ lines: [String]) -> [String] {
        var normalized = lines.map { stripStandaloneParentheticalLine($0) }
        for index in normalized.indices {
            let trimmed = normalized[index].nfc().trimmed
            guard !trimmed.isEmpty else { continue }
            let chars = splitChars(trimmed)
            guard let first = chars.first else { continue }
            let close = parenthesisClose(first)
            guard !close.isEmpty, !trimmed.contains(close) else { continue }
            var closeIndex: Int?
            for candidate in normalized.indices where candidate > index {
                let candidateText = normalized[candidate].nfc().trimmed
                if !candidateText.isEmpty && candidateText.hasSuffix(close) {
                    closeIndex = candidate
                    break
                }
            }
            guard let closeIndex else { continue }
            normalized[index] = stripLeadingParenthesis(normalized[index]).trimmed
            normalized[closeIndex] = stripTrailingParenthesis(normalized[closeIndex], close: close).trimmed
        }
        return normalized
    }

    static func hasOriginalLyricsScript(_ text: String) -> Bool {
        for scalar in text.nfc().unicodeScalars {
            let value = scalar.value
            if (0x3040...0x30ff).contains(value)
                || (0x3400...0x4dbf).contains(value)
                || (0x4e00...0x9fff).contains(value)
                || (0xf900...0xfaff).contains(value)
                || (0x1100...0x11ff).contains(value)
                || (0x3130...0x318f).contains(value)
                || (0xac00...0xd7af).contains(value) {
                return true
            }
        }
        return false
    }

    private static func splitArtists(_ value: String) -> [String] {
        value.split { $0 == "&" || $0 == "," }
            .map { normalizeComparable(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func isAlbumExpansion(_ base: String, _ expanded: String) -> Bool {
        guard !base.isEmpty, expanded.hasPrefix(base), expanded.count > base.count else { return false }
        let next = expanded[expanded.index(expanded.startIndex, offsetBy: base.count)]
        return next.isWhitespace || next == "-" || next == ":" || next == "(" || next == "["
    }

    private static func isStandaloneParentheticalLine(_ text: String) -> Bool {
        let chars = splitChars(text.nfc().trimmed)
        guard chars.count >= 2 else { return false }
        let close = parenthesisClose(chars[0])
        return !close.isEmpty && close == chars[chars.count - 1]
    }

    private static func stripLeadingParenthesis(_ text: String) -> String {
        var chars = splitChars(text.nfc())
        for index in chars.indices {
            if chars[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if !parenthesisClose(chars[index]).isEmpty {
                chars.remove(at: index)
            }
            break
        }
        return chars.joined()
    }

    private static func stripTrailingParenthesis(_ text: String, close: String) -> String {
        var chars = splitChars(text.nfc())
        for index in chars.indices.reversed() {
            if chars[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if chars[index] == close {
                chars.remove(at: index)
            }
            break
        }
        return chars.joined()
    }

    private static func parenthesisClose(_ open: String) -> String {
        if open == "(" { return ")" }
        if open == "（" { return "）" }
        return ""
    }

    static func jaroWinkler(_ rawLeft: String, _ rawRight: String) -> Double {
        let left = Array(normalizeComparable(rawLeft))
        let right = Array(normalizeComparable(rawRight))
        if left.isEmpty || right.isEmpty { return 0 }
        if left == right { return 1 }

        let matchDistance = max(left.count, right.count) / 2 - 1
        var leftMatches = Array(repeating: false, count: left.count)
        var rightMatches = Array(repeating: false, count: right.count)
        var matches = 0

        for leftIndex in left.indices {
            let start = max(0, leftIndex - matchDistance)
            let end = min(leftIndex + matchDistance + 1, right.count)
            if start >= end { continue }
            for rightIndex in start..<end where !rightMatches[rightIndex] && left[leftIndex] == right[rightIndex] {
                leftMatches[leftIndex] = true
                rightMatches[rightIndex] = true
                matches += 1
                break
            }
        }
        if matches == 0 { return 0 }

        var transpositions = 0.0
        var rightIndex = 0
        for leftIndex in left.indices where leftMatches[leftIndex] {
            while rightIndex < rightMatches.count && !rightMatches[rightIndex] {
                rightIndex += 1
            }
            if rightIndex < right.count, left[leftIndex] != right[rightIndex] {
                transpositions += 1
            }
            rightIndex += 1
        }
        transpositions /= 2

        let jaro = ((Double(matches) / Double(left.count))
            + (Double(matches) / Double(right.count))
            + ((Double(matches) - transpositions) / Double(matches))) / 3

        var prefix = 0
        for index in 0..<min(4, min(left.count, right.count)) {
            if left[index] == right[index] {
                prefix += 1
            } else {
                break
            }
        }
        return jaro + Double(prefix) * 0.1 * (1 - jaro)
    }
}

struct HTTPStatusError: LocalizedError, Sendable {
    var statusCode: Int
    var message: String

    var errorDescription: String? {
        message
    }
}

extension URLSession {
    func ivLyricsData(for request: URLRequest, acceptedStatus: Range<Int> = 200..<300) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request, delegate: nil)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPStatusError(statusCode: 0, message: "Invalid HTTP response")
        }
        guard acceptedStatus.contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw HTTPStatusError(statusCode: http.statusCode, message: "HTTP \(http.statusCode)" + (body.isEmpty ? "" : " / \(IvLyricsUtilities.compactBody(body))"))
        }
        return (data, http)
    }
}
