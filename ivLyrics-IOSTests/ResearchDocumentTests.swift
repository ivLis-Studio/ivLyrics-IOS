import XCTest
@testable import ivLyrics_IOS

final class ResearchDocumentTests: XCTestCase {
    func testProviderDocumentParsesEditorialSectionsAndSources() throws {
        let root: [String: Any] = [
            "language": "ko",
            "metadata": ["title": "Song", "artist": "Artist"],
            "editorial_thesis": [
                "hook": ["surprise": "예상 밖의 연결"],
                "one_sentence": "중심 논지",
                "expanded": "확장 설명"
            ],
            "overview": ["headline": "개요 제목", "paragraphs": ["개요 본문"]],
            "trivia": ["items": [["title": "재밌는 사실", "body": "근거 있는 내용", "source_url": "https://example.com/fact"]]],
            "media_gallery": [[
                "type": "image", "title": "공식 이미지",
                "image_url": "https://example.com/image.jpg", "source_url": "https://example.com/fact"
            ]],
            "sources": [["title": "Example", "url": "https://example.com/fact"]]
        ]
        let result = try XCTUnwrap(ResearchDocument.fromProvider(root, targetLang: "ko"))
        XCTAssertEqual(result.thesis, "중심 논지")
        XCTAssertEqual(result.sections.first?.id, "overview")
        XCTAssertEqual(result.funFacts.count, 1)
        XCTAssertEqual(result.mediaGallery?.first?.imageURL, "https://example.com/image.jpg")
        XCTAssertEqual(result.sources.first?.url, "https://example.com/fact")
    }

    func testStreamParserPublishesCompletedTopLevelValues() throws {
        let parser = ResearchStreamParser()
        XCTAssertNil(parser.append("{\"language\":\"ko\",\"metadata\":{\"title\":\"Song\"},", targetLang: "ko"))
        let partial = parser.append("\"editorial_thesis\":{\"one_sentence\":\"중심 논지\",\"expanded\":\"설명\"},", targetLang: "ko")
        XCTAssertEqual(partial?.thesis, "중심 논지")
        let complete = parser.append("\"overview\":{\"headline\":\"개요\",\"paragraphs\":[\"본문\"]},\"sources\":[]}", targetLang: "ko")
        XCTAssertEqual(complete?.sections.first?.headline, "개요")
    }

    func testResearchI18nKeysExistForAllLanguages() throws {
        let data = try Data(contentsOf: Bundle.main.url(forResource: "AppI18nStrings", withExtension: "json")!)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: String]])
        let keys = ["tmi.title", "research.thesis", "research.fun_facts", "research.timeline", "research.sources", "research.web_fallback_warning", "research.font_decrease", "research.font_increase"]
        XCTAssertEqual(root.count, 22)
        for (language, table) in root {
            for key in keys {
                XCTAssertFalse(table[key, default: ""].isEmpty, "\(language) missing \(key)")
            }
        }
    }

    func testExpandedSectionsMythChecksAndYouTubeThumbnail() throws {
        let root: [String: Any] = [
            "language": "ko",
            "editorial_thesis": ["one_sentence": "중심 논지"],
            "basic_information": ["table": [["label": "발매", "value": "2026"]]],
            "chorus_analysis": ["headline": "후렴", "paragraphs": ["본문"]],
            "trivia": ["myth_checks": [["claim": "소문", "explanation": "검증 결과"]]],
            "media_gallery": [["type": "youtube", "title": "Official video", "url": "https://youtu.be/dQw4w9WgXcQ"]]
        ]
        let result = try XCTUnwrap(ResearchDocument.fromProvider(root, targetLang: "ko"))
        XCTAssertTrue(result.sections.contains { $0.id == "basic_information" })
        XCTAssertTrue(result.sections.contains { $0.id == "chorus_analysis" })
        XCTAssertEqual(result.funFacts.count, 1)
        XCTAssertEqual(result.mediaGallery?.first?.displayImageURL, "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
    }

    func testLocalizedResearchWarningsDoNotLeakEnglishProductName() throws {
        let data = try Data(contentsOf: Bundle.main.url(forResource: "AppI18nStrings", withExtension: "json")!)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: String]])
        for (language, table) in root where language != "en" {
            XCTAssertFalse(table["research.web_fallback_warning", default: ""].contains("Research"), "\(language) contains untranslated Research")
        }
    }
}
