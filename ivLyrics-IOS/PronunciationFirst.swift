import Foundation

/// Pronunciation-first display mode and the pronunciation fill.
///
/// Pronunciation-first keeps every row's appearance and only swaps values: the pronunciation
/// is shown in the original row and the original in the pronunciation row. Karaoke units keep
/// their timing; the pronunciation is split across them by AI (the same request as the desktop
/// and Android apps) or, until that arrives, in proportion to each unit's length.
///
/// The pronunciation fill uses the same unit timing while pronunciation-first is off: the
/// pronunciation row under a karaoke line fills along it, with no other karaoke effect.
enum PronunciationFirst {
    static let promptVersion = "timed-pronunciation-v1"
    static let maxChunkUnits = 420
    static let maxChunkItems = 24

    /// One timed unit group: a line's own syllables or one vocal part.
    struct Group {
        let key: String
        let syllables: [LyricsLine.Syllable]
        let pronunciation: String
    }

    /// A group sent to AI: the pronunciation and its timed units.
    struct Item: Equatable {
        let key: String
        let pronunciation: String
        let units: [LyricsLine.Syllable]
    }

    static func unitGroups(_ line: LyricsLine) -> [Group] {
        let timedParts = line.vocalParts.filter { !$0.syllables.isEmpty && !$0.text.trimmed.isEmpty }.count
        var groups: [Group] = []
        for (index, part) in line.vocalParts.enumerated() where !part.syllables.isEmpty {
            var pronunciation = part.pronunciationText.trimmed
            // A single voice can carry the whole line's pronunciation.
            if pronunciation.isEmpty && timedParts == 1 { pronunciation = line.pronunciationText.trimmed }
            groups.append(Group(key: "part:\(index)", syllables: part.syllables, pronunciation: pronunciation))
        }
        if !groups.isEmpty { return groups }
        if !line.syllables.isEmpty {
            groups.append(Group(key: "line", syllables: line.syllables, pronunciation: line.pronunciationText.trimmed))
        }
        return groups
    }

    // MARK: - Swap

    /// Display copy of the result with original and pronunciation swapped.
    static func apply(_ result: LyricsResult, timed: [String: [String]]?) -> LyricsResult {
        guard !result.lines.isEmpty else { return result }
        var display = result
        display.lines = result.lines.enumerated().map { index, line in swapLine(line, lineIndex: index, timed: timed) }
        return display
    }

    static func swapLine(_ line: LyricsLine, lineIndex: Int, timed: [String: [String]]?) -> LyricsLine {
        let pronunciation = line.pronunciationText.trimmed
        var syllables = line.syllables
        var parts = line.vocalParts
        var changed = false
        var hasTimedParts = false
        for group in unitGroups(line) where !group.pronunciation.isEmpty {
            let unitParts = groupParts(timed, lineIndex: lineIndex, group: group)
            let swapped = group.syllables.enumerated().map { index, syllable in
                syllable.copying(text: index < unitParts.count ? unitParts[index] : "")
            }
            if group.key == "line" {
                syllables = swapped
            } else if let partIndex = Int(group.key.dropFirst(5)), parts.indices.contains(partIndex) {
                let part = line.vocalParts[partIndex]
                parts[partIndex] = LyricsLine.VocalPart(
                    id: part.id,
                    role: part.role,
                    speaker: part.speaker,
                    speakerColor: part.speakerColor,
                    speakerFallback: part.speakerFallback,
                    kind: part.kind,
                    text: group.pronunciation,
                    syllables: swapped,
                    pronunciationText: part.text,
                    translationText: part.translationText,
                    furiganaText: ""
                )
                hasTimedParts = true
            }
            changed = true
        }
        if pronunciation.isEmpty && !changed { return line }
        var swapped = LyricsLine(
            startTimeMs: line.startTimeMs,
            endTimeMs: line.endTimeMs,
            text: pronunciation.isEmpty ? line.text : pronunciation,
            syllables: syllables,
            speaker: line.speaker,
            speakerColor: line.speakerColor,
            speakerFallback: line.speakerFallback,
            kind: line.kind,
            vocalParts: parts,
            // Parallel voices already show their own original below each part.
            pronunciationText: pronunciation.isEmpty || hasTimedParts ? "" : line.text,
            translationText: line.translationText,
            furiganaText: ""
        )
        // The row stays the same row for SwiftUI.
        swapped.id = line.id
        return swapped
    }

    private static func groupParts(_ timed: [String: [String]]?, lineIndex: Int, group: Group) -> [String] {
        let length = group.syllables.count
        let stored = timed?["\(lineIndex):\(group.key)"]
        let aligned = stored.flatMap { isValidParts($0, length: length) ? alignParts($0, group.pronunciation) : nil }
        let parts = aligned ?? distribute(group.syllables.map(\.text), group.pronunciation)
        return normalizeParts(parts, length: length)
    }

    static func isValidParts(_ parts: [String], length: Int) -> Bool {
        parts.count == length && parts.contains { !$0.trimmed.isEmpty }
    }

    // MARK: - Distribution

    static func graphemes(_ text: String) -> [String] {
        text.map(String.init)
    }

    private static func isSpace(_ grapheme: String) -> Bool {
        grapheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isSound(_ grapheme: String) -> Bool {
        guard let scalar = grapheme.unicodeScalars.first else { return false }
        return scalar.properties.isAlphabetic || CharacterSet.decimalDigits.contains(scalar)
            || scalar.properties.numericType != nil
    }

    /// Spreads a pronunciation over units in proportion to how much each unit is sung.
    static func distribute(_ unitTexts: [String], _ pronunciation: String) -> [String] {
        let count = unitTexts.count
        var parts = Array(repeating: "", count: count)
        let characters = graphemes(pronunciation.trimmed)
        guard count > 0, !characters.isEmpty else { return parts }
        let weights = unitTexts.map { text in graphemes(text).filter(isSound).count }
        let total = weights.reduce(0, +)
        if total == 0 {
            let target = unitTexts.firstIndex { !$0.trimmed.isEmpty } ?? 0
            parts[target] = characters.joined()
            return parts
        }
        let visibleTotal = characters.filter { !isSpace($0) }.count
        var bounds: [Int] = []
        var accumulated = 0
        for weight in weights {
            accumulated += weight
            bounds.append(Int((Double(visibleTotal * accumulated) / Double(total)).rounded(.toNearestOrAwayFromZero)))
        }
        var unit = 0
        var seen = 0
        for character in characters {
            if !isSpace(character) {
                while unit < count - 1 && seen >= bounds[unit] { unit += 1 }
                seen += 1
            }
            parts[unit] += character
        }
        return parts
    }

    /// Removes duplicated spaces at unit boundaries and spaces around the line.
    static func normalizeParts(_ parts: [String], length: Int) -> [String] {
        var result = (0..<length).map { index in
            (index < parts.count ? parts[index] : "")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        }
        var previousEndsWithSpace = true
        for index in result.indices where !result[index].isEmpty {
            if previousEndsWithSpace {
                result[index] = result[index].replacingOccurrences(of: #"^ +"#, with: "", options: .regularExpression)
            }
            if !result[index].isEmpty { previousEndsWithSpace = result[index].hasSuffix(" ") }
        }
        for index in result.indices.reversed() where !result[index].isEmpty {
            result[index] = result[index].replacingOccurrences(of: #" +$"#, with: "", options: .regularExpression)
            if !result[index].isEmpty { break }
        }
        return result
    }

    /// Letters of a pronunciation (graphemes without spaces), for comparing AI splits.
    static func letters(_ value: String) -> [String] {
        graphemes(value.precomposedStringWithCanonicalMapping).filter { !isSpace($0) }
    }

    /// Whether a split gives back the pronunciation; only spaces may differ.
    static func spells(_ parts: [String], _ pronunciation: String) -> Bool {
        letters(parts.joined()) == letters(pronunciation)
    }

    /// Lays an AI split back onto the pronunciation itself: each unit keeps the letters AI gave
    /// it, and the pronunciation's own spaces return after the letter they follow. AI sometimes
    /// drops or moves word spaces; the shown pronunciation must not change. Nil when the letters
    /// differ.
    static func alignParts(_ parts: [String], _ pronunciation: String) -> [String]? {
        guard spells(parts, pronunciation) else { return nil }
        let counts = parts.map { letters($0).count }
        var aligned = Array(repeating: "", count: parts.count)
        var unit = 0
        var used = 0
        var last = -1
        for character in graphemes(pronunciation.trimmed.precomposedStringWithCanonicalMapping) {
            if isSpace(character) {
                if last >= 0 { aligned[last] += character }
                continue
            }
            while unit < counts.count - 1 && used >= counts[unit] {
                unit += 1
                used = 0
            }
            aligned[unit] += character
            used += 1
            last = unit
        }
        return aligned
    }

    // MARK: - Pronunciation fill

    /// Timed pronunciation units for the rows of one displayed line.
    struct LineFill: Equatable {
        var line: [LyricsLine.Syllable]?
        var parts: [String: [LyricsLine.Syllable]] = [:]

        static let empty = LineFill()

        func part(_ part: LyricsLine.VocalPart) -> [LyricsLine.Syllable]? {
            parts[Fill.partKey(part)]
        }
    }

    /// Timed pronunciation units of the rows that fill along karaoke timing.
    struct Fill: Equatable {
        var lines: [UUID: LineFill] = [:]

        static let empty = Fill()

        var isEmpty: Bool { lines.isEmpty }

        func lineFill(_ line: LyricsLine) -> LineFill {
            lines[line.id] ?? .empty
        }

        static func partKey(_ part: LyricsLine.VocalPart) -> String {
            "\(part.id)|\(part.role)|\(part.startTimeMs)|\(part.text)"
        }

        /// The row's units, only when they spell exactly the pronunciation shown.
        static func matching(_ units: [LyricsLine.Syllable]?, pronunciation: String) -> [LyricsLine.Syllable]? {
            guard let units, !units.isEmpty, !pronunciation.trimmed.isEmpty else { return nil }
            let collapse = { (value: String) in
                value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmed
            }
            return collapse(units.map(\.text).joined()) == collapse(pronunciation) ? units : nil
        }
    }

    /// Pronunciation rows of karaoke lines split over their units (AI split when it fits, else
    /// proportional). Rows keep their text; units carry their karaoke unit's timing.
    static func fill(_ result: LyricsResult, timed: [String: [String]]?) -> Fill {
        guard result.karaoke, !result.lines.isEmpty else { return .empty }
        var fill = Fill()
        for (lineIndex, line) in result.lines.enumerated() {
            var lineFill = LineFill()
            for group in unitGroups(line) where !group.pronunciation.isEmpty {
                let parts = groupParts(timed, lineIndex: lineIndex, group: group)
                let units = zip(group.syllables, parts).compactMap { syllable, text in
                    text.isEmpty ? nil : LyricsLine.Syllable(text: text, startTimeMs: syllable.startTimeMs, endTimeMs: syllable.endTimeMs)
                }
                guard !units.isEmpty else { continue }
                if group.key == "line" {
                    lineFill.line = units
                } else if let partIndex = Int(group.key.dropFirst(5)), line.vocalParts.indices.contains(partIndex) {
                    let part = line.vocalParts[partIndex]
                    // A voice without its own reading carries the line's reading on the line row.
                    if part.pronunciationText.trimmed.isEmpty {
                        lineFill.line = units
                    } else {
                        lineFill.parts[Fill.partKey(part)] = units
                    }
                }
            }
            if lineFill != .empty { fill.lines[line.id] = lineFill }
        }
        return fill
    }

    // MARK: - AI request

    static func timingItems(_ result: LyricsResult) -> [Item] {
        guard result.karaoke else { return [] }
        var items: [Item] = []
        for (lineIndex, line) in result.lines.enumerated() {
            for group in unitGroups(line) where !group.pronunciation.isEmpty {
                guard group.syllables.contains(where: { !$0.text.trimmed.isEmpty }) else { continue }
                items.append(Item(key: "\(lineIndex):\(group.key)", pronunciation: group.pronunciation, units: group.syllables))
            }
        }
        return items
    }

    static func signature(_ items: [Item], targetLang: String, sourceLang: String) -> String {
        var value = "\(promptVersion)|\(targetLang)|\(sourceLang)"
        for item in items {
            value += "\n\(item.key)\u{1}\(item.pronunciation)"
            for unit in item.units {
                value += "\u{2}\(unit.text)\u{3}\(unit.startTimeMs)-\(unit.endTimeMs)"
            }
        }
        return value
    }

    static func lyricsText(_ result: LyricsResult) -> String {
        let text = result.lines.map(\.text.trimmed).filter { !$0.isEmpty }.joined(separator: "\n")
        return text.count > 6000 ? String(text.prefix(6000)) : text
    }

    /// Items grouped so each request stays small enough for one response.
    static func chunks(_ items: [Item], maxUnits: Int = maxChunkUnits, maxItems: Int = maxChunkItems) -> [[Item]] {
        var chunks: [[Item]] = []
        var current: [Item] = []
        var units = 0
        for item in items {
            if !current.isEmpty && (current.count >= maxItems || units + item.units.count > maxUnits) {
                chunks.append(current)
                current = []
                units = 0
            }
            current.append(item)
            units += item.units.count
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    static func itemsJSON(_ items: [Item]) -> String {
        let array: [[String: Any]] = items.enumerated().map { index, item in
            [
                "i": index,
                "n": item.units.count,
                "r": item.pronunciation,
                "u": item.units.map { [$0.text, $0.startTimeMs, $0.endTimeMs] as [Any] }
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    /// The same prompt as the desktop app's buildTimedPronunciationPrompt.
    static func prompt(_ items: [Item], lyricsText: String, sourceLang: String) -> String {
        "You align lyric pronunciation to karaoke timing for ivLyrics.\n\n"
            + "Each item is one sung lyric line. u lists its timed karaoke units in order; each unit is [source text, start ms, end ms]. n is the number of units. r is the pronunciation of that line, already written in the reader's writing system.\n\n"
            + "Task: split r across the units so that p[k] is exactly the part of r that is sung during unit k.\n\n"
            + "Rules:\n"
            + "- Return ONLY valid JSON, no markdown or explanations: {\"l\":[{\"i\":0,\"p\":[\"...\"]}]}\n"
            + "- Return one entry per input item with the same i.\n"
            + "- p must contain exactly n strings, one per unit, in unit order. Never merge, drop, add, or reorder slots.\n"
            + "- Use only the text of r, in its original order. Joining every p of an item must give back r; spaces may only move to unit boundaries. Do not translate, re-romanize, correct, or add anything to r.\n"
            + "- Put each sound on the unit whose source text produces it: kanji/hanzi readings on their characters, okurigana and particles on their own kana, a word's syllables across that word's units, a whole word on a word unit.\n"
            + "- If a reading cannot be divided between the units of one word, keep it on the first of those units and use \"\" for the rest of that word.\n"
            + "- Units that are only spaces or punctuation get \"\" unless r has a space there, in which case use \" \".\n"
            + "- Keep the word spaces of r: end a unit's string with a space where r has a space after it.\n"
            + "- Use the timing only to understand how the line is sung (long notes, held vowels); never change r because of it.\n\n"
            + "Song lyrics for context only (do not output them):\n"
            + lyricsText + "\n\n"
            + "Input source language: " + (sourceLang.trimmed.isEmpty ? "auto" : sourceLang) + "\n"
            + "Items:\n"
            + itemsJSON(items)
    }

    /// Unit pronunciations by item key; items with a slot-count mismatch or changed letters are
    /// left out (and repaired by a smaller request).
    static func parse(_ raw: String, items: [Item]) -> [String: [String]] {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        let rows = (object["l"] as? [Any]) ?? (object["lines"] as? [Any]) ?? []
        var parsed: [String: [String]] = [:]
        for case let entry as [String: Any] in rows {
            let index = (entry["i"] as? Int) ?? (entry["index"] as? Int) ?? -1
            guard items.indices.contains(index), let values = entry["p"] as? [Any] else { continue }
            let item = items[index]
            guard values.count == item.units.count else { continue }
            let parts = values.map { ($0 as? String) ?? "" }
            if isValidParts(parts, length: item.units.count) && spells(parts, item.pronunciation) {
                parsed[item.key] = parts
            }
        }
        return parsed
    }
}
