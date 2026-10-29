import Foundation
import CryptoKit

/// Lazy construction keeps local-only loads independent of network repository
/// caches and credentials. All lookup/selection remains in LyricsRepository.
actor CoreRepository {
    private let store: LocalLyricsStore
    private let storageDirectory: URL
    private let settings: CoreLocalization.Snapshot
    private var repository: LyricsRepository?

    init(store: LocalLyricsStore, storageDirectory: URL, settings: CoreLocalization.Snapshot = .init()) {
        self.store = store
        self.storageDirectory = storageDirectory
        self.settings = settings
    }

    nonisolated static func persistenceDomain(for directory: URL) -> String {
        let identity = SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "kr.ivlis.ivlyrics.spotify.repository." + identity
    }

    func load(_ track: TrackSnapshot) async throws -> LyricsResult? {
        try Task.checkCancellation()
        let repository: LyricsRepository
        if let existing = self.repository {
            repository = existing
        } else {
            let domain = Self.persistenceDomain(for: storageDirectory)
            guard let defaults = UserDefaults(suiteName: domain) else { throw CocoaError(.fileWriteUnknown) }
            var cacheRoot = storageDirectory.appendingPathComponent("ProviderCache", isDirectory: true)
            try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
            var cacheValues = URLResourceValues()
            cacheValues.isExcludedFromBackup = true
            try cacheRoot.setResourceValues(cacheValues)
            repository = LyricsRepository(
                localLyricsStore: store,
                diskCache: LyricsDiskCache(namespace: "base_lyrics", maxEntries: 350, rootDirectory: cacheRoot),
                syncDataResponseCache: RawResponseDiskCache(namespace: "sync_data_api", maxEntries: 700,
                                                            formatVersion: 2, rootDirectory: cacheRoot),
                defaults: defaults,
                secureStore: SecureStringStore(service: domain)
            )
            self.repository = repository
        }
        let loaded = try await repository.loadLyrics(track: track, settings: settings)
        try Task.checkCancellation()
        return loaded.result.lines.isEmpty ? nil : loaded.result
    }
}
