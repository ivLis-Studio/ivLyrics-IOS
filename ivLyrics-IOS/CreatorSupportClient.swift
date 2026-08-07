import Foundation

struct CreatorSupportPresentation: Equatable, Sendable {
    let tier: String
    let mode: String
    let solidColor: String
    let gradientStartColor: String
    let gradientEndColor: String
    let gradientAngle: Int

    var usesGradient: Bool {
        tier == "monthly"
            && mode == "gradient"
            && Self.isHexColor(gradientStartColor)
            && Self.isHexColor(gradientEndColor)
    }

    var hasDecoration: Bool {
        guard tier == "supporter" || tier == "monthly" else { return false }
        return usesGradient || Self.isHexColor(solidColor)
    }

    private static func isHexColor(_ value: String) -> Bool {
        value.range(of: #"^#[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil
    }
}

actor CreatorSupportClient {
    private static let discordUserEndpoint = "https://discord.ivl.is/v1/user/"
    private static let decorationsEndpoint = "https://lyrics.api.ivl.is/user/creator-decorations"
    private static let supporterRoleID = "1530978124073013478"
    private static let monthlySupporterRoleID = "1530978173590966282"
    private static let cacheKey = "creator_support_tier_cache_v1"
    private static let tierCacheTTL: TimeInterval = 60 * 60

    private struct TierCacheEntry: Codable {
        let tier: String
        let expiresAt: Date
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(contributors: [LyricsResult.SyncContributor]) async -> [String: CreatorSupportPresentation] {
        let userHashes = Self.visibleDiscordIDs(contributors)
        guard !userHashes.isEmpty else { return [:] }

        var tiers: [String: String] = [:]
        await withTaskGroup(of: (String, String).self) { group in
            for userHash in userHashes {
                group.addTask { [self] in
                    (userHash, await loadTier(userHash: userHash))
                }
            }
            for await (userHash, tier) in group {
                tiers[userHash] = tier
            }
        }

        let decorations = (try? await fetchDecorations(userHashes: userHashes)) ?? [:]
        var result: [String: CreatorSupportPresentation] = [:]
        for userHash in userHashes {
            guard let tier = tiers[userHash], tier != "none",
                  let decoration = decorations[userHash] else {
                continue
            }
            let storedMode = Self.stringValue(decoration["mode"])
            let presentation = CreatorSupportPresentation(
                tier: tier,
                mode: tier == "monthly" && storedMode == "gradient" ? "gradient" : "solid",
                solidColor: Self.stringValue(decoration["solidColor"]),
                gradientStartColor: Self.stringValue(decoration["gradientStartColor"]),
                gradientEndColor: Self.stringValue(decoration["gradientEndColor"]),
                gradientAngle: min(360, max(0, Self.intValue(decoration["gradientAngle"], fallback: 90)))
            )
            if presentation.hasDecoration {
                result[userHash] = presentation
            }
        }
        return result
    }

    private func loadTier(userHash: String) async -> String {
        var cache = readTierCache()
        let cached = cache[userHash]
        if let cached, cached.expiresAt > Date() {
            return Self.normalizeTier(cached.tier)
        }

        do {
            let tier = try await fetchTier(userHash: userHash)
            cache[userHash] = TierCacheEntry(
                tier: tier,
                expiresAt: Date().addingTimeInterval(Self.tierCacheTTL)
            )
            writeTierCache(cache)
            return tier
        } catch {
            return "none"
        }
    }

    private func fetchTier(userHash: String) async throws -> String {
        guard let encoded = userHash.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: Self.discordUserEndpoint + encoded) else {
            return "none"
        }
        let root = try await getJSON(url: url)
        let payload = root["data"] as? [String: Any]
        let roles = payload?["roles"] as? [[String: Any]] ?? []
        let roleIDs = Set(roles.map { Self.stringValue($0["id"]) })
        if roleIDs.contains(Self.monthlySupporterRoleID) {
            return "monthly"
        }
        return roleIDs.contains(Self.supporterRoleID) ? "supporter" : "none"
    }

    private func fetchDecorations(userHashes: [String]) async throws -> [String: [String: Any]] {
        var components = URLComponents(string: Self.decorationsEndpoint)!
        components.queryItems = [URLQueryItem(name: "userHashes", value: userHashes.joined(separator: ","))]
        guard let url = components.url else { return [:] }
        let root = try await getJSON(url: url)
        guard Self.boolValue(root["success"]),
              let payload = root["data"] as? [String: Any],
              let items = payload["items"] as? [[String: Any]] else {
            return [:]
        }
        var result: [String: [String: Any]] = [:]
        for item in items {
            let userHash = Self.stringValue(item["userHash"])
            guard userHashes.contains(userHash),
                  let decoration = item["decoration"] as? [String: Any] else {
                continue
            }
            result[userHash] = decoration
        }
        return result
    }

    private func getJSON(url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ivLyrics-iOS/1", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache, no-store, must-revalidate", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        return root
    }

    private func readTierCache() -> [String: TierCacheEntry] {
        guard let data = defaults.data(forKey: Self.cacheKey),
              let cache = try? JSONDecoder().decode([String: TierCacheEntry].self, from: data) else {
            return [:]
        }
        return cache
    }

    private func writeTierCache(_ cache: [String: TierCacheEntry]) {
        let oldestAllowed = Date().addingTimeInterval(-24 * 60 * 60)
        let pruned = cache.filter { $0.value.expiresAt > oldestAllowed }
        if let data = try? JSONEncoder().encode(pruned) {
            defaults.set(data, forKey: Self.cacheKey)
        }
    }

    private static func visibleDiscordIDs(_ contributors: [LyricsResult.SyncContributor]) -> [String] {
        var result: [String] = []
        for contributor in contributors.prefix(3) where !contributor.identityHidden {
            let value = contributor.userHash.trimmed
            guard (15...22).contains(value.count), value.allSatisfy(\.isNumber), !result.contains(value) else {
                continue
            }
            result.append(value)
        }
        return result
    }

    private static func normalizeTier(_ value: String) -> String {
        value == "monthly" || value == "supporter" ? value : "none"
    }

    private static func stringValue(_ value: Any?) -> String {
        if let value = value as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private static func intValue(_ value: Any?, fallback: Int) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String, let parsed = Int(value) { return parsed }
        return fallback
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return ["true", "1", "yes"].contains(value.lowercased()) }
        return false
    }
}
