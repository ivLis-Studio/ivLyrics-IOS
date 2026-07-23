import Foundation

struct CulturalAnnotation: Codable, Equatable, Hashable, Sendable, Identifiable {
    var lineIndex: Int
    var expression: String
    var note: String

    var id: String {
        "\(lineIndex)\n\(expression)"
    }

    init(lineIndex: Int, expression: String, note: String) {
        self.lineIndex = max(0, lineIndex)
        self.expression = expression.trimmed
        self.note = Self.compactNote(note)
    }

    static func forLine(_ annotations: [CulturalAnnotation], lineIndex: Int, text: String) -> [CulturalAnnotation] {
        annotations
            .filter {
                $0.lineIndex == lineIndex
                    && !$0.expression.isEmpty
                    && !$0.note.isEmpty
                    && text.contains($0.expression)
            }
            .sorted {
                let left = text.range(of: $0.expression)?.lowerBound ?? text.endIndex
                let right = text.range(of: $1.expression)?.lowerBound ?? text.endIndex
                if left != right { return left < right }
                return $0.expression.count < $1.expression.count
            }
    }

    static func annotateText(_ text: String, annotations: [CulturalAnnotation]) -> String {
        guard !text.isEmpty, !annotations.isEmpty else { return text }
        var result = text
        for marker in markerInsertions(in: text, annotations: annotations).reversed() {
            let index = result.index(result.startIndex, offsetBy: marker.offset)
            result.insert(contentsOf: "[\(marker.number)]", at: index)
        }
        return result
    }

    static func annotateSyllables(
        text: String,
        syllables: [LyricsLine.Syllable],
        annotations: [CulturalAnnotation]
    ) -> [LyricsLine.Syllable] {
        guard !syllables.isEmpty, !annotations.isEmpty else { return syllables }
        let syllableText = syllables.map(\.text).joined()
        let source = text == syllableText ? text : syllableText
        let markers = markerInsertions(in: source, annotations: annotations)
        guard !markers.isEmpty else { return syllables }

        var sourceOffset = 0
        var markerIndex = 0
        return syllables.map { syllable in
            let length = syllable.text.count
            let endOffset = sourceOffset + length
            var value = syllable.text
            var localMarkers: [MarkerInsertion] = []
            while markerIndex < markers.count, markers[markerIndex].offset <= endOffset {
                let marker = markers[markerIndex]
                markerIndex += 1
                if marker.offset > sourceOffset {
                    localMarkers.append(marker)
                }
            }
            for marker in localMarkers.reversed() {
                let index = value.index(value.startIndex, offsetBy: marker.offset - sourceOffset)
                value.insert(contentsOf: "[\(marker.number)]", at: index)
            }
            sourceOffset = endOffset
            return LyricsLine.Syllable(
                text: value,
                startTimeMs: syllable.startTimeMs,
                endTimeMs: syllable.endTimeMs
            )
        }
    }

    static func markerInsertions(
        in text: String,
        annotations: [CulturalAnnotation]
    ) -> [MarkerInsertion] {
        guard !text.isEmpty else { return [] }
        var searchStart = text.startIndex
        var result: [MarkerInsertion] = []
        for (index, annotation) in annotations.enumerated() where !annotation.expression.isEmpty {
            var range = text.range(of: annotation.expression, range: searchStart..<text.endIndex)
            if range == nil {
                range = text.range(of: annotation.expression)
            }
            guard let range else { continue }
            result.append(MarkerInsertion(
                offset: text.distance(from: text.startIndex, to: range.upperBound),
                number: index + 1
            ))
            searchStart = range.upperBound
        }
        return result.sorted { $0.offset < $1.offset }
    }

    static func compactNote(_ value: String) -> String {
        var note = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmed
        guard !note.isEmpty else { return "" }
        if let sentenceEnd = note.firstIndex(where: { ".!?。！？".contains($0) }) {
            note = String(note[...sentenceEnd])
        }
        if note.count > 72 {
            note = String(note.prefix(71)).trimmed + "…"
        }
        return note
    }

    struct MarkerInsertion: Sendable {
        var offset: Int
        var number: Int
    }
}
