import Foundation

struct LyricsTokenizerToken {
    let surface: String
    let start: Int
    let end: Int
    let partOfSpeech: String?
    let partOfSpeechDetail: String?
    let lemma: String?
    let conjugation: String?
}

protocol LyricsTokenizerAdapter {
    func tokenize(_ text: String, locale: String) -> [LyricsTokenizerToken]
}

/// Client-side TinySegmenter 0.2 adapter using the bundled, versioned model.
final class TinyJapaneseTokenizerAdapter: LyricsTokenizerAdapter {
    private static let numericKanji = "一二三四五六七八九十百千万億兆"

    private let bias: Int
    private let weights: [String: [String: Int]]

    convenience init?() {
        guard let url = Bundle.main.url(forResource: "tiny_segmenter_model", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        self.init(modelData: data)
    }

    init?(modelData data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawWeights = root["weights"] as? [String: Any],
              let bias = (rawWeights["BIAS"] as? NSNumber)?.intValue else {
            return nil
        }
        var parsed: [String: [String: Int]] = [:]
        for (name, rawTable) in rawWeights {
            guard let table = rawTable as? [String: Any] else { continue }
            parsed[name] = table.reduce(into: [:]) { result, entry in
                if let value = entry.value as? NSNumber { result[entry.key] = value.intValue }
            }
        }
        self.bias = bias
        self.weights = parsed
    }

    func tokenize(_ text: String, locale: String) -> [LyricsTokenizerToken] {
        tokenRecords(segment(text), in: text)
    }

    private func segment(_ input: String) -> [String] {
        guard !input.isEmpty else { return [] }
        let segments = ["B3", "B2", "B1"] + input.map(String.init) + ["E1", "E2", "E3"]
        let types = ["O", "O", "O"] + input.map { characterType(String($0)) } + ["O", "O", "O"]
        var result: [String] = []
        var word = segments[3]
        var p1 = "U"
        var p2 = "U"
        var p3 = "U"
        for index in 4..<(segments.count - 3) {
            let w1 = segments[index - 3], w2 = segments[index - 2], w3 = segments[index - 1]
            let w4 = segments[index], w5 = segments[index + 1], w6 = segments[index + 2]
            let c1 = types[index - 3], c2 = types[index - 2], c3 = types[index - 1]
            let c4 = types[index], c5 = types[index + 1], c6 = types[index + 2]
            var value = bias
            value += score("UP1", p1) + score("UP2", p2) + score("UP3", p3)
            value += score("BP1", p1 + p2) + score("BP2", p2 + p3)
            value += score("UW1", w1) + score("UW2", w2) + score("UW3", w3)
            value += score("UW4", w4) + score("UW5", w5) + score("UW6", w6)
            value += score("BW1", w2 + w3) + score("BW2", w3 + w4) + score("BW3", w4 + w5)
            value += score("TW1", w1 + w2 + w3) + score("TW2", w2 + w3 + w4)
            value += score("TW3", w3 + w4 + w5) + score("TW4", w4 + w5 + w6)
            value += score("UC1", c1) + score("UC2", c2) + score("UC3", c3)
            value += score("UC4", c4) + score("UC5", c5) + score("UC6", c6)
            value += score("BC1", c2 + c3) + score("BC2", c3 + c4) + score("BC3", c4 + c5)
            value += score("TC1", c1 + c2 + c3) + score("TC2", c2 + c3 + c4)
            value += score("TC3", c3 + c4 + c5) + score("TC4", c4 + c5 + c6)
            value += score("UQ1", p1 + c1) + score("UQ2", p2 + c2) + score("UQ3", p3 + c3)
            value += score("BQ1", p2 + c2 + c3) + score("BQ2", p2 + c3 + c4)
            value += score("BQ3", p3 + c2 + c3) + score("BQ4", p3 + c3 + c4)
            value += score("TQ1", p2 + c1 + c2 + c3) + score("TQ2", p2 + c2 + c3 + c4)
            value += score("TQ3", p3 + c1 + c2 + c3) + score("TQ4", p3 + c2 + c3 + c4)

            var current = "O"
            if value > 0 {
                result.append(word)
                word = ""
                current = "B"
            }
            p1 = p2
            p2 = p3
            p3 = current
            word += segments[index]
        }
        result.append(word)
        return result
    }

    private func score(_ table: String, _ key: String) -> Int {
        weights[table]?[key] ?? 0
    }

    private func characterType(_ value: String) -> String {
        guard let scalar = value.unicodeScalars.first else { return "O" }
        let code = scalar.value
        if Self.numericKanji.contains(value) { return "M" }
        if (0x4E00...0x9FA0).contains(code) || "々〆ヵヶ".contains(value) { return "H" }
        if (0x3041...0x3093).contains(code) { return "I" }
        if (0x30A1...0x30F4).contains(code) || code == 0x30FC
            || (0xFF71...0xFF9D).contains(code) || code == 0xFF9E || code == 0xFF70 { return "K" }
        if (0x61...0x7A).contains(code) || (0x41...0x5A).contains(code)
            || (0xFF41...0xFF5A).contains(code) || (0xFF21...0xFF3A).contains(code) { return "A" }
        if (0x30...0x39).contains(code) || (0xFF10...0xFF19).contains(code) { return "N" }
        return "O"
    }

    private func tokenRecords(_ surfaces: [String], in text: String) -> [LyricsTokenizerToken] {
        let characters = text.map(String.init)
        var cursor = 0
        var output: [LyricsTokenizerToken] = []
        for surface in surfaces where !surface.isEmpty {
            let token = surface.map(String.init)
            guard let start = find(token, in: characters, from: cursor) else { return [] }
            let end = start + token.count
            output.append(LyricsTokenizerToken(
                surface: surface,
                start: start,
                end: end,
                partOfSpeech: nil,
                partOfSpeechDetail: nil,
                lemma: nil,
                conjugation: nil
            ))
            cursor = end
        }
        return output
    }

    private func find(_ needle: [String], in haystack: [String], from start: Int) -> Int? {
        guard !needle.isEmpty, start <= haystack.count - needle.count else { return nil }
        for index in start...(haystack.count - needle.count) where Array(haystack[index..<(index + needle.count)]) == needle {
            return index
        }
        return nil
    }
}
