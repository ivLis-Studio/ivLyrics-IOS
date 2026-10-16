import Foundation

/// Playback endpoint preferences never contain credentials or change authoring destinations.
enum LrclibEndpoint {
    static let settingsKey = "lrclib_custom_endpoint_v1"
    static let officialBase = "https://lrclib.net/api"

    /// Empty means official-only. A bare origin is shorthand for its /api base.
    static func normalized(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "" }
        guard !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              !value.contains("\\"),
              var parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty,
              !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              scheme == "https" || isLocalHTTPHost(host),
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.port == nil || (1...65535).contains(parts.port!),
              let decodedPath = parts.percentEncodedPath.removingPercentEncoding,
              !decodedPath.contains("\\"),
              !decodedPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !decodedPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        parts.scheme = scheme
        parts.host = host
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        if parts.path.isEmpty { parts.path = "/api" }
        guard let url = parts.url, url.host != nil else { return nil }
        let result = url.absoluteString
        return result == officialBase ? "" : result
    }

    static func playbackBases(_ custom: String) -> [String] {
        let custom = normalized(custom) ?? ""
        return custom.isEmpty ? [officialBase] : [custom, officialBase]
    }

    static func cacheIdentity(_ custom: String) -> String {
        "lrclib-endpoint-v1:" + Data((normalized(custom) ?? "").utf8).base64EncodedString()
    }

    /// Matches the local-network ATS exception, restricted to local IP ranges.
    private static func isLocalHTTPHost(_ raw: String) -> Bool {
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if host.contains(":") {
            return host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd")
                || ["fe8", "fe9", "fea", "feb"].contains(where: { host.hasPrefix($0) })
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 4, labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
           let first = Int(labels[0]), let second = Int(labels[1]),
           labels.allSatisfy({ Int($0).map { (0...255).contains($0) } == true }) {
            return first == 10 || first == 127 || (first == 172 && (16...31).contains(second))
                || (first == 192 && second == 168) || (first == 169 && second == 254)
                || (first == 100 && (64...127).contains(second)) // Shared-address VPNs such as Tailscale.
        }
        return !host.contains(".") && host.contains(where: \.isLetter)
    }
}
