import Foundation

var failures: [String] = []

func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    if !condition() {
        failures.append(name)
    }
}

let lineText = "缶蹴りとケイドロで遊ぶ"
let unsorted = [
    CulturalAnnotation(lineIndex: 0, expression: "ケイドロ", note: "A local children's game. More detail."),
    CulturalAnnotation(lineIndex: 0, expression: "缶蹴り", note: "A Japanese can-kicking game."),
    CulturalAnnotation(lineIndex: 1, expression: "夕焼け小焼け", note: "A song used for evening return-home broadcasts.")
]
let lineAnnotations = CulturalAnnotation.forLine(unsorted, lineIndex: 0, text: lineText)

expect(lineAnnotations.map(\.expression) == ["缶蹴り", "ケイドロ"], "annotations sort by expression position")
expect(
    CulturalAnnotation.annotateText(lineText, annotations: lineAnnotations)
        == "缶蹴り[1]とケイドロ[2]で遊ぶ",
    "markers are numbered within the line"
)

let nextLine = "夕焼け小焼けが流れる"
let nextAnnotations = CulturalAnnotation.forLine(unsorted, lineIndex: 1, text: nextLine)
expect(
    CulturalAnnotation.annotateText(nextLine, annotations: nextAnnotations)
        == "夕焼け小焼け[1]が流れる",
    "marker numbering resets on the next line"
)

let syllables = [
    LyricsLine.Syllable(text: "缶蹴り", startTimeMs: 100, endTimeMs: 300),
    LyricsLine.Syllable(text: "と", startTimeMs: 300, endTimeMs: 350),
    LyricsLine.Syllable(text: "ケイドロ", startTimeMs: 350, endTimeMs: 600)
]
let annotatedSyllables = CulturalAnnotation.annotateSyllables(
    text: "缶蹴りとケイドロ",
    syllables: syllables,
    annotations: lineAnnotations
)
expect(annotatedSyllables.map(\.text).joined() == "缶蹴り[1]とケイドロ[2]", "timed syllables receive markers")
expect(
    zip(syllables, annotatedSyllables).allSatisfy {
        $0.startTimeMs == $1.startTimeMs && $0.endTimeMs == $1.endTimeMs
    },
    "marker insertion preserves syllable timing"
)
expect(
    CulturalAnnotation.compactNote("First sentence. Second sentence.") == "First sentence.",
    "notes keep only the first sentence"
)
expect(CulturalAnnotation.compactNote(String(repeating: "a", count: 90)).count == 72, "notes are capped at 72 characters")

let languages = [
    "ko", "en", "zh-CN", "zh-TW", "ja", "hi", "es", "fr", "ar", "fa", "de",
    "ru", "sv", "pt", "bn", "cs", "it", "th", "vi", "id", "ms", "tr"
]
let localizationKeys = [
    "setting.cultural_annotations",
    "setting.cultural_annotations_desc",
    "setting.cultural_font_family",
    "setting.cultural_font_size",
    "setting.cultural_font_weight",
    "setting.cultural_opacity",
    "loading.cultural_annotations",
    "font.pretendard",
    "font.system",
    "font.serif",
    "font.monospace",
    "button.regenerate_cultural_annotations"
]
for language in languages {
    for key in localizationKeys {
        expect(
            CulturalAnnotationI18n.value(language: language, key: key)?.isEmpty == false,
            "missing \(language) translation for \(key)"
        )
    }
}

guard failures.isEmpty else {
    fatalError("Cultural annotation regressions:\n\(failures.joined(separator: "\n"))")
}

print("Cultural annotation tests passed.")
