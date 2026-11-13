import Foundation

/// Pronunciation generated per sung unit of the original, the same as the desktop app's
/// PronunciationSlots.js and the Android app.
///
/// Karaoke songs request their pronunciation already split over the units of each line: single
/// characters for Japanese, Chinese and Korean text, whole words for space-separated text, and
/// punctuation attached to the unit it touches. The line pronunciation is the joined slots, and
/// the part sung during each karaoke syllable is derived from them locally, so a timing change
/// never needs a new request.
enum PronunciationSlots {
    /// Bump when the unit split or the stored shape changes.
    static let version = 1
    static let maxChunkUnits = 360
    static let maxChunkItems = 28
    /// Normalized pronunciation notations (AppSettings.pronunciationNotationLatin / IPA).
    static let latinNotation = "latin"
    static let ipaNotation = "ipa"

    /// One sung unit of a line; offsets count Characters of the trimmed line.
    struct Unit: Equatable {
        let text: String
        let start: Int
        let end: Int
        let gapBefore: Bool
    }

    /// A line sent to AI: its request index and unit texts.
    struct Item: Equatable {
        let index: Int
        let units: [String]
    }

    private enum Kind { case space, char, word, punct }

    private static let syllabicRanges: [ClosedRange<UInt32>] = [
        0x1100...0x11FF, 0x2E80...0x2FDF, 0x3005...0x3007, 0x3021...0x3029, 0x3038...0x303B,
        0x3040...0x30FF, 0x3100...0x312F, 0x3130...0x318F, 0x31A0...0x31BF, 0x31F0...0x31FF,
        0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA960...0xA97F, 0xAC00...0xD7FF, 0xF900...0xFAFF,
        0xFF66...0xFF9F, 0xFFA0...0xFFDC, 0x1B000...0x1B16F, 0x20000...0x323AF
    ]

    private static func isSoundScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    private static func isSyllabicScalar(_ scalar: Unicode.Scalar) -> Bool {
        syllabicRanges.contains { $0.contains(scalar.value) }
    }

    private static func kind(_ character: Character) -> Kind {
        if character.isWhitespace { return .space }
        if character.unicodeScalars.contains(where: isSoundScalar) {
            return character.unicodeScalars.contains(where: isSyllabicScalar) ? .char : .word
        }
        return .punct
    }

    static func hasSound(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isSoundScalar)
    }

    static func normalizeLine(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    private static func isWordJoiner(_ character: Character) -> Bool {
        character == "'" || character == "\u{2019}"
    }

    /// Sung units of one line, in order.
    static func splitUnits(_ text: String) -> [Unit] {
        let characters = Array(text)
        let kinds = characters.map(kind)
        struct Draft { var start: Int; var end: Int; var kind: Kind; var gapBefore: Bool; var closed = false }
        var units: [Draft] = []
        var gap = false
        var pending: Draft?
        for (index, character) in characters.enumerated() {
            let itemKind = kinds[index]
            if itemKind == .space {
                gap = true
                continue
            }
            if itemKind == .punct {
                let free = !units.isEmpty && !gap && pending == nil
                if free, isWordJoiner(character), units[units.count - 1].kind == .word, !units[units.count - 1].closed,
                   index + 1 < kinds.count, kinds[index + 1] == .word {
                    units[units.count - 1].end = index + 1
                    continue
                }
                if free {
                    units[units.count - 1].end = index + 1
                    units[units.count - 1].closed = true
                    continue
                }
                if var waiting = pending, !gap {
                    waiting.end = index + 1
                    pending = waiting
                } else if let waiting = pending {
                    units.append(Draft(start: waiting.start, end: waiting.end, kind: .punct, gapBefore: waiting.gapBefore))
                    pending = Draft(start: index, end: index + 1, kind: .punct, gapBefore: true)
                } else {
                    pending = Draft(start: index, end: index + 1, kind: .punct, gapBefore: !units.isEmpty && gap)
                }
                gap = false
                continue
            }
            if itemKind == .word, let last = units.last, last.kind == .word, !last.closed, !gap, pending == nil {
                units[units.count - 1].end = index + 1
                continue
            }
            if let waiting = pending, gap {
                // Punctuation standing between spaces is a unit of its own.
                units.append(Draft(start: waiting.start, end: waiting.end, kind: .punct, gapBefore: waiting.gapBefore))
                pending = nil
            }
            units.append(Draft(
                start: pending?.start ?? index,
                end: index + 1,
                kind: itemKind,
                gapBefore: pending?.gapBefore ?? (!units.isEmpty && gap)
            ))
            pending = nil
            gap = false
        }
        if let waiting = pending {
            units.append(Draft(start: waiting.start, end: waiting.end, kind: .punct, gapBefore: waiting.gapBefore))
        }
        return units.map { draft in
            Unit(text: String(characters[draft.start..<draft.end]), start: draft.start, end: draft.end, gapBefore: draft.gapBefore)
        }
    }

    private static func cleanPart(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// The line pronunciation of the slots: the original's spaces return between units, and a
    /// slot ending with a space marks a word break.
    static func join(_ units: [Unit], _ parts: [String]) -> String {
        var output = ""
        var needSpace = false
        for (index, unit) in units.enumerated() {
            if unit.gapBefore { needSpace = true }
            let raw = cleanPart(index < parts.count ? parts[index] : "")
            let core = raw.trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix(" ") { needSpace = true }
            guard !core.isEmpty else { continue }
            if needSpace && !output.isEmpty { output += " " }
            output += core
            needSpace = raw.hasSuffix(" ")
        }
        return output
    }

    /// Pronunciation sung during each karaoke syllable of a line whose slots are known. A unit
    /// sung over several syllables is spread over them. Nil when the syllables do not split into
    /// the units the slots were made for.
    static func deriveSyllableParts(
        _ syllableTexts: [String],
        _ parts: [String],
        distribute: ([String], String) -> [String]
    ) -> [String]? {
        guard !syllableTexts.isEmpty else { return nil }
        let joined = Array(syllableTexts.joined())
        let counts = syllableTexts.map(\.count)
        guard counts.reduce(0, +) == joined.count else { return nil }
        var leading = 0
        while leading < joined.count, joined[leading].isWhitespace { leading += 1 }
        var trailing = joined.count
        while trailing > leading, joined[trailing - 1].isWhitespace { trailing -= 1 }
        let units = splitUnits(String(joined[leading..<trailing]))
        guard !units.isEmpty, units.count == parts.count else { return nil }
        var ranges: [Range<Int>] = []
        var offset = 0
        for count in counts {
            ranges.append(offset..<(offset + count))
            offset += count
        }
        var result = Array(repeating: "", count: syllableTexts.count)
        var last = -1
        var needSpace = false
        for (index, unit) in units.enumerated() {
            if unit.gapBefore { needSpace = true }
            let raw = cleanPart(parts[index])
            let core = raw.trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix(" ") { needSpace = true }
            guard !core.isEmpty else { continue }
            if needSpace, last >= 0, !result[last].hasSuffix(" ") { result[last] += " " }
            needSpace = raw.hasSuffix(" ")
            let start = leading + unit.start
            let end = leading + unit.end
            var overlapping: [(syllable: Int, text: String)] = []
            for (syllable, range) in ranges.enumerated() {
                let from = max(start, range.lowerBound)
                let to = min(end, range.upperBound)
                if to > from { overlapping.append((syllable, String(joined[from..<to]))) }
            }
            guard let first = overlapping.first else { continue }
            if overlapping.count == 1 {
                result[first.syllable] += core
                last = max(last, first.syllable)
                continue
            }
            let split = distribute(overlapping.map(\.text), core)
            for (position, item) in overlapping.enumerated() {
                let piece = position < split.count ? split[position] : ""
                guard !piece.isEmpty else { continue }
                result[item.syllable] += piece
                last = max(last, item.syllable)
            }
        }
        return result.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ? result : nil
    }

    // MARK: - Request

    /// Lines with sound, as the request sends them.
    static func items(_ texts: [String]) -> [Item] {
        texts.enumerated().compactMap { index, text in
            guard hasSound(text) else { return nil }
            let units = splitUnits(normalizeLine(text)).map(\.text)
            return units.isEmpty ? nil : Item(index: index, units: units)
        }
    }

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
        let array: [[String: Any]] = items.map { ["i": $0.index, "n": $0.units.count, "u": $0.units] }
        guard let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    static let repairNote = "Your previous answer for these lines had the wrong number of p strings or the wrong writing system. Count u again for every line: p must have exactly n strings."

    private static func examples(notation: String, lang: String, outputScript: String) -> String {
        let language = lang.lowercased()
        if notation == ipaNotation {
            return """
            - 夢ならば: u=["夢","な","ら","ば"] → p=["jɯme ","na","ɾa","ba"]
            - 今日も: u=["今","日","も"] → p=["kʲoː","","mo"]
            - hold me tight: u=["hold","me","tight"] → p=["hoʊld","mi","taɪt"]
            """
        }
        if notation == latinNotation || language == "en" || language.hasPrefix("en-") {
            return """
            - 夢ならば: u=["夢","な","ら","ば"] → p=["yume ","na","ra","ba"] (reads "yume naraba")
            - 今日も: u=["今","日","も"] → p=["kyou","","mo"]
            - 走って: u=["走","っ","て"] → p=["hashi","t","te"]
            - 사랑해 너를: u=["사","랑","해","너","를"] → p=["sa","rang","hae","neo","reul"] (reads "saranghae neoreul")
            """
        }
        if language == "ko" || language.hasPrefix("ko-") {
            return """
            - 夢ならば: u=["夢","な","ら","ば"] → p=["유메","나","라","바"]
            - 今日も: u=["今","日","も"] → p=["쿄오","","모"]
            - 走って: u=["走","っ","て"] → p=["하싯","","테"]
            - hold me tight: u=["hold","me","tight"] → p=["홀드","미","타잇"]
            """
        }
        return """
        - 夢ならば: u=["夢","な","ら","ば"] → 4 strings: the reading of 夢, then of な, ら and ば, all in \(outputScript).
        - 今日も: u=["今","日","も"] → the whole reading of 今日 on 今, "" on 日, then the reading of も.
        - hold me tight: u=["hold","me","tight"] → one pronunciation per word.
        """
    }

    /// The same request as the desktop app's buildPronunciationSlotPrompt, with this app's
    /// script policy.
    static func prompt(
        _ items: [Item],
        lang: String,
        sourceLang: String,
        notation: String,
        scriptInstruction: String,
        outputScript: String,
        audience: String
    ) -> String {
        let source = sourceLang.trimmingCharacters(in: .whitespaces).isEmpty ? "auto" : sourceLang
        return """
        You are the pronunciation conversion system for ivLyrics karaoke.

        Convert lyric sounds for \(audience), written ONLY in \(outputScript).
        \(scriptInstruction)

        TASK:
        Each item is one lyric line split into its sung units, in order: i is the line index, u lists the units and n is how many there are. Japanese, Chinese and Korean text is split into single characters, space-separated text into whole words, and punctuation stays attached to a neighbouring unit.
        Read the whole line first and decide its natural sung pronunciation in context. Then return p: exactly n strings, where p[k] is the part of that pronunciation sung on unit u[k].

        RULES:
        - Return ONLY valid JSON, no markdown or explanations. The first character must be { and the last must be }.
        - Shape: {"l":[{"i":0,"p":["..."]}]} with one entry per input item, keeping its i.
        - p must contain exactly n strings in unit order. Never merge, drop, add, or reorder slots. Count u before answering: if n is 12, p has exactly 12 strings.
        - Put each sound on the unit that produces it: a kanji/hanzi reading on that character, okurigana and particles on their own kana, a whole word's pronunciation on a word unit.
        - Small kana such as ゃ ゅ ょ ぁ ぃ ぅ ぇ ぉ join the previous kana's sound: give them "". Put the sound of っ, ー and ん on their own unit when the output script can write it there; otherwise use "".
        - When a reading cannot be divided between characters (for example 今日 or 大人), put the whole reading on the first character of that word and "" on the rest of it.
        - Particles は, へ, を use their particle pronunciation when used as particles.
        - Use "" for units without sound (punctuation and symbols).
        - Spaces of the original line are restored automatically between units. Where the natural pronunciation has a word break inside unspaced text (Japanese, Chinese), end that unit's string with one space so the joined line reads naturally.
        - Joining the p of a line must give one natural pronunciation of the whole line. This is pronunciation, not translation: never translate the meaning.

        SLOT EXAMPLES:
        \(examples(notation: notation, lang: lang, outputScript: outputScript))

        Input source language: \(source).
        Items:
        \(itemsJSON(items))
        """
    }

    private static let latinLetterRanges: [ClosedRange<UInt32>] = [
        0x41...0x5A, 0x61...0x7A, 0xAA...0xAA, 0xBA...0xBA, 0xC0...0x24F, 0x250...0x2B8, 0x2E0...0x2E4,
        0x1D00...0x1DBF, 0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF, 0xAB30...0xAB6F, 0xFB00...0xFB06,
        0xFF21...0xFF3A, 0xFF41...0xFF5A
    ]
    private static let ipaDisallowedRanges: [ClosedRange<UInt32>] = [
        0x0400...0x052F, 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0x0900...0x097F, 0x0980...0x09FF,
        0x0E00...0x0E7F, 0xFB50...0xFDFF, 0xFE70...0xFEFF
    ]

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    /// Latin and IPA notations fix the output writing system.
    static func isInNotationScript(_ text: String, notation: String) -> Bool {
        if notation == latinNotation {
            return !text.unicodeScalars.contains { scalar in
                isLetter(scalar) && !latinLetterRanges.contains { $0.contains(scalar.value) }
            }
        }
        if notation == ipaNotation {
            return !text.unicodeScalars.contains { scalar in
                isSyllabicScalar(scalar) || ipaDisallowedRanges.contains { $0.contains(scalar.value) }
            }
        }
        return true
    }

    /// Unit pronunciations by request index; lines with a wrong slot count, no sound or the
    /// wrong writing system are left out (and repaired by a smaller request).
    static func parse(_ raw: String, items: [Item], notation: String) -> [Int: [String]] {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        let rows = (object["l"] as? [Any]) ?? (object["lines"] as? [Any]) ?? []
        let expected = Dictionary(items.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        var parsed: [Int: [String]] = [:]
        for case let entry as [String: Any] in rows {
            let index = (entry["i"] as? Int) ?? (entry["index"] as? Int) ?? -1
            guard let item = expected[index], let values = entry["p"] as? [Any], values.count == item.units.count else { continue }
            let parts = values.map { ($0 as? String) ?? "" }
            guard parts.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                  isInNotationScript(parts.joined(), notation: notation) else { continue }
            parsed[index] = parts
        }
        return parsed
    }

    // MARK: - Stored slots

    struct Stored: Codable, Equatable {
        var v: Int
        /// Unit pronunciation by line text.
        var lines: [String: [String]]
    }

    /// Slots by line text for the requests that got them.
    static func stored(texts: [String], slots: [Int: [String]]) -> Stored {
        var lines: [String: [String]] = [:]
        for (index, parts) in slots where texts.indices.contains(index) {
            let key = normalizeLine(texts[index])
            guard splitUnits(key).count == parts.count else { continue }
            lines[key] = parts
        }
        return Stored(v: version, lines: lines)
    }
}
