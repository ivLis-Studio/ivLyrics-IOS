import Foundation

enum UnisonLyricsProvider {
    private static let apiBase = "https://unison.boidu.dev"
    private static let attribution = "Lyrics from Unison (https://unison.boidu.dev)."
    private static let requestTimeout: TimeInterval = 10
    private static let timeUnitPattern = #"^([+-]?[\d.]+)(ms|h|m|s)$"#
    private static let timeUnitRegex = try? NSRegularExpression(
        pattern: timeUnitPattern,
        options: .caseInsensitive
    )
    private static let inlineWhitespacePattern = #"\s+"#
    private static let inlineWhitespaceRegex = try? NSRegularExpression(
        pattern: inlineWhitespacePattern
    )
    private static let lrcOffsetPattern = #"^\[offset:([+-]?\d+)\]"#
    private static let lrcOffsetRegex = try? NSRegularExpression(
        pattern: lrcOffsetPattern,
        options: .caseInsensitive
    )
    private static let lrcMetadataPattern = #"^\[(ar|al|ti|by|re|ve|length):"#
    private static let lrcMetadataRegex = try? NSRegularExpression(
        pattern: lrcMetadataPattern,
        options: .caseInsensitive
    )
    private static let lrcTimestampPattern = #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#
    private static let lrcTimestampRegex = try? NSRegularExpression(
        pattern: lrcTimestampPattern
    )

    private static let speakerPalette = [
        SpeakerPresentation(speaker: "CUSTOM", color: "#a8ccff", fallback: "MALE 1"),
        SpeakerPresentation(speaker: "CUSTOM", color: "#ffb8c7", fallback: "FEMALE 1"),
        SpeakerPresentation(speaker: "CUSTOM", color: "#e4d8ff", fallback: "DUET 1"),
        SpeakerPresentation(speaker: "CUSTOM", color: "#9ae8d4", fallback: "MALE 2"),
        SpeakerPresentation(speaker: "CUSTOM", color: "#ffd6b3", fallback: "FEMALE 2"),
        SpeakerPresentation(speaker: "CUSTOM", color: "#d6e4ff", fallback: "DUET 2"),
        SpeakerPresentation(speaker: "CUSTOM", color: "#bfe8ff", fallback: "MALE 3"),
        SpeakerPresentation(speaker: "CUSTOM", color: "#f6c8ff", fallback: "FEMALE 3"),
        SpeakerPresentation(speaker: "CUSTOM", color: "#ffddf2", fallback: "DUET 3")
    ]

    struct FetchOutcome: Sendable {
        var result: LyricsResult?
        var logs: [String]
    }

    struct ExternalParsedLyrics: Sendable {
        var lines: [LyricsLine]
        var karaoke: Bool
        var synced: Bool
    }

    static func parseExternalLyrics(
        _ lyrics: String,
        format: String,
        durationMs: Int64
    ) throws -> ExternalParsedLyrics {
        let parsed: ParsedLyrics
        switch format.trimmed.lowercased() {
        case "ttml":
            parsed = try parseTtmlLyrics(lyrics, durationMs: durationMs)
        case "lrc":
            parsed = parseLrcLyrics(lyrics, durationMs: durationMs)
        case "plain":
            parsed = parsePlainLyrics(lyrics)
        default:
            throw HTTPStatusError(
                statusCode: 0,
                message: "Unsupported external lyrics format: \(format.trimmed.isEmpty ? "unknown" : format)"
            )
        }
        return ExternalParsedLyrics(lines: parsed.lines, karaoke: parsed.karaoke, synced: parsed.synced)
    }

    static func fetch(
        track: TrackSnapshot,
        isrc: String,
        spotifyTrackId: String
    ) async throws -> FetchOutcome {
        guard track.hasUsableMetadata else {
            return FetchOutcome(result: nil, logs: [])
        }

        var logs: [String] = []
        guard let data = try await fetchLyricsData(track: track, logs: &logs) else {
            logs.append("unison: no lyrics found")
            return FetchOutcome(result: nil, logs: logs)
        }
        let parsed = try parseResponseLyrics(data, durationMs: track.durationMs)
        guard !parsed.lines.isEmpty else {
            logs.append("unison: response has no renderable lyrics")
            return FetchOutcome(result: nil, logs: logs)
        }

        let type = parsed.karaoke ? "karaoke" : (parsed.synced ? "synced" : "plain")
        let vocalPartCount = parsed.lines.reduce(0) { $0 + $1.vocalParts.count }
        logs.append("unison selected: format=\(data.format) / type=\(type) / lines=\(parsed.lines.count) / vocalParts=\(vocalPartCount)")
        return FetchOutcome(
            result: LyricsResult(
                lines: parsed.lines,
                providerLabel: "Unison \(type)",
                detail: attribution,
                karaoke: parsed.karaoke,
                isrc: isrc,
                spotifyTrackId: spotifyTrackId
            ),
            logs: logs
        )
    }

    private static func fetchLyricsData(
        track: TrackSnapshot,
        logs: inout [String]
    ) async throws -> ResponseData? {
        let artists = artistCandidates(track.artist)
        let hasAlbum = !track.album.isEmpty && track.album.lowercased() != "undefined"
        let albumOptions = hasAlbum ? [true, false] : [false]
        var attempts: [RequestAttempt] = []
        for includeAlbum in albumOptions {
            for artist in artists {
                attempts.append(
                    RequestAttempt(
                        url: try lyricsURL(
                            track: track,
                            artist: artist,
                            includeAlbum: includeAlbum,
                            includeDuration: true
                        ),
                        exactMetadataRequired: false
                    )
                )
            }
        }
        if track.durationMs > 0 {
            for artist in artists {
                attempts.append(
                    RequestAttempt(
                        url: try lyricsURL(
                            track: track,
                            artist: artist,
                            includeAlbum: false,
                            includeDuration: false
                        ),
                        exactMetadataRequired: true
                    )
                )
            }
        }

        var seen = Set<String>()
        let uniqueAttempts = attempts.filter { seen.insert($0.url.absoluteString).inserted }
        for (offset, attempt) in uniqueAttempts.enumerated() {
            var request = URLRequest(url: attempt.url, timeoutInterval: requestTimeout)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("ivLyrics-iOS/0.1", forHTTPHeaderField: "User-Agent")
            let (bodyData, response) = try await URLSession.shared.data(for: request, delegate: nil)
            guard let http = response as? HTTPURLResponse else {
                throw HTTPStatusError(statusCode: 0, message: "Invalid Unison HTTP response")
            }
            let object = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any]
            if (200..<300).contains(http.statusCode),
               object?["success"] as? Bool != false,
               let dataObject = object?["data"] as? [String: Any] {
                let data = ResponseData(json: dataObject)
                if !data.lyrics.isEmpty,
                   !attempt.exactMetadataRequired || isExactMetadataMatch(data: data, track: track) {
                    logs.append("unison: request #\(offset + 1) matched" + (attempt.exactMetadataRequired ? " / exact metadata verified" : ""))
                    return data
                }
                if attempt.exactMetadataRequired, !data.lyrics.isEmpty {
                    logs.append("unison: request #\(offset + 1) rejected by exact metadata check")
                }
                continue
            }
            if http.statusCode != 404 {
                let serverMessage = (object?["error"] as? String)?.trimmed ?? ""
                throw HTTPStatusError(
                    statusCode: http.statusCode,
                    message: serverMessage.isEmpty ? "Unison request failed (\(http.statusCode))" : serverMessage
                )
            }
        }
        return nil
    }

    private static func lyricsURL(
        track: TrackSnapshot,
        artist: String,
        includeAlbum: Bool,
        includeDuration: Bool
    ) throws -> URL {
        guard var components = URLComponents(string: "\(apiBase)/lyrics") else {
            throw URLError(.badURL)
        }
        var items = [
            URLQueryItem(name: "song", value: track.title),
            URLQueryItem(name: "artist", value: artist)
        ]
        if includeDuration, track.durationMs > 0 {
            items.append(URLQueryItem(name: "duration", value: String(Int((Double(track.durationMs) / 1000).rounded()))))
        }
        if includeAlbum, !track.album.isEmpty, track.album.lowercased() != "undefined" {
            items.append(URLQueryItem(name: "album", value: track.album))
        }
        components.queryItems = items
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }

    private static func parseResponseLyrics(_ data: ResponseData, durationMs: Int64) throws -> ParsedLyrics {
        switch data.format.lowercased() {
        case "ttml":
            return try parseTtmlLyrics(data.lyrics, durationMs: durationMs)
        case "lrc":
            return parseLrcLyrics(data.lyrics, durationMs: durationMs)
        case "plain":
            return parsePlainLyrics(data.lyrics)
        default:
            throw HTTPStatusError(
                statusCode: 0,
                message: "Unsupported Unison lyrics format: \(data.format.isEmpty ? "unknown" : data.format)"
            )
        }
    }

    private static func parseTtmlLyrics(_ ttml: String, durationMs: Int64) throws -> ParsedLyrics {
        let builder = XMLTreeBuilder()
        let input = declareMissingNamespaces(ttml)
        guard let xmlData = input.data(using: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let parser = XMLParser(data: xmlData)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
        }

        var agentOrder: [String: Int] = [:]
        for agent in elements(named: "agent", roots: builder.roots) {
            let id = attribute(agent, "id")
            if !id.isEmpty, agentOrder[id] == nil {
                agentOrder[id] = agentOrder.count
            }
        }

        var parsedLines: [ParsedLine] = []
        let paragraphs = elements(named: "p", roots: builder.roots)
        for (lineIndex, paragraph) in paragraphs.enumerated() {
            let startTime = parseTimeMs(attribute(paragraph, "begin")) ?? 0
            let endTime: Int64
            if let explicitEnd = parseTimeMs(attribute(paragraph, "end")) {
                endTime = explicitEnd
            } else if let duration = parseTimeMs(attribute(paragraph, "dur")) {
                endTime = startTime + duration
            } else {
                endTime = startTime + 2500
            }
            let lineKey = IvLyricsUtilities.firstNonEmpty(
                attribute(paragraph, "key"),
                attribute(paragraph, "id"),
                "line-\(lineIndex + 1)"
            )
            let lineAgent = attribute(paragraph, "agent")
            addAgentIfNeeded(lineAgent, order: &agentOrder)
            let lineSpeaker = speakerPresentation(lineAgent, order: agentOrder)
            let lead = parseTimedNodes(
                paragraph.contents,
                fallbackStart: startTime,
                fallbackEnd: endTime,
                excludeBackground: true
            )

            var backgrounds: [LyricsLine.VocalPart] = []
            for child in childElements(paragraph.contents) where attribute(child, "role").lowercased() == "x-bg" {
                let backgroundAgent = IvLyricsUtilities.firstNonEmpty(attribute(child, "agent"), lineAgent)
                addAgentIfNeeded(backgroundAgent, order: &agentOrder)
                let backgroundStart = parseTimeMs(attribute(child, "begin")) ?? startTime
                let backgroundEnd = parseTimeMs(attribute(child, "end")) ?? endTime
                let part = stripBackgroundParentheses(
                    parseTimedNodes(
                        child.contents,
                        fallbackStart: backgroundStart,
                        fallbackEnd: backgroundEnd,
                        excludeBackground: false
                    )
                )
                if let vocal = createVocalPart(
                    id: "\(lineKey)-background-\(backgrounds.count + 1)",
                    role: "background",
                    part: part,
                    speaker: speakerPresentation(backgroundAgent, order: agentOrder)
                ) {
                    backgrounds.append(vocal)
                }
            }

            let backgroundTexts = backgrounds.map(\.text)
            var leadPart = createVocalPart(
                id: "\(lineKey)-lead",
                role: "lead",
                part: lead,
                speaker: lineSpeaker
            )
            if leadPart == nil, !backgrounds.isEmpty, !lead.text.isEmpty {
                leadPart = createVocalPart(
                    id: "\(lineKey)-lead",
                    role: "lead",
                    part: ParsedPart(
                        text: lead.text,
                        syllables: [LyricsLine.Syllable(text: lead.text, startTimeMs: startTime, endTimeMs: endTime)],
                        hasTimedText: true
                    ),
                    speaker: lineSpeaker
                )
            }
            if leadPart == nil, !backgrounds.isEmpty {
                let promoted = backgrounds.removeFirst()
                leadPart = LyricsLine.VocalPart(
                    id: "\(lineKey)-lead",
                    role: "lead",
                    speaker: promoted.speaker,
                    speakerColor: promoted.speakerColor,
                    speakerFallback: promoted.speakerFallback,
                    kind: promoted.kind,
                    text: promoted.text,
                    syllables: promoted.syllables
                )
            }

            let displayText: String
            if !backgroundTexts.isEmpty {
                displayText = normalizeDisplayText(([lead.text] + backgroundTexts).filter { !$0.isEmpty }.joined(separator: " "))
            } else {
                displayText = IvLyricsUtilities.firstNonEmpty(normalizeDisplayText(textContent(paragraph)), lead.text)
            }
            guard !displayText.isEmpty else { continue }

            var allParts: [LyricsLine.VocalPart] = []
            if let leadPart {
                allParts.append(leadPart)
            }
            allParts.append(contentsOf: backgrounds)
            let resolvedStart = allParts.reduce(startTime) { min($0, $1.startTimeMs) }
            let resolvedEnd = max(
                resolvedStart + 1,
                allParts.reduce(endTime) { max($0, $1.endTimeMs) }
            )

            let lineSyllables: [LyricsLine.Syllable]
            let vocalParts: [LyricsLine.VocalPart]
            let hasWordTiming: Bool
            if !backgrounds.isEmpty, let leadPart {
                lineSyllables = []
                vocalParts = [leadPart] + backgrounds
                hasWordTiming = true
            } else if let leadPart, !backgroundTexts.isEmpty {
                lineSyllables = leadPart.syllables
                vocalParts = []
                hasWordTiming = true
            } else if !lead.syllables.isEmpty {
                lineSyllables = lead.syllables
                vocalParts = []
                hasWordTiming = lead.hasTimedText
            } else {
                lineSyllables = []
                vocalParts = []
                hasWordTiming = false
            }

            parsedLines.append(
                ParsedLine(
                    startTimeMs: resolvedStart,
                    endTimeMs: resolvedEnd,
                    text: displayText,
                    syllables: lineSyllables,
                    speaker: lineSpeaker,
                    vocalParts: vocalParts,
                    hasWordTiming: hasWordTiming
                )
            )
        }

        parsedLines.sort { $0.startTimeMs < $1.startTimeMs }
        let karaoke = parsedLines.contains(where: \.hasWordTiming)
        let lines = parsedLines.map { line -> LyricsLine in
            var syllables = karaoke ? line.syllables : []
            if karaoke, syllables.isEmpty, line.vocalParts.isEmpty {
                syllables = [
                    LyricsLine.Syllable(
                        text: line.text,
                        startTimeMs: line.startTimeMs,
                        endTimeMs: line.endTimeMs
                    )
                ]
            }
            return LyricsLine(
                startTimeMs: line.startTimeMs,
                endTimeMs: line.endTimeMs,
                text: line.text,
                syllables: syllables,
                speaker: line.speaker.speaker,
                speakerColor: line.speaker.color,
                speakerFallback: line.speaker.fallback,
                kind: "vocal",
                vocalParts: karaoke ? line.vocalParts : []
            )
        }
        let normalizedLines = karaoke ? CrossLineVocalNormalizer.normalize(lines) : lines
        return ParsedLyrics(lines: normalizedLines, karaoke: karaoke, synced: !normalizedLines.isEmpty)
    }

    private static func parseTimedNodes(
        _ contents: [XMLContent],
        fallbackStart: Int64,
        fallbackEnd: Int64,
        excludeBackground: Bool
    ) -> ParsedPart {
        var state = TimedBuilder(
            fallbackStart: max(0, fallbackStart),
            fallbackEnd: max(fallbackStart + 1, fallbackEnd)
        )
        for (index, content) in contents.enumerated() {
            switch content {
            case .text(let rawText):
                if rawText.trimmed.isEmpty {
                    if !state.text.isEmpty, state.text.last != " ", hasContentAfter(contents, index: index) {
                        let boundary = state.syllables.last?.endTimeMs ?? state.fallbackStart
                        appendText(
                            state: &state,
                            rawText: " ",
                            startTime: boundary,
                            endTime: boundary,
                            timed: state.hasTimedText
                        )
                    }
                } else {
                    appendText(
                        state: &state,
                        rawText: rawText,
                        startTime: state.fallbackStart,
                        endTime: state.fallbackEnd,
                        timed: false
                    )
                }
            case .element(let element):
                if excludeBackground, attribute(element, "role").lowercased() == "x-bg" {
                    continue
                }
                if localName(element.name) == "br" {
                    appendText(
                        state: &state,
                        rawText: " ",
                        startTime: state.fallbackStart,
                        endTime: state.fallbackStart,
                        timed: state.hasTimedText
                    )
                    continue
                }
                let elementStart = parseTimeMs(attribute(element, "begin"))
                let explicitEnd = parseTimeMs(attribute(element, "end"))
                let duration = parseTimeMs(attribute(element, "dur"))
                let start = elementStart ?? state.fallbackStart
                let end = explicitEnd ?? duration.map { start + $0 } ?? state.fallbackEnd
                if !childElements(element.contents).isEmpty {
                    let nested = parseTimedNodes(
                        element.contents,
                        fallbackStart: start,
                        fallbackEnd: end,
                        excludeBackground: excludeBackground
                    )
                    state.text += nested.text
                    state.syllables.append(contentsOf: nested.syllables)
                    state.hasTimedText = state.hasTimedText || nested.hasTimedText
                } else {
                    appendText(
                        state: &state,
                        rawText: textContent(element),
                        startTime: start,
                        endTime: end,
                        timed: elementStart != nil || explicitEnd != nil || duration != nil
                    )
                }
            }
        }
        trimEmptySyllables(&state.syllables)
        return ParsedPart(text: state.text.trimmed, syllables: state.syllables, hasTimedText: state.hasTimedText)
    }

    private static func appendText(
        state: inout TimedBuilder,
        rawText: String,
        startTime: Int64,
        endTime: Int64,
        timed: Bool
    ) {
        var text = normalizeInlineText(rawText)
        guard !text.isEmpty else { return }
        if state.text.isEmpty {
            text = String(text.drop(while: \.isWhitespace))
        }
        if state.text.last == " ", text.first == " " {
            text.removeFirst()
        }
        guard !text.isEmpty else { return }
        state.text += text
        guard timed else { return }
        let start = max(0, startTime)
        let end = max(start + 1, endTime >= start ? endTime : state.fallbackEnd)
        state.syllables.append(LyricsLine.Syllable(text: text, startTimeMs: start, endTimeMs: end))
        state.hasTimedText = true
    }

    private static func stripBackgroundParentheses(_ part: ParsedPart) -> ParsedPart {
        var syllables = part.syllables.compactMap { syllable -> LyricsLine.Syllable? in
            let text = syllable.text.regexReplacing("[()（）]", with: "")
            guard !text.isEmpty else { return nil }
            return LyricsLine.Syllable(
                text: text,
                startTimeMs: syllable.startTimeMs,
                endTimeMs: syllable.endTimeMs
            )
        }
        trimEmptySyllables(&syllables)
        return ParsedPart(
            text: normalizeDisplayText(part.text.regexReplacing("[()（）]", with: "")),
            syllables: syllables,
            hasTimedText: part.hasTimedText
        )
    }

    private static func createVocalPart(
        id: String,
        role: String,
        part: ParsedPart,
        speaker: SpeakerPresentation
    ) -> LyricsLine.VocalPart? {
        guard !part.text.isEmpty, !part.syllables.isEmpty else { return nil }
        return LyricsLine.VocalPart(
            id: id,
            role: role,
            speaker: speaker.speaker,
            speakerColor: speaker.color,
            speakerFallback: speaker.fallback,
            kind: "vocal",
            text: part.text,
            syllables: part.syllables
        )
    }

    private static func parseLrcLyrics(_ lrc: String, durationMs: Int64) -> ParsedLyrics {
        var offset: Int64 = 0
        var synced: [LrcLine] = []
        for rawLine in stripBom(lrc).components(separatedBy: .newlines) {
            let offsetMatch: [String]?
            if let lrcOffsetRegex {
                offsetMatch = firstRegexMatch(lrcOffsetRegex, in: rawLine)
            } else {
                offsetMatch = firstRegexMatch(lrcOffsetPattern, in: rawLine, options: .caseInsensitive)
            }
            if let match = offsetMatch,
               let parsedOffset = Int64(match[1]) {
                offset = parsedOffset
                continue
            }
            let isMetadataLine: Bool
            if let lrcMetadataRegex {
                let source = rawLine as NSString
                isMetadataLine = lrcMetadataRegex.firstMatch(
                    in: rawLine,
                    range: NSRange(location: 0, length: source.length)
                ) != nil
            } else {
                isMetadataLine = rawLine.range(
                    of: lrcMetadataPattern,
                    options: [.regularExpression, .caseInsensitive]
                ) != nil
            }
            if isMetadataLine {
                continue
            }
            let matches = lrcTimestampRegex.map { regexMatches($0, in: rawLine) }
                ?? regexMatches(lrcTimestampPattern, in: rawLine)
            guard !matches.isEmpty else { continue }
            let text: String
            if let lrcTimestampRegex {
                let source = rawLine as NSString
                text = lrcTimestampRegex.stringByReplacingMatches(
                    in: rawLine,
                    range: NSRange(location: 0, length: source.length),
                    withTemplate: ""
                ).trimmed
            } else {
                text = rawLine.regexReplacing(lrcTimestampPattern, with: "").trimmed
            }
            guard !text.isEmpty else { continue }
            for match in matches {
                synced.append(
                    LrcLine(
                        startTimeMs: max(0, parseLrcTimestamp(match) + offset),
                        text: text
                    )
                )
            }
        }
        synced.sort { $0.startTimeMs < $1.startTimeMs }
        guard !synced.isEmpty else { return parsePlainLyrics(lrc) }
        let lines = synced.enumerated().map { index, line in
            let end = index + 1 < synced.count
                ? synced[index + 1].startTimeMs
                : (durationMs > 0 ? durationMs : line.startTimeMs + 3000)
            return LyricsLine(
                startTimeMs: line.startTimeMs,
                endTimeMs: max(line.startTimeMs + 1, end),
                text: line.text
            )
        }
        return ParsedLyrics(lines: lines, karaoke: false, synced: true)
    }

    private static func parsePlainLyrics(_ plain: String) -> ParsedLyrics {
        let lines = stripBom(plain)
            .components(separatedBy: .newlines)
            .map(\.trimmed)
            .filter { !$0.isEmpty }
            .map { LyricsLine(startTimeMs: 0, endTimeMs: 0, text: $0) }
        return ParsedLyrics(lines: lines, karaoke: false, synced: false)
    }

    private static func parseTimeMs(_ value: String) -> Int64? {
        let input = value.trimmed
        guard !input.isEmpty else { return nil }
        let timeUnitMatch: [String]?
        if input.contains(":") {
            timeUnitMatch = nil
        } else if let regex = timeUnitRegex {
            let source = input as NSString
            timeUnitMatch = regex.matches(
                in: input,
                range: NSRange(location: 0, length: source.length)
            ).first.map { match in
                (0..<match.numberOfRanges).map { index in
                    let range = match.range(at: index)
                    return range.location == NSNotFound ? "" : source.substring(with: range)
                }
            }
        } else {
            timeUnitMatch = firstRegexMatch(timeUnitPattern, in: input, options: .caseInsensitive)
        }
        if let match = timeUnitMatch,
           let amount = Double(match[1]) {
            let multiplier: Double
            switch match[2].lowercased() {
            case "h": multiplier = 3_600_000
            case "m": multiplier = 60_000
            case "s": multiplier = 1000
            default: multiplier = 1
            }
            return Int64((amount * multiplier).rounded())
        }
        let components = input.split(separator: ":", omittingEmptySubsequences: false)
        let seconds: Double
        switch components.count {
        case 3:
            guard let hours = Double(components[0]),
                  let minutes = Double(components[1]),
                  let value = Double(components[2]) else { return nil }
            seconds = hours * 3600 + minutes * 60 + value
        case 2:
            guard let minutes = Double(components[0]),
                  let value = Double(components[1]) else { return nil }
            seconds = minutes * 60 + value
        case 1:
            guard let value = Double(components[0]) else { return nil }
            seconds = value
        default:
            return nil
        }
        return Int64((seconds * 1000).rounded())
    }

    private static func parseLrcTimestamp(_ match: [String]) -> Int64 {
        let minutes = Int64(match[safe: 1] ?? "") ?? 0
        let seconds = Int64(match[safe: 2] ?? "") ?? 0
        let fraction = match[safe: 3] ?? ""
        let fractionMs: Int64
        switch fraction.count {
        case 0: fractionMs = 0
        case 1: fractionMs = (Int64(fraction) ?? 0) * 100
        case 2: fractionMs = (Int64(fraction) ?? 0) * 10
        default: fractionMs = Int64(String(fraction.prefix(3))) ?? 0
        }
        return minutes * 60_000 + seconds * 1000 + fractionMs
    }

    private static func speakerPresentation(_ agentId: String, order: [String: Int]) -> SpeakerPresentation {
        guard !agentId.isEmpty else { return .empty }
        let index = max(0, order[agentId] ?? 0)
        if index == 0 {
            return SpeakerPresentation(speaker: "NORMAL", color: "", fallback: "")
        }
        return speakerPalette[(index - 1) % speakerPalette.count]
    }

    private static func addAgentIfNeeded(_ agentId: String, order: inout [String: Int]) {
        if !agentId.isEmpty, order[agentId] == nil {
            order[agentId] = order.count
        }
    }

    private static func artistCandidates(_ artistInput: String) -> [String] {
        let artist = artistInput.trimmed
        guard !artist.isEmpty else { return [] }
        guard let separator = artist.range(
            of: #"\s*(?:,|;|\bfeat\.?\b|\bfeaturing\b|\s&\s)\s*"#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return [artist]
        }
        let primary = String(artist[..<separator.lowerBound]).trimmed
        return primary.isEmpty || primary == artist ? [artist] : [artist, primary]
    }

    private static func isExactMetadataMatch(data: ResponseData, track: TrackSnapshot) -> Bool {
        guard normalizeMetadata(data.song) == normalizeMetadata(track.title) else { return false }
        let actualArtist = normalizeMetadata(data.artist)
        return !actualArtist.isEmpty && artistCandidates(track.artist).map(normalizeMetadata).contains(actualArtist)
    }

    private static func normalizeMetadata(_ value: String) -> String {
        value.nfkc()
            .lowercased()
            .regexReplacing(#"[^\p{L}\p{N}]+"#, with: " ")
            .trimmed
    }

    private static func declareMissingNamespaces(_ xml: String) -> String {
        guard let root = firstRegexMatchWithRange(#"<tt\b[^>]*>"#, in: xml, options: .caseInsensitive) else {
            return xml
        }
        var declared = Set(["xml", "xmlns"])
        for match in regexMatches(#"xmlns:([A-Za-z][\w.-]*)\s*="#, in: root.values[0]) {
            if match.count > 1 { declared.insert(match[1]) }
        }
        var used = Set<String>()
        for match in regexMatches(#"</?([A-Za-z][\w.-]*):"#, in: xml) where match.count > 1 {
            used.insert(match[1])
        }
        for match in regexMatches(#"\s([A-Za-z][\w.-]*):[\w.-]+\s*="#, in: xml) where match.count > 1 {
            used.insert(match[1])
        }
        let missing = used.subtracting(declared).sorted()
        guard !missing.isEmpty else { return xml }
        let declarations = missing.map { " xmlns:\($0)=\"urn:ivlyrics:unison:\($0)\"" }.joined()
        let replacement = String(root.values[0].dropLast()) + declarations + ">"
        return (xml as NSString).replacingCharacters(in: root.range, with: replacement)
    }

    private static func elements(named name: String, roots: [XMLNode]) -> [XMLNode] {
        var result: [XMLNode] = []
        func visit(_ node: XMLNode) {
            if localName(node.name) == name {
                result.append(node)
            }
            for child in childElements(node.contents) {
                visit(child)
            }
        }
        roots.forEach(visit)
        return result
    }

    private static func childElements(_ contents: [XMLContent]) -> [XMLNode] {
        contents.compactMap { content in
            if case .element(let node) = content { return node }
            return nil
        }
    }

    private static func attribute(_ node: XMLNode, _ local: String) -> String {
        if let direct = node.attributes[local], !direct.isEmpty {
            return direct
        }
        for (name, value) in node.attributes where localName(name) == local || name == local {
            return value
        }
        return ""
    }

    private static func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    private static func textContent(_ node: XMLNode) -> String {
        node.contents.map { content in
            switch content {
            case .text(let text): return text
            case .element(let child): return textContent(child)
            }
        }.joined()
    }

    private static func hasContentAfter(_ contents: [XMLContent], index: Int) -> Bool {
        guard index + 1 < contents.count else { return false }
        for content in contents[(index + 1)...] {
            switch content {
            case .text(let text) where !text.trimmed.isEmpty:
                return true
            case .element(let node) where !normalizeDisplayText(textContent(node)).isEmpty:
                return true
            default:
                continue
            }
        }
        return false
    }

    private static func normalizeInlineText(_ value: String) -> String {
        guard let regex = inlineWhitespaceRegex else {
            return value.regexReplacing(inlineWhitespacePattern, with: " ")
        }
        return regex.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..<value.endIndex, in: value),
            withTemplate: " "
        )
    }

    private static func normalizeDisplayText(_ value: String) -> String {
        normalizeInlineText(value).trimmed
    }

    private static func trimEmptySyllables(_ syllables: inout [LyricsLine.Syllable]) {
        while syllables.first?.text.trimmed.isEmpty == true {
            syllables.removeFirst()
        }
        while syllables.last?.text.trimmed.isEmpty == true {
            syllables.removeLast()
        }
    }

    private static func stripBom(_ value: String) -> String {
        value.first == "\u{FEFF}" ? String(value.dropFirst()) : value
    }

    private static func regexMatches(
        _ pattern: String,
        in value: String,
        options: NSRegularExpression.Options = []
    ) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        return regexMatches(regex, in: value)
    }

    private static func regexMatches(_ regex: NSRegularExpression, in value: String) -> [[String]] {
        let source = value as NSString
        return regex.matches(in: value, range: NSRange(location: 0, length: source.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
        }
    }

    private static func firstRegexMatch(
        _ pattern: String,
        in value: String,
        options: NSRegularExpression.Options = []
    ) -> [String]? {
        regexMatches(pattern, in: value, options: options).first
    }

    private static func firstRegexMatch(_ regex: NSRegularExpression, in value: String) -> [String]? {
        regexMatches(regex, in: value).first
    }

    private static func firstRegexMatchWithRange(
        _ pattern: String,
        in value: String,
        options: NSRegularExpression.Options = []
    ) -> RegexMatch? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let source = value as NSString
        guard let match = regex.firstMatch(in: value, range: NSRange(location: 0, length: source.length)) else { return nil }
        let values = (0..<match.numberOfRanges).map { index -> String in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : source.substring(with: range)
        }
        return RegexMatch(range: match.range, values: values)
    }

    private struct RequestAttempt {
        var url: URL
        var exactMetadataRequired: Bool
    }

    private struct ResponseData {
        var lyrics: String
        var format: String
        var song: String
        var artist: String

        init(json: [String: Any]) {
            lyrics = json["lyrics"] as? String ?? ""
            format = json["format"] as? String ?? ""
            song = json["song"] as? String ?? ""
            artist = json["artist"] as? String ?? ""
        }
    }

    private struct SpeakerPresentation {
        static let empty = SpeakerPresentation(speaker: "", color: "", fallback: "")

        var speaker: String
        var color: String
        var fallback: String
    }

    private struct ParsedPart {
        var text: String
        var syllables: [LyricsLine.Syllable]
        var hasTimedText: Bool
    }

    private struct TimedBuilder {
        var text = ""
        var syllables: [LyricsLine.Syllable] = []
        var fallbackStart: Int64
        var fallbackEnd: Int64
        var hasTimedText = false
    }

    private struct ParsedLine {
        var startTimeMs: Int64
        var endTimeMs: Int64
        var text: String
        var syllables: [LyricsLine.Syllable]
        var speaker: SpeakerPresentation
        var vocalParts: [LyricsLine.VocalPart]
        var hasWordTiming: Bool
    }

    private struct ParsedLyrics {
        var lines: [LyricsLine]
        var karaoke: Bool
        var synced: Bool
    }

    private struct LrcLine {
        var startTimeMs: Int64
        var text: String
    }

    private struct RegexMatch {
        var range: NSRange
        var values: [String]
    }

    private final class XMLNode {
        var name: String
        var attributes: [String: String]
        var contents: [XMLContent] = []

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }
    }

    private indirect enum XMLContent {
        case text(String)
        case element(XMLNode)
    }

    private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
        var roots: [XMLNode] = []
        private var stack: [XMLNode] = []

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let node = XMLNode(name: qName ?? elementName, attributes: attributeDict)
            if let parent = stack.last {
                parent.contents.append(.element(node))
            } else {
                roots.append(node)
            }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.contents.append(.text(string))
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            if !stack.isEmpty {
                stack.removeLast()
            }
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
