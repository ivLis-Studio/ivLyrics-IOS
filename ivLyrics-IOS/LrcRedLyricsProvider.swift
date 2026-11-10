import Foundation

/// Read-only lrc.red provider and its optional word timing generator.
///
/// Lookups match the desktop addon: the track ISRC first, otherwise a literal title/artist
/// search that accepts only the same song. A record's TTML is preferred, with its LRC as a
/// fallback. Word timing generation is a separate POST whose response is applied only to
/// the same text.
enum LrcRedLyricsProvider {
    static let providerId = "lrcred"
    static let projectURL = "https://lrc.red"
    static let attribution = "Lyrics from lrc.red (https://lrc.red)."
    static let wordSyncTimeout: TimeInterval = 75
    private static let apiBase = "https://lrc.red"
    private static let clientId = "ivLyrics-iOS (+https://github.com/ivLis-Studio/ivLyrics-IOS; mailto:me@ivl.is)"
    private static let requestTimeout: TimeInterval = 15

    struct Outcome: Sendable {
        var lines: [LyricsLine]
        var karaoke: Bool
        var synced: Bool
        var recordIsrc: String
        var logs: [String]
    }

    /// A request failure with its HTTP status, so callers can respect the server's cooldown.
    struct Failure: LocalizedError, Sendable {
        var message: String
        var statusCode = 0
        var retryAfterMs: Int64 = 0

        var errorDescription: String? { message }
    }

    static func fetch(track: TrackSnapshot, isrc: String) async throws -> Outcome? {
        guard track.hasUsableMetadata else { return nil }
        var logs: [String] = []
        let title = track.title.trimmed
        let artist = track.artist.trimmed
        let durationSeconds = track.durationMs > 0 ? (Double(track.durationMs) / 1000).rounded() : 0

        var recordIsrc = ""
        let resolvedIsrc = normalizeIsrc(firstNonEmpty(isrc, track.isrc))
        if !resolvedIsrc.isEmpty {
            do {
                let response = try await get("/s/\(resolvedIsrc).json")
                if response.ok, let record = jsonObject(response.body),
                   !string(record["title"]).isEmpty || !string(record["isrc"]).isEmpty {
                    recordIsrc = firstNonEmpty(normalizeIsrc(string(record["isrc"])), resolvedIsrc)
                    logs.append("lrc.red: ISRC match \(recordIsrc)")
                }
            } catch {
                if isCancellation(error) { throw error }
                logs.append("lrc.red: ISRC lookup failed, searching instead: \(error.localizedDescription)")
            }
        }

        if recordIsrc.isEmpty {
            var bestScore = -1.0
            for query in buildSearchQueries(title: title, artist: artist) {
                var hits: [[String: Any]]?
                do {
                    let response = try await get("/search.json?q=\(queryValue(query))")
                    hits = response.ok ? jsonObject(response.body)?["hits"] as? [[String: Any]] : nil
                } catch {
                    if isCancellation(error) { throw error }
                    hits = nil
                }
                for hit in hits ?? [] {
                    if let score = scoreSearchHit(hit, title: title, artist: artist, durationSeconds: durationSeconds),
                       score > bestScore {
                        bestScore = score
                        recordIsrc = normalizeIsrc(string(hit["isrc"]))
                    }
                }
                if !recordIsrc.isEmpty {
                    logs.append("lrc.red: search match \(recordIsrc) (query=\(query))")
                    break
                }
            }
        }
        guard !recordIsrc.isEmpty else {
            logs.append("lrc.red: no lyrics found")
            return Outcome(lines: [], karaoke: false, synced: false, recordIsrc: "", logs: logs)
        }

        var parsed: UnisonLyricsProvider.ExternalParsedLyrics?
        do {
            let ttml = try await get("/s/\(recordIsrc).ttml")
            guard ttml.ok else { throw Failure(message: "TTML fetch failed (\(ttml.status))", statusCode: ttml.status) }
            let lyrics = try UnisonLyricsProvider.parseExternalLyrics(ttml.body, format: "ttml", durationMs: track.durationMs)
            parsed = lyrics.lines.isEmpty ? nil : lyrics
        } catch {
            if isCancellation(error) { throw error }
            logs.append("lrc.red: TTML unavailable, trying LRC: \(error.localizedDescription)")
        }
        if parsed == nil {
            do {
                let lrc = try await get("/s/\(recordIsrc).lrc")
                if lrc.ok {
                    let lyrics = try UnisonLyricsProvider.parseExternalLyrics(
                        stripEnhancedLrcTags(lrc.body),
                        format: "lrc",
                        durationMs: track.durationMs
                    )
                    parsed = lyrics.lines.isEmpty ? nil : lyrics
                }
            } catch {
                if isCancellation(error) { throw error }
                logs.append("lrc.red: LRC unavailable: \(error.localizedDescription)")
            }
        }
        guard let parsed else {
            logs.append("lrc.red: record \(recordIsrc) has no usable lyrics")
            return Outcome(lines: [], karaoke: false, synced: false, recordIsrc: recordIsrc, logs: logs)
        }
        let type = parsed.karaoke ? "karaoke" : (parsed.synced ? "synced" : "plain")
        logs.append("lrc.red selected: isrc=\(recordIsrc) / type=\(type) / lines=\(parsed.lines.count)")
        return Outcome(lines: parsed.lines, karaoke: parsed.karaoke, synced: parsed.synced, recordIsrc: recordIsrc, logs: logs)
    }

    /// Requests generated word timing. Returns lines whose texts equal the response's line
    /// texts; the caller must still confirm they equal the lyrics already displayed.
    static func requestWordSync(recordIsrc: String) async throws -> [LyricsLine] {
        let isrc = normalizeIsrc(recordIsrc)
        guard !isrc.isEmpty, let url = URL(string: "\(apiBase)/s/\(isrc)/sync") else {
            throw Failure(message: "Missing lrc.red recording")
        }
        var request = URLRequest(url: url, timeoutInterval: wordSyncTimeout)
        request.httpMethod = "POST"
        request.httpBody = Data()
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientId, forHTTPHeaderField: "X-Client-ID")
        request.setValue("ivLyrics-iOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure(
                message: "Word sync failed (\(status))",
                statusCode: status,
                retryAfterMs: parseRetryAfterMs(http?.value(forHTTPHeaderField: "Retry-After"))
            )
        }
        // The whole body is part of the timed request; its content is the generated timing.
        return try parseWordSyncResponse(String(decoding: data, as: UTF8.self), expectedIsrc: isrc)
    }

    static func parseWordSyncResponse(_ body: String, expectedIsrc: String) throws -> [LyricsLine] {
        guard let payload = jsonObject(body),
              normalizeIsrc(string(payload["id"])) == normalizeIsrc(expectedIsrc) else {
            throw Failure(message: "Word sync recording mismatch")
        }
        let lyrics = payload["lyrics"] as? [String: Any]
        let timing = firstNonEmpty(string(lyrics?["timing"]), string(lyrics?["sync"])).lowercased()
        guard let lines = lyrics?["lines"] as? [Any], timing == "word" || timing == "syllable" else {
            throw Failure(message: "Word sync response has no word timing")
        }
        var result: [LyricsLine] = []
        var timedWords = 0
        for case let line as [String: Any] in lines {
            guard let text = line["text"] as? String, !text.trimmed.isEmpty else { continue }
            var wordTexts: [String] = []
            var wordTimes: [(Int64, Int64)] = []
            var cursor = text.startIndex
            for case let fragments as [Any] in (line["words"] as? [Any]) ?? [] {
                guard !fragments.isEmpty else { throw Failure(message: "Invalid word sync fragments") }
                var word = ""
                var begins: [Int64] = []
                var ends: [Int64] = []
                for fragment in fragments {
                    guard let fragment = fragment as? [String: Any], let piece = fragment["text"] as? String else {
                        throw Failure(message: "Invalid word sync text")
                    }
                    let begin = try milliseconds(fragment["begin"])
                    let end = try milliseconds(fragment["end"])
                    guard end >= begin else { throw Failure(message: "Invalid word sync range") }
                    word += piece
                    begins.append(begin)
                    ends.append(end)
                }
                var whitespaceEnd = cursor
                while whitespaceEnd < text.endIndex, text[whitespaceEnd].isWhitespace {
                    whitespaceEnd = text.index(after: whitespaceEnd)
                }
                let whitespace = String(text[cursor..<whitespaceEnd])
                cursor = whitespaceEnd
                guard !word.isEmpty, text[cursor...].hasPrefix(word) else {
                    throw Failure(message: "Word sync text does not match its line")
                }
                // Whitespace belongs to the end of the previous word, as on the desktop.
                if wordTexts.isEmpty {
                    wordTexts.append(whitespace + word)
                } else {
                    wordTexts[wordTexts.count - 1] += whitespace
                    wordTexts.append(word)
                }
                let start = begins[0]
                let end = ends[ends.count - 1]
                guard end >= start else { throw Failure(message: "Invalid word sync range") }
                wordTimes.append((start, end))
                cursor = text.index(cursor, offsetBy: word.count)
                timedWords += 1
            }
            if !wordTexts.isEmpty {
                let remaining = String(text[cursor...])
                guard remaining.trimmed.isEmpty else { throw Failure(message: "Word sync response has unmatched text") }
                wordTexts[wordTexts.count - 1] += remaining
            }
            let lineStart = try milliseconds(line["begin"])
            let lineEnd = try milliseconds(line["end"])
            guard lineEnd >= lineStart else { throw Failure(message: "Invalid word sync line range") }
            var syllables = zip(wordTexts, wordTimes).map { text, time in
                LyricsLine.Syllable(text: text, startTimeMs: time.0, endTimeMs: time.1, sourceGranularity: "word")
            }
            if syllables.isEmpty {
                syllables = [LyricsLine.Syllable(text: text, startTimeMs: lineStart, endTimeMs: lineEnd, sourceGranularity: "word")]
            }
            result.append(LyricsLine(
                startTimeMs: lineStart,
                endTimeMs: max(lineStart + 1, lineEnd),
                text: text,
                syllables: syllables
            ))
        }
        guard timedWords > 0 else { throw Failure(message: "Word sync response has no timed words") }
        return result
    }

    /// True when both results show the same non-empty lyric lines, ignoring timing.
    static func sameLineTexts(_ left: [LyricsLine], _ right: [LyricsLine]) -> Bool {
        let a = lineTexts(left)
        return !a.isEmpty && a == lineTexts(right)
    }

    private static func lineTexts(_ lines: [LyricsLine]) -> [String] {
        lines.compactMap { line in
            let text = line.text.precomposedStringWithCanonicalMapping.trimmed
            return text.isEmpty ? nil : text
        }
    }

    static func stripEnhancedLrcTags(_ lrc: String) -> String {
        replacing(enhancedLrcTag, in: lrc, with: "")
    }

    static func normalizeIsrc(_ value: String) -> String {
        let isrc = replacing(nonAlphanumeric, in: value, with: "").uppercased()
        return matches(isrcPattern, isrc) ? isrc : ""
    }

    static func buildSearchQueries(title: String, artist: String) -> [String] {
        var base = stripTitleDecorations(title)
        if base.isEmpty { base = title }
        var queries: [String] = []
        for value in ["\(title) \(artist)", title, "\(base) \(artist)", base] {
            let query = replacing(spaces, in: value, with: " ").trimmed
            if !query.isEmpty, !queries.contains(query) { queries.append(query) }
        }
        return queries
    }

    static func scoreSearchHit(_ hit: [String: Any], title: String, artist: String, durationSeconds: Double) -> Double? {
        let titleScore = titleMatchScore(actual: string(hit["title"]), expected: title)
        guard !normalizeIsrc(string(hit["isrc"])).isEmpty, titleScore > 0,
              sameArtist(actual: string(hit["artist"]), expected: artist) else { return nil }
        let candidateDuration = (hit["duration"] as? NSNumber)?.doubleValue ?? 0
        let durationScore = durationSeconds > 0 && candidateDuration > 0
            ? max(0, 1 - abs(durationSeconds - candidateDuration) / 30)
            : 0
        // Duration ranks only candidates already identified as the same song.
        return titleScore * 0.6 + 0.3 + durationScore * 0.1
    }

    static func titleMatchScore(actual: String, expected: String) -> Double {
        let wanted = compact(expected)
        let candidate = compact(actual)
        guard !wanted.isEmpty, !candidate.isEmpty else { return 0 }
        if candidate == wanted { return 1 }
        // Identity matching may ignore only known version labels, never e.g. "Song (Part II)".
        let wantedCore = compact(withoutVersionLabels(expected))
        let actualCore = compact(withoutVersionLabels(actual))
        return !wantedCore.isEmpty && actualCore == wantedCore ? 0.9 : 0
    }

    static func sameArtist(actual: String, expected: String) -> Bool {
        let wanted = normalizeString(expected)
        let candidate = normalizeString(actual)
        guard !wanted.isEmpty, !candidate.isEmpty else { return false }
        if candidate == wanted { return true }
        // A catalog may list featured artists where Spotify supplies only the lead.
        let expectedLead = normalizeString(leadArtist(expected))
        return !expectedLead.isEmpty && expectedLead == normalizeString(leadArtist(actual))
    }

    static func normalizeString(_ value: String) -> String {
        var text = value.precomposedStringWithCompatibilityMapping.lowercased()
        // Fold Latin accents without dropping Japanese voicing or marks in other scripts.
        text = replacing(latinMarks, in: text.decomposedStringWithCanonicalMapping, with: "$1")
            .precomposedStringWithCanonicalMapping
        text = replacing(apostrophes, in: text, with: "")
        text = replacing(nonWord, in: text, with: " ")
        return replacing(spaces, in: text, with: " ").trimmed
    }

    static func parseRetryAfterMs(_ value: String?) -> Int64 {
        let raw = value?.trimmed ?? ""
        guard !raw.isEmpty else { return 0 }
        if let seconds = Double(raw) {
            return max(0, Int64((seconds * 1000).rounded()))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return 0 }
        return max(0, Int64((date.timeIntervalSinceNow * 1000).rounded()))
    }

    // MARK: - Helpers

    private static let isrcPattern = regex(#"^[A-Z]{2}[A-Z0-9]{3}\d{7}$"#)
    private static let nonAlphanumeric = regex(#"[^A-Za-z0-9]"#)
    private static let enhancedLrcTag = regex(#"<(?:\d{1,3}:)?\d{1,2}:\d{1,2}(?:[.:]\d{1,3})?>"#)
    private static let titleDecoration = regex(#"\s*[(\[][^)\]]*[)\]]"#)
    private static let titleDashSuffix = regex(#"\s+-\s+.*$"#)
    private static let versionLabel = regex(
        #"\b(?:feat(?:uring)?|ft|version|remaster(?:ed)?|remix|mix|edit|edition|live|acoustic|mono|stereo)\b|\bfrom the vault\b"#,
        [.caseInsensitive]
    )
    private static let parenthesized = regex(#"\(([^()]*)\)|\[([^\[\]]*)\]"#)
    private static let dashSuffixCapture = regex(#"\s+-\s+(.+)$"#)
    private static let artistLeadSeparator = regex(
        #"\s+(?:feat(?:uring)?\.?|ft\.?|with|[x×])\s+|[,;&]"#,
        [.caseInsensitive]
    )
    private static let latinMarks = regex(#"(\p{Script=Latin})\p{M}+"#)
    private static let apostrophes = regex("['’‘`´]")
    private static let nonWord = regex(#"[^\p{L}\p{N}\p{M}]+"#)
    private static let spaces = regex(#"\s+"#)
    private static let queryAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    private struct Response {
        var status: Int
        var body: String
        var ok: Bool { (200..<300).contains(status) }
    }

    private static func get(_ path: String) async throws -> Response {
        guard let url = URL(string: apiBase + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.setValue("application/json, application/ttml+xml, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(clientId, forHTTPHeaderField: "X-Client-ID")
        request.setValue("ivLyrics-iOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        return Response(
            status: (response as? HTTPURLResponse)?.statusCode ?? 0,
            body: String(decoding: data, as: UTF8.self)
        )
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    private static func stripTitleDecorations(_ title: String) -> String {
        var value = replacing(titleDecoration, in: title, with: " ")
        value = replacing(titleDashSuffix, in: value, with: " ")
        return replacing(spaces, in: value, with: " ").trimmed
    }

    private static func withoutVersionLabels(_ title: String) -> String {
        let source = title as NSString
        var value = ""
        var location = 0
        for match in parenthesized.matches(in: title, range: NSRange(location: 0, length: source.length)) {
            value += source.substring(with: NSRange(location: location, length: match.range.location - location))
            let inner = match.range(at: 1).location != NSNotFound
                ? source.substring(with: match.range(at: 1))
                : (match.range(at: 2).location != NSNotFound ? source.substring(with: match.range(at: 2)) : "")
            value += matches(versionLabel, inner) ? " " : source.substring(with: match.range)
            location = match.range.location + match.range.length
        }
        value += source.substring(from: location)
        let text = value as NSString
        if let suffix = dashSuffixCapture.firstMatch(in: value, range: NSRange(location: 0, length: text.length)),
           matches(versionLabel, text.substring(with: suffix.range(at: 1))) {
            return text.substring(to: suffix.range.location)
        }
        return value
    }

    private static func leadArtist(_ value: String) -> String {
        let source = value as NSString
        guard let match = artistLeadSeparator.firstMatch(in: value, range: NSRange(location: 0, length: source.length)) else {
            return value
        }
        return source.substring(to: match.range.location)
    }

    private static func compact(_ value: String) -> String {
        normalizeString(value).replacingOccurrences(of: " ", with: "")
    }

    private static func milliseconds(_ value: Any?) throws -> Int64 {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw Failure(message: "Invalid word sync time")
        }
        let seconds = number.doubleValue
        guard seconds.isFinite, seconds >= 0 else { throw Failure(message: "Invalid word sync time") }
        return Int64((seconds * 1000).rounded())
    }

    private static func jsonObject(_ body: String) -> [String: Any]? {
        guard !body.trimmed.isEmpty, let data = body.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func string(_ value: Any?) -> String {
        (value as? String) ?? ""
    }

    private static func firstNonEmpty(_ values: String...) -> String {
        values.first { !$0.trimmed.isEmpty }?.trimmed ?? ""
    }

    private static func queryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? ""
    }

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Constant patterns; a failure is a programming error caught by the regression script.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
        regex.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil
    }

    private static func replacing(_ regex: NSRegularExpression, in value: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: value,
            range: NSRange(location: 0, length: (value as NSString).length),
            withTemplate: template
        )
    }
}

/// Applies lrc.red word timing to lyrics that are already displayed.
///
/// Generated timing never changes the lyric text, so pronunciation, translation and furigana
/// produced for the line-timed lyrics stay valid and are carried over line by line.
enum LyricsTimingUpgrade {
    /// Whether a displayed base may receive generated lrc.red word timing.
    static func canUpgrade(_ base: LyricsResult) -> Bool {
        !base.karaoke && !base.lines.isEmpty && base.providerId == LrcRedLyricsProvider.providerId
    }

    /// The word-timed replacement for a line-timed lrc.red result, or nil if it does not apply.
    static func upgradedBase(_ base: LyricsResult, timedLines: [LyricsLine]) -> LyricsResult? {
        guard canUpgrade(base), timedLines.count == base.lines.count,
              LrcRedLyricsProvider.sameLineTexts(base.lines, timedLines) else { return nil }
        var upgraded = base
        upgraded.lines = zip(base.lines, timedLines).map { shown, timed in retimed(shown, from: timed) }
        upgraded.providerLabel = "lrc.red karaoke"
        upgraded.karaoke = true
        return upgraded
    }

    /// True when an upgraded base replaces exactly this line-timed result.
    static func upgrades(_ source: LyricsResult, to upgraded: LyricsResult) -> Bool {
        canUpgrade(source) && upgraded.karaoke
            && source.providerId == upgraded.providerId
            && source.selectionPolicyKey == upgraded.selectionPolicyKey
            && source.lines.count == upgraded.lines.count
            && LrcRedLyricsProvider.sameLineTexts(source.lines, upgraded.lines)
    }

    /// Displayed supplements on the upgraded timing; the displayed lines map one to one.
    static func retime(_ displayed: LyricsResult, with timed: LyricsResult) -> LyricsResult {
        guard displayed.lines.count == timed.lines.count else { return timed }
        var result = displayed
        result.lines = zip(displayed.lines, timed.lines).map { shown, line in retimed(shown, from: line) }
        result.providerLabel = timed.providerLabel
        result.karaoke = timed.karaoke
        return result
    }

    /// The shown line, including its identity and supplements, with the other line's timing.
    private static func retimed(_ shown: LyricsLine, from timed: LyricsLine) -> LyricsLine {
        var line = shown
        line.startTimeMs = timed.startTimeMs
        line.endTimeMs = timed.endTimeMs
        line.syllables = timed.syllables
        return line
    }
}
