import Foundation
import CryptoKit

/// User imports survive cache clearing and are only removed by an explicit action.
nonisolated struct LocalLyricsStore: Sendable {
    static let maxBytes = 1024 * 1024
    private let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalLyrics", isDirectory: true)
    }

    private func file(for key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(name + ".txt")
    }

    func contains(key: String) -> Bool {
        FileManager.default.fileExists(atPath: file(for: key).path)
    }

    func load(key: String, durationMs: Int64) throws -> LyricsResult? {
        let url = file(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // UTF-16 imports may grow when saved as UTF-8; the input size limit was
        // already checked at import, so do not reject our normalized copy.
        return try Self.parse(String(contentsOf: url, encoding: .utf8), durationMs: durationMs)
    }

    func save(key: String, text: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file(for: key), options: .atomic)
    }

    func remove(key: String) throws {
        let url = file(for: key)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    static func read(_ url: URL) throws -> String {
        guard ["lrc", "txt"].contains(url.pathExtension.lowercased()) else { throw ImportError.invalid }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Bound the actual read too: a document provider's advertised size may be stale.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try decode(handle.read(upToCount: maxBytes + 1) ?? Data())
    }

    static func decode(_ data: Data) throws -> String {
        guard !data.isEmpty, data.count <= maxBytes else { throw ImportError.invalid }
        let bytes = Array(data.prefix(2))
        let encoding: String.Encoding = bytes == [0xff, 0xfe] ? .utf16LittleEndian
            : bytes == [0xfe, 0xff] ? .utf16BigEndian : .utf8
        let payload = encoding == .utf8 ? data : data.dropFirst(2)
        guard var text = String(data: payload, encoding: encoding), !text.contains("\0") else { throw ImportError.invalid }
        if text.first == "\u{feff}" { text.removeFirst() }
        return text
    }

    static func parse(_ text: String, durationMs: Int64) throws -> LyricsResult {
        let stamp = try NSRegularExpression(pattern: #"\[(\d{1,6}):([0-5]?\d)(?:[.,](\d{1,3}))?\]"#)
        let metadata = try NSRegularExpression(pattern: #"(?i)^\[(?:ar|al|ti|au|length|by|offset|re|ve):.*\]$"#)
        let offsetRegex = try NSRegularExpression(pattern: #"(?im)^\s*\[offset:([+-]?\d{1,9})\]\s*$"#)
        func group(_ match: NSTextCheckingResult, _ index: Int, _ source: String) -> String {
            guard let range = Range(match.range(at: index), in: source) else { return "" }
            return String(source[range])
        }
        let offset = offsetRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last
            .flatMap { Int64(group($0, 1, text)) } ?? 0
        var timed: [LyricsLine] = []
        var plain: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(line.startIndex..., in: line)
            if line.isEmpty || metadata.firstMatch(in: line, range: range) != nil { continue }
            var end = 0
            var times: [Int64] = []
            for match in stamp.matches(in: line, range: range) {
                guard match.range.location == end else { break }
                let minutes = Int64(group(match, 1, line)) ?? 0
                let seconds = Int64(group(match, 2, line)) ?? 0
                let fraction = group(match, 3, line)
                let millis = Int64((fraction + "000").prefix(3)) ?? 0
                times.append(max(0, minutes * 60_000 + seconds * 1000 + millis + offset))
                end = NSMaxRange(match.range)
            }
            if times.isEmpty { plain.append(line) }
            else {
                let words = (line as NSString).substring(from: end).trimmingCharacters(in: .whitespaces)
                timed += times.map { LyricsLine(startTimeMs: $0, endTimeMs: $0, text: words) }
            }
        }
        let synced = !timed.isEmpty
        // Keep duplicate timestamps in file order (for bilingual LRC).
        timed = timed.enumerated().sorted { a, b in
            a.element.startTimeMs == b.element.startTimeMs ? a.offset < b.offset : a.element.startTimeMs < b.element.startTimeMs
        }.map(\.element)
        var nextDistinctStart: Int64?
        for index in timed.indices.reversed() {
            if index + 1 < timed.count, timed[index + 1].startTimeMs > timed[index].startTimeMs {
                nextDistinctStart = timed[index + 1].startTimeMs
            }
            timed[index].endTimeMs = nextDistinctStart
                ?? (durationMs > timed[index].startTimeMs ? durationMs : timed[index].startTimeMs + 4000)
        }
        let lines = synced ? timed : LrcParser.parsePlain(plain.joined(separator: "\n"))
        guard lines.contains(where: { !$0.text.isEmpty }) else { throw ImportError.invalid }
        return LyricsResult(lines: lines, providerLabel: synced ? "Local LRC" : "Local", detail: "", karaoke: false,
                            providerId: "local", selectionPolicyKey: "local", syncType: synced ? "line" : "unknown",
                            syncPoints: synced ? lines.count : 0)
    }

    enum ImportError: Error { case invalid }
}
