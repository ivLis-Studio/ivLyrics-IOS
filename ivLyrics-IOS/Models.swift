import Foundation
import NaturalLanguage

enum InstrumentalBreakMarker {
    private static let htmlTagRegex = try? NSRegularExpression(
        pattern: #"</?[a-z][^>]*>"#,
        options: [.caseInsensitive]
    )
    private static let numericEntityRegex = try? NSRegularExpression(
        pattern: #"&#(?:x([0-9a-f]+)|([0-9]+));?"#,
        options: [.caseInsensitive]
    )
    private static let wrappers: [(Character, Character)] = [
        ("<", ">"), ("＜", "＞"), ("〈", "〉"), ("《", "》"),
        ("[", "]"), ("［", "］"), ("【", "】"),
        ("(", ")"), ("（", "）"), ("{", "}"), ("｛", "｝")
    ]

    static func isMarkerText(_ text: String, allowEmpty: Bool = true) -> Bool {
        let normalized = unwrap(decodeEntities(text))
            .precomposedStringWithCompatibilityMapping
            .trimmed
        if normalized.isEmpty { return allowEmpty }
        return normalized.unicodeScalars.allSatisfy(isMarkerScalar)
    }

    static func isMusicNoteMarkerText(_ text: String) -> Bool {
        let normalized = unwrap(decodeEntities(text))
            .precomposedStringWithCompatibilityMapping
            .trimmed
        guard !normalized.isEmpty,
              normalized.unicodeScalars.allSatisfy(isMarkerScalar) else { return false }
        return normalized.unicodeScalars.contains(where: isMusicNoteScalar)
    }

    private static func decodeEntities(_ text: String) -> String {
        var decoded = text
        if decoded.contains("&") {
            decoded = decoded
                .replacingOccurrences(of: "&amp;", with: "&", options: [.caseInsensitive])
                .replacingOccurrences(of: "&lt;", with: "<", options: [.caseInsensitive])
                .replacingOccurrences(of: "&gt;", with: ">", options: [.caseInsensitive])
                .replacingOccurrences(of: "&nbsp;", with: " ", options: [.caseInsensitive])
                .replacingOccurrences(of: "&sung;", with: "♪", options: [.caseInsensitive])
                .replacingOccurrences(of: "&flat;", with: "♭", options: [.caseInsensitive])
                .replacingOccurrences(of: "&natur;", with: "♮", options: [.caseInsensitive])
                .replacingOccurrences(of: "&sharp;", with: "♯", options: [.caseInsensitive])
        }

        if let numericEntityRegex {
            let matches = numericEntityRegex.matches(
                in: decoded,
                range: NSRange(decoded.startIndex..<decoded.endIndex, in: decoded)
            )
            for match in matches.reversed() {
                let hexRange = Range(match.range(at: 1), in: decoded)
                let decimalRange = Range(match.range(at: 2), in: decoded)
                let digits = hexRange.map { String(decoded[$0]) } ?? decimalRange.map { String(decoded[$0]) }
                let radix = hexRange == nil ? 10 : 16
                guard let digits,
                      let value = UInt32(digits, radix: radix),
                      let scalar = UnicodeScalar(value),
                      let wholeRange = Range(match.range, in: decoded) else { continue }
                decoded.replaceSubrange(wholeRange, with: String(scalar))
            }
        }

        guard decoded.contains("<"), let htmlTagRegex else { return decoded }
        return htmlTagRegex.stringByReplacingMatches(
            in: decoded,
            range: NSRange(decoded.startIndex..<decoded.endIndex, in: decoded),
            withTemplate: ""
        )
    }

    private static func unwrap(_ text: String) -> String {
        var value = text.trimmed
        for _ in 0..<3 {
            guard value.count >= 2,
                  let first = value.first,
                  let last = value.last,
                  wrappers.contains(where: { $0.0 == first && $0.1 == last }) else { break }
            value = String(value.dropFirst().dropLast()).trimmed
        }
        return value
    }

    private static func isMarkerScalar(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
            || value == 0x00A0
            || (value >= 0x200B && value <= 0x200F)
            || (value >= 0x202A && value <= 0x202E)
            || (value >= 0x2060 && value <= 0x2069)
            || value == 0xFE0E
            || value == 0xFE0F
            || value == 0xFEFF
            || (value >= 0x2669 && value <= 0x266F)
            || (value >= 0x1D100 && value <= 0x1D1FF)
            || (value >= 0x1F3B5 && value <= 0x1F3BC)
    }

    private static func isMusicNoteScalar(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return (value >= 0x2669 && value <= 0x266F)
            || (value >= 0x1D100 && value <= 0x1D1FF)
            || (value >= 0x1F3B5 && value <= 0x1F3BC)
    }
}

struct TrackSnapshot: Equatable, Hashable, Sendable {
    private static let isrcSeparatorsRegex = try? NSRegularExpression(pattern: #"[\s-]"#)
    private static let validIsrcRegex = try? NSRegularExpression(pattern: #"^[A-Z]{2}[A-Z0-9]{3}\d{7}$"#)
    private static let spotifyTrackURIPrefix = "spotify:track:"
    private static let spotifyTrackIdUTF8Count = 22
    private static let spotifyTrackURIUTF8Count = 36
    private static let keyWhitespacePattern = #"\s+"#
    private static let keyWhitespaceRegex = try? NSRegularExpression(pattern: keyWhitespacePattern)

    var title: String
    var artist: String
    var album: String
    var packageName: String
    var mediaId: String
    var isrc: String
    var durationMs: Int64
    var positionMs: Int64
    var lastPositionUpdate: Date
    var lastPositionUpdateUptime: TimeInterval
    var playbackSpeed: Double
    var playing: Bool
    var artworkURL: URL?

    var trackId: String {
        Self.extractSpotifyTrackId(mediaId)
    }

    init(
        title: String,
        artist: String,
        album: String = "",
        packageName: String = "ios.manual",
        mediaId: String = "",
        isrc: String = "",
        durationMs: Int64 = 0,
        positionMs: Int64 = 0,
        lastPositionUpdate: Date = Date(),
        lastPositionUpdateUptime: TimeInterval? = nil,
        playbackSpeed: Double = 1,
        playing: Bool = false,
        artworkURL: URL? = nil
    ) {
        self.title = title.trimmed
        self.artist = artist.trimmed
        self.album = album.trimmed
        self.packageName = packageName.trimmed
        self.mediaId = Self.normalizedSpotifyMediaId(mediaId)
        self.isrc = Self.normalizeIsrc(isrc)
        self.durationMs = max(0, durationMs)
        self.positionMs = max(0, positionMs)
        self.lastPositionUpdate = lastPositionUpdate
        let uptimeNow = ProcessInfo.processInfo.systemUptime
        self.lastPositionUpdateUptime = lastPositionUpdateUptime
            ?? max(0, uptimeNow - max(0, Date().timeIntervalSince(lastPositionUpdate)))
        self.playbackSpeed = playbackSpeed > 0 ? playbackSpeed : 1
        self.playing = playing
        self.artworkURL = artworkURL
    }

    var hasUsableMetadata: Bool {
        !title.isEmpty && !artist.isEmpty
    }

    var isSpotifyDjSegment: Bool {
        let normalizedArtist = Self.normalizeForKey(artist)
        guard normalizedArtist == "dj x" else { return false }
        let normalizedTitle = Self.normalizeForKey(title)
        return normalizedTitle == "welcome" || normalizedTitle == "up next"
    }

    var stableKey: String {
        let spotifyTrackId = trackId
        if !spotifyTrackId.isEmpty {
            return "spotify:\(spotifyTrackId)"
        }
        return "\(Self.normalizeForKey(title))|\(Self.normalizeForKey(artist))|\(durationMs)"
    }

    func positionNow(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Int64 {
        guard playing else {
            return clampPosition(positionMs)
        }
        let elapsed = max(0, uptime - lastPositionUpdateUptime) * 1000
        return clampPosition(positionMs + Int64((elapsed * playbackSpeed).rounded()))
    }

    func withPlayback(
        positionMs: Int64,
        playing: Bool,
        date: Date = Date(),
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TrackSnapshot {
        var copy = self
        copy.positionMs = max(0, positionMs)
        copy.playing = playing
        copy.lastPositionUpdate = date
        copy.lastPositionUpdateUptime = uptime
        return copy
    }

    static func == (lhs: TrackSnapshot, rhs: TrackSnapshot) -> Bool {
        lhs.durationMs == rhs.durationMs
            && lhs.playing == rhs.playing
            && lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.packageName == rhs.packageName
            && lhs.mediaId == rhs.mediaId
            && lhs.artworkURL == rhs.artworkURL
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(title)
        hasher.combine(artist)
        hasher.combine(album)
        hasher.combine(packageName)
        hasher.combine(mediaId)
        hasher.combine(durationMs)
        hasher.combine(playing)
        hasher.combine(artworkURL)
    }

    private func clampPosition(_ value: Int64) -> Int64 {
        if durationMs > 0 {
            return max(0, min(durationMs, value))
        }
        return max(0, value)
    }

    static func normalizeIsrc(_ value: String?) -> String {
        let source = value ?? ""
        let compact: String
        if let regex = isrcSeparatorsRegex {
            compact = regex.stringByReplacingMatches(
                in: source,
                range: NSRange(source.startIndex..<source.endIndex, in: source),
                withTemplate: ""
            )
        } else {
            compact = source.replacingOccurrences(of: #"[\s-]"#, with: "", options: .regularExpression)
        }
        let normalized = compact
            .uppercased()
            .trimmed
        let isValid: Bool
        if let regex = validIsrcRegex {
            isValid = regex.firstMatch(
                in: normalized,
                range: NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            ) != nil
        } else {
            isValid = normalized.range(of: #"^[A-Z]{2}[A-Z0-9]{3}\d{7}$"#, options: .regularExpression) != nil
        }
        return isValid ? normalized : ""
    }

    static func extractSpotifyTrackId(_ value: String?) -> String {
        let text = (value ?? "").trimmed
        let utf8Count = text.utf8.count
        if utf8Count == spotifyTrackURIUTF8Count,
           text.hasPrefix(spotifyTrackURIPrefix) {
            let candidate = text.dropFirst(spotifyTrackURIPrefix.count)
            if isAsciiSpotifyTrackId(candidate) {
                return String(candidate)
            }
        }
        if utf8Count == spotifyTrackIdUTF8Count, isAsciiSpotifyTrackId(text[...]) {
            return text
        }
        let pattern = #"(?:spotify:track:|open\.spotify\.com/track/)([A-Za-z0-9]{22})"#
        guard let match = text.range(of: pattern, options: .regularExpression) else {
            return text.range(of: #"^[A-Za-z0-9]{22}$"#, options: .regularExpression) == nil ? "" : text
        }
        let raw = String(text[match])
        if let idRange = raw.range(of: #"[A-Za-z0-9]{22}"#, options: .regularExpression) {
            return String(raw[idRange])
        }
        return ""
    }

    private static func isAsciiSpotifyTrackId(_ value: Substring) -> Bool {
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
        }
    }

    static func normalizedSpotifyMediaId(_ value: String?) -> String {
        let text = (value ?? "").trimmed
        let spotifyId = extractSpotifyTrackId(text)
        return spotifyId.isEmpty ? text : "spotify:track:\(spotifyId)"
    }

    @inline(never)
    private static func normalizeForKey(_ value: String) -> String {
        let normalized = value.trimmed.lowercased()
        guard let regex = keyWhitespaceRegex else {
            return normalized.replacingOccurrences(
                of: keyWhitespacePattern,
                with: " ",
                options: .regularExpression
            )
        }
        return regex.stringByReplacingMatches(
            in: normalized,
            range: NSRange(normalized.startIndex..<normalized.endIndex, in: normalized),
            withTemplate: " "
        )
    }
}

struct LyricsLine: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var startTimeMs: Int64
    var endTimeMs: Int64
    var text: String
    var syllables: [Syllable]
    var speaker: String
    var speakerColor: String
    var speakerFallback: String
    var kind: String
    var vocalParts: [VocalPart]
    var pronunciationText: String
    var translationText: String
    var furiganaText: String

    init(
        startTimeMs: Int64,
        endTimeMs: Int64,
        text: String,
        syllables: [Syllable] = [],
        speaker: String = "",
        speakerColor: String = "",
        speakerFallback: String = "",
        kind: String = "vocal",
        vocalParts: [VocalPart] = [],
        pronunciationText: String = "",
        translationText: String = "",
        furiganaText: String = ""
    ) {
        self.startTimeMs = max(0, startTimeMs)
        self.endTimeMs = max(max(0, startTimeMs), endTimeMs)
        self.text = text
        self.syllables = syllables
        self.speaker = speaker
        self.speakerColor = speakerColor
        self.speakerFallback = speakerFallback
        self.kind = kind.trimmed.isEmpty ? "vocal" : kind.trimmed
        self.vocalParts = vocalParts
        self.pronunciationText = pronunciationText
        self.translationText = translationText
        self.furiganaText = furiganaText
    }

    var isTimed: Bool {
        startTimeMs > 0 || endTimeMs > startTimeMs
    }

    func withSupplements(pronunciation: String, translation: String, furigana: String? = nil) -> LyricsLine {
        LyricsLine(
            startTimeMs: startTimeMs,
            endTimeMs: endTimeMs,
            text: text,
            syllables: syllables,
            speaker: speaker,
            speakerColor: speakerColor,
            speakerFallback: speakerFallback,
            kind: kind,
            vocalParts: vocalParts,
            pronunciationText: pronunciation,
            translationText: translation,
            furiganaText: furigana ?? furiganaText
        )
    }

    struct Syllable: Codable, Equatable, Sendable {
        var text: String
        var startTimeMs: Int64
        var endTimeMs: Int64
        var sourceGranularity: String?
        var inlineStyle: Bool?
        var styleKind: String?
        var styleSpeaker: String?
        var styleSpeakerColor: String?
        var styleSpeakerFallback: String?

        init(
            text: String,
            startTimeMs: Int64,
            endTimeMs: Int64,
            sourceGranularity: String? = nil,
            inlineStyle: Bool? = nil,
            styleKind: String? = nil,
            styleSpeaker: String? = nil,
            styleSpeakerColor: String? = nil,
            styleSpeakerFallback: String? = nil
        ) {
            self.text = text
            self.startTimeMs = max(0, startTimeMs)
            self.endTimeMs = max(max(0, startTimeMs), endTimeMs)
            self.sourceGranularity = sourceGranularity
            self.inlineStyle = inlineStyle
            self.styleKind = styleKind
            self.styleSpeaker = styleSpeaker
            self.styleSpeakerColor = styleSpeakerColor
            self.styleSpeakerFallback = styleSpeakerFallback
        }

        func copying(
            text: String? = nil,
            startTimeMs: Int64? = nil,
            endTimeMs: Int64? = nil,
            sourceGranularity: String? = nil
        ) -> Syllable {
            Syllable(
                text: text ?? self.text,
                startTimeMs: startTimeMs ?? self.startTimeMs,
                endTimeMs: endTimeMs ?? self.endTimeMs,
                sourceGranularity: sourceGranularity ?? self.sourceGranularity,
                inlineStyle: inlineStyle,
                styleKind: styleKind,
                styleSpeaker: styleSpeaker,
                styleSpeakerColor: styleSpeakerColor,
                styleSpeakerFallback: styleSpeakerFallback
            )
        }

        var styleKey: String {
            [
                inlineStyle == true ? "1" : "0",
                styleKind ?? "",
                styleSpeaker ?? "",
                styleSpeakerColor ?? "",
                styleSpeakerFallback ?? ""
            ].joined(separator: "|")
        }
    }

    struct VocalPart: Identifiable, Codable, Equatable, Sendable {
        var id: String
        var role: String
        var speaker: String
        var speakerColor: String
        var speakerFallback: String
        var kind: String
        var text: String
        var syllables: [Syllable]
        var pronunciationText: String
        var translationText: String
        var furiganaText: String

        var startTimeMs: Int64 {
            syllables.first?.startTimeMs ?? 0
        }

        var endTimeMs: Int64 {
            syllables.last?.endTimeMs ?? startTimeMs
        }

        init(
            id: String,
            role: String,
            speaker: String,
            speakerColor: String = "",
            speakerFallback: String = "",
            kind: String,
            text: String,
            syllables: [Syllable],
            pronunciationText: String = "",
            translationText: String = "",
            furiganaText: String = ""
        ) {
            self.id = id
            self.role = role
            self.speaker = speaker
            self.speakerColor = speakerColor
            self.speakerFallback = speakerFallback
            self.kind = kind.trimmed.isEmpty ? "vocal" : kind.trimmed
            self.text = text
            self.syllables = syllables
            self.pronunciationText = pronunciationText
            self.translationText = translationText
            self.furiganaText = furiganaText
        }

        func withSupplements(pronunciation: String, translation: String, furigana: String? = nil) -> VocalPart {
            VocalPart(
                id: id,
                role: role,
                speaker: speaker,
                speakerColor: speakerColor,
                speakerFallback: speakerFallback,
                kind: kind,
                text: text,
                syllables: syllables,
                pronunciationText: pronunciation,
                translationText: translation,
                furiganaText: furigana ?? furiganaText
            )
        }

        private enum CodingKeys: String, CodingKey {
            case id, role, speaker, speakerColor, speakerFallback, kind, text, syllables
            case pronunciationText, translationText, furiganaText
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
            role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
            speaker = try container.decodeIfPresent(String.self, forKey: .speaker) ?? ""
            speakerColor = try container.decodeIfPresent(String.self, forKey: .speakerColor) ?? ""
            speakerFallback = try container.decodeIfPresent(String.self, forKey: .speakerFallback) ?? ""
            let decodedKind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "vocal"
            kind = decodedKind.trimmed.isEmpty ? "vocal" : decodedKind.trimmed
            text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
            syllables = try container.decodeIfPresent([Syllable].self, forKey: .syllables) ?? []
            pronunciationText = try container.decodeIfPresent(String.self, forKey: .pronunciationText) ?? ""
            translationText = try container.decodeIfPresent(String.self, forKey: .translationText) ?? ""
            furiganaText = try container.decodeIfPresent(String.self, forKey: .furiganaText) ?? ""
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(role, forKey: .role)
            try container.encode(speaker, forKey: .speaker)
            try container.encode(speakerColor, forKey: .speakerColor)
            try container.encode(speakerFallback, forKey: .speakerFallback)
            try container.encode(kind, forKey: .kind)
            try container.encode(text, forKey: .text)
            try container.encode(syllables, forKey: .syllables)
            try container.encode(pronunciationText, forKey: .pronunciationText)
            try container.encode(translationText, forKey: .translationText)
            try container.encode(furiganaText, forKey: .furiganaText)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, startTimeMs, endTimeMs, text, syllables, speaker, speakerColor, speakerFallback, kind, vocalParts
        case pronunciationText, translationText, furiganaText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let decodedStart = try container.decodeIfPresent(Int64.self, forKey: .startTimeMs) ?? 0
        startTimeMs = max(0, decodedStart)
        endTimeMs = max(startTimeMs, try container.decodeIfPresent(Int64.self, forKey: .endTimeMs) ?? startTimeMs)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        syllables = try container.decodeIfPresent([Syllable].self, forKey: .syllables) ?? []
        speaker = try container.decodeIfPresent(String.self, forKey: .speaker) ?? ""
        speakerColor = try container.decodeIfPresent(String.self, forKey: .speakerColor) ?? ""
        speakerFallback = try container.decodeIfPresent(String.self, forKey: .speakerFallback) ?? ""
        let decodedKind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "vocal"
        kind = decodedKind.trimmed.isEmpty ? "vocal" : decodedKind.trimmed
        vocalParts = try container.decodeIfPresent([VocalPart].self, forKey: .vocalParts) ?? []
        pronunciationText = try container.decodeIfPresent(String.self, forKey: .pronunciationText) ?? ""
        translationText = try container.decodeIfPresent(String.self, forKey: .translationText) ?? ""
        furiganaText = try container.decodeIfPresent(String.self, forKey: .furiganaText) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(startTimeMs, forKey: .startTimeMs)
        try container.encode(endTimeMs, forKey: .endTimeMs)
        try container.encode(text, forKey: .text)
        try container.encode(syllables, forKey: .syllables)
        try container.encode(speaker, forKey: .speaker)
        try container.encode(speakerColor, forKey: .speakerColor)
        try container.encode(speakerFallback, forKey: .speakerFallback)
        try container.encode(kind, forKey: .kind)
        try container.encode(vocalParts, forKey: .vocalParts)
        try container.encode(pronunciationText, forKey: .pronunciationText)
        try container.encode(translationText, forKey: .translationText)
        try container.encode(furiganaText, forKey: .furiganaText)
    }
}

enum LyricsTextShaping {
    static func requiresContinuousShaping(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x0600...0x06FF).contains(value)
                || (0x0750...0x077F).contains(value)
                || (0x0870...0x089F).contains(value)
                || (0x08A0...0x08FF).contains(value)
                || (0xFB50...0xFDFF).contains(value)
                || (0xFE70...0xFEFF).contains(value)
                || (0x1EE00...0x1EEFF).contains(value)
        }
    }
}

enum LyricsWordSegmenter {
    private static let japaneseParticles: Set<String> = [
        "は", "が", "を", "に", "へ", "で", "と", "の", "も", "や", "か", "ね", "よ", "ぞ", "ぜ",
        "から", "まで", "だけ", "しか", "ほど", "くらい", "ぐらい", "など", "こそ", "とも", "な"
    ]
    private static let japaneseSafeSuffixes: Set<String> = [
        "た", "て", "ば", "ぬ", "って", "った", "いて", "いで", "んで",
        "てる", "でる", "いてる", "えてる", "たい", "ない", "れば"
    ]
    private static let chineseProtected: Set<String> = [
        "我们", "你们", "他们", "她们", "它们", "这个", "那个", "这些", "那些", "这里", "那里",
        "这样", "那样", "这么", "那么", "真的", "的话", "为了", "除了", "只有", "就是", "没有",
        "一下", "一起", "已经", "非常", "特别", "重新", "超级", "无法", "第一次", "经过", "难过",
        "结果", "如果", "最后"
    ]
    private static let chinesePronouns = ["我们", "你们", "他们", "她们", "它们", "我", "你", "他", "她", "它"]
    private static let chineseLeftAtoms: Set<String> = ["不", "没", "很", "也", "都"]
    private static let chineseLocalizers: Set<String> = ["上", "下", "里", "中", "前", "后", "内", "外"]
    private static var japaneseTokenizer: LyricsTokenizerAdapter? = TinyJapaneseTokenizerAdapter()

    static func setJapaneseTokenizer(_ tokenizer: LyricsTokenizerAdapter?) {
        japaneseTokenizer = tokenizer
    }

    static func displayRanges(in text: String, locale localeCode: String) -> [Range<Int>] {
        guard !text.isEmpty else { return [] }
        let characters = text.map(String.init)
        var lexicalRanges: [Range<Int>] = []
        var cursor = 0
        for token in segment(text, locale: localeCode) {
            let tokenCharacters = token.map(String.init)
            guard !tokenCharacters.isEmpty,
                  let start = find(tokenCharacters, in: characters, from: cursor) else {
                return fallbackDisplayRanges(characters)
            }
            lexicalRanges.append(start..<(start + tokenCharacters.count))
            cursor = start + tokenCharacters.count
        }
        guard !lexicalRanges.isEmpty else { return fallbackDisplayRanges(characters) }

        var result: [Range<Int>] = []
        cursor = 0
        for range in lexicalRanges {
            appendGapRanges(to: &result, characters: characters, range: cursor..<range.lowerBound)
            result.append(range)
            cursor = range.upperBound
        }
        appendGapRanges(to: &result, characters: characters, range: cursor..<characters.count)
        return result
    }

    static func segment(_ text: String, locale localeCode: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let resolvedLocale = normalizeLocale(localeCode, text: text)
        let graphemes = text.map(String.init)
        var output: [String] = []
        var lexical = ""
        var pendingPrefix = ""

        func flushLexical() {
            guard !lexical.isEmpty else { return }
            var tokens = segmentLexicalRun(lexical, locale: resolvedLocale)
            if !pendingPrefix.isEmpty, !tokens.isEmpty {
                tokens[0] = pendingPrefix + tokens[0]
                pendingPrefix = ""
            }
            output.append(contentsOf: tokens.filter { !$0.isEmpty })
            lexical = ""
        }

        for index in graphemes.indices {
            let grapheme = graphemes[index]
            let previous = index > graphemes.startIndex ? graphemes[index - 1] : nil
            let next = index + 1 < graphemes.endIndex ? graphemes[index + 1] : nil
            if isLatinJoiner(grapheme, previous: previous, next: next) {
                lexical += grapheme
            } else if isWhitespace(grapheme) {
                flushLexical()
            } else if isOpeningPunctuation(grapheme) {
                flushLexical()
                pendingPrefix += grapheme
            } else if isPunctuation(grapheme) {
                flushLexical()
                if output.isEmpty { pendingPrefix += grapheme } else { output[output.count - 1] += grapheme }
            } else if isSymbol(grapheme) {
                flushLexical()
                output.append(pendingPrefix + grapheme)
                pendingPrefix = ""
            } else {
                lexical += grapheme
            }
        }
        flushLexical()
        if !pendingPrefix.isEmpty {
            if output.isEmpty { output.append(pendingPrefix) } else { output[output.count - 1] += pendingPrefix }
        }
        return output
    }

    private static func segmentLexicalRun(_ run: String, locale: String) -> [String] {
        switch baseLanguage(locale) {
        case "ja": return segmentJapaneseRun(run, locale: locale)
        case "zh": return intlWords(run, locale: locale).flatMap(splitChineseToken)
        default:
            let words = intlWords(run, locale: locale)
            return words.isEmpty ? [run] : words
        }
    }

    private static func segmentJapaneseRun(_ run: String, locale: String) -> [String] {
        var pieces: [(kind: String, text: String)] = []
        var buffer = ""
        var kind: String?
        for grapheme in run.map(String.init) {
            let nextKind = isKatakana(grapheme) ? "katakana" : isLatinNumber(grapheme) ? "latin" : "japanese"
            if let kind, kind != nextKind {
                pieces.append((kind, buffer))
                buffer = ""
            }
            kind = nextKind
            buffer += grapheme
        }
        if let kind, !buffer.isEmpty { pieces.append((kind, buffer)) }
        return pieces.flatMap { piece in
            if piece.kind == "latin" { return [piece.text] }
            let tokens = tokenizeJapanese(piece.text, locale: locale)
            return piece.kind == "japanese"
                ? groupJapaneseTokens(tokens)
                : tokens.map(\.surface)
        }
    }

    private static func tokenizeJapanese(_ text: String, locale: String) -> [LyricsTokenizerToken] {
        if let tokens = japaneseTokenizer?.tokenize(text, locale: locale), !tokens.isEmpty {
            return tokens
        }
        return tokenRecords(intlWords(text, locale: locale), in: text)
    }

    private static func tokenRecords(_ surfaces: [String], in text: String) -> [LyricsTokenizerToken] {
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

    private static func groupJapaneseTokens(_ tokens: [LyricsTokenizerToken]) -> [String] {
        var output: [String] = []
        for tokenRecord in tokens {
            let token = tokenRecord.surface
            guard let previous = output.last else {
                output.append(token)
                continue
            }
            let previousIsParticle = japaneseParticles.contains(previous)
            let safeSuffix = japaneseSafeSuffixes.contains(token)
            let contextualSou = token == "そう" && endsWithHiragana(previous)
            let morphology = [tokenRecord.partOfSpeech, tokenRecord.partOfSpeechDetail]
                .compactMap { $0 }
                .joined(separator: " ")
                .lowercased()
            let morphologicalSuffix = ["auxiliary", "suffix", "conjunctive", "助動詞", "接続助詞", "接尾"]
                .contains { morphology.contains($0) }
            if !previousIsParticle, morphologicalSuffix || (isHiragana(token) && (safeSuffix || contextualSou)) {
                output[output.count - 1] = previous + token
            } else {
                output.append(token)
            }
        }
        return output
    }

    private static func splitChineseToken(_ token: String) -> [String] {
        let characters = token.map(String.init)
        guard characters.count > 1, !chineseProtected.contains(token) else { return token.isEmpty ? [] : [token] }
        if Set(characters).count == 1, hasHan(characters[0]) { return characters }
        for pronoun in chinesePronouns where token.hasPrefix(pronoun) && token != pronoun {
            return [pronoun] + splitChineseToken(String(token.dropFirst(pronoun.count)))
        }
        if token.hasPrefix("一起"), token != "一起" {
            return ["一起"] + splitChineseToken(String(token.dropFirst(2)))
        }
        let first = characters[0]
        let last = characters[characters.count - 1]
        if chineseLeftAtoms.contains(first) {
            return [first] + splitChineseToken(characters.dropFirst().joined())
        }
        if characters.count > 2,
           let index = characters[1..<(characters.count - 1)].firstIndex(where: { ["了", "着", "过"].contains($0) }) {
            return splitChineseToken(characters[..<index].joined())
                + [characters[index]]
                + splitChineseToken(characters[(index + 1)...].joined())
        }
        if last == "了" { return splitChineseToken(characters.dropLast().joined()) + [last] }
        for pronoun in chinesePronouns where token.hasSuffix(pronoun) && token != pronoun {
            return splitChineseToken(String(token.dropLast(pronoun.count))) + [pronoun]
        }
        if last == "的" {
            let stem = characters.dropLast().joined()
            if chinesePronouns.contains(stem) { return [stem, last] }
        }
        if chineseLocalizers.contains(last), characters.count >= 3 {
            return splitChineseToken(characters.dropLast().joined()) + [last]
        }
        return [token]
    }

    private static func intlWords(_ text: String, locale: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(NLLanguage(rawValue: baseLanguage(locale)))
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = String(text[range])
            if isWordLike(token) { result.append(token) }
            return true
        }
        return result
    }

    private static func normalizeLocale(_ localeCode: String, text: String) -> String {
        let explicit = localeCode.trimmed.replacingOccurrences(of: "_", with: "-")
        if !explicit.isEmpty, explicit.lowercased() != "auto" { return explicit }
        if text.unicodeScalars.contains(where: { isHiraganaScalar($0) || isKatakanaScalar($0) }) { return "ja" }
        if text.unicodeScalars.contains(where: { (0x0E00...0x0E7F).contains($0.value) }) { return "th" }
        if text.unicodeScalars.contains(where: { (0x0E80...0x0EFF).contains($0.value) }) { return "lo" }
        if text.unicodeScalars.contains(where: { (0x1780...0x17FF).contains($0.value) }) { return "km" }
        if text.unicodeScalars.contains(where: { (0x1000...0x109F).contains($0.value) }) { return "my" }
        if text.unicodeScalars.contains(where: isHanScalar) { return "zh" }
        return Locale.current.language.languageCode?.identifier ?? "en"
    }

    private static func baseLanguage(_ localeCode: String) -> String {
        localeCode.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? "en"
    }

    private static func find(_ needle: [String], in haystack: [String], from cursor: Int) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        let lastStart = haystack.count - needle.count
        guard cursor <= lastStart else { return nil }
        for start in cursor...lastStart where Array(haystack[start..<(start + needle.count)]) == needle { return start }
        return nil
    }

    private static func appendGapRanges(to output: inout [Range<Int>], characters: [String], range: Range<Int>) {
        var index = range.lowerBound
        while index < range.upperBound {
            if isWhitespace(characters[index]) {
                var end = index + 1
                while end < range.upperBound, isWhitespace(characters[end]) { end += 1 }
                output.append(index..<end)
                index = end
            } else {
                output.append(index..<(index + 1))
                index += 1
            }
        }
    }

    private static func fallbackDisplayRanges(_ characters: [String]) -> [Range<Int>] {
        characters.indices.map { $0..<($0 + 1) }
    }

    private static func isWhitespace(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
    private static func isWordLike(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
    private static func isHiragana(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { isHiraganaScalar($0) || isCombiningMark($0) }
    }
    private static func isKatakana(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            isKatakanaScalar($0) || [0x30FC, 0x30FD, 0x30FE].contains($0.value) || isCombiningMark($0)
        }
    }
    private static func isLatinNumber(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) || isLatinScalar($0) }
    }
    private static func isLatinJoiner(_ value: String, previous: String?, next: String?) -> Bool {
        ["'", "’", "-", "‐"].contains(value) && isLatinNumber(previous) && isLatinNumber(next)
    }
    private static func isOpeningPunctuation(_ value: String) -> Bool {
        guard let category = value.unicodeScalars.first?.properties.generalCategory else { return false }
        return category == .openPunctuation || category == .initialPunctuation
    }
    private static func isPunctuation(_ value: String) -> Bool {
        guard let category = value.unicodeScalars.first?.properties.generalCategory else { return false }
        return [.connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                .initialPunctuation, .finalPunctuation, .otherPunctuation].contains(category)
    }
    private static func isSymbol(_ value: String) -> Bool {
        guard let category = value.unicodeScalars.first?.properties.generalCategory else { return false }
        return [.mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol].contains(category)
    }
    private static func hasHan(_ value: String) -> Bool { value.unicodeScalars.contains(where: isHanScalar) }
    private static func endsWithHiragana(_ value: String) -> Bool { value.unicodeScalars.last.map(isHiraganaScalar) ?? false }
    private static func isHiraganaScalar(_ scalar: Unicode.Scalar) -> Bool { (0x3040...0x309F).contains(scalar.value) }
    private static func isKatakanaScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x30A0...0x30FF).contains(scalar.value) || (0x31F0...0x31FF).contains(scalar.value) || (0xFF66...0xFF9D).contains(scalar.value)
    }
    private static func isHanScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
            || (0xF900...0xFAFF).contains(scalar.value) || (0x20000...0x2FA1F).contains(scalar.value)
    }
    private static func isLatinScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x0041...0x007A).contains(scalar.value) || (0x00C0...0x024F).contains(scalar.value) || (0x1E00...0x1EFF).contains(scalar.value)
    }
    private static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        [.nonspacingMark, .spacingMark, .enclosingMark].contains(scalar.properties.generalCategory)
    }
}

enum KaraokeSyllableTimingNormalizer {
    private static let preWhitespaceMinDurationMs: Int64 = 40
    private static let preWhitespaceNextDurationRatio = 0.35
    private static let preWhitespaceMaxDurationMs: Int64 = 60

    struct FillTiming: Equatable {
        let startTimeMs: Int64
        let endTimeMs: Int64
    }

    static func expandTimedChunks(_ syllables: [LyricsLine.Syllable]) -> [LyricsLine.Syllable] {
#if DEBUG
        _ = regressionChecks
#endif
        return normalizedTimedChunksUnchecked(syllables)
    }

    /// Native counterpart of `Intl.Segmenter({ granularity: "word" })` used by PC.
    /// NLTokenizer supplies language-aware word ranges, while punctuation and spaces
    /// are retained as independent display ranges so the rendered text never changes.
    static func groupedForWordDisplay(
        _ syllables: [LyricsLine.Syllable],
        locale: String
    ) -> [LyricsLine.Syllable] {
        let visibleSourceUnits = syllables.filter {
            !$0.text.isEmpty && !$0.text.unicodeScalars.allSatisfy {
                CharacterSet.whitespacesAndNewlines.contains($0)
            }
        }
        let preservesSourceUnits = visibleSourceUnits.contains {
            $0.sourceGranularity?.trimmed.lowercased() == "word"
        } || (
            visibleSourceUnits.count > 1
                && visibleSourceUnits.contains { $0.text.count > 1 }
        )
        if preservesSourceUnits {
            return groupedPreservingSourceWordUnits(syllables)
        }
        let source = expandTimedChunks(syllables).filter { !$0.text.isEmpty }
        guard !source.isEmpty else { return [] }

        let text = source.map(\.text).joined()
        let characters = text.map(String.init)
        guard !characters.isEmpty else { return [] }

        var sourceRanges: [Range<Int>] = []
        sourceRanges.reserveCapacity(source.count)
        var sourceCursor = 0
        for syllable in source {
            let nextCursor = sourceCursor + syllable.text.count
            sourceRanges.append(sourceCursor..<nextCursor)
            sourceCursor = nextCursor
        }

        let displayRanges = LyricsWordSegmenter.displayRanges(in: text, locale: locale)

        return displayRanges.flatMap { displayRange -> [LyricsLine.Syllable] in
            let overlappingIndices = sourceRanges.indices.filter {
                sourceRanges[$0].upperBound > displayRange.lowerBound
                    && sourceRanges[$0].lowerBound < displayRange.upperBound
            }
            guard let first = overlappingIndices.first else { return [] }
            let wordStartTimeMs = overlappingIndices.reduce(source[first].startTimeMs) {
                min($0, source[$1].startTimeMs)
            }
            let wordEndTimeMs = overlappingIndices.reduce(source[first].endTimeMs) {
                max($0, source[$1].endTimeMs)
            }
            var result: [LyricsLine.Syllable] = []
            var runStart = first
            var runEnd = first

            func appendRun() {
                let lower = max(displayRange.lowerBound, sourceRanges[runStart].lowerBound)
                let upper = min(displayRange.upperBound, sourceRanges[runEnd].upperBound)
                guard lower < upper else { return }
                result.append(source[runStart].copying(
                    text: characters[lower..<upper].joined(),
                    startTimeMs: wordStartTimeMs,
                    endTimeMs: max(wordStartTimeMs, wordEndTimeMs),
                    sourceGranularity: "word"
                ))
            }

            for index in overlappingIndices.dropFirst() {
                if source[index].styleKey != source[runStart].styleKey {
                    appendRun()
                    runStart = index
                }
                runEnd = index
            }
            appendRun()
            return result
        }
    }

    private static func groupedPreservingSourceWordUnits(
        _ syllables: [LyricsLine.Syllable]
    ) -> [LyricsLine.Syllable] {
        var result: [LyricsLine.Syllable] = []
        for syllable in syllables where !syllable.text.isEmpty {
            var run = ""
            var whitespaceRun: Bool?

            func flush() {
                guard !run.isEmpty else { return }
                result.append(syllable.copying(text: run, sourceGranularity: "word"))
                run = ""
            }

            for character in syllable.text {
                let value = String(character)
                let isWhitespace = value.unicodeScalars.allSatisfy {
                    CharacterSet.whitespacesAndNewlines.contains($0)
                }
                if let whitespaceRun, whitespaceRun != isWhitespace {
                    flush()
                }
                whitespaceRun = isWhitespace
                run.append(character)
            }
            flush()
        }
        return result.isEmpty ? syllables : result
    }

    private static func normalizedTimedChunksUnchecked(
        _ syllables: [LyricsLine.Syllable]
    ) -> [LyricsLine.Syllable] {
        let compensated = compensatePreWhitespaceTimings(expandTimedChunksUnchecked(syllables))
        if LyricsTextShaping.requiresContinuousShaping(compensated.map(\.text).joined()) {
            return mergeWordRuns(compensated)
        }
        return compensated
    }

    private static func expandTimedChunksUnchecked(
        _ syllables: [LyricsLine.Syllable]
    ) -> [LyricsLine.Syllable] {
        guard syllables.contains(where: {
            $0.text.count > 1 && $0.endTimeMs > $0.startTimeMs
        }) else {
            return syllables
        }
        var result: [LyricsLine.Syllable] = []
        result.reserveCapacity(syllables.count)
        for syllable in syllables {
            let characterCount = syllable.text.count
            guard characterCount > 1,
                  syllable.endTimeMs > syllable.startTimeMs else {
                result.append(syllable)
                continue
            }

            let duration = syllable.endTimeMs - syllable.startTimeMs
            let characterCount64 = Int64(characterCount)
            let step = duration / characterCount64
            let remainder = duration % characterCount64

            func boundary(_ index: Int64) -> Int64 {
                syllable.startTimeMs
                    + step * index
                    + min(index, remainder)
            }

            for (index, character) in syllable.text.enumerated() {
                let start = boundary(Int64(index))
                let end = boundary(Int64(index + 1))
                result.append(syllable.copying(
                    text: String(character),
                    startTimeMs: start,
                    endTimeMs: max(start, end)
                ))
            }
        }
        return result
    }

    private static func compensatePreWhitespaceTimings(
        _ syllables: [LyricsLine.Syllable]
    ) -> [LyricsLine.Syllable] {
        guard syllables.count >= 2 else { return syllables }
        var result = syllables
        var changed = false
        for index in 0..<(syllables.count - 1) {
            let current = syllables[index]
            let next = syllables[index + 1]
            guard !isWhitespace(current.text), isWhitespace(next.text) else { continue }

            let durationMs = max(0, current.endTimeMs - current.startTimeMs)
            guard durationMs < preWhitespaceMinDurationMs else { continue }
            let nextDurationMs = max(0, next.endTimeMs - next.startTimeMs)
            let computedDurationMs = Int64(
                (Double(nextDurationMs) * preWhitespaceNextDurationRatio).rounded()
            )
            let compensatedDurationMs = max(
                preWhitespaceMinDurationMs,
                min(preWhitespaceMaxDurationMs, computedDurationMs)
            )
            result[index] = current.copying(endTimeMs: current.startTimeMs + compensatedDurationMs)
            changed = true
        }
        return changed ? result : syllables
    }

    private static func isWhitespace(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    /// Arabic contextual forms and bidi ordering require a continuous logical word.
    /// Preserve each word as one renderer item while retaining its complete time span.
    private static func mergeWordRuns(
        _ syllables: [LyricsLine.Syllable]
    ) -> [LyricsLine.Syllable] {
        guard !syllables.isEmpty else { return [] }
        var result: [LyricsLine.Syllable] = []
        result.reserveCapacity(syllables.count)
        var word = ""
        var wordStartMs: Int64 = 0
        var wordEndMs: Int64 = 0
        var styleSource: LyricsLine.Syllable?

        func flushWord() {
            guard !word.isEmpty else { return }
            result.append((styleSource ?? LyricsLine.Syllable(
                text: "",
                startTimeMs: wordStartMs,
                endTimeMs: wordEndMs
            )).copying(text: word, startTimeMs: wordStartMs, endTimeMs: wordEndMs))
            word = ""
            styleSource = nil
        }

        for syllable in syllables where !syllable.text.isEmpty {
            let isWhitespace = syllable.text.unicodeScalars.allSatisfy {
                CharacterSet.whitespacesAndNewlines.contains($0)
            }
            if isWhitespace {
                flushWord()
                result.append(syllable)
                continue
            }
            if let styleSource, styleSource.styleKey != syllable.styleKey {
                flushWord()
            }
            if word.isEmpty {
                wordStartMs = syllable.startTimeMs
                wordEndMs = syllable.endTimeMs
                styleSource = syllable
            } else {
                wordEndMs = max(wordEndMs, syllable.endTimeMs)
            }
            word.append(syllable.text)
        }
        flushWord()
        return result
    }

    /// Preserve every renderer item for per-character motion while distributing only
    /// the fill timing evenly across each Latin word's complete timing span.
    static func latinWordFillTimings(
        _ syllables: [LyricsLine.Syllable]
    ) -> [FillTiming] {
        guard !syllables.isEmpty else { return [] }
        var result = syllables.map {
            FillTiming(startTimeMs: $0.startTimeMs, endTimeMs: $0.endTimeMs)
        }
        var wordIndices: [Int] = []

        func flushWord() {
            guard !wordIndices.isEmpty else { return }
            let text = wordIndices.map { syllables[$0].text }.joined()
            if isLatinWordText(text), let firstIndex = wordIndices.first {
                let wordStartMs = syllables[firstIndex].startTimeMs
                let wordEndMs = max(
                    wordStartMs,
                    wordIndices.map { syllables[$0].endTimeMs }.max() ?? wordStartMs
                )
                let durationMs = max(0, wordEndMs - wordStartMs)
                let totalUnits = wordIndices.reduce(0) {
                    $0 + max(1, syllables[$1].text.count)
                }
                var completedUnits = 0
                for index in wordIndices {
                    let units = max(1, syllables[index].text.count)
                    let fillStartMs = wordStartMs + Int64(
                        (Double(durationMs) * Double(completedUnits) / Double(totalUnits)).rounded()
                    )
                    completedUnits += units
                    let fillEndMs = wordStartMs + Int64(
                        (Double(durationMs) * Double(completedUnits) / Double(totalUnits)).rounded()
                    )
                    result[index] = FillTiming(
                        startTimeMs: fillStartMs,
                        endTimeMs: max(fillStartMs, fillEndMs)
                    )
                }
            }
            wordIndices.removeAll(keepingCapacity: true)
        }

        for (index, syllable) in syllables.enumerated() where !syllable.text.isEmpty {
            let isWhitespace = syllable.text.unicodeScalars.allSatisfy {
                CharacterSet.whitespacesAndNewlines.contains($0)
            }
            if isWhitespace {
                flushWord()
            } else {
                wordIndices.append(index)
            }
        }
        flushWord()
        return result
    }

    private static func isLatinWordText(_ text: String) -> Bool {
        var hasLatinLetter = false
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            guard isLatinLetter(scalar.value) else { return false }
            hasLatinLetter = true
        }
        return hasLatinLetter
    }

    private static func isLatinLetter(_ value: UInt32) -> Bool {
        switch value {
        case 0x0041...0x005A,
             0x0061...0x007A,
             0x00C0...0x02E4,
             0x1D00...0x1DBF,
             0x1E00...0x1EFF,
             0x2C60...0x2C7F,
             0xA720...0xA7FF,
             0xAB30...0xAB6F,
             0xFF21...0xFF3A,
             0xFF41...0xFF5A:
            return true
        default:
            return false
        }
    }

#if DEBUG
    private static let regressionChecks: Void = {
        let oneCharacter = LyricsLine.Syllable(text: "한", startTimeMs: 100, endTimeMs: 400)
        assert(expandTimedChunksUnchecked([oneCharacter]) == [oneCharacter])

        let word = expandTimedChunksUnchecked([
            LyricsLine.Syllable(text: "Back", startTimeMs: 100, endTimeMs: 500)
        ])
        assert(word.map(\.text) == ["B", "a", "c", "k"])
        assert(word.map(\.startTimeMs) == [100, 200, 300, 400])
        assert(word.map(\.endTimeMs) == [200, 300, 400, 500])

        let complexText = "A e\u{301}👩🏽‍🚀!"
        let complex = expandTimedChunksUnchecked([
            LyricsLine.Syllable(text: complexText, startTimeMs: 0, endTimeMs: 500)
        ])
        assert(complex.map(\.text) == complexText.map(String.init))
        assert(complex.map(\.text).joined() == complexText)
        assert(complex.first?.startTimeMs == 0)
        assert(complex.last?.endTimeMs == 500)
        assert(zip(complex, complex.dropFirst()).allSatisfy { $0.endTimeMs == $1.startTimeMs })

        let untimed = LyricsLine.Syllable(text: "word", startTimeMs: 800, endTimeMs: 800)
        assert(expandTimedChunksUnchecked([untimed]) == [untimed])

        let latinCharacters = [
            LyricsLine.Syllable(text: "U", startTimeMs: 100, endTimeMs: 160),
            LyricsLine.Syllable(text: "h", startTimeMs: 160, endTimeMs: 200),
            LyricsLine.Syllable(text: ",", startTimeMs: 200, endTimeMs: 800),
            LyricsLine.Syllable(text: " ", startTimeMs: 800, endTimeMs: 900)
        ]
        let latin = normalizedTimedChunksUnchecked(latinCharacters)
        assert(latin == latinCharacters)
        let latinFill = latinWordFillTimings(latin)
        assert(latinFill.map(\.startTimeMs) == [100, 333, 567, 800])
        assert(latinFill.map(\.endTimeMs) == [333, 567, 800, 900])

        let mixedText = "歌 hello 世界"
        let mixedCharacters = mixedText.enumerated().map { index, character in
            LyricsLine.Syllable(
                text: String(character),
                startTimeMs: Int64(index * 100),
                endTimeMs: Int64((index + 1) * 100)
            )
        }
        let mixed = normalizedTimedChunksUnchecked(mixedCharacters)
        assert(mixed.map(\.text) == mixedText.map(String.init))
        assert(mixed.map(\.text).joined() == mixedText)

        let arabicText = "مرحبا بك"
        let arabicCharacters = arabicText.enumerated().map { index, character in
            LyricsLine.Syllable(
                text: String(character),
                startTimeMs: Int64(index * 100),
                endTimeMs: Int64((index + 1) * 100)
            )
        }
        let arabic = normalizedTimedChunksUnchecked(arabicCharacters)
        assert(arabic.map(\.text) == ["مرحبا", " ", "بك"])
        assert(arabic.map(\.text).joined() == arabicText)
        assert(arabic.first?.startTimeMs == 0)
        assert(arabic.last?.endTimeMs == Int64(arabicCharacters.count * 100))
    }()
#endif
}

struct LyricsResult: Codable, Equatable, Sendable {
    var lines: [LyricsLine]
    var providerLabel: String
    var detail: String
    var karaoke: Bool
    var isrc: String
    var spotifyTrackId: String
    var contributors: [SyncContributor]
    var providerId: String
    var selectionPolicyKey: String

    init(
        lines: [LyricsLine],
        providerLabel: String,
        detail: String,
        karaoke: Bool,
        isrc: String = "",
        spotifyTrackId: String = "",
        contributors: [SyncContributor] = [],
        providerId: String = "",
        selectionPolicyKey: String = ""
    ) {
        self.lines = lines
        self.providerLabel = providerLabel
        self.detail = detail
        self.karaoke = karaoke
        self.isrc = TrackSnapshot.normalizeIsrc(isrc)
        self.spotifyTrackId = spotifyTrackId.trimmed
        self.contributors = contributors
        self.providerId = providerId.trimmed.lowercased()
        self.selectionPolicyKey = selectionPolicyKey.trimmed
    }

    func withSelection(providerId: String, selectionPolicyKey: String) -> LyricsResult {
        LyricsResult(
            lines: lines,
            providerLabel: providerLabel,
            detail: detail,
            karaoke: karaoke,
            isrc: isrc,
            spotifyTrackId: spotifyTrackId,
            contributors: contributors,
            providerId: providerId,
            selectionPolicyKey: selectionPolicyKey
        )
    }

    static func empty(_ detail: String) -> LyricsResult {
        LyricsResult(lines: [], providerLabel: "", detail: detail, karaoke: false)
    }

    private enum CodingKeys: String, CodingKey {
        case lines, providerLabel, detail, karaoke, isrc, spotifyTrackId, contributors
        case providerId, selectionPolicyKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            lines: try container.decodeIfPresent([LyricsLine].self, forKey: .lines) ?? [],
            providerLabel: try container.decodeIfPresent(String.self, forKey: .providerLabel) ?? "",
            detail: try container.decodeIfPresent(String.self, forKey: .detail) ?? "",
            karaoke: try container.decodeIfPresent(Bool.self, forKey: .karaoke) ?? false,
            isrc: try container.decodeIfPresent(String.self, forKey: .isrc) ?? "",
            spotifyTrackId: try container.decodeIfPresent(String.self, forKey: .spotifyTrackId) ?? "",
            contributors: try container.decodeIfPresent([SyncContributor].self, forKey: .contributors) ?? [],
            providerId: try container.decodeIfPresent(String.self, forKey: .providerId) ?? "",
            selectionPolicyKey: try container.decodeIfPresent(String.self, forKey: .selectionPolicyKey) ?? ""
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lines, forKey: .lines)
        try container.encode(providerLabel, forKey: .providerLabel)
        try container.encode(detail, forKey: .detail)
        try container.encode(karaoke, forKey: .karaoke)
        try container.encode(isrc, forKey: .isrc)
        try container.encode(spotifyTrackId, forKey: .spotifyTrackId)
        try container.encode(contributors, forKey: .contributors)
        try container.encode(providerId, forKey: .providerId)
        try container.encode(selectionPolicyKey, forKey: .selectionPolicyKey)
    }

    struct SyncContributor: Codable, Equatable, Hashable, Sendable {
        struct Decoration: Codable, Equatable, Hashable, Sendable {
            var mode: String
            var solidColor: String
            var gradientStartColor: String
            var gradientEndColor: String
            var gradientAngle: Int
        }

        var name: String
        var userHash: String
        var profileAvailable: Bool
        var anonymous: Bool
        var isPrivate: Bool
        var decoration: Decoration?

        var identityHidden: Bool {
            anonymous || isPrivate
        }

        init(
            name: String,
            userHash: String = "",
            profileAvailable: Bool = false,
            anonymous: Bool = false,
            isPrivate: Bool = false,
            decoration: Decoration? = nil
        ) {
            let safeName = name.trimmed
            let safeHash = userHash.trimmed
            let shouldHideIdentity = anonymous || isPrivate
            self.name = shouldHideIdentity || safeName.isEmpty ? "Anonymous" : safeName
            self.userHash = shouldHideIdentity ? "" : safeHash
            self.profileAvailable = !shouldHideIdentity && profileAvailable && !safeHash.isEmpty
            self.anonymous = shouldHideIdentity
            self.isPrivate = isPrivate
            self.decoration = shouldHideIdentity ? nil : decoration
        }

        private enum CodingKeys: String, CodingKey {
            case name, userHash, profileAvailable, anonymous, isPrivate, decoration
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
                userHash: try container.decodeIfPresent(String.self, forKey: .userHash) ?? "",
                profileAvailable: try container.decodeIfPresent(Bool.self, forKey: .profileAvailable) ?? false,
                anonymous: try container.decodeIfPresent(Bool.self, forKey: .anonymous) ?? false,
                isPrivate: try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false,
                decoration: try container.decodeIfPresent(Decoration.self, forKey: .decoration)
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(userHash, forKey: .userHash)
            try container.encode(profileAvailable, forKey: .profileAvailable)
            try container.encode(anonymous, forKey: .anonymous)
            try container.encode(isPrivate, forKey: .isPrivate)
            try container.encodeIfPresent(decoration, forKey: .decoration)
        }
    }
}

struct ManualLrclibCandidate: Identifiable, Equatable, Sendable {
    var id: Int64
    var trackName: String
    var artistName: String
    var albumName: String
    var durationSeconds: Double
    var synced: Bool
    var plain: Bool
    var instrumental: Bool
    var isrc: String
    var score: Double
}

struct YouTubeVideoInfo: Codable, Equatable, Sendable {
    var isrc: String
    var spotifyTrackId: String
    var youtubeVideoId: String
    var youtubeTitle: String
    var hasCaptionStartTime: Bool
    var captionStartTimeSeconds: Double
    var autoGenerated: Bool
    var submitterId: String

    var watchURL: URL? {
        youtubeVideoId.isEmpty ? nil : URL(string: "https://www.youtube.com/watch?v=\(youtubeVideoId)")
    }
}

struct SpotifyResolvedTrack: Equatable, Sendable {
    var spotifyId: String
    var title: String
    var artist: String
    var album: String
    var isrc: String
    var durationMs: Int64
    var artworkURL: URL?
    var logs: [String]
}

struct SpotifyPlaybackSnapshot: Equatable, Sendable {
    private static let spotifyDJPlaylistID = "37i9dQZF1EYkqdzj48dyYq"

    var track: TrackSnapshot
    var progressMs: Int64
    var playing: Bool
    var fetchedAt: Date
    var deviceName: String
    var spotifyDJContext: Bool

    init(
        track: TrackSnapshot,
        progressMs: Int64,
        playing: Bool,
        fetchedAt: Date,
        deviceName: String,
        spotifyDJContext: Bool = false
    ) {
        self.track = track
        self.progressMs = max(0, progressMs)
        self.playing = playing
        self.fetchedAt = fetchedAt
        self.deviceName = deviceName
        self.spotifyDJContext = spotifyDJContext
    }

    static func detectsSpotifyDJContext(title: String, uri: String) -> Bool {
        let normalizedTitle = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedTitle == "dj" || normalizedTitle == "spotify dj" {
            return true
        }
        return uri.range(of: spotifyDJPlaylistID, options: .caseInsensitive) != nil
    }
}

struct SpotifyPlaybackInteractionGuard {
    private struct PlaybackIntent {
        var trackKey: String
        var playing: Bool
        var issuedAtUptime: TimeInterval
    }

    private struct SeekIntent {
        var trackKey: String
        var positionMs: Int64
        var issuedAtUptime: TimeInterval
    }

    private var playbackIntent: PlaybackIntent?
    private var seekIntent: SeekIntent?

    private let playbackHoldSeconds: TimeInterval = 2.0
    private let seekHoldSeconds: TimeInterval = 2.5
    private let seekAcknowledgementToleranceMs: Int64 = 2_500

    mutating func registerPlayback(trackKey: String, playing: Bool, uptime: TimeInterval) {
        playbackIntent = PlaybackIntent(
            trackKey: trackKey,
            playing: playing,
            issuedAtUptime: uptime
        )
    }

    mutating func registerSeek(trackKey: String, positionMs: Int64, uptime: TimeInterval) {
        seekIntent = SeekIntent(
            trackKey: trackKey,
            positionMs: max(0, positionMs),
            issuedAtUptime: uptime
        )
    }

    mutating func reset() {
        playbackIntent = nil
        seekIntent = nil
    }

    mutating func reconcile(
        _ snapshot: SpotifyPlaybackSnapshot,
        currentTrack: TrackSnapshot?,
        uptime: TimeInterval
    ) -> SpotifyPlaybackSnapshot {
        guard let currentTrack,
              currentTrack.stableKey == snapshot.track.stableKey else {
            reset()
            return snapshot
        }

        var positionMs = snapshot.progressMs
        var playing = snapshot.playing
        var preservedOptimisticState = false
        let optimisticPositionMs = currentTrack.positionNow(uptime: uptime)

        if let intent = playbackIntent {
            if intent.trackKey != snapshot.track.stableKey {
                playbackIntent = nil
            } else if snapshot.playing == intent.playing {
                playbackIntent = nil
            } else if uptime - intent.issuedAtUptime <= playbackHoldSeconds {
                playing = intent.playing
                positionMs = optimisticPositionMs
                preservedOptimisticState = true
            } else {
                playbackIntent = nil
            }
        }

        if let intent = seekIntent {
            if intent.trackKey != snapshot.track.stableKey {
                seekIntent = nil
            } else if abs(snapshot.progressMs - intent.positionMs) <= seekAcknowledgementToleranceMs
                        || abs(snapshot.progressMs - optimisticPositionMs) <= seekAcknowledgementToleranceMs {
                seekIntent = nil
            } else if uptime - intent.issuedAtUptime <= seekHoldSeconds {
                positionMs = optimisticPositionMs
                preservedOptimisticState = true
            } else {
                seekIntent = nil
            }
        }

        guard preservedOptimisticState
                || positionMs != snapshot.progressMs
                || playing != snapshot.playing else {
            return snapshot
        }
        let reconciledTrack = snapshot.track.withPlayback(
            positionMs: positionMs,
            playing: playing,
            uptime: uptime
        )
        return SpotifyPlaybackSnapshot(
            track: reconciledTrack,
            progressMs: positionMs,
            playing: playing,
            fetchedAt: snapshot.fetchedAt,
            deviceName: snapshot.deviceName,
            spotifyDJContext: snapshot.spotifyDJContext
        )
    }
}

enum AppStatus: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case setupRequired
    case failed(String)

    func text(settings: AppSettings) -> String {
        switch self {
        case .idle:
            return settings.t("status.idle")
        case .loading:
            return settings.t("status.lyrics_loading")
        case .loaded:
            return settings.t("status.loaded")
        case .setupRequired:
            return settings.t("status.spotify_required_plain")
        case .failed(let message):
            return message
        }
    }
}
