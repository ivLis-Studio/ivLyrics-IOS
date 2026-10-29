import Foundation

@_cdecl("IVLyricsSpotifyBootstrap")
public func IVLyricsSpotifyBootstrap() {
    NSLog("[ivLyrics] Development preview loaded; Spotify version and runtime checks are required before activation.")
}

@_cdecl("IVLyricsSpotifyHostAvailabilityChanged")
public func IVLyricsSpotifyHostAvailabilityChanged(_ available: Bool) {
    DispatchQueue.main.async { IVLyricsSpotifyBridge.hostAdapterAvailable = available }
}

/// A JSON boundary for the guarded Spotify adapter and isolated core fixtures.
@MainActor
@objc(IVLyricsSpotifyBridge)
public final class IVLyricsSpotifyBridge: NSObject {
    private struct Input: Decodable {
        var title: String
        var artist: String
        var album: String?
        var spotifyID: String?
        var isrc: String?
        var durationMs: Int64?

        var track: IVLCoreTrack {
            IVLCoreTrack(title: title, artist: artist, album: album ?? "",
                         spotifyID: spotifyID ?? "", isrc: isrc ?? "", durationMs: durationMs ?? 0)
        }
    }

    private let loader: IVLCoreLoader
    private var work: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var activeTrackKey: String?
    private var editGenerations: [String: UInt64] = [:]

    /// Runtime guards passed and hooks installed; this is not a device-test verdict.
    @objc public fileprivate(set) static var hostAdapterAvailable = false

    @objc public override init() {
        loader = IVLCoreLoader()
        super.init()
    }

    init(loader: IVLCoreLoader) {
        self.loader = loader
        super.init()
    }

    deinit { work?.cancel() }

    /// Input is supplied by a verified host adapter, never scraped or inferred here.
    /// All completions are on the main actor. Cancellation is reported to the caller.
    @objc(loadTrackJSON:allowNetwork:completion:)
    public func loadTrackJSON(_ json: String, allowNetwork: Bool,
                              completion: @escaping (String?, NSError?) -> Void) {
        work?.cancel()
        generation &+= 1
        activeTrackKey = nil
        let request = generation
        do {
            let input = try Self.input(json)
            activeTrackKey = input.track.trackKey
            work = Task { [weak self, loader] in
                do {
                    try Task.checkCancellation()
                    guard self?.generation == request else { throw CancellationError() }
                    let document = try await loader.load(track: input.track, allowNetwork: allowNetwork)
                    try Task.checkCancellation()
                    guard let self, self.generation == request else { throw CancellationError() }
                    completion(document.map { String(decoding: $0.lyricsJSON, as: UTF8.self) }, nil)
                } catch {
                    completion(nil, error as NSError)
                }
            }
        } catch { completion(nil, error as NSError) }
    }

    @objc(importFileURL:trackJSON:completion:)
    public func importFileURL(_ url: URL, trackJSON: String,
                              completion: @escaping (String?, NSError?) -> Void) {
        do {
            let track = try Self.input(trackJSON).track
            let intent = try loader.reserveLocalImport(track: track)
            let edit = beginLocalEdit(track.trackKey)
            Task { [loader] in
                do {
                    let document = try await loader.importLocalFile(url, intent: intent)
                    guard self.editGenerations[track.trackKey] == edit else { throw CancellationError() }
                    completion(String(decoding: document.lyricsJSON, as: UTF8.self), nil)
                } catch {
                    let current = self.editGenerations[track.trackKey] == edit
                    completion(nil, (current ? error : CancellationError()) as NSError)
                }
            }
        } catch { completion(nil, error as NSError) }
    }

    @objc(removeLocalLyricsForTrackJSON:completion:)
    public func removeLocalLyricsForTrackJSON(_ json: String,
                                             completion: @escaping (NSError?) -> Void) {
        do {
            let track = try Self.input(json).track
            _ = beginLocalEdit(track.trackKey)
            try loader.removeLocalLyrics(track: track)
            completion(nil)
        } catch { completion(error as NSError) }
    }

    @objc public func cancelLoading() {
        generation &+= 1
        work?.cancel()
        work = nil
        activeTrackKey = nil
        loader.cancelLoading()
    }

    private func beginLocalEdit(_ trackKey: String) -> UInt64 {
        // Guard the final main-actor callback as well as the store's atomic
        // commit: a removal can occur after a worker returns its document.
        let edit = (editGenerations[trackKey] ?? 0) &+ 1
        editGenerations[trackKey] = edit
        if activeTrackKey == trackKey { cancelLoading() }
        return edit
    }

    private static func input(_ json: String) throws -> Input {
        guard json.utf8.count <= 64 * 1024 else { throw InputError.invalid }
        let input = try JSONDecoder().decode(Input.self, from: Data(json.utf8))
        guard !input.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !input.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (input.durationMs ?? 0) >= 0 else { throw InputError.invalid }
        return input
    }

    private enum InputError: Error { case invalid }
}
