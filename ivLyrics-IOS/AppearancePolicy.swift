import Foundation

/// Shared by settings and the actual video/title navigation paths; Foundation-only for regression tests.
enum AppearancePolicy {
    static func titleAction(_ value: String?) -> String {
        ["disabled", "track", "album", "context"].contains(value ?? "") ? value! : "track"
    }

    static func videoAspect(_ value: String?) -> String {
        ["fit", "fill", "stretch"].contains(value ?? "") ? value! : "fill"
    }

    static func videoDimOpacity(_ brightness: Int) -> Double {
        1 - Double(min(100, max(0, brightness))) / 100
    }

    static func videoStageCSS(_ aspect: String) -> String {
        switch videoAspect(aspect) {
        case "fit": return "width:min(100vw,177.7778vh);height:min(56.25vw,100vh);"
        case "stretch": return "width:100vw;height:56.25vw;"
        default: return "width:100vw;height:56.25vw;min-width:177.7778vh;min-height:100vh;"
        }
    }

    /// URI validation also prevents an arbitrary URL from being opened as a playback context.
    /// Opening this pair navigates in Spotify; it never invokes a player/queue API.
    static func spotifyDestination(_ uri: String) -> (app: URL, web: URL)? {
        let parts = uri.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "spotify",
              ["track", "album", "playlist", "artist", "show", "episode"].contains(parts[1]),
              !parts[2].isEmpty,
              parts[2].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              let app = URL(string: uri),
              let web = URL(string: "https://open.spotify.com/\(parts[1])/\(parts[2])") else { return nil }
        return (app, web)
    }
}
