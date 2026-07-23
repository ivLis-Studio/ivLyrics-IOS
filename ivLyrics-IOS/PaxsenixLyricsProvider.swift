import Foundation

enum PaxsenixLyricsProvider {
    private static let cacheEntityRevision = "|paxsenix-entities-v1-ja-lines-v1"
    private static let encodedEndpoints = [
        "homepage": "aHR0cHM6Ly9seXJpY3MucGF4c2VuaXgub3Jn",
        "catalogSearch": "aHR0cHM6Ly9pdHVuZXMuYXBwbGUuY29tL3NlYXJjaA==",
        "structuredSearch": "aHR0cHM6Ly9seXJpY3MucGF4c2VuaXgub3JnL2t1Z291L3NlYXJjaA==",
        "structuredLyrics": "aHR0cHM6Ly9seXJpY3MucGF4c2VuaXgub3JnL2t1Z291L2x5cmljcw==",
        "catalogLyrics": "aHR0cHM6Ly9seXJpY3MucGF4c2VuaXgub3JnL2FwcGxlLW11c2ljL2x5cmljcw=="
    ]
    private static let encodedStructuredProviderId = "a3Vnb3U="
    private static let requestTimeout: TimeInterval = 12
    private static let japaneseLineSplitTriggerWidth = 22.0
    private static let japaneseLineSplitHardWidth = 26.0
    private static let japaneseLineSplitMinimumWidth = 6.0
    private static let japaneseLineSplitMinimumDurationMs: Int64 = 500
    private static let japaneseLineSplitMaximumSegments = 4
    private static let structuredReferenceLineRegex = try? NSRegularExpression(
        pattern: #"^\[(\d+),(\d+)\](.*)$"#
    )
    private static let structuredReferenceTokenRegex = try? NSRegularExpression(
        pattern: #"<\d+,\d+,\d+>"#
    )
    private static let referenceDoubleQuotePattern = #"[“”„‟]"#
    private static let referenceDoubleQuoteRegex = try? NSRegularExpression(
        pattern: referenceDoubleQuotePattern
    )
    private static let referenceSingleQuotePattern = #"[‘’‚‛]"#
    private static let referenceSingleQuoteRegex = try? NSRegularExpression(
        pattern: referenceSingleQuotePattern
    )
    private static let referenceWhitespacePattern = #"\s"#
    private static let referenceWhitespaceRegex = try? NSRegularExpression(
        pattern: referenceWhitespacePattern
    )
    private static let comparableApostrophePattern = #"[’‘`´]"#
    private static let comparableApostropheRegex = try? NSRegularExpression(
        pattern: comparableApostrophePattern
    )
    private static let comparableFeaturingPattern = #"\b(feat(?:uring)?|ft)\.?\b"#
    private static let comparableFeaturingRegex = try? NSRegularExpression(
        pattern: comparableFeaturingPattern,
        options: .caseInsensitive
    )
    private static let comparableNonAlphanumericPattern = #"[^\p{L}\p{N}]+"#
    private static let comparableNonAlphanumericRegex = try? NSRegularExpression(
        pattern: comparableNonAlphanumericPattern
    )
    private static let comparableWhitespacePattern = #"\s+"#
    private static let comparableWhitespaceRegex = try? NSRegularExpression(
        pattern: comparableWhitespacePattern
    )
    private static let titleDecorationPattern = #"\([^)]*\)|\[[^\]]*\]"#
    private static let titleDecorationRegex = try? NSRegularExpression(
        pattern: titleDecorationPattern
    )
    private static let titleVersionSuffixPattern = #"\s+-\s+(?:remaster(?:ed)?|live|version|edit|mix).*$"#
    private static let titleVersionSuffixRegex = try? NSRegularExpression(
        pattern: titleVersionSuffixPattern,
        options: .caseInsensitive
    )
    private static let lyricEntityPattern = #"&(?:#[xX][0-9A-Fa-f]+|#[0-9]+|[A-Za-z][A-Za-z0-9]+);"#
    private static let lyricEntityRegex = try? NSRegularExpression(pattern: lyricEntityPattern)
    private static let namedLyricEntities: [String: String] = [
        "amp": "&", "apos": "'", "quot": "\"", "lt": "<", "gt": ">"
    ]

    private struct JapaneseSplitSegmentKey: Hashable {
        let start: Int
        let end: Int
    }
#if DEBUG
    private static let lyricEntityRegressionChecks: Void = {
        assert(decodeLyricEntities("Don&apos;t stop") == "Don't stop")
        assert(decodeLyricEntities("R&B &amp; friends &#39;now&#x27;") == "R&B & friends 'now'")
        assert(decodeLyricEntities("&amp;apos;") == "&apos;")
        assert(decodeLyricEntities("keep &unknown; and &#xD800;") == "keep &unknown; and &#xD800;")

        let cached = LyricsResult(
            lines: [LyricsLine(startTimeMs: 0, endTimeMs: 1, text: "Don&apos;t &amp;apos;")],
            providerLabel: "Lyrically (Paxsenix)",
            detail: "",
            karaoke: false,
            providerId: "paxsenix",
            selectionPolicyKey: "provider-policy-v1"
        )
        assert(!canReuseCachedResult(cached))
        let marked = markEntitiesDecoded(in: cached)
        assert(canReuseCachedResult(marked))
        assert(marked.lines.first?.text == "Don&apos;t &amp;apos;")
        assert(markEntitiesDecoded(in: marked) == marked)

        let splitApostrophe = parseTimedTokens(
            [
                ["text": "Don", "part": false, "timestamp": 0, "endtime": 100],
                ["text": "&apos;", "part": false, "timestamp": 100, "endtime": 150],
                ["text": "t", "part": false, "timestamp": 150, "endtime": 200]
            ],
            fallbackStart: 0,
            fallbackEnd: 200,
            referenceText: nil
        )
        assert(splitApostrophe.map(\.text).joined() == "Don't")

        let longJapaneseLine = LyricsLine(
            startTimeMs: 26_115,
            endTimeMs: 34_353,
            text: "ドラマの中に迷い込んだ 結末を知らないアクター 君と僕との相関図が まだ空白で気になんだ",
            syllables: [
                LyricsLine.Syllable(text: "ドラマの中に迷い込ん", startTimeMs: 26_115, endTimeMs: 27_615),
                LyricsLine.Syllable(text: "だ ", startTimeMs: 27_615, endTimeMs: 27_997),
                LyricsLine.Syllable(text: "結末を知らないアク", startTimeMs: 28_137, endTimeMs: 29_758),
                LyricsLine.Syllable(text: "ター ", startTimeMs: 29_758, endTimeMs: 30_094),
                LyricsLine.Syllable(text: "君と僕との相関図が ", startTimeMs: 30_234, endTimeMs: 32_027),
                LyricsLine.Syllable(text: "まだ空白", startTimeMs: 32_180, endTimeMs: 33_005),
                LyricsLine.Syllable(text: "で気になん", startTimeMs: 33_207, endTimeMs: 33_903),
                LyricsLine.Syllable(text: "だ", startTimeMs: 33_903, endTimeMs: 34_353)
            ]
        )
        let splitJapanese = splitLongJapaneseLine(longJapaneseLine, previous: nil, next: nil)
        assert(splitJapanese.map(\.text) == [
            "ドラマの中に迷い込んだ 結末を知らないアクター",
            "君と僕との相関図が まだ空白で気になんだ"
        ])
        assert(splitJapanese.map(\.startTimeMs) == [26_115, 30_234])
        assert(splitJapanese.map(\.endTimeMs) == [30_094, 34_353])
    }()
#endif
    private static let speakerPalette: [(color: String, fallback: String)] = [
        ("#a8ccff", "MALE 1"),
        ("#ffb8c7", "FEMALE 1"),
        ("#e4d8ff", "DUET 1"),
        ("#9ae8d4", "MALE 2"),
        ("#ffd6b3", "FEMALE 2"),
        ("#d6e4ff", "DUET 2")
    ]
    private static let creditLabels: Set<String> = [
        "词", "詞", "作词", "作詞", "填词", "填詞", "词曲", "詞曲",
        "曲", "作曲", "编曲", "編曲", "弦编曲", "弦編曲", "弦乐编曲", "弦樂編曲",
        "lyrics", "lyric", "lyricsby", "lyricby", "lyricist",
        "composedby", "composer", "musicby", "arrangedby", "arranger", "stringsarrangedby",
        "producedby", "producer", "制作", "製作", "制作人", "製作人",
        "翻译", "翻譯", "translatedby", "歌手", "演唱", "原唱", "原曲", "录音", "錄音",
        "混音", "和声", "和聲", "vocal", "vocals", "vocalby", "vocalsby",
        "mixby", "mixedby", "mixingby", "masteredby", "masteringby"
    ]
    private static let noLyricsPlaceholders: Set<String> = [
        "纯音乐请欣赏", "纯音乐请您欣赏", "纯音乐敬请欣赏",
        "純音樂請欣賞", "純音樂請您欣賞",
        "此歌曲为没有填词的纯音乐请您欣赏", "此歌曲為沒有填詞的純音樂請您欣賞",
        "该歌曲为纯音乐请您欣赏", "該歌曲為純音樂請您欣賞",
        "暂无歌词", "暫無歌詞", "没有歌词", "沒有歌詞"
    ]

    static var projectURL: String {
#if DEBUG
        _ = lyricEntityRegressionChecks
#endif
        return endpoint("homepage") ?? ""
    }

    struct FetchOutcome: Sendable {
        var karaoke: [LyricsLine]?
        var synced: [LyricsLine]?
        var plain: [LyricsLine]?
        var sourceType: String
        var logs: [String]
    }

    private struct ParsedVariants: Sendable {
        var karaoke: [LyricsLine]?
        var synced: [LyricsLine]?
        var plain: [LyricsLine]?
    }

    private struct SearchCandidate {
        var id: String
        var title: String
        var artist: String
        var album: String
        var durationSeconds: Double
    }

    private struct PayloadCandidate: @unchecked Sendable {
        var source: String
        var payload: [String: Any]
    }

    private struct ParsedCandidate: Sendable {
        var source: String
        var parsed: ParsedVariants
    }

    private struct SpeakerPresentation {
        var speaker: String
        var color: String
        var fallback: String
    }

    static func fetch(track: TrackSnapshot) async throws -> FetchOutcome? {
        guard track.hasUsableMetadata else { return nil }

        async let structuredAttempt = fetchAttempt(source: "structured") {
            try await fetchStructuredCandidate(track: track)
        }
        async let catalogAttempt = fetchAttempt(source: "catalog") {
            try await fetchCatalogCandidate(track: track)
        }
        let attempts = await [structuredAttempt, catalogAttempt]
        var logs = attempts.flatMap(\.logs)
        let candidates = attempts.compactMap(\.candidate).compactMap { candidate -> ParsedCandidate? in
            guard let parsed = try? parsePayload(candidate.payload, durationMs: track.durationMs, track: track) else {
                return nil
            }
            return ParsedCandidate(source: candidate.source, parsed: parsed)
        }
        guard let best = candidates.max(by: { quality($0) < quality($1) }), quality(best) > 0 else {
            logs.append("paxsenix: no renderable lyrics")
            return nil
        }
        let type = best.parsed.karaoke?.isEmpty == false
            ? "karaoke"
            : (best.parsed.synced?.isEmpty == false ? "synced" : "plain")
        logs.append("paxsenix selected: source=\(best.source) / type=\(type)")
        return FetchOutcome(
            karaoke: best.parsed.karaoke,
            synced: best.parsed.synced,
            plain: best.parsed.plain,
            sourceType: best.source,
            logs: logs
        )
    }

    private struct FetchAttemptResult: @unchecked Sendable {
        var candidate: PayloadCandidate?
        var logs: [String]
    }

    private static func fetchAttempt(
        source: String,
        operation: @escaping @Sendable () async throws -> PayloadCandidate?
    ) async -> FetchAttemptResult {
        do {
            let candidate = try await operation()
            return FetchAttemptResult(
                candidate: candidate,
                logs: [candidate == nil ? "paxsenix \(source): no match" : "paxsenix \(source): matched"]
            )
        } catch {
            return FetchAttemptResult(candidate: nil, logs: ["paxsenix \(source): \(error.localizedDescription)"])
        }
    }

    private static func fetchStructuredCandidate(track: TrackSnapshot) async throws -> PayloadCandidate? {
        guard let base = endpoint("structuredSearch"),
              var search = URLComponents(string: base) else { throw URLError(.badURL) }
        search.queryItems = [URLQueryItem(name: "q", value: searchTerm(track))]
        guard let searchURL = search.url else { throw URLError(.badURL) }
        let object = try await fetchJson(searchURL)
        guard let rows = object as? [[String: Any]] else { return nil }
        let candidates = rows.map {
            SearchCandidate(
                id: string($0["hash"]),
                title: string($0["title"]),
                artist: string($0["artist"]),
                album: string($0["album"]),
                durationSeconds: double($0["duration"])
            )
        }
        guard let match = selectBestCandidate(candidates, track: track),
              let base = endpoint("structuredLyrics") else { return nil }
        for wordTiming in [false, true] {
            guard var lyrics = URLComponents(string: base) else { continue }
            lyrics.queryItems = [
                URLQueryItem(name: "id", value: match.id),
                URLQueryItem(name: "word", value: String(wordTiming)),
                URLQueryItem(name: "v", value: "2")
            ]
            guard let url = lyrics.url,
                  let payload = try await fetchJson(url) as? [String: Any],
                  (payload["lyrics"] as? [Any])?.isEmpty == false else { continue }
            return PayloadCandidate(source: "structured", payload: payload)
        }
        return nil
    }

    private static func fetchCatalogCandidate(track: TrackSnapshot) async throws -> PayloadCandidate? {
        guard let base = endpoint("catalogSearch"),
              var search = URLComponents(string: base) else { throw URLError(.badURL) }
        search.queryItems = [
            URLQueryItem(name: "term", value: searchTerm(track)),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "25")
        ]
        guard let searchURL = search.url,
              let root = try await fetchJson(searchURL) as? [String: Any],
              let rows = root["results"] as? [[String: Any]] else { return nil }
        let candidates = rows.map {
            SearchCandidate(
                id: string($0["trackId"]),
                title: string($0["trackName"]),
                artist: string($0["artistName"]),
                album: string($0["collectionName"]),
                durationSeconds: double($0["trackTimeMillis"]) / 1000
            )
        }
        guard let match = selectBestCandidate(candidates, track: track),
              let base = endpoint("catalogLyrics"),
              var lyrics = URLComponents(string: base) else { return nil }
        lyrics.queryItems = [
            URLQueryItem(name: "id", value: match.id),
            URLQueryItem(name: "v", value: "2")
        ]
        guard let url = lyrics.url,
              let payload = try await fetchJson(url) as? [String: Any] else { return nil }
        return PayloadCandidate(source: "catalog", payload: payload)
    }

    private static func fetchJson(_ url: URL) async throws -> Any {
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ivLyrics-iOS/1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.ivLyricsData(for: request)
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func parsePayload(
        _ payload: [String: Any],
        durationMs: Int64,
        track: TrackSnapshot
    ) throws -> ParsedVariants? {
#if DEBUG
        _ = lyricEntityRegressionChecks
#endif
        if isTargetStructuredPayload(payload),
           let structured = parseStructuredLyrics(payload, requestedDurationMs: durationMs, track: track) {
            return structured
        }
        if isTargetStructuredPayload(payload), payload["lyrics"] is [Any] {
            return nil
        }
        if let ttml = payload["ttmlContent"] as? String, !ttml.trimmed.isEmpty {
            let parsed = try UnisonLyricsProvider.parseExternalLyrics(ttml, format: "ttml", durationMs: durationMs)
            return variants(from: parsed)
        }
        if let lrc = payload["lrc"] as? String, !lrc.trimmed.isEmpty {
            let parsed = try UnisonLyricsProvider.parseExternalLyrics(
                decodeLyricEntities(lrc),
                format: "lrc",
                durationMs: durationMs
            )
            return variants(from: parsed)
        }
        let plain = string(payload["plain"]).trimmed.isEmpty
            ? string(payload["lyrics"])
            : string(payload["plain"])
        let parsed = try UnisonLyricsProvider.parseExternalLyrics(
            decodeLyricEntities(plain),
            format: "plain",
            durationMs: durationMs
        )
        return variants(from: parsed)
    }

    private static func variants(from parsed: UnisonLyricsProvider.ExternalParsedLyrics) -> ParsedVariants? {
        guard !parsed.lines.isEmpty else { return nil }
        let plain = parsed.lines.map {
            LyricsLine(startTimeMs: 0, endTimeMs: 0, text: $0.text)
        }
        if parsed.karaoke {
            let karaoke = CrossLineVocalNormalizer.normalize(parsed.lines)
            let synced = karaoke.map(demoteSynced)
            return ParsedVariants(karaoke: karaoke, synced: synced, plain: plain)
        }
        return ParsedVariants(
            karaoke: nil,
            synced: parsed.synced ? parsed.lines.map(demoteSynced) : nil,
            plain: plain
        )
    }

    private static func parseStructuredLyrics(
        _ payload: [String: Any],
        requestedDurationMs: Int64,
        track: TrackSnapshot
    ) -> ParsedVariants? {
        guard let allLines = payload["lyrics"] as? [[String: Any]], !allLines.isEmpty else {
            return nil
        }
        let references = parseStructuredReferenceLines(payload)
        let metadataIndexes = leadingMetadataLineIndexes(
            payload: payload,
            track: track,
            references: references
        )
        let rawLines = allLines.enumerated().compactMap { offset, line in
            metadataIndexes.contains(offset) ? nil : line
        }
        guard !rawLines.isEmpty else { return nil }
        if rawLines.count <= 3, rawLines.allSatisfy({ line in
            guard structuredBackgroundText(line).isEmpty else { return false }
            let start = lineStartTime(line)
            return isNoLyricsPlaceholder(structuredLineText(line, reference: references[start]))
        }) {
            return nil
        }

        let metadata = payload["metadata"] as? [String: Any]
        let metadataDuration = milliseconds(metadata?["duration"]) ?? 0
        let durationMs = requestedDurationMs > 0 ? requestedDurationMs : metadataDuration
        var agentOrder: [String: Int] = [:]
        if let agents = metadata?["agents"] as? [[String: Any]] {
            for agent in agents {
                let id = string(agent["id"]).trimmed
                if !id.isEmpty, agentOrder[id] == nil {
                    agentOrder[id] = agentOrder.count
                }
            }
        }
        for line in rawLines {
            let agent = string(line["agent"]).trimmed
            if !agent.isEmpty, agentOrder[agent] == nil {
                agentOrder[agent] = agentOrder.count
            }
        }

        let starts = rawLines.map(lineStartTime)
        let hasSyllableSync = string(payload["syncType"]).lowercased() == "syllable"
        var karaokeLines: [LyricsLine] = []
        karaokeLines.reserveCapacity(rawLines.count)
        for (index, rawLine) in rawLines.enumerated() {
            let start = starts[index]
            let nextStart = index + 1 < starts.count ? starts[index + 1] : nil
            let rawTextItems = rawLine["text"] as? [[String: Any]] ?? []
            var end = milliseconds(rawLine["endtime"])
                ?? milliseconds(rawTextItems.last?["endtime"])
                ?? nextStart
                ?? (start + 3000)
            if durationMs > 0 { end = min(end, durationMs) }
            if let nextStart, end > nextStart + 15_000 { end = nextStart }
            end = max(start + 1, end)

            let presentation = speakerPresentation(rawLine, agentOrder: agentOrder)
            let leadSyllables = parseTimedTokens(
                rawTextItems,
                fallbackStart: start,
                fallbackEnd: end,
                referenceText: references[start]
            ).map { clamp($0, end: end) }
            let backgroundSyllables = parseTimedTokens(
                rawLine["backgroundText"] as? [[String: Any]] ?? [],
                fallbackStart: start,
                fallbackEnd: end,
                referenceText: nil
            ).map { clamp($0, end: end) }
            let rawLeadText = rawLine["text"] is String
                ? decodeLyricEntities(string(rawLine["text"])).trimmed
                : ""
            let leadText = IvLyricsUtilities.firstNonEmpty(
                leadSyllables.map { $0.text }.joined().trimmed,
                rawLeadText
            )
            let backgroundText = backgroundSyllables.map { $0.text }.joined().trimmed
            guard !leadText.isEmpty || !backgroundText.isEmpty else { continue }

            let key = IvLyricsUtilities.firstNonEmpty(string(rawLine["key"]), "line-\(index + 1)")
            let leadPart = makeVocalPart(
                id: "\(key)-lead",
                role: "lead",
                syllables: leadSyllables,
                presentation: presentation
            )
            let backgroundPart = makeVocalPart(
                id: "\(key)-background-1",
                role: "background",
                syllables: backgroundSyllables,
                presentation: presentation
            )
            let displayText = [leadText, backgroundText].filter { !$0.isEmpty }.joined(separator: " ")
            var lineSyllables: [LyricsLine.Syllable] = []
            var vocalParts: [LyricsLine.VocalPart] = []
            if hasSyllableSync {
                if let leadPart, let backgroundPart {
                    vocalParts = [leadPart, backgroundPart]
                } else if let leadPart {
                    lineSyllables = leadPart.syllables
                } else if let backgroundPart {
                    lineSyllables = backgroundPart.syllables
                }
            }
            let resolvedStart = vocalParts.map(\.startTimeMs).min() ?? lineSyllables.first?.startTimeMs ?? start
            let resolvedEnd = max(
                resolvedStart + 1,
                vocalParts.map(\.endTimeMs).max() ?? lineSyllables.last?.endTimeMs ?? end
            )
            karaokeLines.append(
                LyricsLine(
                    startTimeMs: resolvedStart,
                    endTimeMs: resolvedEnd,
                    text: displayText,
                    syllables: lineSyllables,
                    speaker: presentation.speaker,
                    speakerColor: presentation.color,
                    speakerFallback: presentation.fallback,
                    kind: "vocal",
                    vocalParts: vocalParts
                )
            )
        }
        karaokeLines.sort { $0.startTimeMs < $1.startTimeMs }
        guard !karaokeLines.isEmpty else { return nil }
        let displayLines = hasSyllableSync && isJapanesePayload(payload)
            ? splitLongJapaneseLines(karaokeLines)
            : karaokeLines

        let karaoke = hasSyllableSync
            && displayLines.contains(where: { !$0.syllables.isEmpty || !$0.vocalParts.isEmpty })
            ? CrossLineVocalNormalizer.normalize(displayLines)
            : nil
        let synced = string(payload["syncType"]).lowercased() == "none"
            ? nil
            : displayLines.map(demoteSynced)
        let plain = displayLines.map {
            LyricsLine(startTimeMs: 0, endTimeMs: 0, text: $0.text)
        }
        return ParsedVariants(karaoke: karaoke, synced: synced, plain: plain)
    }

    private static func isJapanesePayload(_ payload: [String: Any]) -> Bool {
        let metadata = payload["metadata"] as? [String: Any]
        return [
            string(metadata?["language"]),
            string(metadata?["languageTag"]),
            string(payload["language"]),
            string(payload["languageTag"])
        ].contains(where: isJapaneseLanguageTag)
    }

    private static func isJapaneseLanguageTag(_ value: String) -> Bool {
        let tag = value.trimmed.lowercased()
        return tag == "ja" || tag.hasPrefix("ja-") || tag.hasPrefix("ja_")
    }

    private static func splitLongJapaneseLines(_ lines: [LyricsLine]) -> [LyricsLine] {
        lines.enumerated().flatMap { index, line in
            let previous = index > 0 ? lines[index - 1] : nil
            let next = index + 1 < lines.count ? lines[index + 1] : nil
            return splitLongJapaneseLine(line, previous: previous, next: next)
        }
    }

    private static func splitLongJapaneseLine(
        _ line: LyricsLine,
        previous: LyricsLine?,
        next: LyricsLine?
    ) -> [LyricsLine] {
        let syllables = line.syllables
        guard line.vocalParts.isEmpty,
              syllables.count >= 2 else {
            return [line]
        }

        for index in syllables.indices {
            let syllable = syllables[index]
            guard !normalizeJapaneseSplitText(syllable.text).isEmpty,
                  syllable.endTimeMs >= syllable.startTimeMs,
                  measureJapaneseLyricsWidth(syllable.text) <= japaneseLineSplitHardWidth else {
                return [line]
            }
            if index > 0 {
                let prior = syllables[index - 1]
                guard syllable.startTimeMs > prior.startTimeMs,
                      syllable.startTimeMs >= prior.endTimeMs else {
                    return [line]
                }
            }
        }

        guard let first = syllables.first,
              let last = syllables.last,
              previous == nil || previous!.endTimeMs <= first.startTimeMs,
              next == nil || next!.startTimeMs >= last.endTimeMs else {
            return [line]
        }

        let normalizedLineText = normalizeJapaneseSplitText(line.text)
        let normalizedSyllableText = normalizeJapaneseSplitText(syllables.map(\.text).joined())
        let lineWidth = measureJapaneseLyricsWidth(normalizedLineText)
        guard !normalizedLineText.isEmpty,
              normalizedLineText == normalizedSyllableText,
              lineWidth > japaneseLineSplitTriggerWidth else {
            return [line]
        }

        var boundaryGaps: [Int: Int64] = [:]
        let candidates = (1..<syllables.count).filter { boundary in
            let left = syllables[boundary - 1]
            let right = syllables[boundary]
            guard left.endTimeMs <= right.startTimeMs,
                  endsWithJapaneseSplitWhitespace(left.text)
                    || startsWithJapaneseSplitWhitespace(right.text) else {
                return false
            }
            boundaryGaps[boundary] = max(0, right.startTimeMs - left.endTimeMs)
            return true
        }
        guard !candidates.isEmpty else { return [line] }

        let minimumCount = max(2, Int(ceil(lineWidth / japaneseLineSplitHardWidth)))
        let maximumCount = min(
            japaneseLineSplitMaximumSegments,
            min(candidates.count + 1, syllables.count)
        )
        guard minimumCount <= maximumCount else { return [line] }

        var bestBoundaries: [Int]?
        var bestScore = Double.greatestFiniteMagnitude
        var segmentMetrics: [JapaneseSplitSegmentKey: (width: Double, duration: Int64)] = [:]
        for segmentCount in minimumCount...maximumCount {
            var chosen: [Int] = []
            chooseJapaneseSplitBoundaries(
                candidates: candidates,
                needed: segmentCount - 1,
                cursor: 0,
                chosen: &chosen
            ) { boundaries in
                let points = [0] + boundaries + [syllables.count]
                let targetWidth = lineWidth / Double(segmentCount)
                var score = 0.0
                for segment in 0..<segmentCount {
                    let start = points[segment]
                    let end = points[segment + 1]
                    let key = JapaneseSplitSegmentKey(start: start, end: end)
                    let metrics: (width: Double, duration: Int64)
                    if let cached = segmentMetrics[key] {
                        metrics = cached
                    } else {
                        let slice = Array(syllables[start..<end])
                        metrics = (
                            width: measureJapaneseLyricsWidth(slice.map(\.text).joined()),
                            duration: (slice.last?.endTimeMs ?? 0) - (slice.first?.startTimeMs ?? 0)
                        )
                        segmentMetrics[key] = metrics
                    }
                    guard metrics.width >= japaneseLineSplitMinimumWidth,
                          metrics.width <= japaneseLineSplitHardWidth,
                          metrics.duration >= japaneseLineSplitMinimumDurationMs else {
                        return
                    }
                    score += pow(metrics.width - targetWidth, 2)
                    if segment < segmentCount - 1,
                       let gap = boundaryGaps[points[segment + 1]] {
                        score -= min(Double(gap) / 200.0, 1.0)
                    }
                }
                if score < bestScore {
                    bestScore = score
                    bestBoundaries = boundaries
                }
            }
            if bestBoundaries != nil { break }
        }
        guard let bestBoundaries else { return [line] }

        let points = [0] + bestBoundaries + [syllables.count]
        let fragments = (0..<(points.count - 1)).map { index in
            let slice = Array(syllables[points[index]..<points[index + 1]])
            return LyricsLine(
                startTimeMs: index == 0
                    ? min(line.startTimeMs, slice[0].startTimeMs)
                    : slice[0].startTimeMs,
                endTimeMs: index == points.count - 2
                    ? max(line.endTimeMs, slice.last!.endTimeMs)
                    : slice.last!.endTimeMs,
                text: trimJapaneseSplitWhitespace(slice.map(\.text).joined()),
                syllables: slice,
                speaker: line.speaker,
                speakerColor: line.speakerColor,
                speakerFallback: line.speakerFallback,
                kind: line.kind,
                pronunciationText: line.pronunciationText,
                translationText: line.translationText,
                furiganaText: line.furiganaText
            )
        }

        guard fragments.reduce(0, { $0 + $1.syllables.count }) == syllables.count,
              normalizeJapaneseSplitText(fragments.map(\.text).joined(separator: " "))
                == normalizedLineText else {
            return [line]
        }
        for index in fragments.indices where index > 0 {
            guard fragments[index - 1].endTimeMs <= fragments[index].startTimeMs else {
                return [line]
            }
        }
        return fragments
    }

    private static func chooseJapaneseSplitBoundaries(
        candidates: [Int],
        needed: Int,
        cursor: Int,
        chosen: inout [Int],
        visit: ([Int]) -> Void
    ) {
        if chosen.count == needed {
            visit(chosen)
            return
        }
        guard cursor < candidates.count,
              candidates.count - cursor >= needed - chosen.count else {
            return
        }
        for index in cursor..<candidates.count {
            chosen.append(candidates[index])
            chooseJapaneseSplitBoundaries(
                candidates: candidates,
                needed: needed,
                cursor: index + 1,
                chosen: &chosen,
                visit: visit
            )
            chosen.removeLast()
        }
    }

    private static func normalizeJapaneseSplitText(_ value: String) -> String {
        var result = ""
        var pendingSpace = false
        for character in value {
            if isJapaneseSplitWhitespace(character) {
                pendingSpace = !result.isEmpty
                continue
            }
            if pendingSpace {
                result.append(" ")
                pendingSpace = false
            }
            result.append(character)
        }
        return result
    }

    private static func trimJapaneseSplitWhitespace(_ value: String) -> String {
        String(
            value
                .drop(while: isJapaneseSplitWhitespace)
                .reversed()
                .drop(while: isJapaneseSplitWhitespace)
                .reversed()
        )
    }

    private static func startsWithJapaneseSplitWhitespace(_ value: String) -> Bool {
        value.first.map(isJapaneseSplitWhitespace) == true
    }

    private static func endsWithJapaneseSplitWhitespace(_ value: String) -> Bool {
        value.last.map(isJapaneseSplitWhitespace) == true
    }

    private static func isJapaneseSplitWhitespace(_ character: Character) -> Bool {
        character.isWhitespace || character.unicodeScalars.contains { $0.value == 0x3000 }
    }

    private static func measureJapaneseLyricsWidth(_ text: String) -> Double {
        text.reduce(0) { total, character in
            if character.unicodeScalars.allSatisfy({ CharacterSet.nonBaseCharacters.contains($0) }) {
                return total
            }
            if isJapaneseSplitWhitespace(character) { return total + 0.33 }
            if isFullWidthLyricsCharacter(character) { return total + 1.0 }
            if isASCII(character, range: 65...90) { return total + 0.72 }
            if isASCII(character, range: 97...122) { return total + 0.58 }
            if character.isNumber { return total + 0.62 }
            if ".,'’!?;:()-".contains(character) { return total + 0.38 }
            return total + 0.8
        }
    }

    private static func isASCII(_ character: Character, range: ClosedRange<UInt32>) -> Bool {
        character.unicodeScalars.count == 1
            && character.unicodeScalars.first.map { range.contains($0.value) } == true
    }

    private static func isFullWidthLyricsCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x3040...0x30ff).contains(value)
                || (0x3400...0x9fff).contains(value)
                || (0xac00...0xd7af).contains(value)
                || (0xf900...0xfaff).contains(value)
                || (0x1f000...0x1faff).contains(value)
        }
    }

    private static func parseTimedTokens(
        _ items: [[String: Any]],
        fallbackStart: Int64,
        fallbackEnd: Int64,
        referenceText: String?
    ) -> [LyricsLine.Syllable] {
        guard !items.isEmpty else { return [] }
        let referenceBoundaries = referenceWhitespaceBoundaries(items: items, referenceText: referenceText)
        var consumedCharacters = 0
        return items.enumerated().compactMap { index, item -> LyricsLine.Syllable? in
            var text = decodeLyricEntities(string(item["text"]))
            guard !text.isEmpty else { return nil }
            if let referenceBoundaries {
                text = text.trimmed
                consumedCharacters += normalizeReferenceSpacingCharacters(text).count
                if index + 1 < items.count, referenceBoundaries.contains(consumedCharacters) {
                    text += " "
                }
            } else if shouldAppendBoundary(
                item: item,
                next: index + 1 < items.count ? items[index + 1] : nil,
                text: text
            ) {
                text += " "
            }
            let start = milliseconds(item["timestamp"]) ?? fallbackStart
            let nextStart = index + 1 < items.count ? milliseconds(items[index + 1]["timestamp"]) : nil
            let end = milliseconds(item["endtime"]) ?? nextStart ?? fallbackEnd
            return LyricsLine.Syllable(text: text, startTimeMs: start, endTimeMs: max(start + 1, end))
        }
    }

    private static func referenceWhitespaceBoundaries(
        items: [[String: Any]],
        referenceText: String?
    ) -> Set<Int>? {
        guard let referenceText, !referenceText.isEmpty else { return nil }
        let decodedReferenceText = decodeLyricEntities(referenceText)
        let compactTokens = items.map {
            normalizeReferenceSpacingCharacters(decodeLyricEntities(string($0["text"])))
        }
        guard compactTokens.allSatisfy({ !$0.isEmpty }),
              compactTokens.joined() == normalizeReferenceSpacingCharacters(decodedReferenceText) else {
            return nil
        }
        var boundaries = Set<Int>()
        var characterCount = 0
        var inWhitespace = false
        for character in decodedReferenceText {
            if character.isWhitespace {
                if !inWhitespace, characterCount > 0 { boundaries.insert(characterCount) }
                inWhitespace = true
            } else {
                inWhitespace = false
                characterCount += normalizeReferenceSpacingCharacters(String(character)).count
            }
        }
        return boundaries
    }

    private static func shouldAppendBoundary(
        item: [String: Any],
        next: [String: Any]?,
        text: String
    ) -> Bool {
        guard let next,
              (item["part"] as? Bool) == false,
              text.last?.isWhitespace != true else { return false }
        let nextText = decodeLyricEntities(string(next["text"]))
        guard let first = nextText.first,
              !first.isWhitespace,
              !",.;:!?%)]}'’‘".contains(first),
              let last = text.last,
              !"-‐‑‒–—'’".contains(last) else { return false }
        return true
    }

    private static func makeVocalPart(
        id: String,
        role: String,
        syllables: [LyricsLine.Syllable],
        presentation: SpeakerPresentation
    ) -> LyricsLine.VocalPart? {
        let text = syllables.map(\.text).joined().trimmed
        guard !syllables.isEmpty, !text.isEmpty else { return nil }
        return LyricsLine.VocalPart(
            id: id,
            role: role,
            speaker: presentation.speaker,
            speakerColor: presentation.color,
            speakerFallback: presentation.fallback,
            kind: "vocal",
            text: text,
            syllables: syllables
        )
    }

    private static func clamp(_ syllable: LyricsLine.Syllable, end: Int64) -> LyricsLine.Syllable {
        LyricsLine.Syllable(
            text: syllable.text,
            startTimeMs: syllable.startTimeMs,
            endTimeMs: min(max(syllable.startTimeMs + 1, syllable.endTimeMs), end)
        )
    }

    private static func demoteSynced(_ line: LyricsLine) -> LyricsLine {
        LyricsLine(
            startTimeMs: line.startTimeMs,
            endTimeMs: line.endTimeMs,
            text: line.text,
            speaker: line.speaker,
            speakerColor: line.speakerColor,
            speakerFallback: line.speakerFallback,
            kind: line.kind
        )
    }

    private static func speakerPresentation(
        _ line: [String: Any],
        agentOrder: [String: Int]
    ) -> SpeakerPresentation {
        let agent = string(line["agent"]).trimmed
        let oppositeTurn = line["oppositeTurn"] as? Bool ?? false
        let index = agentOrder[agent] ?? (oppositeTurn ? 1 : 0)
        guard index > 0 else {
            return SpeakerPresentation(speaker: "NORMAL", color: "", fallback: "")
        }
        let palette = speakerPalette[(index - 1) % speakerPalette.count]
        return SpeakerPresentation(speaker: "CUSTOM", color: palette.color, fallback: palette.fallback)
    }

    private static func parseStructuredReferenceLines(_ payload: [String: Any]) -> [Int64: String] {
        let metadata = payload["metadata"] as? [String: Any]
        let metadataRaw = metadata?["rawData"] as? [String: Any]
        let rootRaw = payload["rawData"] as? [String: Any]
        let source = IvLyricsUtilities.firstNonEmpty(
            string(metadataRaw?["lyrics_text"]),
            string(rootRaw?["lyrics_text"])
        )
        guard !source.isEmpty,
              let regex = structuredReferenceLineRegex else {
            return [:]
        }
        var result: [Int64: String] = [:]
        for rawLine in source.components(separatedBy: .newlines) {
            let ns = rawLine as NSString
            guard let match = regex.firstMatch(
                in: rawLine,
                range: NSRange(location: 0, length: ns.length)
            ), match.numberOfRanges >= 4 else { continue }
            let timestamp = Int64(ns.substring(with: match.range(at: 1)))
            let rawText = ns.substring(with: match.range(at: 3))
            let text: String
            if let tokenRegex = structuredReferenceTokenRegex {
                text = tokenRegex.stringByReplacingMatches(
                    in: rawText,
                    range: NSRange(location: 0, length: (rawText as NSString).length),
                    withTemplate: ""
                )
            } else {
                text = rawText.regexReplacing(#"<\d+,\d+,\d+>"#, with: "")
            }
            if let timestamp { result[timestamp] = text }
        }
        return result
    }

    private static func leadingMetadataLineIndexes(
        payload: [String: Any],
        track: TrackSnapshot,
        references: [Int64: String]
    ) -> Set<Int> {
        guard isTargetStructuredPayload(payload),
              let lines = payload["lyrics"] as? [[String: Any]],
              !lines.isEmpty else { return [] }
        let earlyCreditIndexes = leadingIndexesThroughEarlyCredit(
            lines: lines,
            references: references
        )
        var result = Set<Int>()
        var hasStrongAnchor = false
        var acceptsCreditContinuation = false
        var previousMetadataStart: Int64?
        for index in 0..<lines.count {
            let line = lines[index]
            let start = lineStartTime(line)
            let text = structuredLineText(line, reference: references[start])
            let isTitleHeader = index == 0 && isTitleArtistHeader(text, track: track)
            let isEarlyCreditPrefix = earlyCreditIndexes.contains(index)
            let isCredit = isCreditMetadataText(text)
            let isCopyright = hasStrongAnchor && isCopyrightMetadataText(text)
            let isCreditContinuation = acceptsCreditContinuation
                && isNearPreviousMetadataLine(start, previous: previousMetadataStart)
                && isCreditContinuationText(text)
            guard isTitleHeader
                    || isEarlyCreditPrefix
                    || isCredit
                    || isCreditContinuation
                    || isCopyright else { break }
            if isTitleHeader || isEarlyCreditPrefix || isCredit { hasStrongAnchor = true }
            acceptsCreditContinuation = isCredit || isCreditContinuation
            previousMetadataStart = start
            result.insert(index)
        }
        return result
    }

    private static func leadingIndexesThroughEarlyCredit(
        lines: [[String: Any]],
        references: [Int64: String]
    ) -> Set<Int> {
        let earlyLimit = min(lines.count, 10)
        guard earlyLimit > 0,
              let creditIndex = (0..<earlyLimit).first(where: { index in
                  let start = lineStartTime(lines[index])
                  return isCreditMetadataText(
                      structuredLineText(lines[index], reference: references[start])
                  )
              }) else {
            return []
        }
        return Set(0...creditIndex)
    }

    private static func isDashSeparatedHeaderLike(_ text: String) -> Bool {
        let normalized = text.nfkc().trimmed
        guard (3...220).contains(normalized.count) else { return false }
        let separators = CharacterSet(charactersIn: "-‐‑‒–—")
        for scalarIndex in normalized.unicodeScalars.indices
        where separators.contains(normalized.unicodeScalars[scalarIndex]) {
            let separatorIndex = scalarIndex.samePosition(in: normalized) ?? normalized.startIndex
            let next = normalized.index(after: separatorIndex)
            let title = String(normalized[..<separatorIndex]).trimmed
            let contributors = String(normalized[next...]).trimmed
            guard !title.isEmpty,
                  title.count <= 140,
                  title.range(of: #"[\p{L}\p{N}]"#, options: .regularExpression) != nil else {
                continue
            }
            if isContributorNameList(contributors) { return true }
        }
        return false
    }

    private static func isNearPreviousMetadataLine(_ start: Int64, previous: Int64?) -> Bool {
        guard let previous, start > 0, previous > 0 else { return true }
        return start >= previous && start - previous <= 8_000
    }

    private static func isCreditContinuationText(_ text: String) -> Bool {
        let normalized = text.nfkc().trimmed
        guard normalized.count <= 180,
              normalized.range(of: #"[:：!?！？。]"#, options: .regularExpression) == nil else {
            return false
        }
        let names = normalized
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).trimmed }
        guard names.count >= 2,
              names.count <= 8,
              names.allSatisfy({ isLikelyPersonOrGroupName($0) }) else {
            return false
        }
        return true
    }

    private static func isLikelyPersonOrGroupName(_ value: String) -> Bool {
        guard (2...64).contains(value.count),
              value.range(
                of: #"^[\p{L}\p{M}\p{N}\s.'’&()_-]+$"#,
                options: .regularExpression
              ) != nil else {
            return false
        }
        let words = value.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty, words.count <= 6 else { return false }
        let lowercaseConnectors: Set<String> = ["and", "de", "del", "la", "le", "of", "the", "van", "von"]
        return words.allSatisfy { rawWord in
            let word = String(rawWord).trimmingCharacters(in: .punctuationCharacters)
            guard let firstLetter = word.first(where: { $0.isLetter }) else { return false }
            let first = String(firstLetter)
            let isCased = first.lowercased() != first.uppercased()
            return !isCased || first == first.uppercased() || lowercaseConnectors.contains(word.lowercased())
        }
    }

    private static func isTitleArtistHeader(_ text: String, track: TrackSnapshot) -> Bool {
        let expectedTitle = normalizeMetadataIdentity(track.title)
        guard !expectedTitle.isEmpty else { return false }
        let expectedArtist = normalizeMetadataIdentity(track.artist)
        let separators = CharacterSet(charactersIn: "-‐‑‒–—")
        for scalarIndex in text.unicodeScalars.indices where separators.contains(text.unicodeScalars[scalarIndex]) {
            let separatorIndex = scalarIndex.samePosition(in: text) ?? text.startIndex
            let next = text.index(after: separatorIndex)
            let left = normalizeMetadataIdentity(String(text[..<separatorIndex]))
            let right = normalizeMetadataIdentity(String(text[next...]))
            guard !left.isEmpty, !right.isEmpty else { continue }
            if left == expectedTitle { return true }
            let artistMatches = expectedArtist.isEmpty
                || left == expectedArtist
                || left.contains(expectedArtist)
                || expectedArtist.contains(left)
            if right == expectedTitle, artistMatches { return true }
        }
        return false
    }

    private static func isCreditMetadataText(_ text: String) -> Bool {
        creditMetadataParts(text) != nil
    }

    private static func isStrongCreditMetadataText(_ text: String) -> Bool {
        guard let parts = creditMetadataParts(text) else { return false }
        return isContributorNameList(parts.value)
    }

    private static func creditMetadataParts(_ text: String) -> (label: String, value: String)? {
        let normalized = text.nfkc().trimmed
        guard let separator = normalized.firstIndex(where: { $0 == ":" || $0 == "：" }),
              separator != normalized.startIndex,
              !String(normalized[normalized.index(after: separator)...]).trimmed.isEmpty else { return nil }
        let label = String(normalized[..<separator])
            .lowercased()
            .regexReplacing(#"[\s._-]+"#, with: "")
        guard creditLabels.contains(label) else { return nil }
        return (
            label: label,
            value: String(normalized[normalized.index(after: separator)...]).trimmed
        )
    }

    private static func isContributorNameList(_ value: String) -> Bool {
        let names = value.nfkc()
            .components(separatedBy: CharacterSet(charactersIn: "/／⁄,，、"))
            .map(\.trimmed)
        return !names.isEmpty && names.allSatisfy(isContributorNameSegment)
    }

    private static func isContributorNameSegment(_ value: String) -> Bool {
        guard (1...64).contains(value.count),
              value.range(of: #"[\p{L}\p{N}]"#, options: .regularExpression) != nil,
              value.range(
                of: #"^[\p{L}\p{M}\p{N}\s.'’‘`´,&+()\-·・]+$"#,
                options: .regularExpression
              ) != nil else {
            return false
        }
        if value.range(
            of: #"[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        let connectors: Set<String> = [
            "and", "de", "del", "der", "di", "du", "la", "le", "of", "the", "van", "von", "y"
        ]
        let words = value
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= 6 else { return false }
        let significantWords = words.filter { !connectors.contains($0.lowercased()) }
        guard !significantWords.isEmpty else { return false }
        return significantWords.contains { word in
            guard let firstLetter = word.first(where: { $0.isLetter }) else {
                return word.allSatisfy(\.isNumber)
            }
            let first = String(firstLetter)
            let startsWithUppercase = first == first.uppercased() && first != first.lowercased()
            let casedLetters = word.filter { character in
                character.isLetter && character.lowercased() != character.uppercased()
            }
            let isMixedCaseAlias = casedLetters.contains(where: \.isLowercase)
                && casedLetters.contains(where: \.isUppercase)
            return startsWithUppercase || isMixedCaseAlias
        }
    }

    private static func isCopyrightMetadataText(_ text: String) -> Bool {
        text.nfkc().trimmed.range(
            of: #"^(?:©|℗|ⓒ|\(c\)|\(p\)|copyright\b)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func isNoLyricsPlaceholder(_ text: String) -> Bool {
        let normalized = text.nfkc()
            .lowercased()
            .regexReplacing(#"[\p{P}\p{S}\s]+"#, with: "")
        return noLyricsPlaceholders.contains(normalized)
    }

    private static func isTargetStructuredPayload(_ payload: [String: Any]) -> Bool {
        if string(payload["provider"]).lowercased() == decodeBase64(encodedStructuredProviderId)?.lowercased() {
            return true
        }
        let metadata = payload["metadata"] as? [String: Any]
        let metadataRaw = metadata?["rawData"] as? [String: Any]
        let rootRaw = payload["rawData"] as? [String: Any]
        let format = IvLyricsUtilities.firstNonEmpty(
            string(metadataRaw?["format"]),
            string(rootRaw?["format"]),
            string(metadata?["format"])
        )
        return format.lowercased() == "krc"
    }

    private static func structuredLineText(_ line: [String: Any], reference: String?) -> String {
        if let reference, !reference.trimmed.isEmpty {
            return decodeLyricEntities(reference).trimmed
        }
        if let items = line["text"] as? [[String: Any]] {
            return items.map { decodeLyricEntities(string($0["text"])) }.joined().trimmed
        }
        return decodeLyricEntities(string(line["text"])).trimmed
    }

    private static func structuredBackgroundText(_ line: [String: Any]) -> String {
        if let items = line["backgroundText"] as? [[String: Any]] {
            return items.map { decodeLyricEntities(string($0["text"])) }.joined().trimmed
        }
        return decodeLyricEntities(string(line["backgroundText"])).trimmed
    }

    static func canReuseCachedResult(_ result: LyricsResult) -> Bool {
        let providerId = result.providerId.trimmed.lowercased()
        let providerLabel = result.providerLabel.trimmed.lowercased()
        let isPaxsenix = providerId == "paxsenix"
            || providerLabel.contains("paxsenix")
            || providerLabel.contains("lyrically")
        return !isPaxsenix || result.selectionPolicyKey.hasSuffix(cacheEntityRevision)
    }

    static func markEntitiesDecoded(in result: LyricsResult) -> LyricsResult {
        guard result.providerId == "paxsenix",
              !result.selectionPolicyKey.hasSuffix(cacheEntityRevision) else { return result }
        var marked = result
        marked.selectionPolicyKey += cacheEntityRevision
        return marked
    }

    private static func decodeLyricEntities(_ value: String) -> String {
        guard value.contains("&"), let regex = lyricEntityRegex else { return value }
        let source = value as NSString
        let matches = regex.matches(
            in: value,
            range: NSRange(location: 0, length: source.length)
        )
        guard !matches.isEmpty else { return value }

        var result = ""
        result.reserveCapacity(value.count)
        var cursor = 0
        for match in matches {
            let range = match.range
            if range.location > cursor {
                result += source.substring(with: NSRange(location: cursor, length: range.location - cursor))
            }
            let entity = source.substring(with: range)
            result += decodedLyricEntity(entity) ?? entity
            cursor = NSMaxRange(range)
        }
        if cursor < source.length {
            result += source.substring(from: cursor)
        }
        return result
    }

    private static func decodedLyricEntity(_ entity: String) -> String? {
        guard entity.first == "&", entity.last == ";" else { return nil }
        let body = String(entity.dropFirst().dropLast())
        if body.hasPrefix("#") {
            let numeric = String(body.dropFirst())
            let radix: Int
            let digits: String
            if numeric.first == "x" || numeric.first == "X" {
                radix = 16
                digits = String(numeric.dropFirst())
            } else {
                radix = 10
                digits = numeric
            }
            guard let value = UInt32(digits, radix: radix),
                  let scalar = UnicodeScalar(value),
                  isRenderableLyricScalar(scalar) else { return nil }
            return String(scalar)
        }
        return namedLyricEntities[body]
    }

    private static func isRenderableLyricScalar(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        if value < 0x20 {
            return value == 0x09 || value == 0x0A || value == 0x0D
        }
        return !(0x7F...0x9F).contains(value)
    }

    private static func lineStartTime(_ line: [String: Any]) -> Int64 {
        let items = line["text"] as? [[String: Any]]
        return milliseconds(line["timestamp"]) ?? milliseconds(items?.first?["timestamp"]) ?? 0
    }

    private static func normalizeReferenceSpacingCharacters(_ value: String) -> String {
        let doubleQuotesNormalized = replaceMatches(
            in: value.nfkc(),
            regex: referenceDoubleQuoteRegex,
            fallbackPattern: referenceDoubleQuotePattern,
            with: "\""
        )
        let quotesNormalized = replaceMatches(
            in: doubleQuotesNormalized,
            regex: referenceSingleQuoteRegex,
            fallbackPattern: referenceSingleQuotePattern,
            with: "'"
        )
        return replaceMatches(
            in: quotesNormalized,
            regex: referenceWhitespaceRegex,
            fallbackPattern: referenceWhitespacePattern,
            with: ""
        )
    }

    private static func selectBestCandidate(
        _ candidates: [SearchCandidate],
        track: TrackSnapshot
    ) -> SearchCandidate? {
        candidates
            .filter { !$0.id.isEmpty }
            .map { ($0, candidateScore($0, track: track)) }
            .filter { $0.1 >= 45 }
            .max { $0.1 < $1.1 }?
            .0
    }

    private static func candidateScore(_ candidate: SearchCandidate, track: TrackSnapshot) -> Double {
        let artistScore = textScore(track.artist, candidate.artist, weight: 30)
        let albumScore = textScore(track.album, candidate.album, weight: 30)
        var score = textScore(track.title, candidate.title, weight: 70, titleCore: true)
        if normalizeComparable(track.title) == normalizeComparable(candidate.title) { score += 18 }
        score += artistScore + albumScore
        if !track.artist.isEmpty, !candidate.artist.isEmpty, artistScore == 0, albumScore == 0 {
            score -= 72
        }
        if track.durationMs > 0, candidate.durationSeconds > 0 {
            let difference = abs(Double(track.durationMs) / 1000 - candidate.durationSeconds)
            if difference <= 2 { score += 24 }
            else if difference <= 5 { score += 18 }
            else if difference <= 15 { score += 8 }
            else if difference > 60 { score -= 20 }
        }
        return score
    }

    private static func textScore(
        _ expected: String,
        _ actual: String,
        weight: Double,
        titleCore: Bool = false
    ) -> Double {
        let left = titleCore ? normalizeTitleCore(expected) : normalizeComparable(expected)
        let right = titleCore ? normalizeTitleCore(actual) : normalizeComparable(actual)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return weight }
        if left.contains(right) || right.contains(left) { return weight * 0.78 }
        return weight * 0.62 * tokenOverlap(left, right)
    }

    private static func tokenOverlap(_ left: String, _ right: String) -> Double {
        let leftTokens = Set(left.split(separator: " ").map(String.init).filter { $0.count > 1 })
        let rightTokens = Set(right.split(separator: " ").map(String.init).filter { $0.count > 1 })
        guard !leftTokens.isEmpty, !rightTokens.isEmpty else { return 0 }
        let matches = leftTokens.intersection(rightTokens).count
        return Double(matches) / Double(max(1, min(leftTokens.count, rightTokens.count)))
    }

    private static func normalizeComparable(_ value: String) -> String {
        var normalized = replaceMatches(
            in: value.nfkc().lowercased(),
            regex: comparableApostropheRegex,
            fallbackPattern: comparableApostrophePattern,
            with: "'"
        )
        normalized = replaceMatches(
            in: normalized,
            regex: comparableFeaturingRegex,
            fallbackPattern: comparableFeaturingPattern,
            fallbackOptions: [.regularExpression, .caseInsensitive],
            with: " "
        )
        normalized = replaceMatches(
            in: normalized,
            regex: comparableNonAlphanumericRegex,
            fallbackPattern: comparableNonAlphanumericPattern,
            with: " "
        ).trimmed
        return replaceMatches(
            in: normalized,
            regex: comparableWhitespaceRegex,
            fallbackPattern: comparableWhitespacePattern,
            with: " "
        )
    }

    private static func normalizeTitleCore(_ value: String) -> String {
        normalizeComparable(
            replaceMatches(
                in: replaceMatches(
                    in: value,
                    regex: titleDecorationRegex,
                    fallbackPattern: titleDecorationPattern,
                    with: " "
                ),
                regex: titleVersionSuffixRegex,
                fallbackPattern: titleVersionSuffixPattern,
                fallbackOptions: [.regularExpression, .caseInsensitive],
                with: " "
            )
        )
    }

    private static func normalizeMetadataIdentity(_ value: String) -> String {
        replaceMatches(
            in: normalizeTitleCore(value),
            regex: comparableWhitespaceRegex,
            fallbackPattern: comparableWhitespacePattern,
            with: ""
        )
    }

    private static func replaceMatches(
        in value: String,
        regex: NSRegularExpression?,
        fallbackPattern: String,
        fallbackOptions: String.CompareOptions = .regularExpression,
        with replacement: String
    ) -> String {
        guard let regex else {
            return value.replacingOccurrences(
                of: fallbackPattern,
                with: replacement,
                options: fallbackOptions
            )
        }
        return regex.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..<value.endIndex, in: value),
            withTemplate: replacement
        )
    }

    private static func quality(_ candidate: ParsedCandidate) -> Double {
        let sourceBonus = candidate.source == "catalog" ? 2.0 : 0
        if let karaoke = candidate.parsed.karaoke, !karaoke.isEmpty {
            let backgrounds = karaoke.filter { $0.vocalParts.contains(where: { $0.role == "background" }) }.count
            return 3000 + Double(backgrounds * 10) + sourceBonus + Double(karaoke.count) / 1000
        }
        if let synced = candidate.parsed.synced, !synced.isEmpty {
            return 2000 + sourceBonus + Double(synced.count) / 1000
        }
        if let plain = candidate.parsed.plain, !plain.isEmpty {
            return 1000 + sourceBonus + Double(plain.count) / 1000
        }
        return 0
    }

    private static func searchTerm(_ track: TrackSnapshot) -> String {
        [track.title, track.artist].map(\.trimmed).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func endpoint(_ key: String) -> String? {
        encodedEndpoints[key].flatMap(decodeBase64)
    }

    private static func decodeBase64(_ value: String) -> String? {
        guard let data = Data(base64Encoded: value),
              let decoded = String(data: data, encoding: .utf8),
              decoded.hasPrefix("https://") || !decoded.contains("://") else { return nil }
        return decoded
    }

    private static func milliseconds(_ value: Any?) -> Int64? {
        let number: Double?
        if let value = value as? NSNumber { number = value.doubleValue }
        else if let value = value as? String { number = Double(value) }
        else { number = nil }
        guard let number, number.isFinite else { return nil }
        return max(0, Int64(number.rounded()))
    }

    private static func double(_ value: Any?) -> Double {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) ?? 0 }
        return 0
    }

    private static func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }
}
