import Foundation

/// Input supplied by a separately verified host adapter. This type does not
/// discover Spotify objects, authorize playback, or subscribe to host events.
public struct IVLCoreTrack: Sendable {
    public let title: String
    public let artist: String
    public let album: String
    public let spotifyID: String
    public let isrc: String
    public let durationMs: Int64

    public init(title: String, artist: String, album: String = "", spotifyID: String = "",
                isrc: String = "", durationMs: Int64 = 0) {
        self.title = title
        self.artist = artist
        self.album = album
        self.spotifyID = spotifyID
        self.isrc = isrc
        self.durationMs = durationMs
    }

    fileprivate var snapshot: TrackSnapshot {
        TrackSnapshot(title: title, artist: artist, album: album, packageName: "ivlyrics.spotify.adapter",
                      mediaId: spotifyID, isrc: isrc, durationMs: durationMs)
    }

    public var trackKey: String { snapshot.stableKey }

    fileprivate func validatedSnapshot() throws -> TrackSnapshot {
        let track = snapshot
        guard !track.trackId.isEmpty || track.hasUsableMetadata else { throw IVLCoreError.invalidTrack }
        return track
    }
}

/// JSON uses the original app's Codable LyricsResult schema, retaining timing,
/// syllables, speakers and vocal parts without maintaining another lyric model.
public struct IVLCoreDocument: Sendable {
    public let trackKey: String
    public let providerID: String
    public let lineCount: Int
    public let lyricsJSON: Data

    init(track: TrackSnapshot, result: LyricsResult) throws {
        trackKey = track.stableKey
        providerID = result.providerId
        lineCount = result.lines.count
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        lyricsJSON = try encoder.encode(result)
    }
}

public enum IVLCoreError: Error {
    case invalidTrack
}

/// Reserve synchronously at the UI/host boundary before scheduling async work.
public struct IVLCoreImportIntent: Sendable {
    fileprivate let track: TrackSnapshot
    fileprivate let request: UUID
}

private final class CoreLoadState: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = UUID()
    private var trackKey: String?
    private var task: Task<IVLCoreDocument?, Error>?

    func begin(trackKey: String? = nil) -> UUID {
        lock.lock()
        let old = task
        generation = UUID()
        self.trackKey = trackKey
        let next = generation
        task = nil
        lock.unlock()
        old?.cancel()
        return next
    }

    func cancel(trackKey expected: String) {
        lock.lock()
        guard trackKey == expected else { lock.unlock(); return }
        let old = task
        generation = UUID()
        trackKey = nil
        task = nil
        lock.unlock()
        old?.cancel()
    }

    func register(_ next: Task<IVLCoreDocument?, Error>, generation expected: UUID) {
        lock.lock()
        let current = generation == expected
        if current { task = next }
        lock.unlock()
        if !current { next.cancel() }
    }

    func isCurrent(_ expected: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == expected
    }

    func finish(_ expected: UUID) {
        lock.lock(); defer { lock.unlock() }
        if generation == expected { task = nil }
    }
}

/// Foundation-only preparation for a host adapter, not a Spotify runtime hook.
/// Network access is opt-in for every load. The original LyricsRepository owns
/// matching, provider selection, retries and ivLyrics sync-data application.
public actor IVLCoreLoader {
    typealias Provider = @Sendable (TrackSnapshot) async throws -> LyricsResult?
    nonisolated private let store: LocalLyricsStore
    nonisolated private let loads = CoreLoadState()
    private let fetchLyrics: Provider

    public init(storageDirectory: URL? = nil) {
        let root = Self.storageRoot(storageDirectory)
        let store = LocalLyricsStore(root: root)
        self.store = store
        let repository = CoreRepository(store: store, storageDirectory: root)
        fetchLyrics = { try await repository.load($0) }
    }

    // Internal dependency injection keeps fixtures offline without replacing the
    // production parser or duplicating transport behavior.
    init(storageDirectory: URL, fetchLyrics: @escaping Provider) {
        store = LocalLyricsStore(root: storageDirectory)
        self.fetchLyrics = fetchLyrics
    }

    nonisolated private static func storageRoot(_ directory: URL?) -> URL {
        directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                                in: .userDomainMask)[0]
            .appendingPathComponent("ivLyricsSpotify", isDirectory: true)
            .appendingPathComponent("LocalLyrics", isDirectory: true)
    }

    public nonisolated func cancelLoading() {
        _ = loads.begin()
    }

    public func load(track input: IVLCoreTrack, allowNetwork: Bool = false) async throws -> IVLCoreDocument? {
        try Task.checkCancellation()
        let track = try input.validatedSnapshot()
        let generation = loads.begin(trackKey: track.stableKey)
        let store = store
        let fetchLyrics = fetchLyrics
        let task = Task.detached(priority: .userInitiated) { () async throws -> IVLCoreDocument? in
            try Task.checkCancellation()
            if let local = try store.load(key: track.stableKey, durationMs: track.durationMs) {
                try Task.checkCancellation()
                return try IVLCoreDocument(track: track, result: local)
            }
            guard allowNetwork else { return nil }
            guard let result = try await fetchLyrics(track) else { return nil }
            try Task.checkCancellation()
            return try IVLCoreDocument(track: track, result: result)
        }
        loads.register(task, generation: generation)
        defer { loads.finish(generation) }
        let document = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard loads.isCurrent(generation) else { throw CancellationError() }
        return document
    }

    public func importLocalFile(_ url: URL, track input: IVLCoreTrack) async throws -> IVLCoreDocument {
        try await importLocalFile(url, intent: reserveLocalImport(track: input))
    }

    public nonisolated func reserveLocalImport(track input: IVLCoreTrack) throws -> IVLCoreImportIntent {
        let track = try input.validatedSnapshot()
        loads.cancel(trackKey: track.stableKey)
        return IVLCoreImportIntent(track: track, request: store.beginImport(key: track.stableKey))
    }

    public func importLocalFile(_ url: URL, intent: IVLCoreImportIntent) async throws -> IVLCoreDocument {
        let store = store
        let track = intent.track
        let request = intent.request
        defer { _ = store.finishImport(key: track.stableKey, request: request) }
        try Task.checkCancellation()
        let saved = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try store.importFile(url, key: track.stableKey, durationMs: track.durationMs, request: request)
            }.value
        } onCancel: {
            // A cancelled read must not commit after the caller has moved on.
            _ = store.finishImport(key: track.stableKey, request: request)
        }
        try Task.checkCancellation()
        guard saved,
              let local = try store.load(key: track.stableKey, durationMs: track.durationMs),
              store.finishImport(key: track.stableKey, request: request) else {
            throw CancellationError()
        }
        return try IVLCoreDocument(track: track, result: local)
    }

    public nonisolated func removeLocalLyrics(track input: IVLCoreTrack) throws {
        let track = try input.validatedSnapshot()
        loads.cancel(trackKey: track.stableKey)
        try store.remove(key: track.stableKey)
    }

}
