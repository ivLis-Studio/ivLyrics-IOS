import Foundation

// A read-only adapter for the original model/repository. It never reads the
// host's defaults, credentials, app settings singleton or resource bundle.
struct CoreLocalization {
    let translate: (String) -> String
    func t(_ key: String) -> String { translate(key) }

    static let lyricsTypeKaraoke = "karaoke"
    static let lyricsTypeSynced = "synced"
    static let lyricsTypePlain = "plain"

    struct LyricsProvider: Sendable {
        let id: String
        let name: String
        let supportsNativeKaraoke: Bool
        let supportsSynced: Bool
        let supportsPlain: Bool
    }

    static func lyricsProviderById(_ id: String) -> LyricsProvider? {
        switch id.trimmed.lowercased() {
        case "lrclib": return LyricsProvider(id: "lrclib", name: "LRCLIB", supportsNativeKaraoke: false, supportsSynced: true, supportsPlain: true)
        case "lyricsplus": return LyricsProvider(id: "lyricsplus", name: "LyricsPlus", supportsNativeKaraoke: true, supportsSynced: true, supportsPlain: true)
        case "paxsenix": return LyricsProvider(id: "paxsenix", name: "Lyrically (Paxsenix)", supportsNativeKaraoke: true, supportsSynced: true, supportsPlain: true)
        case "unison": return LyricsProvider(id: "unison", name: "Unison", supportsNativeKaraoke: true, supportsSynced: true, supportsPlain: true)
        default: return nil
        }
    }

    struct Snapshot: Sendable {
        let enabledLyricsProviderOrder: [String]
        let lrclibCustomEndpoint: String
        let preferLyricsTypeOverProviderOrder: Bool
        let preferSyncDataProvider: Bool
        let spotifyClientId = ""
        let spotifyClientSecret = ""
        let uiLang: String

        init(enabledLyricsProviderOrder: [String] = ["lrclib", "lyricsplus"],
             lrclibCustomEndpoint: String = "", preferLyricsTypeOverProviderOrder: Bool = true,
             preferSyncDataProvider: Bool = true, uiLang: String = "en") {
            var seen = Set<String>()
            self.enabledLyricsProviderOrder = enabledLyricsProviderOrder.compactMap { value in
                let id = value.trimmed.lowercased()
                return CoreLocalization.lyricsProviderById(id) != nil && seen.insert(id).inserted ? id : nil
            }
            self.lrclibCustomEndpoint = LrclibEndpoint.normalized(lrclibCustomEndpoint) ?? ""
            self.preferLyricsTypeOverProviderOrder = preferLyricsTypeOverProviderOrder
            self.preferSyncDataProvider = preferSyncDataProvider
            self.uiLang = uiLang
        }

        func isLyricsTypeEnabled(providerId: String, type: String) -> Bool {
            enabledLyricsProviderOrder.contains(providerId)
                && [lyricsTypeKaraoke, lyricsTypeSynced, lyricsTypePlain].contains(type)
        }

        var lyricsProviderPolicySignature: String {
            "spotify-core-policy-v1|\(enabledLyricsProviderOrder.joined(separator: ","))|\(preferSyncDataProvider)|\(preferLyricsTypeOverProviderOrder)|\(LrclibEndpoint.cacheIdentity(lrclibCustomEndpoint))"
        }
    }
}

typealias AppSettings = CoreLocalization

// Repository status strings do not require the standalone app's
// resource files or Bundle.main (which belongs to Spotify in this process).
enum AppI18n {
    static func t(_ language: String?, _ key: String) -> String {
        switch key {
        case "repo.metadata_waiting": return "Waiting for track metadata"
        case "repo.lyrics_not_found": return "No lyrics found"
        case "repo.detail.manual_lrclib": return "Manually selected LRCLIB lyrics"
        case "repo.detail.sync_applied_search": return "ivLyrics sync applied to matching lyrics"
        case "repo.detail.sync_applied_direct": return "ivLyrics sync applied to its saved LRCLIB source"
        case "repo.detail.no_spotify_isrc": return "LRCLIB line lyrics. Spotify ISRC lookup is unavailable."
        case "repo.detail.no_sync_data": return "LRCLIB line lyrics. No matching sync-data was found for this ISRC."
        case "repo.detail.sync_apply_failed": return "LRCLIB line lyrics. Sync-data could not be applied."
        default: return key
        }
    }
}
