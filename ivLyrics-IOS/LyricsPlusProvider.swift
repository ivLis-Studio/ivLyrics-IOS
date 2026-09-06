import Foundation

enum LyricsPlusProvider {
    static let projectURL = "https://github.com/ibratabian17/lyricsplus"

    private static let encodedBaseURLs = [
        "YUhSMGNITTZMeTlzZVhKcFkzTndiSFZ6TG5CeWFtdDBiR0V1YlhrdWFXUT0=",
        "YUhSMGNITTZMeTlzZVhKcFkzTXVaMlZsYTJWa0xuZDBaZz09"
    ]
    private static let requestTimeout: TimeInterval = 12
    private static let splitTriggerWidth = 22.0
    private static let splitHardWidth = 26.0
    private static let splitMinimumWidth = 6.0
    private static let splitMinimumDurationMs: Int64 = 500
    private static let splitMaximumSegments = 4
    private static let endpointRotation = EndpointRotation()
#if DEBUG
    private static let boundaryRegressionChecks: Void = {
        func syllable(_ text: String, _ start: Int64, _ end: Int64) -> LyricsLine.Syllable {
            LyricsLine.Syllable(text: text, startTimeMs: start, endTimeMs: end)
        }

        assert(safeBoundary(syllable("Eng", 0, 100), syllable("lish", 100, 200)) == nil)
        assert(safeBoundary(syllable("한국", 0, 100), syllable("어", 100, 200)) == nil)
        assert(safeBoundary(syllable("한국어 ", 0, 100), syllable("가사", 100, 200)) != nil)
        assert(safeBoundary(syllable("ドラ", 0, 100), syllable("マ", 100, 200)) != nil)

        let parenthesized = LyricsLine.VocalPart(
            id: "background-parentheses-regression",
            role: "lead",
            speaker: "vocal2",
            kind: "vocal",
            text: "（(Back) vocal）",
            syllables: [
                syllable("（", 0, 10),
                syllable("(Back)", 10, 100),
                syllable(" vocal）", 100, 200)
            ]
        )
        assert(stripBackgroundParentheses(parenthesized.text).trimmed == "Back vocal")
        assert(stripBackgroundSyllableParentheses(parenthesized.syllables).map(\.text) == ["Back", " vocal"])
    }()
#endif
    private static let speakerPalette: [(String, String)] = [
        ("#a8ccff", "MALE 1"),
        ("#ffb8c7", "FEMALE 1"),
        ("#e4d8ff", "DUET 1"),
        ("#9ae8d4", "MALE 2"),
        ("#ffd6b3", "FEMALE 2"),
        ("#d6e4ff", "DUET 2"),
        ("#bfe8ff", "MALE 3"),
        ("#f6c8ff", "FEMALE 3"),
        ("#ffddf2", "DUET 3")
    ]

    struct FetchOutcome: Sendable {
        var karaoke: [LyricsLine]?
        var synced: [LyricsLine]?
        var plain: [LyricsLine]?
        var sourceType: String
        var logs: [String]
    }

    private struct RawLine: Sendable {
        var sourceIndex: Int
        var line: LyricsLine
        var hasTiming: Bool
        var hasWordTiming: Bool
    }

    private struct RawSyllable: Sendable {
        var value: LyricsLine.Syllable
        var isBackground: Bool
    }

    private struct SpeakerPresentation: Sendable {
        var speaker: String
        var color: String
        var fallback: String
    }

    private struct SplitSegmentKey: Hashable {
        let start: Int
        let end: Int
    }

    private actor EndpointRotation {
        private var nextIndex = 0

        func ordered(_ values: [String]) -> [String] {
            guard !values.isEmpty else { return [] }
            let start = nextIndex % values.count
            nextIndex = (nextIndex + 1) % values.count
            return (0..<values.count).map { values[(start + $0) % values.count] }
        }
    }

    static func fetch(track: TrackSnapshot, isrc rawIsrc: String) async throws -> FetchOutcome? {
        let isrc = TrackSnapshot.normalizeIsrc(rawIsrc)
        guard !isrc.isEmpty || track.hasUsableMetadata else { return nil }

        let decodedBases = encodedBaseURLs.compactMap(decodeTwice)
        let bases = await endpointRotation.ordered(decodedBases)
        var logs: [String] = []
        var lastError: Error?
        var notFoundCount = 0

        for (offset, base) in bases.enumerated() {
            do {
                guard var components = URLComponents(string: "\(base)/v2/lyrics/get") else {
                    throw URLError(.badURL)
                }
                if !isrc.isEmpty {
                    components.queryItems = [URLQueryItem(name: "isrc", value: isrc)]
                } else {
                    var queryItems = [
                        URLQueryItem(name: "title", value: track.title),
                        URLQueryItem(name: "artist", value: track.artist)
                    ]
                    if !track.album.isEmpty, track.album.lowercased() != "undefined" {
                        queryItems.append(URLQueryItem(name: "album", value: track.album))
                    }
                    if track.durationMs > 0 {
                        queryItems.append(
                            URLQueryItem(
                                name: "duration",
                                value: String(
                                    format: "%.3f",
                                    locale: Locale(identifier: "en_US_POSIX"),
                                    Double(track.durationMs) / 1000
                                )
                            )
                        )
                    }
                    components.queryItems = queryItems
                }
                guard let url = components.url else { throw URLError(.badURL) }
                var request = URLRequest(url: url, timeoutInterval: requestTimeout)
                request.httpMethod = "GET"
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("ivLyrics-iOS/1.0", forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.ivLyricsData(for: request)
                let outcome = try parse(data: data, durationMs: track.durationMs)
                logs.append("lyricsplus: mirror #\(offset + 1) selected / type=\(outcome.sourceType)")
                var result = outcome
                result.logs = logs + outcome.logs
                return result
            } catch let error as HTTPStatusError where error.statusCode == 404 {
                notFoundCount += 1
                logs.append("lyricsplus: mirror #\(offset + 1) not found")
            } catch {
                lastError = error
                logs.append("lyricsplus: mirror #\(offset + 1) failed / \(error.localizedDescription)")
            }
        }

        if notFoundCount == bases.count { return nil }
        if let lastError { throw lastError }
        return nil
    }

    private static func decodeTwice(_ value: String) -> String? {
        guard let firstData = Data(base64Encoded: value),
              let first = String(data: firstData, encoding: .utf8),
              let secondData = Data(base64Encoded: first),
              let decoded = String(data: secondData, encoding: .utf8),
              decoded.hasPrefix("https://") else {
            return nil
        }
        return decoded
    }

    static func parse(data: Data, durationMs: Int64) throws -> FetchOutcome {
#if DEBUG
        _ = boundaryRegressionChecks
#endif
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if isTruthyJsonValue(root["error"]) {
            throw HTTPStatusError(statusCode: 404, message: "LyricsPlus lyrics not found")
        }
        let lyrics = root["lyrics"] as? [[String: Any]] ?? []
        guard !lyrics.isEmpty else {
            throw HTTPStatusError(statusCode: 404, message: "LyricsPlus response has no lyrics")
        }
        let rawSourceType = string(root["type"]).trimmed.lowercased()
        let sourceType: String
        switch rawSourceType {
        case "word": sourceType = "word"
        case "line": sourceType = "line"
        case "none", "plain", "unsynced": sourceType = "plain"
        default:
            if lyrics.contains(where: { ($0["syllabus"] as? [[String: Any]])?.isEmpty == false }) {
                sourceType = "word"
            } else if lyrics.contains(where: { optionalMilliseconds($0["time"]) != nil }) {
                sourceType = "line"
            } else {
                sourceType = "plain"
            }
        }
        let metadata = root["metadata"] as? [String: Any]
        let agents = metadata?["agents"] as? [String: Any] ?? [:]
        let agentOrder = Array(agents.keys)
        var singerOrder: [String] = []
        var rawLines: [RawLine] = []

        for (index, item) in lyrics.enumerated() {
            let element = item["element"] as? [String: Any] ?? [:]
            let singer = string(element["singer"]).trimmed
            if !singer.isEmpty, !singerOrder.contains(singer) {
                singerOrder.append(singer)
            }
            let presentation = speakerPresentation(
                singer: singer,
                singerOrder: singerOrder,
                agentOrder: agentOrder,
                agents: agents
            )
            let rawStart = optionalMilliseconds(item["time"])
            let rawDuration = positiveMilliseconds(item["duration"])
            let rawSyllables = item["syllabus"] as? [[String: Any]] ?? []
            let parsedSyllables = rawSyllables.compactMap(parseSyllable)
            let leadSyllables = parsedSyllables.filter { !$0.isBackground }.map(\.value)
            let backgroundSyllables = stripBackgroundSyllableParentheses(
                parsedSyllables.filter(\.isBackground).map(\.value)
            )
            let leadText = leadSyllables.map(\.text).joined().trimmed
            let backgroundText = backgroundSyllables.map(\.text).joined().trimmed
            let sourceText = string(item["text"]).trimmed
            let text = backgroundSyllables.isEmpty
                ? IvLyricsUtilities.firstNonEmpty(sourceText, parsedSyllables.map(\.value.text).joined().trimmed)
                : [leadText, backgroundText].filter { !$0.isEmpty }.joined(separator: " ")
            guard !text.isEmpty else { continue }
            let allSyllables = parsedSyllables.map(\.value)
            var effectiveStart = rawStart
            var effectiveEnd = rawStart.flatMap { start in rawDuration.map { start + $0 } }
            if let syllableStart = allSyllables.map(\.startTimeMs).min() {
                effectiveStart = min(effectiveStart ?? syllableStart, syllableStart)
            }
            if let syllableEnd = allSyllables.map(\.endTimeMs).max() {
                effectiveEnd = max(effectiveEnd ?? syllableEnd, syllableEnd)
            }
            let lineKey = string(element["key"]).trimmed.isEmpty
                ? "L\(index + 1)"
                : string(element["key"]).trimmed
            var vocalParts: [LyricsLine.VocalPart] = []
            if sourceType == "word", !backgroundSyllables.isEmpty {
                let leadPart = LyricsLine.VocalPart(
                    id: "lyricsplus-\(lineKey)-lead",
                    role: "lead",
                    speaker: presentation.speaker,
                    speakerColor: presentation.color,
                    speakerFallback: presentation.fallback,
                    kind: "vocal",
                    text: leadText,
                    syllables: leadSyllables
                )
                let backgroundPart = LyricsLine.VocalPart(
                    id: "lyricsplus-\(lineKey)-background-1",
                    role: "background",
                    speaker: presentation.speaker,
                    speakerColor: presentation.color,
                    speakerFallback: presentation.fallback,
                    kind: "vocal",
                    text: backgroundText,
                    syllables: backgroundSyllables
                )
                if !leadSyllables.isEmpty { vocalParts = [leadPart, backgroundPart] }
            }
            let line = LyricsLine(
                startTimeMs: sourceType == "plain" ? 0 : (effectiveStart ?? 0),
                endTimeMs: sourceType == "plain" ? 0 : (effectiveEnd ?? effectiveStart ?? 0),
                text: text,
                syllables: sourceType == "word" && vocalParts.isEmpty
                    ? (leadSyllables.isEmpty ? backgroundSyllables : leadSyllables)
                    : [],
                speaker: presentation.speaker,
                speakerColor: presentation.color,
                speakerFallback: presentation.fallback,
                vocalParts: vocalParts
            )
            rawLines.append(
                RawLine(
                    sourceIndex: index,
                    line: line,
                    hasTiming: effectiveStart != nil,
                    hasWordTiming: !allSyllables.isEmpty
                )
            )
        }

        guard !rawLines.isEmpty else {
            throw HTTPStatusError(statusCode: 404, message: "LyricsPlus response has no renderable lyrics")
        }
        let timedRaw = fillLineEndTimes(rawLines.filter(\.hasTiming), durationMs: durationMs)
        let completeTiming = timedRaw.count == rawLines.count
        let synced = completeTiming && sourceType != "plain"
            ? timedRaw.map { demoteToSynced($0.line) }
            : nil
        let plain = rawLines.sorted { $0.sourceIndex < $1.sourceIndex }.map { demoteToPlain($0.line) }
        var karaoke: [LyricsLine]? = nil
        if completeTiming,
           sourceType == "word",
           timedRaw.allSatisfy(\.hasWordTiming) {
            // Singer identity and overlapping timing do not establish a background
            // relationship. Keep each source line and its explicit isBackground parts.
            karaoke = splitLongSoloLines(timedRaw.map(\.line))
        }
        let typeLabel = sourceType == "word" ? "Word" : (sourceType == "line" ? "Line" : "Plain")
        return FetchOutcome(
            karaoke: karaoke?.isEmpty == false ? karaoke : nil,
            synced: synced?.isEmpty == false ? synced : nil,
            plain: plain.isEmpty ? nil : plain,
            sourceType: typeLabel,
            logs: [
                "lyricsplus parsed: type=\(typeLabel) / sourceLines=\(rawLines.count) / karaokeLines=\(karaoke?.count ?? 0)"
            ]
        )
    }

    private static func parseSyllable(_ object: [String: Any]) -> RawSyllable? {
        let text = string(object["text"])
        guard !text.trimmed.isEmpty,
              let start = optionalMilliseconds(object["time"]) else { return nil }
        let duration = positiveMilliseconds(object["duration"]) ?? 1
        return RawSyllable(
            value: LyricsLine.Syllable(text: text, startTimeMs: start, endTimeMs: start + duration),
            isBackground: (object["isBackground"] as? Bool) == true
        )
    }

    private static func fillLineEndTimes(_ lines: [RawLine], durationMs: Int64) -> [RawLine] {
        let ordered = lines.sorted {
            $0.line.startTimeMs == $1.line.startTimeMs
                ? $0.sourceIndex < $1.sourceIndex
                : $0.line.startTimeMs < $1.line.startTimeMs
        }
        return ordered.enumerated().map { index, raw in
            var copy = raw
            if copy.line.endTimeMs <= copy.line.startTimeMs {
                let nextStart = index + 1 < ordered.count ? ordered[index + 1].line.startTimeMs : -1
                copy.line.endTimeMs = nextStart > copy.line.startTimeMs
                    ? nextStart
                    : max(
                        copy.line.startTimeMs + 1,
                        durationMs > copy.line.startTimeMs ? durationMs : copy.line.startTimeMs + 3_000
                    )
            }
            return copy
        }
    }

    private static func demoteToSynced(_ line: LyricsLine) -> LyricsLine {
        LyricsLine(
            startTimeMs: line.startTimeMs,
            endTimeMs: line.endTimeMs,
            text: line.text,
            speaker: line.speaker,
            speakerColor: line.speakerColor,
            speakerFallback: line.speakerFallback
        )
    }

    private static func demoteToPlain(_ line: LyricsLine) -> LyricsLine {
        LyricsLine(
            startTimeMs: 0,
            endTimeMs: 0,
            text: line.text,
            speaker: line.speaker,
            speakerColor: line.speakerColor,
            speakerFallback: line.speakerFallback
        )
    }

    private static func stripBackgroundSyllableParentheses(
        _ syllables: [LyricsLine.Syllable]
    ) -> [LyricsLine.Syllable] {
        syllables.compactMap { syllable in
            let text = stripBackgroundParentheses(syllable.text)
            guard !text.isEmpty else { return nil }
            return LyricsLine.Syllable(
                text: text,
                startTimeMs: syllable.startTimeMs,
                endTimeMs: syllable.endTimeMs
            )
        }
    }

    private static func stripBackgroundParentheses(_ text: String) -> String {
        text.replacingOccurrences(of: "[()（）]", with: "", options: .regularExpression)
    }

    private static func splitLongSoloLines(_ lines: [LyricsLine]) -> [LyricsLine] {
        lines.enumerated().flatMap { index, line in
            let previous = index > 0 ? lines[index - 1] : nil
            let next = index + 1 < lines.count ? lines[index + 1] : nil
            return splitLongSoloLine(line, previous: previous, next: next)
        }
    }

    private static func splitLongSoloLine(_ line: LyricsLine, previous: LyricsLine?, next: LyricsLine?) -> [LyricsLine] {
        let syllables = line.syllables
        guard line.vocalParts.isEmpty,
              syllables.count >= 2 else {
            return [line]
        }
        let lineWidth = measureWidth(line.text)
        guard lineWidth > splitTriggerWidth,
              (previous == nil || previous!.endTimeMs <= line.startTimeMs),
              (next == nil || next!.startTimeMs >= line.endTimeMs),
              syllables.map(\.text).joined().trimmed == line.text.trimmed else {
            return [line]
        }
        for index in syllables.indices {
            let item = syllables[index]
            guard item.endTimeMs >= item.startTimeMs else { return [line] }
            if index > 0 {
                let prior = syllables[index - 1]
                guard item.startTimeMs >= prior.endTimeMs else { return [line] }
            }
        }
        var boundaryPenalties: [Int: Double] = [:]
        let candidates = (1..<syllables.count).filter { boundary in
            guard let penalty = safeBoundary(syllables[boundary - 1], syllables[boundary]) else {
                return false
            }
            boundaryPenalties[boundary] = penalty
            return true
        }
        guard !candidates.isEmpty else { return [line] }
        let minimumCount = max(2, Int(ceil(lineWidth / splitHardWidth)))
        let maximumCount = min(splitMaximumSegments, candidates.count + 1)
        guard minimumCount <= maximumCount else { return [line] }

        var bestBoundaries: [Int]?
        var bestScore = Double.greatestFiniteMagnitude
        var segmentMetrics: [SplitSegmentKey: (width: Double, duration: Int64)] = [:]
        for segmentCount in minimumCount...maximumCount {
            var chosen: [Int] = []
            chooseBoundaries(
                candidates: candidates,
                needed: segmentCount - 1,
                cursor: 0,
                chosen: &chosen
            ) { boundaries in
                let points = [0] + boundaries + [syllables.count]
                let target = lineWidth / Double(segmentCount)
                var score = 0.0
                for segment in 0..<segmentCount {
                    let start = points[segment]
                    let end = points[segment + 1]
                    let key = SplitSegmentKey(start: start, end: end)
                    let metrics: (width: Double, duration: Int64)
                    if let cached = segmentMetrics[key] {
                        metrics = cached
                    } else {
                        let slice = Array(syllables[start..<end])
                        metrics = (
                            width: measureWidth(slice.map(\.text).joined()),
                            duration: (slice.last?.endTimeMs ?? 0) - (slice.first?.startTimeMs ?? 0)
                        )
                        segmentMetrics[key] = metrics
                    }
                    guard metrics.width >= splitMinimumWidth,
                          metrics.width <= splitHardWidth,
                          metrics.duration >= splitMinimumDurationMs else { return }
                    score += pow(metrics.width - target, 2)
                    if segment < segmentCount - 1,
                       let boundary = boundaryPenalties[points[segment + 1]] {
                        score += boundary
                    }
                }
                if score < bestScore {
                    bestScore = score
                    bestBoundaries = boundaries
                }
            }
            if bestBoundaries != nil { break }
        }
        guard let boundaries = bestBoundaries else { return [line] }
        let points = [0] + boundaries + [syllables.count]
        return (0..<(points.count - 1)).map { index in
            let slice = Array(syllables[points[index]..<points[index + 1]])
            return LyricsLine(
                startTimeMs: index == 0 ? min(line.startTimeMs, slice[0].startTimeMs) : slice[0].startTimeMs,
                endTimeMs: index == points.count - 2 ? max(line.endTimeMs, slice.last!.endTimeMs) : slice.last!.endTimeMs,
                text: slice.map(\.text).joined().trimmed,
                syllables: slice,
                speaker: line.speaker,
                speakerColor: line.speakerColor,
                speakerFallback: line.speakerFallback
            )
        }
    }

    private static func chooseBoundaries(
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
              candidates.count - cursor >= needed - chosen.count else { return }
        for index in cursor..<candidates.count {
            chosen.append(candidates[index])
            chooseBoundaries(candidates: candidates, needed: needed, cursor: index + 1, chosen: &chosen, visit: visit)
            chosen.removeLast()
        }
    }

    private static func safeBoundary(_ left: LyricsLine.Syllable, _ right: LyricsLine.Syllable) -> Double? {
        guard left.endTimeMs <= right.startTimeMs,
              let leftCharacter = boundaryCharacter(left.text, fromEnd: true),
              let rightCharacter = boundaryCharacter(right.text, fromEnd: false),
              !"([{（「『【〈《".contains(leftCharacter),
              !")]})）」』】〉》、。，．！？?!".contains(rightCharacter),
              !"ゃゅょっぁぃぅぇぉゎャュョッァィゥェォヮー々".contains(rightCharacter) else {
            return nil
        }
        let hasWhitespace = left.text.last?.isWhitespace == true || right.text.first?.isWhitespace == true
        let punctuation = "。！？?!…；;：:、，,.".contains(leftCharacter)
        let scriptChange = (isCjk(leftCharacter) && isLatinOrNumber(rightCharacter))
            || (isLatinOrNumber(leftCharacter) && isCjk(rightCharacter))
        let noSpaceScriptBoundary = isNoSpaceCjk(leftCharacter) && isNoSpaceCjk(rightCharacter)
        if isLatinOrNumber(leftCharacter), isLatinOrNumber(rightCharacter), !hasWhitespace, !punctuation {
            return nil
        }
        guard hasWhitespace || punctuation || scriptChange || noSpaceScriptBoundary else { return nil }
        return hasWhitespace ? 0 : (punctuation ? 1 : (scriptChange ? 10 : 12))
    }

    private static func boundaryCharacter(_ text: String, fromEnd: Bool) -> Character? {
        let values = text.filter { !$0.isWhitespace }
        return fromEnd ? values.last : values.first
    }

    private static func measureWidth(_ text: String) -> Double {
        text.reduce(0) { total, character in
            if character.isWhitespace { return total + 0.33 }
            if isCjk(character) { return total + 1.0 }
            if character.isASCIIUppercase { return total + 0.72 }
            if character.isASCIILowercase { return total + 0.58 }
            if character.isNumber { return total + 0.62 }
            if ".,'’!?;:()-".contains(character) { return total + 0.38 }
            return total + 0.8
        }
    }

    private static func isLatinOrNumber(_ character: Character) -> Bool {
        character.isASCIIUppercase || character.isASCIILowercase || character.isNumber
    }

    private static func isCjk(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x3040...0x30ff).contains(value)
                || (0x3400...0x9fff).contains(value)
                || (0xac00...0xd7af).contains(value)
                || (0xf900...0xfaff).contains(value)
        }
    }

    private static func isNoSpaceCjk(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x3040...0x30ff).contains(value)
                || (0x3400...0x9fff).contains(value)
                || (0xf900...0xfaff).contains(value)
        }
    }

    private static func speakerPresentation(
        singer: String,
        singerOrder: [String],
        agentOrder: [String],
        agents: [String: Any]
    ) -> SpeakerPresentation {
        guard !singer.isEmpty else { return SpeakerPresentation(speaker: "NORMAL", color: "", fallback: "") }
        let index = singerOrder.firstIndex(of: singer) ?? agentOrder.firstIndex(of: singer) ?? 0
        if index == 0 { return SpeakerPresentation(speaker: "NORMAL", color: "", fallback: "") }
        let agent = agents[singer] as? [String: Any]
        let palette: (String, String)
        if string(agent?["type"]).lowercased() == "group" {
            let groupPalette = speakerPalette.filter { $0.1.hasPrefix("DUET") }
            let priorGroupCount = singerOrder.prefix(index).filter { candidate in
                let metadata = agents[candidate] as? [String: Any]
                return string(metadata?["type"]).lowercased() == "group"
            }.count
            palette = groupPalette[priorGroupCount % groupPalette.count]
        } else {
            palette = speakerPalette[(index - 1) % speakerPalette.count]
        }
        return SpeakerPresentation(speaker: "CUSTOM", color: palette.0, fallback: palette.1)
    }

    private static func string(_ value: Any?) -> String {
        value as? String ?? ""
    }

    private static func isTruthyJsonValue(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let boolean = value as? Bool { return boolean }
        if let number = value as? NSNumber { return number.doubleValue != 0 }
        if let string = value as? String { return !string.trimmed.isEmpty }
        return true
    }

    private static func optionalMilliseconds(_ value: Any?) -> Int64? {
        guard let value, !(value is NSNull) else { return nil }
        let number: Double?
        if let raw = value as? NSNumber {
            number = raw.doubleValue
        } else if let raw = value as? String, !raw.trimmed.isEmpty {
            number = Double(raw)
        } else {
            number = nil
        }
        guard let number,
              number.isFinite,
              number >= 0,
              number <= Double(Int64.max) else { return nil }
        return Int64(number.rounded())
    }

    private static func positiveMilliseconds(_ value: Any?) -> Int64? {
        guard let value = optionalMilliseconds(value), value > 0 else { return nil }
        return value
    }
}

private extension Character {
    var isASCIIUppercase: Bool {
        unicodeScalars.count == 1 && unicodeScalars.first.map { (65...90).contains($0.value) } == true
    }

    var isASCIILowercase: Bool {
        unicodeScalars.count == 1 && unicodeScalars.first.map { (97...122).contains($0.value) } == true
    }
}
