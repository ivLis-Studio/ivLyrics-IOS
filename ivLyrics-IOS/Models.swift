import Foundation

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

        init(text: String, startTimeMs: Int64, endTimeMs: Int64) {
            self.text = text
            self.startTimeMs = max(0, startTimeMs)
            self.endTimeMs = max(max(0, startTimeMs), endTimeMs)
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

enum KaraokeSyllableTimingNormalizer {
    static func expandTimedChunks(_ syllables: [LyricsLine.Syllable]) -> [LyricsLine.Syllable] {
#if DEBUG
        _ = regressionChecks
#endif
        return expandTimedChunksUnchecked(syllables)
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
                result.append(LyricsLine.Syllable(
                    text: String(character),
                    startTimeMs: start,
                    endTimeMs: max(start, end)
                ))
            }
        }
        return result
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
        var name: String
        var userHash: String
        var profileAvailable: Bool
        var anonymous: Bool
        var isPrivate: Bool

        var identityHidden: Bool {
            anonymous || isPrivate
        }

        init(
            name: String,
            userHash: String = "",
            profileAvailable: Bool = false,
            anonymous: Bool = false,
            isPrivate: Bool = false
        ) {
            let safeName = name.trimmed
            let safeHash = userHash.trimmed
            let shouldHideIdentity = anonymous || isPrivate
            self.name = shouldHideIdentity || safeName.isEmpty ? "Anonymous" : safeName
            self.userHash = shouldHideIdentity ? "" : safeHash
            self.profileAvailable = !shouldHideIdentity && profileAvailable && !safeHash.isEmpty
            self.anonymous = shouldHideIdentity
            self.isPrivate = isPrivate
        }

        private enum CodingKeys: String, CodingKey {
            case name, userHash, profileAvailable, anonymous, isPrivate
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
                userHash: try container.decodeIfPresent(String.self, forKey: .userHash) ?? "",
                profileAvailable: try container.decodeIfPresent(Bool.self, forKey: .profileAvailable) ?? false,
                anonymous: try container.decodeIfPresent(Bool.self, forKey: .anonymous) ?? false,
                isPrivate: try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(userHash, forKey: .userHash)
            try container.encode(profileAvailable, forKey: .profileAvailable)
            try container.encode(anonymous, forKey: .anonymous)
            try container.encode(isPrivate, forKey: .isPrivate)
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
