import Foundation

actor LyricsRepository {
    private let lrclibBase = "https://lrclib.net/api"
    private let syncDataBase = "https://lyrics.api.ivl.is/lyrics/sync-data"
    private let syncDataRequestVersion = "20260701"
    private let openDbOrigin = "https://ivlis.kr"
    private let openDbRoot = "https://ivlis.kr/ivLyrics/opendb"
    private let syncDataSpotifyOrigin = "https://xpui.app.spotify.com"
    private let syncDataSpotifyReferer = "https://xpui.app.spotify.com/"
    private let spotifyAccountsTokenEndpoint = "https://accounts.spotify.com/api/token"
    private let spotifySearchBase = "https://api.spotify.com/v1/search"
    private let spotifyTrackBase = "https://api.spotify.com/v1/tracks/"
    private let spotifyEnglishAcceptLanguage = "en-US,en;q=0.9"
    private let lrclibProviderId = "lrclib"
    private let syncDataCacheSchema = "sync-data-api-v1"
    private let durationToleranceSeconds = 15.0
    private let syncedFallbackScoreWindow = 0.50
    private let syncedFallbackMinTitleScore = 0.78
    private let syncedFallbackMinArtistScore = 0.45
    private let spotifyTokenMaxAgeMs: Int64 = 50 * 60 * 1000
    private let spotifyTokenRefreshGraceMs: Int64 = 30_000
    private static let lyricsCacheMaxAgeMs: Int64 = 7 * 24 * 60 * 60 * 1000
    private let openDbFreshMs: Int64 = 60_000
    private let openDbUnavailableRetryMs: Int64 = 5 * 60 * 1000
    private let syncDataServerCacheBypassMs: Int64 = 30 * 1000
    private let networkRequestTimeout: TimeInterval = 47
    private let lrclibSignatureTimeout: TimeInterval = 18

    private struct MemoryLyricsCacheEntry {
        var result: LyricsResult
        var savedAtMs: Int64
    }

    private struct ProviderVariants {
        var providerId: String
        var karaoke: LyricsResult?
        var synced: LyricsResult?
        var plain: LyricsResult?

        func result(for type: String) -> LyricsResult? {
            switch type {
            case AppSettings.lyricsTypeKaraoke: return karaoke
            case AppSettings.lyricsTypeSynced: return synced
            case AppSettings.lyricsTypePlain: return plain
            default: return nil
            }
        }
    }

    private var cache: [String: MemoryLyricsCacheEntry] = [:]
    private let diskCache = LyricsDiskCache(
        namespace: "base_lyrics",
        maxEntries: 350,
        maxAgeMs: LyricsRepository.lyricsCacheMaxAgeMs
    )
    private let syncDataResponseCache = RawResponseDiskCache(
        namespace: "sync_data_api",
        maxEntries: 700,
        maxAgeMs: LyricsRepository.lyricsCacheMaxAgeMs,
        formatVersion: 2
    )
    private let defaults = UserDefaults.standard
    private var spotifyAccessToken = ""
    private var spotifyTokenSourceKey = ""
    private var spotifyTokenIssuedAtMs: Int64 = 0
    private var spotifyTokenExpiresAtMs: Int64 = 0
    private var syncDataServerCacheBypassUntil: [String: Int64] = [:]
    private var syncDataServerCacheBypassAllUntilMs: Int64 = 0

    init() {
        spotifyAccessToken = defaults.string(forKey: "spotify_token_cache_access_token") ?? ""
        spotifyTokenSourceKey = defaults.string(forKey: "spotify_token_cache_source_key") ?? ""
        spotifyTokenIssuedAtMs = Int64(defaults.double(forKey: "spotify_token_cache_issued_at_ms"))
        spotifyTokenExpiresAtMs = Int64(defaults.double(forKey: "spotify_token_cache_expires_at_ms"))
    }

    struct LoadedLyrics: Sendable {
        var trackKey: String
        var result: LyricsResult
        var artworkURL: URL?
        var logs: [String]
        var resolvedIsrc: String
        var resolvedSpotifyTrackId: String
    }

    struct ResolvedSpotifyMetadata: Sendable {
        var trackKey: String
        var isrc: String
        var spotifyTrackId: String
        var artworkURL: URL?
    }

    struct SpotifyCredentialValidation: Sendable {
        var expiresInSeconds: Int64
        var logs: [String]
    }

    struct SpotifyTrackHydration: Sendable {
        var track: TrackSnapshot
        var logs: [String]
    }

    private func getMemoryCachedLyrics(_ key: String) -> LyricsResult? {
        guard let entry = cache[key] else { return nil }
        if nowMs() - entry.savedAtMs > Self.lyricsCacheMaxAgeMs {
            cache.removeValue(forKey: key)
            return nil
        }
        guard PaxsenixLyricsProvider.canReuseCachedResult(entry.result) else {
            cache.removeValue(forKey: key)
            return nil
        }
        return entry.result
    }

    private func putMemoryCachedLyrics(_ key: String, result: LyricsResult) {
        guard !key.trimmed.isEmpty, !result.lines.isEmpty else { return }
        cache[key] = MemoryLyricsCacheEntry(
            // The live response has already had creator privacy applied by the
            // API. Keep that response intact for this process so a public
            // creator does not immediately turn into "Anonymous" on the next
            // in-memory cache hit. Persistent caches remain redacted below and
            // are rehydrated from the network before their identity is trusted.
            result: result,
            savedAtMs: nowMs()
        )
    }

    private func markProviderLyricsNormalized(_ result: LyricsResult) -> LyricsResult {
        PaxsenixLyricsProvider.markEntitiesDecoded(in: result)
    }

    private func reusableDiskCachedLyrics(_ key: String) -> LyricsResult? {
        guard let result = diskCache.get(key) else { return nil }
        guard PaxsenixLyricsProvider.canReuseCachedResult(result) else {
            diskCache.remove(key)
            return nil
        }
        return result
    }

    private func privacySafeContributorFallback(_ result: LyricsResult) -> LyricsResult {
        guard !result.contributors.isEmpty else { return result }
        var redacted = result
        redacted.contributors = result.contributors.map { contributor in
            LyricsResult.SyncContributor(
                name: "Anonymous",
                userHash: "",
                profileAvailable: false,
                anonymous: true,
                isPrivate: contributor.isPrivate
            )
        }
        return redacted
    }

    private func lyricsForImmediateCachedPresentation(_ result: LyricsResult) -> LyricsResult {
        guard !result.contributors.isEmpty else { return result }
        var presentation = result
        // Timing can be displayed immediately, but cached identity must not be
        // shown until the no-store metadata refresh has confirmed its current
        // privacy state. An empty credit is less misleading than a public user
        // flashing as Anonymous (or a newly-private user flashing as public).
        presentation.contributors = []
        return presentation
    }

    private func canApplyIvLyricsSyncToCachedResult(
        _ result: LyricsResult,
        settings: AppSettings.Snapshot
    ) -> Bool {
        guard !result.lines.isEmpty,
              !result.karaoke,
              let provider = AppSettings.lyricsProviderById(result.providerId),
              provider.supportsIvLyricsSync,
              settings.enabledLyricsProviderOrder.contains(provider.id) else {
            return false
        }
        return settings.isLyricsTypeEnabled(
            providerId: provider.id,
            type: AppSettings.lyricsTypeKaraoke
        )
    }

    private func shouldRevalidateCachedResult(
        _ result: LyricsResult,
        settings: AppSettings.Snapshot,
        resolvedIsrc: String
    ) -> Bool {
        guard !result.lines.isEmpty else { return false }
        if !result.contributors.isEmpty {
            // Creator visibility can change independently of lyric timing.
            // Revalidate contributor metadata even for a live memory-cache hit
            // so a later privacy change cannot leak through a stale identity.
            return true
        }
        guard result.selectionPolicyKey != "manual" else { return false }
        if canApplyIvLyricsSyncToCachedResult(result, settings: settings) { return true }
        guard settings.preferSyncDataProvider,
              !TrackSnapshot.normalizeIsrc(resolvedIsrc).isEmpty else {
            return false
        }
        guard let provider = AppSettings.lyricsProviderById(result.providerId) else { return true }
        return !provider.supportsIvLyricsSync || !result.karaoke
    }

    private func preferredIvLyricsSyncProviderId(
        settings: AppSettings.Snapshot,
        availableProviderIds: Set<String>
    ) -> String {
        guard settings.preferSyncDataProvider, !availableProviderIds.isEmpty else { return "" }
        return settings.enabledLyricsProviderOrder.first { providerId in
            guard let provider = AppSettings.lyricsProviderById(providerId) else { return false }
            return provider.supportsIvLyricsSync
                && availableProviderIds.contains(providerId)
                && settings.isLyricsTypeEnabled(
                    providerId: providerId,
                    type: AppSettings.lyricsTypeKaraoke
                )
        } ?? ""
    }

    func loadLyrics(
        track: TrackSnapshot,
        settings: AppSettings.Snapshot,
        onCachedLyricsLoaded: ((LoadedLyrics) async -> Void)? = nil,
        onProviderLoading: ((String) async -> Void)? = nil,
        onSpotifyMetadataResolved: ((ResolvedSpotifyMetadata) async -> Void)? = nil
    ) async throws -> LoadedLyrics {
        guard track.hasUsableMetadata else {
            return LoadedLyrics(trackKey: "", result: .empty(ui("repo.metadata_waiting", settings: settings)), artworkURL: nil, logs: [], resolvedIsrc: "", resolvedSpotifyTrackId: "")
        }

        var logs: [String] = []
        func log(_ message: String) {
            logs.append(message)
        }

        let key = track.stableKey
        let cacheKey = lyricsCacheKey(trackKey: key, settings: settings)
        var publishedSpotifyMetadataKeys = Set<String>()
        func publishResolvedMetadata(isrc: String, spotifyTrackId: String, artworkURL: URL?) async {
            guard let onSpotifyMetadataResolved else { return }
            let normalizedIsrc = TrackSnapshot.normalizeIsrc(isrc)
            let safeSpotifyTrackId = spotifyTrackId.trimmed
            guard !normalizedIsrc.isEmpty || !safeSpotifyTrackId.isEmpty || artworkURL != nil else { return }
            let eventKey = "\(normalizedIsrc)|\(safeSpotifyTrackId)|\(artworkURL?.absoluteString ?? "")"
            guard !publishedSpotifyMetadataKeys.contains(eventKey) else { return }
            publishedSpotifyMetadataKeys.insert(eventKey)
            await onSpotifyMetadataResolved(
                ResolvedSpotifyMetadata(
                    trackKey: key,
                    isrc: normalizedIsrc,
                    spotifyTrackId: safeSpotifyTrackId,
                    artworkURL: artworkURL
                )
            )
        }

        var cachedBase: LyricsResult?
        if let cached = getMemoryCachedLyrics(cacheKey) {
            let cachedIsrc = IvLyricsUtilities.firstNonEmpty(cached.isrc, track.isrc)
            if !shouldRevalidateCachedResult(cached, settings: settings, resolvedIsrc: cachedIsrc) {
                log("cache hit: \(track.title) / \(track.artist)")
                return LoadedLyrics(trackKey: key, result: cached, artworkURL: nil, logs: logs, resolvedIsrc: cached.isrc, resolvedSpotifyTrackId: cached.spotifyTrackId)
            }
            cachedBase = cached
            log("cache hit: lyrics served immediately; rechecking OpenDB sync-data priority in background")
            if let onCachedLyricsLoaded {
                await onCachedLyricsLoaded(
                    LoadedLyrics(
                        trackKey: key,
                        result: lyricsForImmediateCachedPresentation(cached),
                        artworkURL: nil,
                        logs: logs,
                        resolvedIsrc: cached.isrc,
                        resolvedSpotifyTrackId: cached.spotifyTrackId
                    )
                )
                logs.removeAll(keepingCapacity: true)
            }
        }
        if cachedBase == nil, let diskCached = reusableDiskCachedLyrics(cacheKey) {
            putMemoryCachedLyrics(cacheKey, result: diskCached)
            let cachedIsrc = IvLyricsUtilities.firstNonEmpty(diskCached.isrc, track.isrc)
            if !shouldRevalidateCachedResult(diskCached, settings: settings, resolvedIsrc: cachedIsrc) {
                log("disk cache hit: provider=\(diskCached.providerId) / contributors=\(diskCached.contributors.count)")
                return LoadedLyrics(trackKey: key, result: diskCached, artworkURL: nil, logs: logs, resolvedIsrc: diskCached.isrc, resolvedSpotifyTrackId: diskCached.spotifyTrackId)
            }
            cachedBase = diskCached
            log("lyrics disk cache hit: served immediately; rechecking OpenDB sync-data priority in background")
            if let onCachedLyricsLoaded {
                await onCachedLyricsLoaded(
                    LoadedLyrics(
                        trackKey: key,
                        result: lyricsForImmediateCachedPresentation(diskCached),
                        artworkURL: nil,
                        logs: logs,
                        resolvedIsrc: diskCached.isrc,
                        resolvedSpotifyTrackId: diskCached.spotifyTrackId
                    )
                )
                logs.removeAll(keepingCapacity: true)
            }
        }

        log("track: \"\(track.title)\" / \"\(track.artist)\"" + (track.album.isEmpty ? "" : " / album=\"\(track.album)\"") + " / duration=\(track.durationMs)ms" + (track.isrc.isEmpty ? "" : " / player ISRC=\(track.isrc)"))
        let hasCachedIsrc = cachedBase?.isrc.isEmpty == false
        log(hasCachedIsrc
            ? "flow: cached ISRC -> provider quality selection"
            : "flow: Spotify Web API search -> provider quality selection")

        let spotifyMatch: SpotifyTrackMatch?
        if let cachedBase, hasCachedIsrc {
            log("spotify lookup skipped: cached ISRC=\(cachedBase.isrc)" + (cachedBase.spotifyTrackId.isEmpty ? "" : " / trackId=\(cachedBase.spotifyTrackId)"))
            await publishResolvedMetadata(
                isrc: cachedBase.isrc,
                spotifyTrackId: cachedBase.spotifyTrackId,
                artworkURL: nil
            )
            spotifyMatch = nil
        } else {
            spotifyMatch = await fetchSpotifyIsrc(track: track, settings: settings, log: log) { match in
                await publishResolvedMetadata(isrc: match.isrc, spotifyTrackId: match.spotifyId, artworkURL: match.artworkURL)
            }
        }
        let isrc = IvLyricsUtilities.firstNonEmpty(spotifyMatch?.isrc, track.isrc, cachedBase?.isrc)
        let spotifyTrackId = IvLyricsUtilities.firstNonEmpty(spotifyMatch?.spotifyId, track.trackId, cachedBase?.spotifyTrackId)
        let hasSpotifyIsrc = spotifyMatch?.isrc.isEmpty == false
        let isrcFromCache = !hasSpotifyIsrc && track.isrc.isEmpty && cachedBase?.isrc.isEmpty == false
        let isrcSource = isrc.isEmpty ? "" : (hasSpotifyIsrc ? "Spotify Web API" : (isrcFromCache ? "lyrics cache" : "player metadata"))
        log(isrc.isEmpty ? "isrc: unavailable after Spotify lookup" : "isrc: \(isrc) (\(isrcSource))")
        if !isrc.isEmpty {
            await publishResolvedMetadata(isrc: isrc, spotifyTrackId: spotifyTrackId, artworkURL: spotifyMatch?.artworkURL)
        }

        if let cached = cachedBase, !cached.contributors.isEmpty {
            let supportsContributorRefresh = !isrc.isEmpty
                && AppSettings.lyricsProviderById(cached.providerId)?.supportsIvLyricsSync == true
            if supportsContributorRefresh,
               let currentSyncData = await fetchSyncData(
                    isrc: isrc,
                    providerId: cached.providerId,
                    track: track,
                    spotifyMatch: spotifyMatch,
                    log: log,
                    forceContributorRefresh: true
                ) {
                var hydrated = cached
                hydrated.contributors = currentSyncData.contributors
                cachedBase = hydrated
                putMemoryCachedLyrics(cacheKey, result: hydrated)
                diskCache.put(cacheKey, result: hydrated)
                log("sync-data contributors refreshed for cached lyrics: count=\(currentSyncData.contributors.count)")
            } else {
                let privacySafe = privacySafeContributorFallback(cached)
                cachedBase = privacySafe
                putMemoryCachedLyrics(cacheKey, result: privacySafe)
                diskCache.put(cacheKey, result: privacySafe)
                log("sync-data contributor refresh failed; privacy-safe anonymous fallback used")
            }
        }

        let syncDataProviders = isrc.isEmpty
            ? Set<String>()
            : await availableSyncDataProviderIds(isrc: isrc, log: log)
        if let cachedBase {
            let preferredSyncProvider = preferredIvLyricsSyncProviderId(
                settings: settings,
                availableProviderIds: syncDataProviders
            )
            let cachedProviderIsPreferred = !preferredSyncProvider.isEmpty
                && cachedBase.providerId == preferredSyncProvider
            if !preferredSyncProvider.isEmpty,
               (!cachedProviderIsPreferred || !cachedBase.karaoke) {
                if cachedProviderIsPreferred,
                   canApplyIvLyricsSyncToCachedResult(cachedBase, settings: settings) {
                    let syncData = await fetchSyncData(
                        isrc: isrc,
                        providerId: preferredSyncProvider,
                        track: track,
                        spotifyMatch: spotifyMatch,
                        log: log
                    )
                    if let applied = applySyncData(
                        syncData,
                        base: cachedBase,
                        providerName: AppSettings.lyricsProviderById(preferredSyncProvider)?.name ?? "LRCLIB",
                        track: track,
                        isrc: isrc,
                        spotifyTrackId: spotifyTrackId,
                        log: log
                    ) {
                        let selected = markProviderLyricsNormalized(
                            applied.withSelection(
                                providerId: preferredSyncProvider,
                                selectionPolicyKey: settings.lyricsProviderPolicySignature
                            )
                        )
                        putMemoryCachedLyrics(cacheKey, result: selected)
                        diskCache.put(cacheKey, result: selected)
                        return LoadedLyrics(trackKey: key, result: selected, artworkURL: spotifyMatch?.artworkURL, logs: logs, resolvedIsrc: isrc, resolvedSpotifyTrackId: spotifyTrackId)
                    }
                    log("cached provider sync-data apply failed; cached lyrics kept")
                    return LoadedLyrics(trackKey: key, result: cachedBase, artworkURL: spotifyMatch?.artworkURL, logs: logs, resolvedIsrc: isrc, resolvedSpotifyTrackId: spotifyTrackId)
                }
                log("cached provider \(cachedBase.providerId.isEmpty ? "unknown" : cachedBase.providerId) replaced by OpenDB sync-data provider \(preferredSyncProvider)")
            } else if canApplyIvLyricsSyncToCachedResult(cachedBase, settings: settings),
                      syncDataProviders.contains(cachedBase.providerId) {
                let syncData = await fetchSyncData(
                    isrc: isrc,
                    providerId: cachedBase.providerId,
                    track: track,
                    spotifyMatch: spotifyMatch,
                    log: log
                )
                if let applied = applySyncData(
                    syncData,
                    base: cachedBase,
                    providerName: AppSettings.lyricsProviderById(cachedBase.providerId)?.name ?? "LRCLIB",
                    track: track,
                    isrc: isrc,
                    spotifyTrackId: spotifyTrackId,
                    log: log
                ) {
                    let selected = markProviderLyricsNormalized(
                        applied.withSelection(
                            providerId: cachedBase.providerId,
                            selectionPolicyKey: settings.lyricsProviderPolicySignature
                        )
                    )
                    putMemoryCachedLyrics(cacheKey, result: selected)
                    diskCache.put(cacheKey, result: selected)
                    return LoadedLyrics(trackKey: key, result: selected, artworkURL: spotifyMatch?.artworkURL, logs: logs, resolvedIsrc: isrc, resolvedSpotifyTrackId: spotifyTrackId)
                }
                log("cached provider sync-data unavailable; cached lyrics kept")
                return LoadedLyrics(trackKey: key, result: cachedBase, artworkURL: spotifyMatch?.artworkURL, logs: logs, resolvedIsrc: isrc, resolvedSpotifyTrackId: spotifyTrackId)
            } else {
                log("OpenDB sync-data priority unchanged; cached provider kept: \(cachedBase.providerId.isEmpty ? "unknown" : cachedBase.providerId)")
                return LoadedLyrics(trackKey: key, result: cachedBase, artworkURL: spotifyMatch?.artworkURL, logs: logs, resolvedIsrc: isrc, resolvedSpotifyTrackId: spotifyTrackId)
            }
        }
        var providerOrder = settings.enabledLyricsProviderOrder
        if settings.preferSyncDataProvider, !syncDataProviders.isEmpty {
            let preferred = providerOrder.filter {
                syncDataProviders.contains($0)
                    && AppSettings.lyricsProviderById($0)?.supportsIvLyricsSync == true
                    && settings.isLyricsTypeEnabled(providerId: $0, type: AppSettings.lyricsTypeKaraoke)
            }
            let preferredSet = Set(preferred)
            providerOrder = preferred + providerOrder.filter { !preferredSet.contains($0) }
        }
        log("provider order: \(providerOrder.joined(separator: " -> ")) / sync-data=\(syncDataProviders.sorted()) / policy=\(settings.preferLyricsTypeOverProviderOrder ? "type-first" : "provider-first")")

        var attempts: [String: ProviderVariants] = [:]
        var attempted = Set<String>()
        func loadOnce(_ providerId: String) async -> ProviderVariants? {
            if attempted.contains(providerId) { return attempts[providerId] }
            attempted.insert(providerId)
            if let providerName = AppSettings.lyricsProviderById(providerId)?.name {
                await onProviderLoading?(providerName)
            }
            do {
                if let variants = try await loadProviderVariants(
                    providerId: providerId,
                    track: track,
                    spotifyMatch: spotifyMatch,
                    isrc: isrc,
                    spotifyTrackId: spotifyTrackId,
                    syncDataAvailable: syncDataProviders.contains(providerId),
                    settings: settings,
                    log: log
                ) {
                    attempts[providerId] = variants
                    return variants
                }
            } catch {
                log("provider \(providerId) error: \(error.localizedDescription)")
            }
            return nil
        }

        var selected: LyricsResult?
        var selectedProvider = ""
        var selectedType = ""
        if settings.preferLyricsTypeOverProviderOrder {
            for type in [AppSettings.lyricsTypeKaraoke, AppSettings.lyricsTypeSynced, AppSettings.lyricsTypePlain] {
                for providerId in providerOrder {
                    guard settings.isLyricsTypeEnabled(providerId: providerId, type: type),
                          canProviderParticipate(
                            providerId: providerId,
                            type: type,
                            syncDataAvailable: syncDataProviders.contains(providerId)
                          ) else { continue }
                    if let result = await loadOnce(providerId)?.result(for: type), !result.lines.isEmpty {
                        selected = result
                        selectedProvider = providerId
                        selectedType = type
                        break
                    }
                }
                if selected != nil { break }
            }
        } else {
            for providerId in providerOrder {
                let allowedTypes = [
                    AppSettings.lyricsTypeKaraoke,
                    AppSettings.lyricsTypeSynced,
                    AppSettings.lyricsTypePlain
                ].filter { type in
                    settings.isLyricsTypeEnabled(providerId: providerId, type: type)
                        && canProviderParticipate(
                            providerId: providerId,
                            type: type,
                            syncDataAvailable: syncDataProviders.contains(providerId)
                        )
                }
                guard !allowedTypes.isEmpty else { continue }
                guard let variants = await loadOnce(providerId) else { continue }
                for type in allowedTypes {
                    if let result = variants.result(for: type), !result.lines.isEmpty {
                        selected = result
                        selectedProvider = providerId
                        selectedType = type
                        break
                    }
                }
                if selected != nil { break }
            }
        }

        if let selected {
            let selectedWithPolicy = markProviderLyricsNormalized(
                selected.withSelection(
                    providerId: selectedProvider,
                    selectionPolicyKey: settings.lyricsProviderPolicySignature
                )
            )
            log("provider selected: \(selectedProvider) / type=\(selectedType) / lines=\(selected.lines.count)")
            putMemoryCachedLyrics(cacheKey, result: selectedWithPolicy)
            diskCache.put(cacheKey, result: selectedWithPolicy)
            return LoadedLyrics(trackKey: key, result: selectedWithPolicy, artworkURL: spotifyMatch?.artworkURL, logs: logs, resolvedIsrc: isrc, resolvedSpotifyTrackId: spotifyTrackId)
        }
        if let cachedBase {
            log("provider refresh failed: keeping cached lyrics")
            return LoadedLyrics(trackKey: key, result: cachedBase, artworkURL: spotifyMatch?.artworkURL, logs: logs, resolvedIsrc: isrc, resolvedSpotifyTrackId: spotifyTrackId)
        }
        let result = LyricsResult.empty(ui("repo.lyrics_not_found", settings: settings))
        return LoadedLyrics(trackKey: key, result: result, artworkURL: spotifyMatch?.artworkURL, logs: logs, resolvedIsrc: isrc, resolvedSpotifyTrackId: spotifyTrackId)
    }

    private func lyricsCacheKey(trackKey: String, settings: AppSettings.Snapshot) -> String {
        "\(trackKey)|\(settings.lyricsProviderPolicySignature)"
    }

    private func availableSyncDataProviderIds(isrc: String, log: (String) -> Void) async -> Set<String> {
        let normalizedIsrc = TrackSnapshot.normalizeIsrc(isrc)
        guard !normalizedIsrc.isEmpty else { return [] }
        do {
            guard let providerMap = try await loadOpenDbProviderMap(log: log) else { return [] }
            var result = Set<String>()
            for (rawProvider, rawItems) in providerMap {
                let provider = rawProvider.trimmed.lowercased()
                guard AppSettings.lyricsProviderById(provider)?.supportsIvLyricsSync == true else { continue }
                let items = rawItems as? [String] ?? []
                if items.contains(where: { TrackSnapshot.normalizeIsrc($0) == normalizedIsrc }) {
                    result.insert(provider)
                }
            }
            return result
        } catch {
            markOpenDbUnavailable()
            log("sync-data opendb provider lookup error: \(error.localizedDescription)")
            return []
        }
    }

    private func canProviderParticipate(providerId: String, type: String, syncDataAvailable: Bool) -> Bool {
        guard let provider = AppSettings.lyricsProviderById(providerId) else { return false }
        switch type {
        case AppSettings.lyricsTypeKaraoke:
            return provider.supportsNativeKaraoke
                || (provider.supportsIvLyricsSync && syncDataAvailable)
        case AppSettings.lyricsTypeSynced:
            return provider.supportsSynced
        case AppSettings.lyricsTypePlain:
            return provider.supportsPlain
        default:
            return false
        }
    }

    private func loadProviderVariants(
        providerId: String,
        track: TrackSnapshot,
        spotifyMatch: SpotifyTrackMatch?,
        isrc: String,
        spotifyTrackId: String,
        syncDataAvailable: Bool,
        settings: AppSettings.Snapshot,
        log: @escaping (String) -> Void
    ) async throws -> ProviderVariants? {
        log("provider attempt: \(providerId)")
        switch providerId {
        case "paxsenix":
            guard let outcome = try await PaxsenixLyricsProvider.fetch(track: track) else {
                log("paxsenix: no lyrics found")
                return nil
            }
            outcome.logs.forEach(log)
            let detail = "Lyrics via Lyrically API (\(PaxsenixLyricsProvider.projectURL))."
            return ProviderVariants(
                providerId: providerId,
                karaoke: outcome.karaoke.map {
                    lyricsResult(lines: $0, providerName: "Lyrically (Paxsenix)", type: AppSettings.lyricsTypeKaraoke, detail: detail, karaoke: true, isrc: isrc, spotifyTrackId: spotifyTrackId)
                },
                synced: outcome.synced.map {
                    lyricsResult(lines: $0, providerName: "Lyrically (Paxsenix)", type: AppSettings.lyricsTypeSynced, detail: detail, karaoke: false, isrc: isrc, spotifyTrackId: spotifyTrackId)
                },
                plain: outcome.plain.map {
                    lyricsResult(lines: $0, providerName: "Lyrically (Paxsenix)", type: AppSettings.lyricsTypePlain, detail: detail, karaoke: false, isrc: isrc, spotifyTrackId: spotifyTrackId)
                }
            )

        case "lyricsplus":
            guard let outcome = try await LyricsPlusProvider.fetch(track: track, isrc: isrc) else {
                log("lyricsplus: no lyrics found")
                return nil
            }
            outcome.logs.forEach(log)
            let detail = "Lyrics from LyricsPlus (\(LyricsPlusProvider.projectURL))."
            return ProviderVariants(
                providerId: providerId,
                karaoke: outcome.karaoke.map {
                    lyricsResult(lines: $0, providerName: "LyricsPlus", type: AppSettings.lyricsTypeKaraoke, detail: detail, karaoke: true, isrc: isrc, spotifyTrackId: spotifyTrackId)
                },
                synced: outcome.synced.map {
                    lyricsResult(lines: $0, providerName: "LyricsPlus", type: AppSettings.lyricsTypeSynced, detail: detail, karaoke: false, isrc: isrc, spotifyTrackId: spotifyTrackId)
                },
                plain: outcome.plain.map {
                    lyricsResult(lines: $0, providerName: "LyricsPlus", type: AppSettings.lyricsTypePlain, detail: detail, karaoke: false, isrc: isrc, spotifyTrackId: spotifyTrackId)
                }
            )

        case "unison":
            let outcome = try await UnisonLyricsProvider.fetch(track: track, isrc: isrc, spotifyTrackId: spotifyTrackId)
            outcome.logs.forEach(log)
            guard let base = outcome.result, !base.lines.isEmpty else { return nil }
            let isSynced = base.lines.contains(where: \.isTimed)
            return ProviderVariants(
                providerId: providerId,
                karaoke: base.karaoke ? base : nil,
                synced: isSynced ? demotedResult(base, type: AppSettings.lyricsTypeSynced) : nil,
                plain: demotedResult(base, type: AppSettings.lyricsTypePlain)
            )

        case "lrclib":
            let syncData = AppSettings.lyricsProviderById(providerId)?.supportsIvLyricsSync == true
                && syncDataAvailable
                && settings.isLyricsTypeEnabled(providerId: providerId, type: AppSettings.lyricsTypeKaraoke)
                ? await fetchSyncData(isrc: isrc, providerId: providerId, track: track, spotifyMatch: spotifyMatch, log: log)
                : nil
            return try await loadLrclibVariants(
                track: track,
                spotifyMatch: spotifyMatch,
                syncData: syncData,
                isrc: isrc,
                spotifyTrackId: spotifyTrackId,
                settings: settings,
                log: log
            )
        default:
            return nil
        }
    }

    private func loadLrclibVariants(
        track: TrackSnapshot,
        spotifyMatch: SpotifyTrackMatch?,
        syncData: SyncDataResult?,
        isrc: String,
        spotifyTrackId: String,
        settings: AppSettings.Snapshot,
        log: @escaping (String) -> Void
    ) async throws -> ProviderVariants? {
        var candidate: LrclibCandidate?
        var loadedFromSyncSource = false
        let syncDataContext = syncData.map(SyncDataCandidateContext.init)
        let sourceId = syncDataContext?.lrclibId ?? 0
        if sourceId > 0 {
            log("sync-data source: lrclibId=\(sourceId), direct loading LRCLIB")
            candidate = await fetchLrclibCandidateById(sourceId, log: log)
            if let candidate {
                decorateCandidateForSyncData(candidate, syncData: syncDataContext)
                loadedFromSyncSource = true
            }
        }
        if candidate == nil {
            candidate = try await searchBestCandidate(track: track, spotifyMatch: spotifyMatch, syncData: syncDataContext, log: log)
        }
        guard let candidate else {
            log("lrclib: no candidate selected")
            return nil
        }
        log("lrclib selected: \(describeLrclibCandidate(candidate))" + (loadedFromSyncSource ? " / source=sync-data.lrclibId" : " / source=search"))
        if candidate.instrumental, !candidate.hasLyrics { return nil }

        let duration = secondsToMs(candidate.durationSeconds, fallbackDurationMs: track.durationMs)
        let syncedLines = LrcParser.parseSynced(candidate.syncedLyrics, durationMs: duration)
        var plainLines = LrcParser.parsePlain(candidate.plainLyrics)
        if plainLines.isEmpty, !syncedLines.isEmpty {
            plainLines = syncedLines.map { demoteLine($0, type: AppSettings.lyricsTypePlain) }
        }
        let detail = ui(
            isrc.isEmpty ? "repo.detail.no_spotify_isrc" : (syncData == nil ? "repo.detail.no_sync_data" : "repo.detail.sync_apply_failed"),
            settings: settings
        )
        var variants = ProviderVariants(
            providerId: "lrclib",
            karaoke: nil,
            synced: syncedLines.isEmpty ? nil : lyricsResult(lines: syncedLines, providerName: "LRCLIB", type: AppSettings.lyricsTypeSynced, detail: detail, karaoke: false, isrc: isrc, spotifyTrackId: spotifyTrackId),
            plain: plainLines.isEmpty ? nil : lyricsResult(lines: plainLines, providerName: "LRCLIB", type: AppSettings.lyricsTypePlain, detail: detail, karaoke: false, isrc: isrc, spotifyTrackId: spotifyTrackId)
        )
        variants.karaoke = applySyncData(
            syncData,
            base: candidate.useSyncedLyrics() ? (variants.synced ?? variants.plain) : (variants.plain ?? variants.synced),
            providerName: "LRCLIB",
            track: track,
            isrc: isrc,
            spotifyTrackId: spotifyTrackId,
            detail: ui(loadedFromSyncSource ? "repo.detail.sync_applied_direct" : "repo.detail.sync_applied_search", settings: settings),
            log: log
        )
        return variants.karaoke == nil && variants.synced == nil && variants.plain == nil ? nil : variants
    }

    private func applySyncData(
        _ syncData: SyncDataResult?,
        base: LyricsResult?,
        providerName: String,
        track: TrackSnapshot,
        isrc: String,
        spotifyTrackId: String,
        detail: String? = nil,
        log: (String) -> Void
    ) -> LyricsResult? {
        guard let syncData, let base, !base.lines.isEmpty else { return nil }
        let applied = SyncDataApplier.applyWithDiagnostics(baseLyrics: base.lines, syncBody: syncData.syncBody, track: track)
        applied.diagnostics.forEach { log("sync-data apply [\(providerName)]: \($0)") }
        guard !applied.lines.isEmpty else { return nil }
        log("sync-data applied [\(providerName)]: lines=\(applied.lines.count) / vocalParts=\(applied.lines.reduce(0) { $0 + $1.vocalParts.count })")
        return LyricsResult(
            lines: applied.lines,
            providerLabel: "ivLyrics sync-data + \(providerName)",
            detail: detail ?? base.detail,
            karaoke: true,
            isrc: isrc,
            spotifyTrackId: spotifyTrackId,
            contributors: syncData.contributors
        )
    }

    private func lyricsResult(
        lines: [LyricsLine],
        providerName: String,
        type: String,
        detail: String,
        karaoke: Bool,
        isrc: String,
        spotifyTrackId: String
    ) -> LyricsResult {
        LyricsResult(
            lines: lines,
            providerLabel: "\(providerName) \(type)",
            detail: detail,
            karaoke: karaoke,
            isrc: isrc,
            spotifyTrackId: spotifyTrackId
        )
    }

    private func demotedResult(_ result: LyricsResult, type: String) -> LyricsResult {
        LyricsResult(
            lines: result.lines.map { demoteLine($0, type: type) },
            providerLabel: result.providerLabel.components(separatedBy: " ").first.map { "\($0) \(type)" } ?? result.providerLabel,
            detail: result.detail,
            karaoke: false,
            isrc: result.isrc,
            spotifyTrackId: result.spotifyTrackId,
            contributors: result.contributors,
            providerId: result.providerId,
            selectionPolicyKey: result.selectionPolicyKey
        )
    }

    private func demoteLine(_ line: LyricsLine, type: String) -> LyricsLine {
        LyricsLine(
            startTimeMs: type == AppSettings.lyricsTypePlain ? 0 : line.startTimeMs,
            endTimeMs: type == AppSettings.lyricsTypePlain ? 0 : line.endTimeMs,
            text: line.text,
            speaker: line.speaker,
            speakerColor: line.speakerColor,
            speakerFallback: line.speakerFallback
        )
    }

    func clearCache() {
        cache.removeAll()
        diskCache.clear()
        syncDataResponseCache.clear()
        clearOpenDbCache()
        markSyncDataServerCacheBypass("")
    }

    func clearCacheForTrack(_ trackKey: String) {
        let key = trackKey.trimmed
        guard !key.isEmpty else { return }
        cache.keys.filter { $0 == key || $0.hasPrefix("\(key)|provider-policy-") }.forEach { cache.removeValue(forKey: $0) }
        diskCache.remove(key)
        diskCache.removeByKeyPrefix("\(key)|provider-policy-")
    }

    func clearSyncDataCacheForIsrc(_ isrc: String) {
        let prefix = syncDataCacheKeyPrefix(isrc)
        guard !prefix.isEmpty else { return }
        syncDataResponseCache.removeByKeyPrefix(prefix)
        clearOpenDbCache()
        markSyncDataServerCacheBypass(TrackSnapshot.normalizeIsrc(isrc))
    }

    func searchManualLrclib(track: TrackSnapshot?, title: String, artist: String) async throws -> [ManualLrclibCandidate] {
        let queryTitle = IvLyricsUtilities.firstNonEmpty(title, track?.title)
        let queryArtist = IvLyricsUtilities.firstNonEmpty(artist, track?.artist)
        guard !queryTitle.isEmpty else { return [] }
        var logs: [String] = []
        func log(_ message: String) { logs.append(message) }
        var candidates = try await searchManualLrclibCandidates(title: queryTitle, artist: queryArtist, log: log)
        let scoringTrack = manualScoringTrack(track: track, title: queryTitle, artist: queryArtist)
        for candidate in candidates {
            candidate.score = scoringTrack == nil ? 0 : scoreCandidate(track: scoringTrack!, candidate: candidate, hasSyncData: false)
        }
        candidates.sort(by: compareLrclibCandidates)
        return candidates.prefix(14).map { ManualLrclibCandidate(candidate: $0) }
    }

    func loadManualLrclibCandidate(track: TrackSnapshot?, selected: ManualLrclibCandidate, settings: AppSettings.Snapshot) async throws -> LyricsResult {
        var logs: [String] = []
        func log(_ message: String) { logs.append(message) }
        guard selected.id > 0, let candidate = await fetchLrclibCandidateById(selected.id, log: log) else {
            throw NSError(domain: "ivLyrics.LyricsRepository", code: -1, userInfo: [NSLocalizedDescriptionKey: ui("repo.lyrics_not_found", settings: settings)])
        }
        let lineSynced = candidate.useSyncedLyrics()
        let lines = lineSynced
            ? LrcParser.parseSynced(candidate.syncedLyrics, durationMs: secondsToMs(candidate.durationSeconds, fallbackDurationMs: track?.durationMs ?? 0))
            : LrcParser.parsePlain(candidate.plainLyrics)
        if lines.isEmpty {
            return LyricsResult.empty(ui(candidate.instrumental ? "repo.instrumental" : "repo.no_renderable_lyrics", settings: settings))
        }
        let result = LyricsResult(
            lines: lines,
            providerLabel: lineSynced ? "LRCLIB synced" : "LRCLIB plain",
            detail: ui("repo.detail.manual_lrclib", settings: settings),
            karaoke: false,
            isrc: IvLyricsUtilities.firstNonEmpty(candidate.isrc, track?.isrc),
            spotifyTrackId: track?.trackId ?? ""
        ).withSelection(providerId: "lrclib", selectionPolicyKey: "manual")
        if let key = track?.stableKey, !key.isEmpty {
            let cacheKey = lyricsCacheKey(trackKey: key, settings: settings)
            putMemoryCachedLyrics(cacheKey, result: result)
            diskCache.put(cacheKey, result: result)
        }
        return result
    }

    private func ui(_ key: String, settings: AppSettings.Snapshot) -> String {
        AppI18n.t(settings.uiLang, key)
    }

    func resolveSpotifyTrack(_ rawTrackId: String, settings: AppSettings.Snapshot) async throws -> SpotifyResolvedTrack? {
        let trackId = TrackSnapshot.extractSpotifyTrackId(rawTrackId)
        guard !trackId.isEmpty else { return nil }
        var logs: [String] = []
        func log(_ message: String) { logs.append(message) }
        let token = try await getSpotifyAccessToken(forceRefresh: false, settings: settings, log: log)
        guard !token.isEmpty else {
            log("spotify manual metadata: Spotify API credentials unavailable")
            return SpotifyResolvedTrack(spotifyId: trackId, title: "", artist: "", album: "", isrc: "", durationMs: 0, artworkURL: nil, logs: logs)
        }
        guard let match = try await fetchSpotifyTrackById(
            token: token,
            trackId: trackId,
            label: "manual metadata",
            headers: ["Authorization": "Bearer \(token)"],
            requireIsrc: false,
            log: log
        ) else {
            return nil
        }
        return SpotifyResolvedTrack(
            spotifyId: match.spotifyId,
            title: match.title,
            artist: match.artist,
            album: match.album,
            isrc: match.isrc,
            durationMs: match.durationMs,
            artworkURL: match.artworkURL,
            logs: logs
        )
    }

    func validateSpotifyCredentials(clientId: String, clientSecret: String) async throws -> SpotifyCredentialValidation {
        var logs: [String] = []
        func log(_ message: String) {
            logs.append(message)
        }
        let credentials = SpotifyCredentials(clientId: clientId, clientSecret: clientSecret)
        guard credentials.configured else {
            invalidateSpotifyToken()
            log(credentials.partial ? "spotify token: Spotify API client id/secret is incomplete" : "spotify token: Spotify API credentials not configured")
            throw HTTPStatusError(statusCode: 0, message: "Spotify Client ID와 Client Secret이 필요합니다")
        }
        let response = try await requestSpotifyClientCredentialsToken(credentials: credentials, log: log)
        guard !response.accessToken.isEmpty else {
            throw HTTPStatusError(statusCode: 0, message: "Spotify token response가 비어 있습니다")
        }
        cacheSpotifyToken(credentials: credentials, response: response, log: log)
        return SpotifyCredentialValidation(expiresInSeconds: response.expiresInSeconds, logs: logs)
    }

    private func searchBestCandidate(track: TrackSnapshot, spotifyMatch: SpotifyTrackMatch?, syncData: SyncDataCandidateContext?, log: @escaping (String) -> Void) async throws -> LrclibCandidate? {
        var candidates: [LrclibCandidate] = []
        let spotifySearchTrack = buildSpotifyLrclibSearchTrack(track: track, spotifyMatch: spotifyMatch, log: log)
        let spotifySearchLabelPrefix = spotifyMatch?.hasEnglishMetadata == true ? "spotify-en" : "spotify"

        if let signatureCandidate = try await fetchLrclibCandidateBySignature(track: track, spotifyMatch: spotifyMatch, log: log) {
            appendUniqueCandidates(&candidates, [signatureCandidate])
        }

        let signatureNeedsFallback = candidates.isEmpty
            || needsLegacySyncLineShapeMatch(syncData, candidates)
            || (shouldPreferSyncedLrclibFallback(syncData) && !candidates.contains(where: hasSyncedLyricsPayload))
        if signatureNeedsFallback {
            let trackMatches = try await searchLrclibFallbackBatch(
                track: track,
                labelPrefix: "",
                includeAlbum: true,
                log: log
            )
            appendUniqueCandidates(&candidates, trackMatches)
            if let spotifySearchTrack {
                let spotifyMatches = try await searchLrclibFallbackBatch(
                    track: spotifySearchTrack,
                    labelPrefix: spotifySearchLabelPrefix,
                    includeAlbum: false,
                    log: log
                )
                appendUniqueCandidates(&candidates, spotifyMatches)
            }
        }
        guard !candidates.isEmpty else {
            log("lrclib search: no candidates")
            return nil
        }

        for candidate in candidates {
            decorateCandidateForSyncData(candidate, syncData: syncData)
            candidate.albumMatchScore = 0
            candidate.score = scoreCandidate(track: track, candidate: candidate, hasSyncData: syncData != nil)
            if let spotifySearchTrack {
                candidate.score = max(candidate.score, scoreCandidate(track: spotifySearchTrack, candidate: candidate, hasSyncData: syncData != nil))
            }
        }
        candidates.sort(by: compareLrclibCandidates)
        if let syncData, !syncData.lineCharCounts.isEmpty {
            log("lrclib sync-data exact line-shape candidates=\(countSyncLineExactCandidates(candidates))")
        }
        log("lrclib ranked candidates:")
        for (index, candidate) in candidates.prefix(5).enumerated() {
            log("  #\(index + 1) score=\(fmt(candidate.score)) album=\(fmt(candidate.albumMatchScore)) sourceScore=\(candidate.syncSourceMatchScore) syncLineExact=\(candidate.syncLineExactMatch) preferred=\(candidate.preferredLyricsSource) \(describeLrclibCandidate(candidate))")
        }
        if shouldPreferLegacyExactSyncLineShape(syncData),
           let exact = selectLegacyExactLineShapeCandidate(track: track, candidates: candidates, log: log) {
            return exact
        } else if shouldPreferLegacyExactSyncLineShape(syncData) {
            log("lrclib legacy sync-data: no exact line-shape candidate found; using ranked fallback")
        }

        let best = selectSyncedFallbackCandidate(track: track, spotifySearchTrack: spotifySearchTrack, syncData: syncData, candidates: candidates, best: candidates[0], log: log)
        if best.syncSourceMatchScore <= 0,
           !best.syncLineExactMatch,
           !isReasonableSyncedFallbackMatch(track: track, spotifySearchTrack: spotifySearchTrack, candidate: best) {
            log("lrclib selected: rejected top candidate, artist or duration mismatch: \(describeLrclibCandidate(best))")
            return nil
        }
        if best.score <= 2.2 && best.syncSourceMatchScore <= 0 && !best.syncLineExactMatch {
            log("lrclib selected: rejected top candidate, score below threshold: \(fmt(best.score))")
            return nil
        }
        return best
    }

    func hydrateSpotifyTrackMetadata(track: TrackSnapshot, settings: AppSettings.Snapshot) async -> SpotifyTrackHydration {
        var logs: [String] = []
        func log(_ message: String) {
            logs.append(message)
        }
        let trackId = track.trackId
        guard !trackId.isEmpty else {
            log("spotify live metadata: no Spotify track id to hydrate")
            return SpotifyTrackHydration(track: track, logs: logs)
        }
        do {
            var token = try await getSpotifyAccessToken(forceRefresh: false, settings: settings, log: log)
            guard !token.isEmpty else {
                log("spotify live metadata: token unavailable")
                return SpotifyTrackHydration(track: track, logs: logs)
            }
            let match: SpotifyTrackMatch?
            do {
                match = try await fetchSpotifyTrackById(
                    token: token,
                    trackId: trackId,
                    label: "live metadata",
                    headers: ["Authorization": "Bearer \(token)"],
                    requireIsrc: false,
                    log: log
                )
            } catch let error as HTTPStatusError where isSpotifyTokenFailure(error) {
                log("spotify token: rejected by live metadata request (\(error.localizedDescription)), refreshing")
                invalidateSpotifyToken()
                token = try await getSpotifyAccessToken(forceRefresh: true, settings: settings, log: log)
                guard !token.isEmpty else {
                    log("spotify live metadata: token refresh failed")
                    return SpotifyTrackHydration(track: track, logs: logs)
                }
                match = try await fetchSpotifyTrackById(
                    token: token,
                    trackId: trackId,
                    label: "live metadata",
                    headers: ["Authorization": "Bearer \(token)"],
                    requireIsrc: false,
                    log: log
                )
            }
            guard let match else {
                return SpotifyTrackHydration(track: track, logs: logs)
            }
            return SpotifyTrackHydration(track: hydratedTrack(base: track, match: match), logs: logs)
        } catch {
            log("spotify live metadata error: \(error.localizedDescription)")
            return SpotifyTrackHydration(track: track, logs: logs)
        }
    }

    private func buildSpotifyLrclibSearchTrack(track: TrackSnapshot, spotifyMatch: SpotifyTrackMatch?, log: (String) -> Void) -> TrackSnapshot? {
        guard let spotifyMatch else { return nil }
        let spotifyTitle = IvLyricsUtilities.firstNonEmpty(spotifyMatch.englishTitle, spotifyMatch.title)
        let spotifyArtist = IvLyricsUtilities.firstNonEmpty(spotifyMatch.englishArtist, spotifyMatch.artist)
        let spotifyAlbum = IvLyricsUtilities.firstNonEmpty(spotifyMatch.englishAlbum, spotifyMatch.album)
        guard !spotifyTitle.isEmpty, !spotifyArtist.isEmpty else { return nil }
        if IvLyricsUtilities.sameSearchMetadata(track.title, spotifyTitle)
            && IvLyricsUtilities.sameSearchMetadata(track.artist, spotifyArtist)
            && (spotifyAlbum.isEmpty || IvLyricsUtilities.sameSearchMetadata(track.album, spotifyAlbum)) {
            return nil
        }
        let englishMetadata = spotifyMatch.hasEnglishMetadata
        log("lrclib spotify metadata search enabled / english=\(englishMetadata) / title=\"\(spotifyTitle)\" / artist=\"\(spotifyArtist)\"" + (spotifyAlbum.isEmpty || englishMetadata ? "" : " / album=\"\(spotifyAlbum)\""))
        return TrackSnapshot(
            title: spotifyTitle,
            artist: spotifyArtist,
            album: englishMetadata ? "" : spotifyAlbum,
            packageName: track.packageName,
            mediaId: track.mediaId,
            isrc: IvLyricsUtilities.firstNonEmpty(spotifyMatch.isrc, track.isrc),
            durationMs: spotifyMatch.durationMs > 0 ? spotifyMatch.durationMs : track.durationMs,
            positionMs: track.positionMs,
            lastPositionUpdate: track.lastPositionUpdate,
            lastPositionUpdateUptime: track.lastPositionUpdateUptime,
            playbackSpeed: track.playbackSpeed,
            playing: track.playing,
            artworkURL: track.artworkURL
        )
    }

    private func hydratedTrack(base track: TrackSnapshot, match: SpotifyTrackMatch) -> TrackSnapshot {
        let position = track.positionNow()
        return TrackSnapshot(
            title: IvLyricsUtilities.firstNonEmpty(match.title, track.title),
            artist: IvLyricsUtilities.firstNonEmpty(match.artist, track.artist),
            album: IvLyricsUtilities.firstNonEmpty(match.album, track.album),
            packageName: track.packageName,
            mediaId: IvLyricsUtilities.firstNonEmpty(match.spotifyId, track.mediaId),
            isrc: IvLyricsUtilities.firstNonEmpty(match.isrc, track.isrc),
            durationMs: match.durationMs > 0 ? match.durationMs : track.durationMs,
            positionMs: position,
            lastPositionUpdate: Date(),
            playbackSpeed: track.playbackSpeed,
            playing: track.playing,
            artworkURL: match.artworkURL ?? track.artworkURL
        )
    }

    private func searchManualLrclibCandidates(title: String, artist: String, log: (String) -> Void) async throws -> [LrclibCandidate] {
        var candidates: [LrclibCandidate] = []
        var structured = ["track_name": title]
        if !artist.trimmed.isEmpty {
            structured["artist_name"] = artist.trimmed
        }
        try await appendUniqueCandidates(&candidates, searchLrclib(params: structured, label: "manual:structured", log: log))
        if !artist.trimmed.isEmpty {
            try await appendUniqueCandidates(&candidates, searchLrclib(params: ["q": "\(title) \(artist.trimmed)"], label: "manual:q:title+artist", log: log))
        }
        try await appendUniqueCandidates(&candidates, searchLrclib(params: ["q": title], label: "manual:q:title", log: log))
        return candidates
    }

    private func manualScoringTrack(track: TrackSnapshot?, title: String, artist: String) -> TrackSnapshot? {
        let scoreTitle = IvLyricsUtilities.firstNonEmpty(title, track?.title)
        let scoreArtist = IvLyricsUtilities.firstNonEmpty(artist, track?.artist)
        guard !scoreTitle.isEmpty, !scoreArtist.isEmpty else { return nil }
        return TrackSnapshot(
            title: scoreTitle,
            artist: scoreArtist,
            album: track?.album ?? "",
            packageName: track?.packageName ?? "",
            mediaId: track?.mediaId ?? "",
            isrc: track?.isrc ?? "",
            durationMs: track?.durationMs ?? 0,
            positionMs: track?.positionMs ?? 0,
            lastPositionUpdate: track?.lastPositionUpdate ?? Date(),
            lastPositionUpdateUptime: track?.lastPositionUpdateUptime,
            playbackSpeed: track?.playbackSpeed ?? 1,
            playing: track?.playing ?? false,
            artworkURL: track?.artworkURL
        )
    }

    private func searchLrclib(params: [String: String], label: String, log: (String) -> Void) async throws -> [LrclibCandidate] {
        let startedAt = ProcessInfo.processInfo.systemUptime
        log("lrclib search [\(label)]: \(describeParams(params))")
        let body = try await get("\(lrclibBase)/search?\(IvLyricsUtilities.encodeParams(params))")
        let array = try jsonArray(body)
        let candidates = array.compactMap { item -> LrclibCandidate? in
            guard let object = item as? [String: Any] else { return nil }
            let candidate = LrclibCandidate(json: object)
            return candidate.hasLyrics ? candidate : nil
        }
        log("lrclib search [\(label)]: candidates=\(candidates.count) / elapsed=\(fmt(ProcessInfo.processInfo.systemUptime - startedAt))s")
        return candidates
    }

    private func searchLrclibFallback(params: [String: String], label: String, log: (String) -> Void) async throws -> [LrclibCandidate] {
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            return try await searchLrclib(params: params, label: label, log: log)
        } catch {
            if isCancellationError(error) {
                throw error
            }
            log("lrclib search [\(label)] failed after \(fmt(ProcessInfo.processInfo.systemUptime - startedAt))s: \(error.localizedDescription); continuing fallback")
            return []
        }
    }

    private func searchLrclibFallbackBatch(track: TrackSnapshot, labelPrefix: String, includeAlbum: Bool, log: @escaping (String) -> Void) async throws -> [LrclibCandidate] {
        guard !track.title.isEmpty else { return [] }
        let prefix = labelPrefix.trimmed.isEmpty ? "" : "\(labelPrefix.trimmed):"
        async let structured = searchLrclibFallback(
            params: buildStructuredQuery(track, includeAlbum: includeAlbum),
            label: "\(prefix)structured",
            log: log
        )
        async let titleArtist = searchLrclibFallback(
            params: ["q": "\(track.title) \(track.artist)"],
            label: "\(prefix)q:title+artist",
            log: log
        )
        async let titleOnly = searchLrclibFallback(
            params: ["q": track.title],
            label: "\(prefix)q:title",
            log: log
        )

        let batches = try await (structured, titleArtist, titleOnly)
        var candidates: [LrclibCandidate] = []
        appendUniqueCandidates(&candidates, batches.0)
        appendUniqueCandidates(&candidates, batches.1)
        appendUniqueCandidates(&candidates, batches.2)
        return candidates
    }

    private func fetchLrclibCandidateBySignature(track: TrackSnapshot, spotifyMatch: SpotifyTrackMatch?, log: (String) -> Void) async throws -> LrclibCandidate? {
        let title = IvLyricsUtilities.firstNonEmpty(spotifyMatch?.title, track.title)
        let artist = IvLyricsUtilities.firstNonEmpty(spotifyMatch?.artist, track.artist)
        let album = IvLyricsUtilities.firstNonEmpty(spotifyMatch?.album, track.album)
        let spotifyDurationMs = spotifyMatch?.durationMs ?? 0
        let durationMs = spotifyDurationMs > 0 ? spotifyDurationMs : track.durationMs
        guard !title.isEmpty, !artist.isEmpty, !album.isEmpty, durationMs > 0 else {
            log("lrclib signature: skipped, album or duration unavailable")
            return nil
        }

        let params = [
            "track_name": title,
            "artist_name": artist,
            "album_name": album,
            "duration": String(Double(durationMs) / 1000.0)
        ]
        let startedAt = ProcessInfo.processInfo.systemUptime
        log("lrclib signature: \(describeParams(params))")
        do {
            let body = try await get(
                "\(lrclibBase)/get?\(IvLyricsUtilities.encodeParams(params))",
                timeoutInterval: lrclibSignatureTimeout
            )
            let candidate = LrclibCandidate(json: try jsonObject(body))
            guard candidate.hasLyrics else {
                log("lrclib signature: response has no lyrics payload")
                return nil
            }
            log("lrclib signature: matched in \(fmt(ProcessInfo.processInfo.systemUptime - startedAt))s / \(describeLrclibCandidate(candidate))")
            return candidate
        } catch let error as HTTPStatusError where error.statusCode == 404 {
            log("lrclib signature: no exact match after \(fmt(ProcessInfo.processInfo.systemUptime - startedAt))s")
            return nil
        } catch {
            if isCancellationError(error) {
                throw error
            }
            log("lrclib signature error after \(fmt(ProcessInfo.processInfo.systemUptime - startedAt))s: \(error.localizedDescription); continuing search")
            return nil
        }
    }

    private func fetchLrclibCandidateById(_ lrclibId: Int64, log: (String) -> Void) async -> LrclibCandidate? {
        guard lrclibId > 0 else { return nil }
        do {
            let body = try await get("\(lrclibBase)/get/\(lrclibId)")
            let candidate = LrclibCandidate(json: try jsonObject(body))
            if candidate.hasLyrics {
                log("lrclib direct: \(describeLrclibCandidate(candidate))")
                return candidate
            }
            log("lrclib direct: id=\(lrclibId) has no lyrics payload")
            return nil
        } catch {
            log("lrclib direct error: id=\(lrclibId) / \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchSyncData(
        isrc: String,
        providerId: String,
        track: TrackSnapshot,
        spotifyMatch: SpotifyTrackMatch?,
        log: (String) -> Void,
        forceContributorRefresh: Bool = false
    ) async -> SyncDataResult? {
        do {
            let normalizedIsrc = TrackSnapshot.normalizeIsrc(isrc)
            let normalizedProvider = providerId.trimmed.lowercased()
            guard !normalizedIsrc.isEmpty, AppSettings.lyricsProviderById(normalizedProvider) != nil else { return nil }
            let cacheKey = syncDataCacheKey(isrc, providerId: normalizedProvider)
            let cachedResponse = syncDataResponseCache.get(cacheKey)
            let cachedIdentityRedacted = cachedResponse.contains("\"identityRedacted\":true")
            if !forceContributorRefresh, !cachedResponse.isEmpty, !cachedIdentityRedacted {
                log("sync-data cache hit: isrc=\(normalizedIsrc)")
                return try parseSyncDataResponse(
                    cachedResponse,
                    expectedProvider: normalizedProvider,
                    log: log,
                    fromCache: true
                )
            }
            if forceContributorRefresh || cachedIdentityRedacted {
                log("sync-data timing cache hit; refreshing contributor privacy metadata")
            }

            let bypassServerCache = shouldBypassSyncDataServerCache(normalizedIsrc)
            if !forceContributorRefresh, !cachedIdentityRedacted {
                if bypassServerCache {
                    if await isOpenDbUnavailable(log: log) {
                        log("sync-data opendb: unavailable after cache clear, skip direct sync-data request")
                        return nil
                    }
                } else {
                    guard await shouldRequestSyncDataFromOpenDb(isrc: normalizedIsrc, provider: normalizedProvider, log: log) else {
                        return nil
                    }
                }
            }

            var params: [String: String] = [
                "isrc": normalizedIsrc,
                "provider": normalizedProvider,
                "request-version": syncDataRequestVersion,
                "metadata": "1",
                "title": IvLyricsUtilities.firstNonEmpty(spotifyMatch?.title, track.title),
                "artist": IvLyricsUtilities.firstNonEmpty(spotifyMatch?.artist, track.artist),
                "album": IvLyricsUtilities.firstNonEmpty(spotifyMatch?.album, track.album)
            ]
            if bypassServerCache {
                params["bypassCache"] = "1"
            }
            let trackId = IvLyricsUtilities.firstNonEmpty(spotifyMatch?.spotifyId, track.trackId)
            if !trackId.isEmpty {
                params["trackId"] = trackId
            }
            log("sync-data request: \(describeParams(params))")
            let headers = syncDataHeaders()
            log("sync-data headers: Origin=\(headers["Origin"] ?? "")")
            let response = try await get("\(syncDataBase)?\(IvLyricsUtilities.encodeParams(params))", headers: headers)
            let result = try parseSyncDataResponse(
                response,
                expectedProvider: normalizedProvider,
                log: log,
                fromCache: false
            )
            if !cacheKey.isEmpty,
               let persistentResponse = redactedSyncDataResponseForPersistence(response) {
                syncDataResponseCache.put(cacheKey, body: persistentResponse)
            }
            return result
        } catch {
            log("sync-data error: \(error.localizedDescription)")
            return nil
        }
    }

    private func shouldRequestSyncDataFromOpenDb(isrc: String, provider: String, log: (String) -> Void) async -> Bool {
        let normalizedIsrc = TrackSnapshot.normalizeIsrc(isrc)
        let normalizedProvider = provider.trimmed.lowercased()
        guard !normalizedIsrc.isEmpty, !normalizedProvider.isEmpty else { return false }
        do {
            guard let providerMap = try await loadOpenDbProviderMap(log: log) else {
                log("sync-data opendb: unavailable, skip direct sync-data request")
                return false
            }
            let providerItems = providerMap.first { key, _ in
                key.trimmed.lowercased() == normalizedProvider
            }?.value as? [String]
            let exists = providerItems?.contains(where: {
                TrackSnapshot.normalizeIsrc($0) == normalizedIsrc
            }) == true
            if !exists {
                log("sync-data opendb: not listed, skip direct sync-data request / provider=\(normalizedProvider) / isrc=\(normalizedIsrc)")
            }
            return exists
        } catch {
            markOpenDbUnavailable()
            log("sync-data opendb error: \(error.localizedDescription)")
            return false
        }
    }

    private func isOpenDbUnavailable(log: (String) -> Void) async -> Bool {
        do {
            return try await loadOpenDbProviderMap(log: log) == nil
        } catch {
            markOpenDbUnavailable()
            log("sync-data opendb error: \(error.localizedDescription)")
            return true
        }
    }

    private func loadOpenDbProviderMap(log: (String) -> Void) async throws -> [String: Any]? {
        let now = nowMs()
        let unavailableUntil = Int64(defaults.double(forKey: "sync_data_opendb_unavailable_until_ms"))
        if unavailableUntil > now {
            return nil
        }
        let cached = defaults.string(forKey: "sync_data_opendb_provider_map") ?? ""
        if !cached.isEmpty,
           now - Int64(defaults.double(forKey: "sync_data_opendb_fetched_at_ms")) < openDbFreshMs,
           let object = try? jsonObject(cached) {
            return object
        }
        do {
            log("sync-data opendb manifest request")
            let manifest = try jsonObject(try await get("\(openDbRoot)/data/manifest.json"))
            let signature = openDbManifestSignature(manifest)
            if !cached.isEmpty,
               !signature.isEmpty,
               signature == (defaults.string(forKey: "sync_data_opendb_manifest_signature") ?? ""),
               let providerMap = try? jsonObject(cached) {
                defaults.set(Double(now), forKey: "sync_data_opendb_fetched_at_ms")
                defaults.set(0.0, forKey: "sync_data_opendb_unavailable_until_ms")
                log("sync-data opendb manifest unchanged: cached provider map reused")
                return providerMap
            }

            let refreshed = try await refreshOpenDbProviderMap(manifest: manifest, log: log)
            if let data = try? JSONSerialization.data(withJSONObject: refreshed),
               let raw = String(data: data, encoding: .utf8) {
                defaults.set(raw, forKey: "sync_data_opendb_provider_map")
                defaults.set(Double(now), forKey: "sync_data_opendb_fetched_at_ms")
                defaults.set(signature, forKey: "sync_data_opendb_manifest_signature")
                defaults.set(stringValue((manifest["base"] as? [String: Any])?["date"]), forKey: "sync_data_opendb_base_date")
                defaults.set(0.0, forKey: "sync_data_opendb_unavailable_until_ms")
            }
            return refreshed
        } catch {
            defaults.set(Double(now + openDbUnavailableRetryMs), forKey: "sync_data_opendb_unavailable_until_ms")
            throw error
        }
    }

    private func openDbManifestSignature(_ manifest: [String: Any]) -> String {
        let deltas = (manifest["deltas"] as? [[String: Any]]) ?? []
        let base = manifest["base"] as? [String: Any]
        let current = manifest["current"] as? [String: Any]
        let signatureObject: [String: Any] = [
            "schema": (manifest["schema"] as? NSNumber)?.intValue ?? 0,
            "base": IvLyricsUtilities.firstNonEmpty(stringValue(base?["sha256"]), stringValue(base?["url"])),
            "deltas": deltas.map {
                IvLyricsUtilities.firstNonEmpty(stringValue($0["sha256"]), stringValue($0["url"]), stringValue($0["date"]))
            },
            "current": IvLyricsUtilities.firstNonEmpty(
                stringValue(current?["sha256"]),
                stringValue(current?["updatedAt"]),
                stringValue(current?["url"])
            )
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: signatureObject, options: [.sortedKeys]),
              let signature = String(data: data, encoding: .utf8) else {
            return ""
        }
        return signature
    }

    private func refreshOpenDbProviderMap(manifest: [String: Any], log: (String) -> Void) async throws -> [String: Any] {
        var providerMap: [String: Set<String>] = [:]
        if let base = manifest["base"] as? [String: Any] {
            try await mergeOpenDbProviderFile(providerMap: &providerMap, relativeUrl: stringValue(base["url"]), delta: false)
        }
        if let deltas = manifest["deltas"] as? [[String: Any]] {
            for delta in deltas {
                try await mergeOpenDbProviderFile(providerMap: &providerMap, relativeUrl: stringValue(delta["url"]), delta: true)
            }
        }
        if let current = manifest["current"] as? [String: Any] {
            try await mergeOpenDbProviderFile(providerMap: &providerMap, relativeUrl: stringValue(current["url"]), delta: true)
        }
        let plain = providerMap.mapValues { Array($0).sorted() }
        log("sync-data opendb refreshed: lrclib=\(plain[lrclibProviderId]?.count ?? 0)")
        return plain
    }

    private func mergeOpenDbProviderFile(providerMap: inout [String: Set<String>], relativeUrl: String, delta: Bool) async throws {
        let url = resolveOpenDbUrl(relativeUrl)
        guard !url.isEmpty else { return }
        let file = try jsonObject(try await get(url))
        if delta {
            mergeOpenDbProviderObject(providerMap: &providerMap, source: file["add"] as? [String: Any], add: true)
            mergeOpenDbProviderObject(providerMap: &providerMap, source: file["remove"] as? [String: Any], add: false)
        } else {
            mergeOpenDbProviderObject(providerMap: &providerMap, source: file["items"] as? [String: Any], add: true)
        }
    }

    private func mergeOpenDbProviderObject(providerMap: inout [String: Set<String>], source: [String: Any]?, add: Bool) {
        guard let source else { return }
        for (provider, rawEntries) in source {
            let entries = rawEntries as? [String] ?? []
            var target = providerMap[provider] ?? []
            for entry in entries {
                let normalizedIsrc = TrackSnapshot.normalizeIsrc(entry)
                guard !normalizedIsrc.isEmpty else { continue }
                if add {
                    target.insert(normalizedIsrc)
                } else {
                    target.remove(normalizedIsrc)
                }
            }
            providerMap[provider] = target
        }
    }

    private func resolveOpenDbUrl(_ relativeUrl: String) -> String {
        let value = relativeUrl.trimmed
        if value.isEmpty { return "" }
        if value.hasPrefix("http://") || value.hasPrefix("https://") { return value }
        if value.hasPrefix("/") { return openDbOrigin + value }
        return "\(openDbRoot)/\(value)"
    }

    private func clearOpenDbCache() {
        defaults.removeObject(forKey: "sync_data_opendb_provider_map")
        defaults.removeObject(forKey: "sync_data_opendb_fetched_at_ms")
        defaults.removeObject(forKey: "sync_data_opendb_manifest_signature")
        defaults.removeObject(forKey: "sync_data_opendb_base_date")
        defaults.removeObject(forKey: "sync_data_opendb_unavailable_until_ms")
    }

    private func markSyncDataServerCacheBypass(_ normalizedIsrc: String) {
        let expiresAt = nowMs() + syncDataServerCacheBypassMs
        let key = normalizedIsrc.trimmed
        if key.isEmpty {
            syncDataServerCacheBypassAllUntilMs = expiresAt
            syncDataServerCacheBypassUntil.removeAll()
            return
        }
        syncDataServerCacheBypassUntil[key] = expiresAt
    }

    private func shouldBypassSyncDataServerCache(_ normalizedIsrc: String) -> Bool {
        let now = nowMs()
        if syncDataServerCacheBypassAllUntilMs > now {
            return true
        }
        if syncDataServerCacheBypassAllUntilMs > 0 {
            syncDataServerCacheBypassAllUntilMs = 0
        }

        let key = normalizedIsrc.trimmed
        guard !key.isEmpty, let expiresAt = syncDataServerCacheBypassUntil[key] else {
            return false
        }
        if expiresAt <= now {
            syncDataServerCacheBypassUntil.removeValue(forKey: key)
            return false
        }
        return true
    }

    private func markOpenDbUnavailable() {
        defaults.set(Double(nowMs() + openDbUnavailableRetryMs), forKey: "sync_data_opendb_unavailable_until_ms")
    }

    private func parseSyncDataResponse(
        _ response: String,
        expectedProvider: String,
        log: (String) -> Void,
        fromCache: Bool
    ) throws -> SyncDataResult? {
        let prefix = fromCache ? "sync-data cached response" : "sync-data response"
        let root = try jsonObject(response)
        guard let data = root["data"] as? [String: Any] else {
            log("\(prefix): no data")
            return nil
        }
        let normalizedExpectedProvider = expectedProvider.trimmed.lowercased()
        let responseProvider = stringValue(data["provider"], fallback: normalizedExpectedProvider).trimmed.lowercased()
        guard responseProvider == normalizedExpectedProvider else {
            log("\(prefix): provider mismatch / expected=\(normalizedExpectedProvider) / actual=\(responseProvider)")
            return nil
        }
        if let syncData = data["syncData"] as? [String: Any] {
            let body = syncBodyWithDurationFallback(syncBody: syncData, wrapper: data)
            let result = SyncDataResult(syncBody: body, provider: responseProvider, contributors: parseSyncContributors(data: data, syncData: syncData))
            log("\(prefix): provider=\(result.provider) / lines=\(result.lineCharCounts.count) / lrclibId=\(result.lrclibId) / contributors=\(result.contributors.count)\(syncDurationSuffix(result.syncBody))")
            return result
        }
        if data["lines"] is [[String: Any]] {
            let body = syncBodyWithDurationFallback(syncBody: data, wrapper: data)
            let result = SyncDataResult(syncBody: body, provider: responseProvider, contributors: parseSyncContributors(data: data, syncData: data))
            log("\(prefix): legacy body / provider=\(result.provider) / lines=\(result.lineCharCounts.count) / lrclibId=\(result.lrclibId) / contributors=\(result.contributors.count)\(syncDurationSuffix(result.syncBody))")
            return result
        }
        log("\(prefix): data without lines")
        return nil
    }

    private func syncBodyWithDurationFallback(syncBody: [String: Any], wrapper: [String: Any]) -> [String: Any] {
        let durationMs = SyncDataApplier.normalizeDurationMs(syncBody["trackDurationMs"], wrapper["trackDurationMs"], syncBody["durationMs"], wrapper["durationMs"], syncBody["duration_ms"], wrapper["duration_ms"])
        if durationMs <= 0 || SyncDataApplier.normalizeDurationMs(syncBody["trackDurationMs"]) > 0 {
            return syncBody
        }
        var copy = syncBody
        copy["trackDurationMs"] = durationMs
        return copy
    }

    private func syncDurationSuffix(_ syncBody: [String: Any]) -> String {
        let durationMs = SyncDataApplier.normalizeDurationMs(syncBody["trackDurationMs"], syncBody["durationMs"], syncBody["duration_ms"])
        return durationMs <= 0 ? "" : " / durationMs=\(durationMs)"
    }

    private func fetchSpotifyIsrc(
        track: TrackSnapshot,
        settings: AppSettings.Snapshot,
        log: (String) -> Void,
        onResolved: ((SpotifyTrackMatch) async -> Void)? = nil
    ) async -> SpotifyTrackMatch? {
        guard !track.title.trimmed.isEmpty, !track.artist.trimmed.isEmpty else {
            log("spotify search: missing title or artist metadata")
            return nil
        }
        do {
            var token = try await getSpotifyAccessToken(forceRefresh: false, settings: settings, log: log)
            guard !token.isEmpty else {
                log("spotify token: unavailable; configure Spotify API client id/secret in settings")
                return nil
            }

            if !track.trackId.isEmpty {
                do {
                    if var direct = try await fetchSpotifyTrackById(token: token, trackId: track.trackId, log: log), !direct.isrc.isEmpty {
                        if isSpotifyDurationCompatible(track: track, match: direct) {
                            await onResolved?(direct)
                            direct = await attachSpotifyEnglishMetadata(token: token, match: direct, log: log)
                            log("spotify selected ISRC: direct track metadata \(describeSpotifyMatch(direct))")
                            return direct
                        }
                        log("spotify track: direct metadata skipped by duration, \(spotifyDurationNote(track: track, match: direct)) \(describeSpotifyMatch(direct))")
                    }
                } catch let error as HTTPStatusError where isSpotifyTokenFailure(error) {
                    log("spotify token: rejected by direct track request (\(error.localizedDescription)), refreshing")
                    invalidateSpotifyToken()
                    token = try await getSpotifyAccessToken(forceRefresh: true, settings: settings, log: log)
                    if !token.isEmpty,
                       var direct = try await fetchSpotifyTrackById(token: token, trackId: track.trackId, log: log),
                       !direct.isrc.isEmpty {
                        if isSpotifyDurationCompatible(track: track, match: direct) {
                            await onResolved?(direct)
                            direct = await attachSpotifyEnglishMetadata(token: token, match: direct, log: log)
                            log("spotify selected ISRC: direct track metadata after refresh \(describeSpotifyMatch(direct))")
                            return direct
                        }
                        log("spotify track: direct metadata after refresh skipped by duration, \(spotifyDurationNote(track: track, match: direct)) \(describeSpotifyMatch(direct))")
                    }
                }
            }

            var matches: [SpotifyTrackMatch]
            do {
                matches = try await searchSpotifyCandidates(track: track, token: token, log: log)
            } catch let error as HTTPStatusError where isSpotifyTokenFailure(error) {
                log("spotify token: rejected by Spotify API (\(error.localizedDescription)), refreshing")
                invalidateSpotifyToken()
                token = try await getSpotifyAccessToken(forceRefresh: true, settings: settings, log: log)
                guard !token.isEmpty else {
                    log("spotify token: refresh failed")
                    return nil
                }
                matches = try await searchSpotifyCandidates(track: track, token: token, log: log)
            }
            guard !matches.isEmpty else {
                log("spotify search: no candidates with ISRC")
                return nil
            }
            guard let selected = selectSpotifyMatchByApiOrder(track: track, matches: matches, log: log) else {
                return nil
            }
            await onResolved?(selected)
            return await attachSpotifyEnglishMetadata(token: token, match: selected, log: log)
        } catch {
            log("spotify search error: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchSpotifyTrackById(token: String, trackId: String, log: (String) -> Void) async throws -> SpotifyTrackMatch? {
        try await fetchSpotifyTrackById(token: token, trackId: trackId, label: "direct metadata", headers: ["Authorization": "Bearer \(token)"], requireIsrc: true, log: log)
    }

    private func fetchSpotifyTrackById(token: String, trackId: String, label: String, headers: [String: String], requireIsrc: Bool, log: (String) -> Void) async throws -> SpotifyTrackMatch? {
        guard !trackId.trimmed.isEmpty else { return nil }
        log("spotify track: \(label) lookup id=\(trackId)")
        let response = try await get("\(spotifyTrackBase)\(IvLyricsUtilities.urlEncode(trackId.trimmed))", headers: headers)
        let match = SpotifyTrackMatch(json: try jsonObject(response), requireIsrc: requireIsrc)
        if let match {
            log("spotify track: \(label) ready \(describeSpotifyMatch(match))")
        } else {
            log("spotify track: no usable \(label)")
        }
        return match
    }

    private func attachSpotifyEnglishMetadata(token: String, match: SpotifyTrackMatch, log: (String) -> Void) async -> SpotifyTrackMatch {
        guard !match.spotifyId.isEmpty, !token.trimmed.isEmpty else { return match }
        do {
            let headers = ["Authorization": "Bearer \(token)", "Accept-Language": spotifyEnglishAcceptLanguage]
            guard let english = try await fetchSpotifyTrackById(token: token, trackId: match.spotifyId, label: "english metadata", headers: headers, requireIsrc: false, log: log),
                  !english.title.isEmpty, !english.artist.isEmpty else {
                return match
            }
            let merged = match.withEnglishMetadata(english)
            if merged.hasEnglishMetadata {
                log("spotify english metadata: title=\"\(merged.englishTitle)\" / artist=\"\(merged.englishArtist)\"")
            } else {
                log("spotify english metadata: same as selected metadata")
            }
            return merged
        } catch {
            log("spotify english metadata error: \(error.localizedDescription)")
            return match
        }
    }

    private func searchSpotifyCandidates(track: TrackSnapshot, token: String, log: (String) -> Void) async throws -> [SpotifyTrackMatch] {
        var matches: [SpotifyTrackMatch] = []
        matches.append(contentsOf: try await searchSpotifyTracks(token: token, query: "\(track.title) \(track.artist)", label: "plain", log: log))
        matches.append(contentsOf: try await searchSpotifyTracks(token: token, query: buildSpotifyFieldQuery(track), label: "field", log: log))
        var ordered: [String: SpotifyTrackMatch] = [:]
        var keys: [String] = []
        for match in matches {
            let key = match.spotifyId.isEmpty ? "\(match.isrc)|\(match.title)|\(match.artist)|\(match.durationMs)" : match.spotifyId
            guard !key.trimmed.isEmpty, ordered[key] == nil else { continue }
            ordered[key] = match
            keys.append(key)
        }
        return keys.compactMap { ordered[$0] }
    }

    private func searchSpotifyTracks(token: String, query: String, label: String, log: (String) -> Void) async throws -> [SpotifyTrackMatch] {
        let params = ["q": query, "type": "track", "limit": "10"]
        log("spotify search [\(label)]: q=\(query)")
        let response = try await get("\(spotifySearchBase)?\(IvLyricsUtilities.encodeParams(params))", headers: ["Authorization": "Bearer \(token)"])
        let root = try jsonObject(response)
        let items = ((root["tracks"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        let matches = items.compactMap { SpotifyTrackMatch(json: $0, requireIsrc: true) }
        log("spotify search [\(label)]: candidates=\(matches.count)")
        return matches
    }

    private func selectSpotifyMatchByApiOrder(track: TrackSnapshot, matches: [SpotifyTrackMatch], log: (String) -> Void) -> SpotifyTrackMatch? {
        log("spotify ordered candidates:")
        for (index, match) in matches.prefix(8).enumerated() {
            log("  #\(index + 1) \(spotifyDurationNote(track: track, match: match)) \(describeSpotifyMatch(match))")
        }
        for (index, match) in matches.enumerated() where isSpotifyDurationCompatible(track: track, match: match) {
            log("spotify selected ISRC: \(match.isrc) / responseOrder=\(index + 1) / trackId=\(match.spotifyId)")
            return match
        }
        log("spotify selected ISRC: rejected all candidates by duration mismatch")
        return nil
    }

    private func getSpotifyAccessToken(forceRefresh: Bool, settings: AppSettings.Snapshot, log: (String) -> Void) async throws -> String {
        let credentials = SpotifyCredentials(clientId: settings.spotifyClientId, clientSecret: settings.spotifyClientSecret)
        guard credentials.configured else {
            invalidateSpotifyToken()
            log(credentials.partial ? "spotify token: Spotify API client id/secret is incomplete" : "spotify token: Spotify API credentials not configured")
            return ""
        }
        let tokenSourceKey = credentials.sourceKey
        let now = nowMs()
        if !forceRefresh, isSpotifyTokenUsable(now: now, tokenSourceKey: tokenSourceKey) {
            log("spotify token: cached token reused (\(credentials.sourceLabel))")
            return spotifyAccessToken
        }
        if forceRefresh {
            log("spotify token: forced refresh")
        } else if !spotifyAccessToken.isEmpty, tokenSourceKey != spotifyTokenSourceKey {
            log("spotify token: cached token source changed, refreshing")
        } else if !spotifyAccessToken.isEmpty {
            log("spotify token: cached token expired, refreshing")
        }
        do {
            let response = try await requestSpotifyClientCredentialsToken(credentials: credentials, log: log)
            guard !response.accessToken.isEmpty else { return "" }
            cacheSpotifyToken(credentials: credentials, response: response, log: log)
            return spotifyAccessToken
        } catch {
            invalidateSpotifyToken()
            log("spotify token: refresh error (\(credentials.sourceLabel)): \(error.localizedDescription)")
            return ""
        }
    }

    private func requestSpotifyClientCredentialsToken(credentials: SpotifyCredentials, log: (String) -> Void) async throws -> SpotifyTokenResponse {
        log("spotify token: requesting with Spotify API credentials")
        let basic = Data("\(credentials.clientId):\(credentials.clientSecret)".utf8).base64EncodedString()
        let response = try await postForm(spotifyAccountsTokenEndpoint, params: ["grant_type": "client_credentials"], headers: ["Authorization": "Basic \(basic)"])
        let root = try jsonObject(response)
        return SpotifyTokenResponse(accessToken: extractSpotifyToken(root), expiresInSeconds: max(60, int64Value(root["expires_in"], fallback: int64Value(root["expiresIn"], fallback: 3600))))
    }

    private func cacheSpotifyToken(credentials: SpotifyCredentials, response: SpotifyTokenResponse, log: (String) -> Void) {
        let issuedAtMs = nowMs()
        let providerTtlMs = max(60, response.expiresInSeconds) * 1000
        let effectiveTtlMs = min(providerTtlMs, spotifyTokenMaxAgeMs)
        spotifyAccessToken = response.accessToken
        spotifyTokenSourceKey = credentials.sourceKey
        spotifyTokenIssuedAtMs = issuedAtMs
        spotifyTokenExpiresAtMs = issuedAtMs + effectiveTtlMs
        persistSpotifyToken()
        log("spotify token: refreshed and saved (\(credentials.sourceLabel)), ttl=\(Int((Double(effectiveTtlMs) / 1000.0).rounded()))s")
    }

    private func isSpotifyTokenUsable(now: Int64, tokenSourceKey: String) -> Bool {
        guard !spotifyAccessToken.isEmpty, tokenSourceKey == spotifyTokenSourceKey else { return false }
        guard spotifyTokenIssuedAtMs > 0, now - spotifyTokenIssuedAtMs < spotifyTokenMaxAgeMs else { return false }
        return spotifyTokenExpiresAtMs > now + spotifyTokenRefreshGraceMs
    }

    private func persistSpotifyToken() {
        defaults.set(spotifyAccessToken, forKey: "spotify_token_cache_access_token")
        defaults.set(spotifyTokenSourceKey, forKey: "spotify_token_cache_source_key")
        defaults.set(Double(spotifyTokenIssuedAtMs), forKey: "spotify_token_cache_issued_at_ms")
        defaults.set(Double(spotifyTokenExpiresAtMs), forKey: "spotify_token_cache_expires_at_ms")
    }

    private func invalidateSpotifyToken() {
        spotifyAccessToken = ""
        spotifyTokenSourceKey = ""
        spotifyTokenIssuedAtMs = 0
        spotifyTokenExpiresAtMs = 0
        defaults.removeObject(forKey: "spotify_token_cache_access_token")
        defaults.removeObject(forKey: "spotify_token_cache_source_key")
        defaults.removeObject(forKey: "spotify_token_cache_issued_at_ms")
        defaults.removeObject(forKey: "spotify_token_cache_expires_at_ms")
    }

    private func isSpotifyTokenFailure(_ error: HTTPStatusError) -> Bool {
        error.statusCode == 401 || error.statusCode == 403
    }

    private func scoreCandidate(track: TrackSnapshot, candidate: LrclibCandidate, hasSyncData: Bool) -> Double {
        let titleScore = IvLyricsUtilities.titleScore(track.title, candidate.trackName)
        let artistScore = IvLyricsUtilities.bestArtistScore(track.artist, candidate.artistName)
        let albumScore = IvLyricsUtilities.albumScore(track.album, candidate.albumName)
        let durationScore = IvLyricsUtilities.durationScore(expectedDurationMs: track.durationMs, candidateDurationSeconds: candidate.durationSeconds, tolerance: durationToleranceSeconds)
        let lyricsScore = candidate.useSyncedLyrics() ? 0.8 : (candidate.plainLyrics?.trimmed.isEmpty == false ? 0.25 : 0)
        candidate.albumMatchScore = max(candidate.albumMatchScore, albumScore)
        var score = titleScore * 4.0 + artistScore * 3.0 + albumScore * 1.25 + durationScore * 2.0 + lyricsScore
        if track.durationMs > 0, candidate.durationSeconds > 0 {
            let diff = abs(Double(track.durationMs) / 1000.0 - candidate.durationSeconds)
            if diff > durationToleranceSeconds {
                score -= min(2.5, (diff - durationToleranceSeconds) / 15.0)
            }
        }
        if hasSyncData, candidate.syncLineExactMatch {
            score += 2.5
        }
        return score
    }

    private func decorateCandidateForSyncData(_ candidate: LrclibCandidate, syncData: SyncDataCandidateContext?) {
        candidate.preferredLyricsSource = ""
        candidate.syncLineExactMatch = false
        candidate.exactSyncedLineMatch = false
        candidate.exactPlainLineMatch = false
        candidate.syncSourceMatchScore = 0
        candidate.syncSourceIdMatch = false
        candidate.syncSourceTextMatch = false
        candidate.syncSourceLineCountMatch = false
        candidate.hasOriginalLyricsScript = false
        guard let syncData else { return }

        let syncLineCounts = syncData.lineCharCounts
        let normalizeParentheticalLines = syncData.shouldNormalizeParentheticalLines
        let syncedLineCharCounts = candidateLineCharCounts(
            candidate.syncedLyrics,
            stripTimestamps: true,
            normalizeParentheticalLines: normalizeParentheticalLines
        )
        let plainLineCharCounts = candidateLineCharCounts(
            candidate.plainLyrics,
            stripTimestamps: false,
            normalizeParentheticalLines: normalizeParentheticalLines
        )
        candidate.exactSyncedLineMatch = hasExactLineShape(syncLineCounts, syncedLineCharCounts)
        candidate.exactPlainLineMatch = hasExactLineShape(syncLineCounts, plainLineCharCounts)
        candidate.syncLineExactMatch = candidate.exactSyncedLineMatch || candidate.exactPlainLineMatch
        candidate.preferredLyricsSource = candidate.exactSyncedLineMatch ? "synced" : (candidate.exactPlainLineMatch ? "plain" : syncData.preferredLyricsSource)
        let initialPreferredSource = candidate.preferredLyricsSource
        let initialCandidateText = candidateComparableText(candidate, preferredSource: initialPreferredSource, normalizeParentheticalLines: normalizeParentheticalLines)
        candidate.hasOriginalLyricsScript = IvLyricsUtilities.hasOriginalLyricsScript(initialCandidateText)

        guard syncData.hasLrclibSource else { return }
        let sourceId = syncData.lrclibId
        candidate.syncSourceIdMatch = sourceId > 0 && candidate.id == sourceId
        let sourceLineCounts = syncData.sourceLineCharCounts
        let sourceSyncedLineMatch = hasExactLineShape(sourceLineCounts, syncedLineCharCounts)
        let sourcePlainLineMatch = hasExactLineShape(sourceLineCounts, plainLineCharCounts)
        if candidate.preferredLyricsSource.isEmpty {
            candidate.preferredLyricsSource = sourceSyncedLineMatch ? "synced" : (sourcePlainLineMatch ? "plain" : syncData.preferredLyricsSource)
        }

        let preferredSource = IvLyricsUtilities.firstNonEmpty(candidate.preferredLyricsSource, syncData.preferredLyricsSource)
        let candidateText = preferredSource == initialPreferredSource
            ? initialCandidateText
            : candidateComparableText(candidate, preferredSource: preferredSource, normalizeParentheticalLines: normalizeParentheticalLines)
        let sourceFingerprint = syncData.sourceLyricsFingerprint
        candidate.syncSourceTextMatch = !sourceFingerprint.isEmpty && sourceFingerprint == IvLyricsUtilities.lyricsFingerprint(candidateText)
        candidate.syncSourceLineCountMatch = hasExactLineShape(sourceLineCounts, IvLyricsUtilities.lineCharCounts(IvLyricsUtilities.comparableLyricsLines(candidateText, stripTimestamps: false)))

        if candidate.syncSourceIdMatch {
            candidate.syncSourceMatchScore = 100
        } else if candidate.syncSourceTextMatch {
            candidate.syncSourceMatchScore = 90
        } else if candidate.syncSourceLineCountMatch {
            candidate.syncSourceMatchScore = 60
        }
    }

    private func candidateLineCharCounts(_ text: String?, stripTimestamps: Bool, normalizeParentheticalLines: Bool) -> [Int] {
        guard let text, !text.isEmpty else { return [] }
        return IvLyricsUtilities.lineCharCounts(IvLyricsUtilities.comparableLyricsLines(text, stripTimestamps: stripTimestamps, normalizeParentheticalLines: normalizeParentheticalLines))
    }

    private func candidateComparableText(_ candidate: LrclibCandidate, preferredSource: String, normalizeParentheticalLines: Bool) -> String {
        let useSynced = preferredSource == "synced"
            ? candidate.syncedLyrics != nil
            : (preferredSource != "plain" && candidate.plainLyrics == nil && candidate.syncedLyrics != nil)
        let text = useSynced ? IvLyricsUtilities.stripLrcTimestamps(candidate.syncedLyrics) : IvLyricsUtilities.firstNonEmpty(candidate.plainLyrics, IvLyricsUtilities.stripLrcTimestamps(candidate.syncedLyrics))
        return IvLyricsUtilities.joinLinesForFingerprint(IvLyricsUtilities.comparableLyricsLines(text, stripTimestamps: false, normalizeParentheticalLines: normalizeParentheticalLines))
    }

    private func hasExactLineShape(_ expectedCounts: [Int], _ actualCounts: [Int]) -> Bool {
        !expectedCounts.isEmpty && expectedCounts == actualCounts
    }

    private func needsLegacySyncLineShapeMatch(_ syncData: SyncDataCandidateContext?, _ candidates: [LrclibCandidate]) -> Bool {
        shouldPreferLegacyExactSyncLineShape(syncData) && !hasSyncLineExactCandidate(candidates, syncData: syncData)
    }

    private func shouldPreferLegacyExactSyncLineShape(_ syncData: SyncDataCandidateContext?) -> Bool {
        guard let syncData else { return false }
        return !syncData.lineCharCounts.isEmpty && syncData.lrclibId <= 0 && syncData.sourceLineCharCounts.isEmpty
    }

    private func hasSyncLineExactCandidate(_ candidates: [LrclibCandidate], syncData: SyncDataCandidateContext?) -> Bool {
        guard let syncData else { return false }
        for candidate in candidates {
            decorateCandidateForSyncData(candidate, syncData: syncData)
            if candidate.syncLineExactMatch { return true }
        }
        return false
    }

    private func countSyncLineExactCandidates(_ candidates: [LrclibCandidate]) -> Int {
        candidates.filter(\.syncLineExactMatch).count
    }

    private func selectLegacyExactLineShapeCandidate(track: TrackSnapshot, candidates: [LrclibCandidate], log: (String) -> Void) -> LrclibCandidate? {
        let exact = candidates.filter(\.syncLineExactMatch)
        guard !exact.isEmpty else { return nil }
        let selected = exact.sorted { left, right in compareLegacyExactLineShapeCandidates(track: track, left: left, right: right) }.first!
        log("lrclib legacy sync-data: selected exact line-shape candidate / group=\(legacyExactLineShapeGroup(selected)) / withinDuration=\(isWithinDurationTolerance(track: track, candidate: selected)) / \(describeLrclibCandidate(selected))")
        return selected
    }

    private func compareLegacyExactLineShapeCandidates(track: TrackSnapshot, left: LrclibCandidate, right: LrclibCandidate) -> Bool {
        let groupLeft = legacyExactLineShapeGroup(left)
        let groupRight = legacyExactLineShapeGroup(right)
        if groupLeft != groupRight { return groupLeft > groupRight }
        let leftWithin = isWithinDurationTolerance(track: track, candidate: left)
        let rightWithin = isWithinDurationTolerance(track: track, candidate: right)
        if leftWithin != rightWithin { return leftWithin && !rightWithin }
        let leftDiff = durationDiffSeconds(track: track, candidate: left)
        let rightDiff = durationDiffSeconds(track: track, candidate: right)
        if leftDiff != rightDiff { return leftDiff < rightDiff }
        return compareLrclibCandidates(left, right)
    }

    private func legacyExactLineShapeGroup(_ candidate: LrclibCandidate) -> Int {
        if candidate.hasOriginalLyricsScript && candidate.exactSyncedLineMatch { return 4 }
        if candidate.hasOriginalLyricsScript && candidate.exactPlainLineMatch { return 3 }
        if candidate.exactSyncedLineMatch { return 2 }
        return candidate.exactPlainLineMatch ? 1 : 0
    }

    private func selectSyncedFallbackCandidate(track: TrackSnapshot, spotifySearchTrack: TrackSnapshot?, syncData: SyncDataCandidateContext?, candidates: [LrclibCandidate], best: LrclibCandidate, log: (String) -> Void) -> LrclibCandidate {
        guard shouldPreferSyncedLrclibFallback(syncData), !best.useSyncedLyrics() else { return best }
        if hasSyncedLyricsPayload(best), isReasonableSyncedFallbackMatch(track: track, spotifySearchTrack: spotifySearchTrack, candidate: best) {
            best.preferredLyricsSource = "synced"
            log("lrclib synced fallback: using synced lyrics from top candidate / score=\(fmt(best.score)) / \(describeLrclibCandidate(best))")
            return best
        }
        let floor = best.score - syncedFallbackScoreWindow
        for candidate in candidates where candidate !== best && hasSyncedLyricsPayload(candidate) {
            if candidate.score + 0.0001 < floor { continue }
            if !isReasonableSyncedFallbackMatch(track: track, spotifySearchTrack: spotifySearchTrack, candidate: candidate) { continue }
            if !passesLrclibSelectionThreshold(candidate) { continue }
            candidate.preferredLyricsSource = "synced"
            log("lrclib synced fallback: selected synced candidate within score window / bestPlainScore=\(fmt(best.score)) / syncedScore=\(fmt(candidate.score)) / window=\(fmt(syncedFallbackScoreWindow)) / \(describeLrclibCandidate(candidate))")
            return candidate
        }
        return best
    }

    private func shouldPreferSyncedLrclibFallback(_ syncData: SyncDataCandidateContext?) -> Bool {
        syncData == nil || (syncData!.lrclibId <= 0 && syncData!.lineCharCounts.isEmpty)
    }

    private func passesLrclibSelectionThreshold(_ candidate: LrclibCandidate) -> Bool {
        candidate.score > 2.2 || candidate.syncSourceMatchScore > 0 || candidate.syncLineExactMatch
    }

    private func hasSyncedLyricsPayload(_ candidate: LrclibCandidate) -> Bool {
        candidate.syncedLyrics?.trimmed.isEmpty == false
    }

    private func isReasonableSyncedFallbackMatch(track: TrackSnapshot, spotifySearchTrack: TrackSnapshot?, candidate: LrclibCandidate) -> Bool {
        if !candidate.isrc.isEmpty {
            if candidate.isrc == track.isrc { return true }
            if let spotifySearchTrack, candidate.isrc == spotifySearchTrack.isrc { return true }
        }
        return isReasonableSyncedFallbackMatch(track: track, candidate: candidate)
            || (spotifySearchTrack.map { isReasonableSyncedFallbackMatch(track: $0, candidate: candidate) } ?? false)
    }

    private func isReasonableSyncedFallbackMatch(track: TrackSnapshot, candidate: LrclibCandidate) -> Bool {
        let title = IvLyricsUtilities.titleScore(track.title, candidate.trackName)
        let artist = IvLyricsUtilities.bestArtistScore(track.artist, candidate.artistName)
        let durationOk = track.durationMs <= 0 || candidate.durationSeconds <= 0 || isWithinDurationTolerance(track: track, candidate: candidate)
        return title >= syncedFallbackMinTitleScore && artist >= syncedFallbackMinArtistScore && durationOk
    }

    private func isWithinDurationTolerance(track: TrackSnapshot, candidate: LrclibCandidate) -> Bool {
        durationDiffSeconds(track: track, candidate: candidate) <= durationToleranceSeconds
    }

    private func durationDiffSeconds(track: TrackSnapshot, candidate: LrclibCandidate) -> Double {
        if track.durationMs <= 0 || candidate.durationSeconds <= 0 { return Double.greatestFiniteMagnitude }
        return abs(Double(track.durationMs) / 1000.0 - candidate.durationSeconds)
    }

    private func appendUniqueCandidates(_ target: inout [LrclibCandidate], _ next: [LrclibCandidate]) {
        for candidate in next where !containsCandidate(target, candidate) {
            target.append(candidate)
        }
    }

    private func containsCandidate(_ candidates: [LrclibCandidate], _ candidate: LrclibCandidate) -> Bool {
        for existing in candidates {
            if existing.id > 0 && candidate.id > 0 && existing.id == candidate.id {
                return true
            }
            if existing.id <= 0 || candidate.id <= 0 {
                let existingKey = lrclibCandidateKey(existing)
                let nextKey = lrclibCandidateKey(candidate)
                if !existingKey.isEmpty && existingKey == nextKey {
                    return true
                }
            }
        }
        return false
    }

    private func lrclibCandidateKey(_ candidate: LrclibCandidate) -> String {
        "\(candidate.trackName)\n\(candidate.artistName)\n\(candidate.albumName)".lowercased().trimmed
    }

    private func compareLrclibCandidates(_ left: LrclibCandidate, _ right: LrclibCandidate) -> Bool {
        if left.syncSourceMatchScore != right.syncSourceMatchScore { return left.syncSourceMatchScore > right.syncSourceMatchScore }
        if left.syncLineExactMatch != right.syncLineExactMatch { return left.syncLineExactMatch && !right.syncLineExactMatch }
        if left.exactSyncedLineMatch != right.exactSyncedLineMatch { return left.exactSyncedLineMatch && !right.exactSyncedLineMatch }
        return left.score > right.score
    }

    private func buildStructuredQuery(_ track: TrackSnapshot, includeAlbum: Bool = true) -> [String: String] {
        var params = ["track_name": track.title, "artist_name": track.artist]
        if includeAlbum, !track.album.isEmpty {
            params["album_name"] = track.album
        }
        return params
    }

    private func buildSpotifyFieldQuery(_ track: TrackSnapshot) -> String {
        var builder = "track:\(spotifySearchValue(track.title)) artist:\(spotifySearchValue(track.artist))"
        if !track.album.isEmpty {
            builder += " album:\(spotifySearchValue(track.album))"
        }
        return builder
    }

    private func spotifySearchValue(_ value: String) -> String {
        let normalized = value.trimmed.replacingOccurrences(of: "\"", with: "")
        return normalized.contains(" ") ? "\"\(normalized)\"" : normalized
    }

    private func isSpotifyDurationCompatible(track: TrackSnapshot, match: SpotifyTrackMatch) -> Bool {
        track.durationMs <= 0 || match.durationMs <= 0 || spotifyDurationDiffSeconds(track: track, match: match) <= durationToleranceSeconds
    }

    private func spotifyDurationNote(track: TrackSnapshot, match: SpotifyTrackMatch) -> String {
        guard track.durationMs > 0, match.durationMs > 0 else { return "duration=unchecked" }
        let diff = spotifyDurationDiffSeconds(track: track, match: match)
        return "\(diff <= durationToleranceSeconds ? "duration=ok" : "duration=skip") diff=\(fmt(diff))s"
    }

    private func spotifyDurationDiffSeconds(track: TrackSnapshot, match: SpotifyTrackMatch) -> Double {
        abs(Double(track.durationMs - match.durationMs) / 1000.0)
    }

    private func syncDataCacheKey(_ isrc: String, providerId: String) -> String {
        let normalized = TrackSnapshot.normalizeIsrc(isrc)
        let provider = providerId.trimmed.lowercased()
        return normalized.isEmpty || provider.isEmpty ? "" : "\(syncDataCacheSchema)|isrc:\(normalized)|provider:\(provider)"
    }

    private func syncDataCacheKeyPrefix(_ isrc: String) -> String {
        let normalized = TrackSnapshot.normalizeIsrc(isrc)
        return normalized.isEmpty ? "" : "\(syncDataCacheSchema)|isrc:\(normalized)|provider:"
    }

    private func syncDataHeaders() -> [String: String] {
        [
            "Origin": syncDataSpotifyOrigin,
            "Referer": syncDataSpotifyReferer,
            "X-ivLyrics-Client": "ios",
            "Cache-Control": "no-cache, no-store, must-revalidate",
            "Pragma": "no-cache"
        ]
    }

    private func get(_ url: String, headers: [String: String] = [:], timeoutInterval: TimeInterval? = nil) async throws -> String {
        guard let parsed = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: parsed, timeoutInterval: timeoutInterval ?? networkRequestTimeout)
        request.httpMethod = "GET"
        if headers["Cache-Control"]?.contains("no-cache") == true {
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ivLyrics-iOS/0.1", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, _) = try await URLSession.shared.ivLyricsData(for: request)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        return (error as? URLError)?.code == .cancelled
    }

    private func postForm(_ url: String, params: [String: String], headers: [String: String]) async throws -> String {
        guard let parsed = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: parsed, timeoutInterval: networkRequestTimeout)
        request.httpMethod = "POST"
        let body = IvLyricsUtilities.encodeParams(params).data(using: .utf8) ?? Data()
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("ivLyrics-iOS/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, _) = try await URLSession.shared.ivLyricsData(for: request)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        let data = Data(text.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        return object
    }

    private func jsonArray(_ text: String) throws -> [Any] {
        let data = Data(text.utf8)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        return array
    }

    private func parseSyncContributors(data: [String: Any], syncData: [String: Any]) -> [LyricsResult.SyncContributor] {
        var combined: [Any] = []
        for key in ["contributors", "creators", "authors"] {
            appendContributorEntries(&combined, object: data, key: key)
            appendContributorEntries(&combined, object: syncData, key: key)
        }
        if let creator = data["creator"] { combined.append(creator) }
        if let creator = syncData["creator"] { combined.append(creator) }
        return parseSyncContributors(combined)
    }

    private func redactedSyncDataResponseForPersistence(_ response: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(response.utf8)),
              let redacted = redactContributorIdentityContainers(object),
              JSONSerialization.isValidJSONObject(redacted),
              let data = try? JSONSerialization.data(withJSONObject: redacted),
              let serialized = String(data: data, encoding: .utf8),
              !serialized.isEmpty else {
            // Never persist a response we could not safely inspect.
            return nil
        }
        return serialized
    }

    private func redactContributorIdentityContainers(_ value: Any) -> Any? {
        if let array = value as? [Any] {
            return array.compactMap { redactContributorIdentityContainers($0) }
        }
        guard let object = value as? [String: Any] else {
            return value
        }

        var redacted: [String: Any] = [:]
        for (key, nestedValue) in object {
            switch key {
            case "contributors", "creators", "authors":
                if let contributors = nestedValue as? [Any] {
                    redacted[key] = contributors.map(redactedContributorForPersistence)
                } else {
                    redacted[key] = redactedContributorForPersistence(nestedValue)
                }
            case "creator":
                redacted[key] = redactedContributorForPersistence(nestedValue)
            default:
                redacted[key] = redactContributorIdentityContainers(nestedValue) ?? NSNull()
            }
        }
        return redacted
    }

    private func redactedContributorForPersistence(_ raw: Any) -> [String: Any] {
        let object = raw as? [String: Any] ?? [:]
        let isPrivate = boolValue(object["isPrivate"], fallback: false)
            || boolValue(object["private"], fallback: false)
            || (object.keys.contains("profilePublic")
                && !boolValue(object["profilePublic"], fallback: true))
        return [
            "name": "Anonymous",
            "displayName": "Anonymous",
            "userHash": NSNull(),
            "avatarUrl": NSNull(),
            "linked": false,
            "profileAvailable": false,
            "spotifyUserId": NSNull(),
            "spotifyDisplayName": NSNull(),
            "spotifyProfileUrl": NSNull(),
            "profileUrl": NSNull(),
            "identifier": NSNull(),
            "anonymous": true,
            "isPrivate": isPrivate,
            "identityRedacted": true
        ]
    }

    private func appendContributorEntries(_ target: inout [Any], object: [String: Any], key: String) {
        if let array = object[key] as? [Any] {
            target.append(contentsOf: array)
        } else if let entry = object[key] {
            target.append(entry)
        }
    }

    private func parseSyncContributors(_ array: [Any]) -> [LyricsResult.SyncContributor] {
        var result: [LyricsResult.SyncContributor] = []
        var seen = Set<String>()
        var anonymousAdded = false
        for raw in array {
            var name = ""
            var userHash = ""
            var profileAvailable = false
            var anonymous = false
            var isPrivate = false
            if let string = raw as? String {
                name = string.trimmed
            } else if let object = raw as? [String: Any] {
                isPrivate = boolValue(object["isPrivate"], fallback: false)
                    || boolValue(object["private"], fallback: false)
                    || (object.keys.contains("profilePublic")
                        && !boolValue(object["profilePublic"], fallback: true))
                anonymous = boolValue(object["anonymous"], fallback: false) || isPrivate
                name = IvLyricsUtilities.firstNonEmpty(
                    IvLyricsUtilities.firstNonEmpty(
                        IvLyricsUtilities.firstNonEmpty(stringValue(object["name"]), stringValue(object["nickname"])),
                        stringValue(object["displayName"])
                    ),
                    IvLyricsUtilities.firstNonEmpty(stringValue(object["username"]), stringValue(object["spotifyDisplayName"]))
                )
                userHash = IvLyricsUtilities.firstNonEmpty(IvLyricsUtilities.firstNonEmpty(stringValue(object["userHash"]), stringValue(object["hash"])), stringValue(object["id"]))
                profileAvailable = boolValue(object["profileAvailable"], fallback: !userHash.isEmpty)
                if object.keys.contains("linked"), !boolValue(object["linked"], fallback: false) {
                    profileAvailable = false
                }
            }
            let identityHidden = anonymous || isPrivate
            if identityHidden {
                name = "Anonymous"
                userHash = ""
                profileAvailable = false
            } else if name.trimmed.isEmpty {
                name = "Anonymous"
            }
            let key = userHash.isEmpty ? "name:\(name.lowercased())" : userHash
            let legacyAnonymous = !identityHidden && name.caseInsensitiveCompare("anonymous") == .orderedSame && userHash.isEmpty
            if legacyAnonymous {
                if anonymousAdded { continue }
                anonymousAdded = true
            } else if !identityHidden && seen.contains(key) {
                continue
            }
            if !identityHidden {
                seen.insert(key)
            }
            result.append(LyricsResult.SyncContributor(
                name: name,
                userHash: userHash,
                profileAvailable: profileAvailable,
                anonymous: anonymous,
                isPrivate: isPrivate
            ))
        }
        return result
    }

    private func describeParams(_ params: [String: String]) -> String {
        "{" + params.keys.sorted().map { "\($0)=\(params[$0] ?? "")" }.joined(separator: ", ") + "}"
    }

    private func describeSpotifyMatch(_ match: SpotifyTrackMatch) -> String {
        "id=\(match.spotifyId) / isrc=\(match.isrc) / title=\"\(match.title)\" / artist=\"\(match.artist)\" / album=\"\(match.album)\" / duration=\(match.durationMs)ms" + (match.artworkURL == nil ? "" : " / artwork=\(match.artworkWidth)x\(match.artworkHeight)")
    }

    private func describeLrclibCandidate(_ candidate: LrclibCandidate) -> String {
        "id=\(candidate.id) / title=\"\(candidate.trackName)\" / artist=\"\(candidate.artistName)\" / album=\"\(candidate.albumName)\" / duration=\(fmt(candidate.durationSeconds))s / synced=\(candidate.syncedLyrics != nil) / plain=\(candidate.plainLyrics != nil)" + (candidate.syncSourceMatchScore > 0 ? " / sourceMatch[id=\(candidate.syncSourceIdMatch),text=\(candidate.syncSourceTextMatch),shape=\(candidate.syncSourceLineCountMatch)]" : "")
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func secondsToMs(_ seconds: Double, fallbackDurationMs: Int64) -> Int64 {
        seconds > 0 ? Int64((seconds * 1000).rounded()) : max(0, fallbackDurationMs)
    }

    private func extractSpotifyToken(_ object: [String: Any]) -> String {
        let token = IvLyricsUtilities.firstNonEmpty(stringValue(object["access_token"]), stringValue(object["accessToken"]), stringValue(object["token"]), stringValue(object["spotifyAccessToken"]))
        if !token.isEmpty {
            return stripBearer(token)
        }
        if let data = object["data"] as? [String: Any] {
            let nested = extractSpotifyToken(data)
            if !nested.isEmpty { return nested }
        }
        if let session = object["session"] as? [String: Any] {
            return extractSpotifyToken(session)
        }
        return ""
    }

    private func stripBearer(_ value: String) -> String {
        value.replacingOccurrences(of: #"(?i)^Bearer\s+"#, with: "", options: .regularExpression).trimmed
    }

    private func stringValue(_ value: Any?, fallback: String = "") -> String {
        if let value = value as? String { return value.trimmed.isEmpty ? fallback : value.trimmed }
        if let value = value { return String(describing: value).trimmed }
        return fallback
    }

    private func int64Value(_ value: Any?, fallback: Int64 = 0) -> Int64 {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String, let parsed = Int64(value.trimmed) { return parsed }
        return fallback
    }

    private func boolValue(_ value: Any?, fallback: Bool = false) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return fallback
    }

    private func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

private extension ManualLrclibCandidate {
    init(candidate: LrclibCandidate) {
        self.init(
            id: candidate.id,
            trackName: candidate.trackName,
            artistName: candidate.artistName,
            albumName: candidate.albumName,
            durationSeconds: max(0, candidate.durationSeconds),
            synced: candidate.syncedLyrics != nil,
            plain: candidate.plainLyrics != nil,
            instrumental: candidate.instrumental,
            isrc: candidate.isrc,
            score: candidate.score
        )
    }
}

private final class LrclibCandidate {
    let id: Int64
    let trackName: String
    let artistName: String
    let albumName: String
    let durationSeconds: Double
    let instrumental: Bool
    let plainLyrics: String?
    let syncedLyrics: String?
    let isrc: String
    var score = 0.0
    var preferredLyricsSource = ""
    var syncLineExactMatch = false
    var exactSyncedLineMatch = false
    var exactPlainLineMatch = false
    var syncSourceMatchScore = 0
    var syncSourceIdMatch = false
    var syncSourceTextMatch = false
    var syncSourceLineCountMatch = false
    var hasOriginalLyricsScript = false
    var albumMatchScore = 0.0

    init(json: [String: Any]) {
        if let number = json["id"] as? NSNumber {
            id = number.int64Value
        } else if let value = json["id"] as? Int64 {
            id = value
        } else if let value = json["id"] as? Int {
            id = Int64(value)
        } else {
            id = Int64((json["id"] as? String)?.trimmed ?? "") ?? 0
        }
        trackName = IvLyricsUtilities.firstNonEmpty(json["trackName"] as? String, json["name"] as? String)
        artistName = (json["artistName"] as? String) ?? ""
        albumName = (json["albumName"] as? String) ?? ""
        if let number = json["duration"] as? NSNumber {
            durationSeconds = number.doubleValue
        } else {
            durationSeconds = Double((json["duration"] as? String) ?? "") ?? 0
        }
        if let value = json["instrumental"] as? Bool {
            instrumental = value
        } else if let value = json["instrumental"] as? NSNumber {
            instrumental = value.boolValue
        } else {
            instrumental = (json["instrumental"] as? String)?.caseInsensitiveCompare("true") == .orderedSame
        }
        plainLyrics = Self.emptyToNil(json["plainLyrics"] as? String)
        syncedLyrics = Self.emptyToNil(json["syncedLyrics"] as? String)
        isrc = TrackSnapshot.normalizeIsrc(IvLyricsUtilities.firstNonEmpty(json["isrc"] as? String, json["ISRC"] as? String))
    }

    var hasLyrics: Bool {
        instrumental || plainLyrics != nil || syncedLyrics != nil
    }

    func useSyncedLyrics() -> Bool {
        if preferredLyricsSource == "plain", plainLyrics != nil {
            return false
        }
        return syncedLyrics?.trimmed.isEmpty == false
    }

    private static func emptyToNil(_ value: String?) -> String? {
        guard let value, !value.trimmed.isEmpty else { return nil }
        return value
    }
}

private struct SyncDataResult {
    var syncBody: [String: Any]
    var provider: String
    var contributors: [LyricsResult.SyncContributor]

    var source: [String: Any]? {
        syncBody["source"] as? [String: Any]
    }

    var hasLrclibSource: Bool {
        guard let source else { return false }
        let provider = ((source["provider"] as? String) ?? "").trimmed.lowercased()
        return provider.isEmpty || provider == "lrclib"
    }

    var lrclibId: Int64 {
        guard let source else { return 0 }
        if let number = source["lrclibId"] as? NSNumber {
            return max(0, number.int64Value)
        }
        if let string = source["lrclibId"] as? String, let value = Int64(string.trimmed) {
            return max(0, value)
        }
        return 0
    }

    var preferredLyricsSource: String {
        guard let value = source?["preferredLyricsSource"] as? String else { return "" }
        return value == "plain" || value == "synced" ? value : ""
    }

    var sourceLyricsFingerprint: String {
        (source?["lyricsFingerprint"] as? String)?.trimmed ?? ""
    }

    var sourceLineCharCounts: [Int] {
        if let values = source?["lineCharCounts"] as? [Int] { return values }
        if let values = source?["lineCharCounts"] as? [NSNumber] { return values.map { $0.intValue } }
        return []
    }

    var lineCharCounts: [Int] {
        guard let lines = syncBody["lines"] as? [[String: Any]], !lines.isEmpty else { return [] }
        return lines.map { line in
            if let chars = line["chars"] as? [Any] { return chars.count }
            return 0
        }
    }

    var shouldNormalizeParentheticalLines: Bool {
        let version: Int
        if let value = syncBody["version"] as? NSNumber {
            version = value.intValue
        } else if let value = syncBody["version"] as? String {
            version = Int(value.trimmed) ?? 1
        } else {
            version = syncBody["version"] as? Int ?? 1
        }
        return version >= 2 || !sourceLineCharCounts.isEmpty
    }
}

private struct SyncDataCandidateContext {
    let lineCharCounts: [Int]
    let shouldNormalizeParentheticalLines: Bool
    let hasLrclibSource: Bool
    let lrclibId: Int64
    let preferredLyricsSource: String
    let sourceLyricsFingerprint: String
    let sourceLineCharCounts: [Int]

    init(_ syncData: SyncDataResult) {
        lineCharCounts = syncData.lineCharCounts
        shouldNormalizeParentheticalLines = syncData.shouldNormalizeParentheticalLines
        hasLrclibSource = syncData.hasLrclibSource
        lrclibId = syncData.lrclibId
        preferredLyricsSource = syncData.preferredLyricsSource
        sourceLyricsFingerprint = syncData.sourceLyricsFingerprint
        sourceLineCharCounts = syncData.sourceLineCharCounts
    }
}

private struct SpotifyTrackMatch: Sendable {
    var spotifyId: String
    var title: String
    var artist: String
    var album: String
    var durationMs: Int64
    var isrc: String
    var artworkURL: URL?
    var artworkWidth: Int
    var artworkHeight: Int
    var englishTitle: String
    var englishArtist: String
    var englishAlbum: String

    init?(json: [String: Any], requireIsrc: Bool) {
        let externalIds = json["external_ids"] as? [String: Any]
        let isrc = TrackSnapshot.normalizeIsrc(externalIds?["isrc"] as? String)
        if requireIsrc, isrc.isEmpty {
            return nil
        }
        let albumObject = json["album"] as? [String: Any]
        let artwork = Self.bestAlbumArtwork(albumObject)
        spotifyId = (json["id"] as? String) ?? ""
        title = (json["name"] as? String) ?? ""
        artist = Self.artistText(json["artists"] as? [[String: Any]])
        album = (albumObject?["name"] as? String) ?? ""
        if let number = json["duration_ms"] as? NSNumber {
            durationMs = number.int64Value
        } else {
            durationMs = Int64(json["duration_ms"] as? Int ?? 0)
        }
        self.isrc = isrc
        artworkURL = URL(string: artwork.url)
        artworkWidth = artwork.width
        artworkHeight = artwork.height
        englishTitle = ""
        englishArtist = ""
        englishAlbum = ""
    }

    var hasEnglishMetadata: Bool {
        (!englishTitle.isEmpty && !IvLyricsUtilities.sameSearchMetadata(title, englishTitle))
            || (!englishArtist.isEmpty && !IvLyricsUtilities.sameSearchMetadata(artist, englishArtist))
    }

    func withEnglishMetadata(_ english: SpotifyTrackMatch) -> SpotifyTrackMatch {
        guard !english.title.trimmed.isEmpty, !english.artist.trimmed.isEmpty else { return self }
        let nextTitle = IvLyricsUtilities.sameSearchMetadata(title, english.title) ? "" : english.title
        let nextArtist = IvLyricsUtilities.sameSearchMetadata(artist, english.artist) ? "" : english.artist
        let nextAlbum = IvLyricsUtilities.sameSearchMetadata(album, english.album) ? "" : english.album
        guard !nextTitle.isEmpty || !nextArtist.isEmpty else { return self }
        var copy = self
        copy.englishTitle = IvLyricsUtilities.firstNonEmpty(nextTitle, title)
        copy.englishArtist = IvLyricsUtilities.firstNonEmpty(nextArtist, artist)
        copy.englishAlbum = nextAlbum
        return copy
    }

    private static func artistText(_ artists: [[String: Any]]?) -> String {
        artists?.compactMap { ($0["name"] as? String)?.trimmed }.filter { !$0.isEmpty }.joined(separator: ", ") ?? ""
    }

    private static func bestAlbumArtwork(_ album: [String: Any]?) -> (url: String, width: Int, height: Int) {
        guard let images = album?["images"] as? [[String: Any]], !images.isEmpty else {
            return ("", 0, 0)
        }
        var best = ("", 0, 0)
        var bestArea: Int64 = -1
        for image in images {
            let url = (image["url"] as? String)?.trimmed ?? ""
            guard !url.isEmpty else { continue }
            let width = (image["width"] as? NSNumber)?.intValue ?? image["width"] as? Int ?? 0
            let height = (image["height"] as? NSNumber)?.intValue ?? image["height"] as? Int ?? 0
            let area = width > 0 && height > 0 ? Int64(width * height) : 0
            if best.0.isEmpty || area > bestArea {
                best = (url, width, height)
                bestArea = area
            }
        }
        return best
    }
}

private struct SpotifyTokenResponse {
    var accessToken: String
    var expiresInSeconds: Int64
}

private struct SpotifyCredentials {
    var clientId: String
    var clientSecret: String

    init(clientId: String, clientSecret: String) {
        self.clientId = clientId.trimmed
        self.clientSecret = clientSecret.trimmed
    }

    var configured: Bool {
        !clientId.isEmpty && !clientSecret.isEmpty
    }

    var partial: Bool {
        clientId.isEmpty != clientSecret.isEmpty
    }

    var sourceKey: String {
        guard configured else { return "spotify-client:missing" }
        let secretHash = String(UInt32(bitPattern: Self.javaStringHash(clientId + "\n" + clientSecret)), radix: 16)
        return "spotify-client:\(clientId):\(secretHash)"
    }

    var sourceLabel: String {
        "Spotify API credentials"
    }

    private static func javaStringHash(_ value: String) -> Int32 {
        value.utf16.reduce(Int32(0)) { hash, codeUnit in
            hash &* 31 &+ Int32(codeUnit)
        }
    }
}
