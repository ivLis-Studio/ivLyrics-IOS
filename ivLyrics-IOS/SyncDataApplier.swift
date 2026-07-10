import Foundation

enum SyncDataApplier {
    private static let durationOffsetMinDiffMs: Int64 = 500
    private static let durationFrontOffsetRatio = 0.3

    struct ApplyResult: Sendable {
        var lines: [LyricsLine]
        var diagnostics: [String]

        static func empty(_ reason: String) -> ApplyResult {
            ApplyResult(lines: [], diagnostics: reason.trimmed.isEmpty ? [] : [reason])
        }
    }

    static func applyWithDiagnostics(baseLyrics: [LyricsLine], syncBody: [String: Any], track: TrackSnapshot?) -> ApplyResult {
        guard !baseLyrics.isEmpty else {
            return .empty("missing base lyrics or sync body")
        }
        guard let rawLines = syncBody["lines"] as? [Any], !rawLines.isEmpty else {
            return .empty("sync body has no lines")
        }

        let source = syncBody["source"] as? [String: Any]
        let hasSourceLineShape = !(readIntArray(source?["lineCharCounts"]).isEmpty)
        let version = intValue(syncBody["version"], fallback: 1)
        let normalizeParentheticalLines = version >= 2 || hasSourceLineShape
        let baseLines = getBaseLyricLines(baseLyrics, normalizeParentheticalLines: normalizeParentheticalLines)
        guard !baseLines.isEmpty else {
            return .empty("base lyrics became empty after normalization")
        }

        var diagnostics: [String] = [
            "shape: baseLines=\(baseLines.count) / rawSyncLines=\(rawLines.count) / sourceLineShape=\(hasSourceLineShape) / version=\(version)"
        ]

        var syncLines = parseSyncLines(rawLines)
        guard !syncLines.isEmpty else {
            return .empty("no valid sync lines parsed from JSON")
        }

        let sourcePrefix = resolveSourcePrefix(source: source, baseLines: baseLines)
        if sourcePrefix < 0 {
            return .empty("source line shape mismatch: expected=\(previewIntegers(readIntArray(source?["lineCharCounts"]))) actual=\(previewIntegers(baseLines.map { IvLyricsUtilities.splitChars($0).count }))")
        }
        if sourcePrefix > 0 {
            let charOffset = leadingCharOffset(readIntArray(source?["lineCharCounts"]), prefixLength: sourcePrefix)
            syncLines = shiftSyncLines(syncLines, charOffset: charOffset)
            diagnostics.append("source prefix trimmed: lines=\(sourcePrefix) / charOffset=\(charOffset)")
        } else if let source {
            let expectedFingerprint = stringValue(source["lyricsFingerprint"])
            if !expectedFingerprint.isEmpty {
                let actual = IvLyricsUtilities.lyricsFingerprint(IvLyricsUtilities.joinLinesForFingerprint(baseLines))
                guard expectedFingerprint == actual else {
                    return .empty("source fingerprint mismatch: expected=\(expectedFingerprint) actual=\(actual)")
                }
                diagnostics.append("source fingerprint matched: \(actual)")
            }
        }

        let durationAdjustment = computeDurationAdjustment(syncBody: syncBody, track: track)
        if durationAdjustment.offsetMs != 0 {
            syncLines = shiftSyncTimes(syncLines, offsetSeconds: Double(durationAdjustment.offsetMs) / 1000.0)
            diagnostics.append("duration offset applied: frontOffset=\(durationAdjustment.offsetMs)ms / registered=\(durationAdjustment.registeredDurationMs)ms / current=\(durationAdjustment.currentDurationMs)ms / diff=\(durationAdjustment.diffMs)ms / rearRemainder=\(durationAdjustment.diffMs - durationAdjustment.offsetMs)ms / frontRatio=\(durationFrontOffsetRatio)")
        } else if durationAdjustment.registeredDurationMs > 0, durationAdjustment.currentDurationMs > 0, durationAdjustment.diffMs != 0 {
            diagnostics.append("duration offset skipped: registered=\(durationAdjustment.registeredDurationMs)ms / current=\(durationAdjustment.currentDurationMs)ms / diff=\(durationAdjustment.diffMs)ms")
        }

        let fullChars = IvLyricsUtilities.splitChars(baseLines.joined())
        syncLines = normalizeParallelParts(syncLines, fullChars: fullChars)
        diagnostics.append("char map: fullChars=\(fullChars.count)")

        var result: [LyricsLine] = []
        var skippedLines = 0
        for index in syncLines.indices {
            let line = syncLines[index]
            guard line.isUsable(fullCharCount: fullChars.count) else {
                skippedLines += 1
                continue
            }

            let nextLine = nextUsableLine(syncLines, startIndex: index + 1, fullCharCount: fullChars.count)
            let lineText = joinChars(fullChars, start: line.start, end: line.end)
            var lineStartMs = secondsToMs(line.chars[0])
            var lineEndMs = nextLine?.chars.first.map(secondsToMs) ?? (secondsToMs(line.chars[line.chars.count - 1]) + 2_000)
            let lineDurationSec = Double(lineEndMs - lineStartMs) / 1000.0
            let avgCharDuration = max(0.2, lineDurationSec / Double(max(1, line.chars.count)))
            let lastCharMaxDuration = max(0.5, min(1.5, avgCharDuration * 2.5))

            let timedLine = buildLineSyllables(line: line, lineText: lineText, lineEndMs: lineEndMs, lastCharMaxDuration: lastCharMaxDuration)
            guard !timedLine.syllables.isEmpty else { continue }
            lineEndMs = timedLine.endTimeMs

            let vocalParts = buildVocalParts(line: line, fullChars: fullChars, fallbackEndMs: lineEndMs, lastCharMaxDuration: lastCharMaxDuration)
            if vocalParts.count > 1 {
                let leadPart = vocalParts.first { $0.role == "lead" } ?? vocalParts[0]
                for part in vocalParts {
                    lineStartMs = min(lineStartMs, part.startTimeMs)
                    lineEndMs = max(lineEndMs, part.endTimeMs)
                }
                result.append(LyricsLine(
                    startTimeMs: lineStartMs,
                    endTimeMs: lineEndMs,
                    text: lineText,
                    syllables: timedLine.syllables,
                    speaker: IvLyricsUtilities.firstNonEmpty(line.speaker, leadPart.speaker),
                    speakerColor: IvLyricsUtilities.firstNonEmpty(line.speakerColor, leadPart.speakerColor),
                    speakerFallback: IvLyricsUtilities.firstNonEmpty(line.speakerFallback, leadPart.speakerFallback),
                    kind: IvLyricsUtilities.firstNonEmpty(line.kind, leadPart.kind),
                    vocalParts: vocalParts
                ))
            } else if let part = vocalParts.first {
                result.append(LyricsLine(
                    startTimeMs: lineStartMs,
                    endTimeMs: lineEndMs,
                    text: lineText,
                    syllables: timedLine.syllables,
                    speaker: IvLyricsUtilities.firstNonEmpty(line.speaker, part.speaker),
                    speakerColor: IvLyricsUtilities.firstNonEmpty(line.speakerColor, part.speakerColor),
                    speakerFallback: IvLyricsUtilities.firstNonEmpty(line.speakerFallback, part.speakerFallback),
                    kind: IvLyricsUtilities.firstNonEmpty(line.kind, part.kind)
                ))
            } else {
                result.append(LyricsLine(
                    startTimeMs: lineStartMs,
                    endTimeMs: lineEndMs,
                    text: lineText,
                    syllables: timedLine.syllables,
                    speaker: line.speaker,
                    speakerColor: line.speakerColor,
                    speakerFallback: line.speakerFallback,
                    kind: line.kind
                ))
            }
        }

        guard !result.isEmpty else {
            return .empty("rendered 0 karaoke lines; skippedSyncLines=\(skippedLines) / fullChars=\(fullChars.count)")
        }
        if skippedLines > 0 {
            diagnostics.append("skipped unusable sync lines=\(skippedLines)")
        }
        return ApplyResult(lines: result, diagnostics: diagnostics)
    }

    private static func buildLineSyllables(line: SyncLine, lineText: String, lineEndMs: Int64, lastCharMaxDuration: Double) -> TimedSyllables {
        let chars = IvLyricsUtilities.splitChars(lineText)
        let charCount = min(line.chars.count, chars.count)
        guard charCount > 0 else {
            return TimedSyllables(syllables: [], endTimeMs: lineEndMs)
        }

        var syllables: [LyricsLine.Syllable] = []
        var adjustedEndMs = lineEndMs
        for charIndex in 0..<charCount {
            let charStartMs = secondsToMs(line.chars[charIndex])
            let charEndMs: Int64
            if charIndex < charCount - 1 {
                charEndMs = secondsToMs(line.chars[charIndex + 1])
            } else {
                let naturalEndMs = secondsToMs(line.chars[charIndex] + lastCharMaxDuration)
                charEndMs = min(lineEndMs, naturalEndMs)
                adjustedEndMs = charEndMs
            }
            syllables.append(LyricsLine.Syllable(text: chars[charIndex], startTimeMs: charStartMs, endTimeMs: charEndMs))
        }
        return TimedSyllables(syllables: syllables, endTimeMs: adjustedEndMs)
    }

    private static func buildVocalParts(line: SyncLine, fullChars: [String], fallbackEndMs: Int64, lastCharMaxDuration: Double) -> [LyricsLine.VocalPart] {
        line.parts.compactMap { buildVocalPart(part: $0, line: line, fullChars: fullChars, fallbackEndMs: fallbackEndMs, lastCharMaxDuration: lastCharMaxDuration) }
    }

    private static func buildVocalPart(part: ParallelPart, line: SyncLine, fullChars: [String], fallbackEndMs: Int64, lastCharMaxDuration: Double) -> LyricsLine.VocalPart? {
        guard !part.ranges.isEmpty, !part.chars.isEmpty else { return nil }
        var syllables: [LyricsLine.Syllable] = []
        var partCharIndex = 0
        for rangeIndex in part.ranges.indices {
            let range = part.ranges[rangeIndex]
            if rangeIndex > 0 {
                let joinMode = rangeIndex - 1 < part.join.count ? part.join[rangeIndex - 1] : 1
                if joinMode == 1 || joinMode == 2 {
                    let previousTime = syllables.last?.endTimeMs ?? secondsToMs(part.chars[min(max(0, partCharIndex), part.chars.count - 1)])
                    syllables.append(LyricsLine.Syllable(text: " ", startTimeMs: previousTime, endTimeMs: previousTime))
                }
            }

            for sourceIndex in range.start...range.end {
                guard sourceIndex >= 0, sourceIndex < fullChars.count else {
                    partCharIndex += 1
                    continue
                }
                let startSeconds = partCharIndex < part.chars.count ? part.chars[partCharIndex] : (line.chars.first ?? 0)
                let charStartMs = secondsToMs(startSeconds)
                let charEndMs: Int64
                if partCharIndex + 1 < part.chars.count {
                    charEndMs = secondsToMs(part.chars[partCharIndex + 1])
                } else {
                    charEndMs = min(fallbackEndMs, charStartMs + Int64((lastCharMaxDuration * 1000).rounded()))
                }
                syllables.append(LyricsLine.Syllable(text: fullChars[sourceIndex], startTimeMs: charStartMs, endTimeMs: charEndMs))
                partCharIndex += 1
            }
        }
        let trimmed = trimWhitespaceSyllables(syllables)
        guard !trimmed.isEmpty else { return nil }
        let text = trimmed.map(\.text).joined()
        return LyricsLine.VocalPart(
            id: part.id,
            role: part.role,
            speaker: part.speaker,
            speakerColor: part.speakerColor,
            speakerFallback: part.speakerFallback,
            kind: part.kind,
            text: text,
            syllables: trimmed
        )
    }

    private static func parseSyncLines(_ rawLines: [Any]) -> [SyncLine] {
        rawLines.compactMap { rawValue in
            guard let rawLine = rawValue as? [String: Any] else { return nil }
            let parallel = parseParallel(rawLine["parallel"] as? [String: Any])
            return SyncLine(
                start: intValue(rawLine["start"], fallback: -1),
                end: intValue(rawLine["end"], fallback: -1),
                chars: readDoubleArray(rawLine["chars"]),
                speaker: stringValue(rawLine["speaker"]),
                speakerColor: speakerMetadataValue(rawLine, wireKey: "speaker-color", legacyKey: "speakerColor"),
                speakerFallback: speakerMetadataValue(rawLine, wireKey: "speaker-fallback", legacyKey: "speakerFallback"),
                kind: IvLyricsUtilities.firstNonEmpty(stringValue(rawLine["kind"]), "vocal"),
                parts: parallel.parts,
                hiddenRanges: parallel.hiddenRanges
            )
        }
    }

    private static func parseParallel(_ object: [String: Any]?) -> Parallel {
        guard let object else {
            return Parallel(parts: [], hiddenRanges: [])
        }
        let hiddenRanges = readRanges(object["hiddenRanges"])
        guard let rawParts = object["parts"] as? [Any], !rawParts.isEmpty else {
            return Parallel(parts: [], hiddenRanges: hiddenRanges)
        }
        let parts = rawParts.compactMap { rawValue -> ParallelPart? in
            guard let rawPart = rawValue as? [String: Any] else { return nil }
            let ranges = readRanges(rawPart["ranges"])
            let chars = readDoubleArray(rawPart["chars"])
            guard !ranges.isEmpty, !chars.isEmpty else { return nil }
            return ParallelPart(
                id: stringValue(rawPart["id"]),
                role: stringValue(rawPart["role"]),
                speaker: stringValue(rawPart["speaker"]),
                speakerColor: speakerMetadataValue(rawPart, wireKey: "speaker-color", legacyKey: "speakerColor"),
                speakerFallback: speakerMetadataValue(rawPart, wireKey: "speaker-fallback", legacyKey: "speakerFallback"),
                kind: IvLyricsUtilities.firstNonEmpty(stringValue(rawPart["kind"]), "vocal"),
                ranges: ranges,
                join: readIntArray(rawPart["join"]),
                chars: chars
            )
        }
        return Parallel(parts: parts, hiddenRanges: hiddenRanges)
    }

    private static func normalizeParallelParts(_ lines: [SyncLine], fullChars: [String]) -> [SyncLine] {
        guard !lines.isEmpty, !fullChars.isEmpty else { return lines }
        return lines.map { line in
            guard !line.parts.isEmpty else { return line }
            var parts = line.parts.map { stripParentheticalPartRange($0, fullChars: fullChars) }
            parts = splitHiddenDelimitedParallelParts(parts, hiddenRanges: line.hiddenRanges)
            return line.withParts(parts)
        }
    }

    private static func stripParentheticalPartRange(_ part: ParallelPart, fullChars: [String]) -> ParallelPart {
        guard part.ranges.count == 1 else { return part }
        let range = part.ranges[0]
        guard range.start >= 0, range.end < fullChars.count, part.chars.count == range.count else { return part }
        let stripped = stripStandaloneParentheticalCharRange(fullChars, start: range.start, end: range.end)
        guard stripped.changed, stripped.start <= stripped.end else { return part }
        let charOffset = stripped.start - range.start
        let charEnd = charOffset + (stripped.end - stripped.start + 1)
        guard charOffset >= 0, charEnd <= part.chars.count else { return part }
        return part.withRangesAndChars([RangeValue(start: stripped.start, end: stripped.end)], Array(part.chars[charOffset..<charEnd]))
    }

    private static func splitHiddenDelimitedParallelParts(_ parts: [ParallelPart], hiddenRanges: [RangeValue]) -> [ParallelPart] {
        guard !hiddenRanges.isEmpty else { return parts }
        var usedIds = Set(parts.map(\.id).filter { !$0.isEmpty })
        var split: [ParallelPart] = []
        var changed = false
        for part in parts {
            if let splitPart = splitHiddenDelimitedParallelPart(part, hiddenRanges: hiddenRanges, usedIds: &usedIds) {
                changed = true
                split.append(contentsOf: splitPart)
            } else {
                split.append(part)
            }
        }
        return changed && split.count <= 16 ? split : parts
    }

    private static func splitHiddenDelimitedParallelPart(_ part: ParallelPart, hiddenRanges: [RangeValue], usedIds: inout Set<String>) -> [ParallelPart]? {
        guard part.role == "background",
              !part.id.isEmpty,
              part.ranges.count >= 2,
              part.join.count == part.ranges.count - 1,
              part.chars.count == countRangeChars(part.ranges) else {
            return nil
        }
        for joinMode in part.join where joinMode < 0 || joinMode > 2 || joinMode == 2 {
            return nil
        }
        for index in part.ranges.indices where index > 0 {
            let range = part.ranges[index]
            let previous = part.ranges[index - 1]
            if range.start <= previous.end || !isRangeGapFullyHidden(hiddenRanges, gapStart: previous.end + 1, gapEnd: range.start - 1) {
                return nil
            }
        }

        var splitParts: [ParallelPart] = []
        var charOffset = 0
        for index in part.ranges.indices {
            let range = part.ranges[index]
            let charCount = range.count
            guard let id = index == 0 ? part.id : nextPartId(usedIds: &usedIds) else { return nil }
            splitParts.append(ParallelPart(
                id: id,
                role: part.role,
                speaker: part.speaker,
                speakerColor: part.speakerColor,
                speakerFallback: part.speakerFallback,
                kind: part.kind,
                ranges: [range],
                join: [],
                chars: Array(part.chars[charOffset..<(charOffset + charCount)])
            ))
            charOffset += charCount
        }
        return splitParts
    }

    private static func nextUsableLine(_ lines: [SyncLine], startIndex: Int, fullCharCount: Int) -> SyncLine? {
        guard startIndex < lines.count else { return nil }
        for index in startIndex..<lines.count where lines[index].isUsable(fullCharCount: fullCharCount) {
            return lines[index]
        }
        return nil
    }

    private static func resolveSourcePrefix(source: [String: Any]?, baseLines: [String]) -> Int {
        guard let source else { return 0 }
        let expectedCounts = readIntArray(source["lineCharCounts"])
        guard !expectedCounts.isEmpty else { return 0 }
        let actualCounts = baseLines.map { IvLyricsUtilities.splitChars($0).count }
        if sameShape(expectedCounts, actualCounts, expectedOffset: 0) {
            return 0
        }
        guard expectedCounts.count > actualCounts.count else { return -1 }
        let maxPrefix = expectedCounts.count - actualCounts.count
        for prefix in 1...maxPrefix where sameShape(expectedCounts, actualCounts, expectedOffset: prefix) {
            return prefix
        }
        return -1
    }

    private static func sameShape(_ expected: [Int], _ actual: [Int], expectedOffset: Int) -> Bool {
        guard expected.count - expectedOffset == actual.count else { return false }
        for index in actual.indices where expected[expectedOffset + index] != actual[index] {
            return false
        }
        return true
    }

    private static func leadingCharOffset(_ lineCounts: [Int], prefixLength: Int) -> Int {
        lineCounts.prefix(prefixLength).reduce(0) { $0 + max(0, $1) }
    }

    private static func shiftSyncLines(_ lines: [SyncLine], charOffset: Int) -> [SyncLine] {
        guard charOffset > 0 else { return lines }
        return lines.compactMap { line in
            guard line.end >= charOffset else { return nil }
            let parts = line.parts.compactMap { shiftPartRanges($0, charOffset: charOffset) }
            return SyncLine(
                start: max(0, line.start - charOffset),
                end: max(0, line.end - charOffset),
                chars: line.chars,
                speaker: line.speaker,
                speakerColor: line.speakerColor,
                speakerFallback: line.speakerFallback,
                kind: line.kind,
                parts: parts,
                hiddenRanges: shiftRanges(line.hiddenRanges, charOffset: charOffset).ranges
            )
        }
    }

    private static func shiftPartRanges(_ part: ParallelPart, charOffset: Int) -> ParallelPart? {
        let shifted = shiftRanges(part.ranges, charOffset: charOffset)
        guard !shifted.ranges.isEmpty else { return nil }
        let nextCharCount = countRangeChars(shifted.ranges)
        let from = min(max(0, shifted.removedLeadingChars), part.chars.count)
        let to = min(part.chars.count, from + nextCharCount)
        guard to - from == nextCharCount else { return nil }
        return part.withRangesAndChars(shifted.ranges, Array(part.chars[from..<to]))
    }

    private static func shiftRanges(_ ranges: [RangeValue], charOffset: Int) -> ShiftedRanges {
        var shifted: [RangeValue] = []
        var removedLeadingChars = 0
        for range in ranges {
            if range.end < charOffset {
                removedLeadingChars += range.count
                continue
            }
            if range.start < charOffset {
                removedLeadingChars += charOffset - range.start
            }
            shifted.append(RangeValue(start: max(0, range.start - charOffset), end: max(0, range.end - charOffset)))
        }
        return ShiftedRanges(ranges: shifted, removedLeadingChars: removedLeadingChars)
    }

    private static func shiftSyncTimes(_ lines: [SyncLine], offsetSeconds: Double) -> [SyncLine] {
        lines.map { line in
            SyncLine(
                start: line.start,
                end: line.end,
                chars: shiftTimes(line.chars, offsetSeconds: offsetSeconds),
                speaker: line.speaker,
                speakerColor: line.speakerColor,
                speakerFallback: line.speakerFallback,
                kind: line.kind,
                parts: line.parts.map { $0.withChars(shiftTimes($0.chars, offsetSeconds: offsetSeconds)) },
                hiddenRanges: line.hiddenRanges
            )
        }
    }

    private static func shiftTimes(_ values: [Double], offsetSeconds: Double) -> [Double] {
        values.map { max(0, (($0 + offsetSeconds) * 1000).rounded() / 1000) }
    }

    private static func computeDurationAdjustment(syncBody: [String: Any], track: TrackSnapshot?) -> DurationAdjustment {
        let currentDurationMs = track?.durationMs ?? 0
        guard currentDurationMs > 0 else {
            return DurationAdjustment(registeredDurationMs: 0, currentDurationMs: currentDurationMs, diffMs: 0, offsetMs: 0)
        }
        let registeredDurationMs = normalizeDurationMs(syncBody["trackDurationMs"], syncBody["durationMs"], syncBody["duration_ms"])
        guard registeredDurationMs > 0 else {
            return DurationAdjustment(registeredDurationMs: 0, currentDurationMs: currentDurationMs, diffMs: 0, offsetMs: 0)
        }
        let diffMs = currentDurationMs - registeredDurationMs
        if abs(diffMs) < durationOffsetMinDiffMs {
            return DurationAdjustment(registeredDurationMs: registeredDurationMs, currentDurationMs: currentDurationMs, diffMs: diffMs, offsetMs: 0)
        }
        return DurationAdjustment(registeredDurationMs: registeredDurationMs, currentDurationMs: currentDurationMs, diffMs: diffMs, offsetMs: Int64((Double(diffMs) * durationFrontOffsetRatio).rounded()))
    }

    static func normalizeDurationMs(_ values: Any?...) -> Int64 {
        for value in values {
            guard let value, !(value is NSNull) else { continue }
            let numeric = doubleValue(value)
            if let numeric, numeric.isFinite, numeric > 0, numeric <= 86_400_000 {
                return Int64(numeric.rounded())
            }
        }
        return 0
    }

    private static func getBaseLyricLines(_ lines: [LyricsLine], normalizeParentheticalLines: Bool) -> [String] {
        var result = lines.map { $0.text.nfc().trimmed }
            .filter { !$0.isEmpty }
            .map { normalizeParentheticalLines ? IvLyricsUtilities.stripStandaloneParentheticalLine($0) : $0 }
        if normalizeParentheticalLines {
            result = IvLyricsUtilities.normalizeStandaloneParentheticalBlocks(result)
        }
        return result.map { $0.nfc().trimmed }.filter { !$0.isEmpty }
    }

    private static func trimWhitespaceSyllables(_ syllables: [LyricsLine.Syllable]) -> [LyricsLine.Syllable] {
        var start = 0
        var end = syllables.count
        while start < end && isWhitespace(syllables[start].text) { start += 1 }
        while end > start && isWhitespace(syllables[end - 1].text) { end -= 1 }
        return start >= end ? [] : Array(syllables[start..<end])
    }

    private static func readRanges(_ raw: Any?) -> [RangeValue] {
        guard let array = raw as? [Any] else { return [] }
        return array.compactMap { rawValue in
            guard let value = rawValue as? [String: Any] else { return nil }
            let start = intValue(value["start"], fallback: -1)
            let end = intValue(value["end"], fallback: -1)
            return start >= 0 && end >= start ? RangeValue(start: start, end: end) : nil
        }
    }

    private static func readIntArray(_ raw: Any?) -> [Int] {
        guard let values = raw as? [Any] else { return [] }
        return values.map { intValue($0, fallback: 0) }
    }

    private static func readDoubleArray(_ raw: Any?) -> [Double] {
        guard let values = raw as? [Any] else { return [] }
        return values.compactMap(doubleValue).filter(\.isFinite)
    }

    private static func intValue(_ value: Any?, fallback: Int) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber, !isJSONBoolean(value) { return value.intValue }
        if let value = value as? String,
           let numeric = Double(value.trimmed),
           numeric.isFinite,
           numeric >= Double(Int.min),
           numeric <= Double(Int.max) {
            return Int(numeric)
        }
        return fallback
    }

    private static func stringValue(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let value = value as? String { return value }
        if let value = value as? Bool { return value ? "true" : "false" }
        if let value = value as? NSNumber { return value.stringValue }
        return String(describing: value)
    }

    private static func speakerMetadataValue(
        _ object: [String: Any],
        wireKey: String,
        legacyKey: String
    ) -> String {
        IvLyricsUtilities.firstNonEmpty(
            stringValue(object[wireKey]),
            stringValue(object[legacyKey])
        )
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let value = value as? NSNumber, !isJSONBoolean(value) {
            return value.doubleValue
        }
        if let value = value as? String {
            return Double(value.trimmed)
        }
        return nil
    }

    private static func isJSONBoolean(_ value: NSNumber) -> Bool {
        CFGetTypeID(value) == CFBooleanGetTypeID()
    }

    private static func joinChars(_ chars: [String], start: Int, end: Int) -> String {
        guard !chars.isEmpty, start <= end else { return "" }
        let safeStart = max(0, start)
        let safeEnd = min(chars.count - 1, end)
        guard safeStart <= safeEnd else { return "" }
        return chars[safeStart...safeEnd].joined()
    }

    private static func countRangeChars(_ ranges: [RangeValue]) -> Int {
        ranges.reduce(0) { $0 + $1.count }
    }

    private static func isRangeGapFullyHidden(_ hiddenRanges: [RangeValue], gapStart: Int, gapEnd: Int) -> Bool {
        guard gapStart <= gapEnd, !hiddenRanges.isEmpty else { return false }
        var cursor = gapStart
        for range in hiddenRanges {
            if range.end < cursor { continue }
            if range.start > cursor { return false }
            cursor = max(cursor, range.end + 1)
            if cursor > gapEnd { return true }
        }
        return false
    }

    private static func nextPartId(usedIds: inout Set<String>) -> String? {
        for scalar in UnicodeScalar("a").value...UnicodeScalar("z").value {
            let id = String(UnicodeScalar(scalar)!)
            if !usedIds.contains(id) {
                usedIds.insert(id)
                return id
            }
        }
        for index in 1...16 {
            let id = "p\(index)"
            if !usedIds.contains(id) {
                usedIds.insert(id)
                return id
            }
        }
        return nil
    }

    private static func stripStandaloneParentheticalCharRange(_ chars: [String], start: Int, end: Int) -> StripResult {
        var nextStart = start
        var nextEnd = end
        var changed = false
        var trimmed = trimWhitespaceRange(chars, start: nextStart, end: nextEnd)
        nextStart = trimmed.start
        nextEnd = trimmed.end
        while nextStart < nextEnd && isStandaloneParentheticalLine(joinChars(chars, start: nextStart, end: nextEnd)) {
            nextStart += 1
            nextEnd -= 1
            changed = true
            trimmed = trimWhitespaceRange(chars, start: nextStart, end: nextEnd)
            nextStart = trimmed.start
            nextEnd = trimmed.end
        }
        return StripResult(start: nextStart, end: nextEnd, changed: changed)
    }

    private static func trimWhitespaceRange(_ chars: [String], start: Int, end: Int) -> RangeValue {
        var nextStart = start
        var nextEnd = end
        while nextStart <= nextEnd, nextStart < chars.count, isWhitespace(chars[nextStart]) { nextStart += 1 }
        while nextEnd >= nextStart, nextEnd >= 0, isWhitespace(chars[nextEnd]) { nextEnd -= 1 }
        return RangeValue(start: nextStart, end: nextEnd)
    }

    private static func isStandaloneParentheticalLine(_ text: String) -> Bool {
        let chars = IvLyricsUtilities.splitChars(text.nfc().trimmed)
        guard chars.count >= 2 else { return false }
        let close = parenthesisClose(chars[0])
        return !close.isEmpty && close == chars[chars.count - 1]
    }

    private static func parenthesisClose(_ open: String) -> String {
        if open == "(" { return ")" }
        if open == "（" { return "）" }
        return ""
    }

    private static func isWhitespace(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func secondsToMs(_ seconds: Double) -> Int64 {
        Int64((max(0, seconds) * 1000).rounded())
    }

    private static func previewIntegers(_ values: [Int]) -> String {
        guard !values.isEmpty else { return "[]" }
        let preview = values.prefix(12).map(String.init).joined(separator: ",")
        return "[\(preview)\(values.count > 12 ? ",..." : "")] len=\(values.count)"
    }

    private struct TimedSyllables {
        var syllables: [LyricsLine.Syllable]
        var endTimeMs: Int64
    }

    private struct Parallel {
        var parts: [ParallelPart]
        var hiddenRanges: [RangeValue]
    }

    private struct SyncLine {
        var start: Int
        var end: Int
        var chars: [Double]
        var speaker: String
        var speakerColor: String
        var speakerFallback: String
        var kind: String
        var parts: [ParallelPart]
        var hiddenRanges: [RangeValue]

        func withParts(_ nextParts: [ParallelPart]) -> SyncLine {
            SyncLine(
                start: start,
                end: end,
                chars: chars,
                speaker: speaker,
                speakerColor: speakerColor,
                speakerFallback: speakerFallback,
                kind: kind,
                parts: nextParts,
                hiddenRanges: hiddenRanges
            )
        }

        func isUsable(fullCharCount: Int) -> Bool {
            let expected = end - start + 1
            return start >= 0 && end >= start && end < fullCharCount && expected > 0 && chars.count == expected
        }
    }

    private struct ParallelPart {
        var id: String
        var role: String
        var speaker: String
        var speakerColor: String
        var speakerFallback: String
        var kind: String
        var ranges: [RangeValue]
        var join: [Int]
        var chars: [Double]

        func withRangesAndChars(_ nextRanges: [RangeValue], _ nextChars: [Double]) -> ParallelPart {
            ParallelPart(
                id: id,
                role: role,
                speaker: speaker,
                speakerColor: speakerColor,
                speakerFallback: speakerFallback,
                kind: kind,
                ranges: nextRanges,
                join: join,
                chars: nextChars
            )
        }

        func withChars(_ nextChars: [Double]) -> ParallelPart {
            ParallelPart(
                id: id,
                role: role,
                speaker: speaker,
                speakerColor: speakerColor,
                speakerFallback: speakerFallback,
                kind: kind,
                ranges: ranges,
                join: join,
                chars: nextChars
            )
        }
    }

    private struct RangeValue {
        var start: Int
        var end: Int
        var count: Int { max(0, end - start + 1) }
    }

    private struct ShiftedRanges {
        var ranges: [RangeValue]
        var removedLeadingChars: Int
    }

    private struct DurationAdjustment {
        var registeredDurationMs: Int64
        var currentDurationMs: Int64
        var diffMs: Int64
        var offsetMs: Int64
    }

    private struct StripResult {
        var start: Int
        var end: Int
        var changed: Bool
    }
}
