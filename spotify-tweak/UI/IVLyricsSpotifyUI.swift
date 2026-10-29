import Foundation
import UIKit
import UniformTypeIdentifiers

/// Register on the main thread. The host adapter owns the actual playback seek.
@_cdecl("IVLyricsSpotifyUISetSeekHandler")
public func IVLyricsSpotifyUISetSeekHandler(_ handler: (@convention(c) (Int64) -> Void)?) {
    DispatchQueue.main.async { IVLyricsSpotifyUI.shared.seekHandler = handler }
}

/// Main-thread boundary for a separately verified host adapter. This class does
/// not discover Spotify classes, alter native views, or authorize playback.
@MainActor
@objc(IVLyricsSpotifyUI)
public final class IVLyricsSpotifyUI: NSObject, UIDocumentPickerDelegate {
    @objc public static let shared = IVLyricsSpotifyUI()
    @objc public var onReadyChanged: ((Bool) -> Void)? {
        didSet { onReadyChanged?(hasTrackAndLyrics) }
    }
    @objc public private(set) var hasTrackAndLyrics = false

    private struct PlaybackInput: Decodable {
        var title: String
        var artist: String
        var album: String?
        var spotifyID: String?
        var isrc: String?
        var durationMs: Int64?
        var positionMs: Int64?
        var playing: Bool?
        var speed: Double?
    }

    let loader: IVLCoreLoader
    private let surfaces = NSHashTable<IVLLyricsSurface>.weakObjects()
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private var edits: [String: UUID] = [:]
    private var pickerTracks: [ObjectIdentifier: TrackSnapshot] = [:]
    private(set) var track: TrackSnapshot?
    private(set) var result: LyricsResult?
    private(set) var status = IVLUIText.chooseTrack
    private(set) var loading = false
    var seekHandler: (@convention(c) (Int64) -> Void)?

    @objc public override init() {
        loader = IVLCoreLoader()
        super.init()
    }

    // Synthetic host fixtures use isolated storage and a controlled provider.
    init(loader: IVLCoreLoader) {
        self.loader = loader
        super.init()
    }

    deinit { work?.cancel() }

    @objc(updateStateJSON:)
    public func updateStateJSON(_ json: String) {
        do {
            guard json.utf8.count <= 64 * 1024 else { throw UIError.invalidState }
            let input = try JSONDecoder().decode(PlaybackInput.self, from: Data(json.utf8))
            let speed = input.speed ?? 1
            guard speed.isFinite, speed > 0, speed <= 8,
                  (input.durationMs ?? 0) >= 0, (input.positionMs ?? 0) >= 0 else { throw UIError.invalidState }
            let next = TrackSnapshot(title: input.title, artist: input.artist, album: input.album ?? "",
                                     packageName: "ivlyrics.spotify.adapter", mediaId: input.spotifyID ?? "",
                                     isrc: input.isrc ?? "", durationMs: input.durationMs ?? 0,
                                     positionMs: input.positionMs ?? 0, playbackSpeed: speed,
                                     playing: input.playing ?? false)
            guard next.hasUsableMetadata || !next.trackId.isEmpty else { throw UIError.invalidState }
            let changed = track?.stableKey != next.stableKey
                || track?.title != next.title || track?.artist != next.artist
                || track?.album != next.album || track?.isrc != next.isrc
                || track?.durationMs != next.durationMs
            track = next
            if changed { reload() }
            else { surfaces.allObjects.forEach { $0.updatePlayback() } }
        } catch {
            // An invalid/disconnected host state must never keep another song's
            // lyrics on top of the native Spotify UI.
            hostDisconnected()
        }
    }

    @objc(attachCardToView:)
    public func attachCardToView(_ host: UIView) { attach(to: host, compact: true) }

    @objc(attachFullscreenToView:)
    public func attachFullscreenToView(_ host: UIView) { attach(to: host, compact: false) }

    @objc(detachFromView:)
    public func detachFromView(_ host: UIView) {
        host.subviews.compactMap { $0 as? IVLLyricsSurface }
            .filter { $0.owner === self }.forEach { $0.removeFromSuperview() }
    }

    private func attach(to host: UIView, compact: Bool) {
        if host.subviews.compactMap({ $0 as? IVLLyricsSurface })
            .contains(where: { $0.owner === self && $0.compact == compact }) {
            return
        }
        // Only remove this module's own children, never the host's content.
        detachFromView(host)
        let surface = makeSurface(compact: compact, standalone: false)
        host.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            surface.topAnchor.constraint(equalTo: host.topAnchor),
            surface.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
    }

    func makeSurface(compact: Bool, standalone: Bool) -> IVLLyricsSurface {
        let surface = IVLLyricsSurface(owner: self, compact: compact, standalone: standalone)
        surfaces.add(surface)
        surface.refresh()
        return surface
    }

    @objc(presentFromViewController:)
    public func presentFromViewController(_ presenter: UIViewController) {
        guard presenter.presentedViewController == nil else { return }
        let screen = IVLLyricsScreen(owner: self)
        let navigation = UINavigationController(rootViewController: screen)
        navigation.overrideUserInterfaceStyle = .dark
        navigation.modalPresentationStyle = .pageSheet
        presenter.present(navigation, animated: true)
    }

    @objc public func hostDisconnected() {
        generation = UUID()
        work?.cancel(); work = nil
        loader.cancelLoading()
        track = nil; result = nil; loading = false
        status = IVLUIText.chooseTrack
        publish()
    }

    func reload() {
        generation = UUID()
        work?.cancel(); work = nil
        loader.cancelLoading()
        result = nil
        guard let captured = track else { loading = false; publish(); return }
        let request = generation
        let key = captured.stableKey
        loading = true; status = IVLUIText.loading
        publish()
        work = Task { [weak self, loader] in
            do {
                let document = try await loader.load(track: Self.coreTrack(captured), allowNetwork: true)
                try Task.checkCancellation()
                guard let self, self.generation == request, self.track?.stableKey == key else { return }
                self.result = try document.map { try JSONDecoder().decode(LyricsResult.self, from: $0.lyricsJSON) }
                self.loading = false
                self.status = self.result?.lines.isEmpty == false ? "" : IVLUIText.noLyrics
                self.publish()
            } catch {
                guard let self, self.generation == request, self.track?.stableKey == key else { return }
                self.loading = false; self.result = nil
                self.status = IVLUIText.loadFailed
                self.publish()
            }
        }
    }

    private func publish() {
        let ready = track != nil && result?.lines.isEmpty == false
        let changed = ready != hasTrackAndLyrics
        hasTrackAndLyrics = ready
        surfaces.allObjects.forEach { $0.refresh() }
        if changed { onReadyChanged?(ready) }
    }

    func chooseFile(from presenter: UIViewController) {
        guard let captured = track, presenter.presentedViewController == nil else { return }
        let lrc = UTType(filenameExtension: "lrc") ?? .plainText
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [lrc, .plainText], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        pickerTracks[ObjectIdentifier(picker)] = captured
        presenter.present(picker, animated: true)
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let captured = pickerTracks.removeValue(forKey: ObjectIdentifier(controller)),
              let url = urls.first else { return }
        importFile(url, for: captured)
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pickerTracks.removeValue(forKey: ObjectIdentifier(controller))
    }

    // Called synchronously at picker completion. The captured song, not the
    // latest playback state, owns the selected file throughout the async read.
    func importFile(_ url: URL, for captured: TrackSnapshot) {
        let key = captured.stableKey
        do {
            let intent = try loader.reserveLocalImport(track: Self.coreTrack(captured))
            let edit = UUID(); edits[key] = edit
            if track?.stableKey == key {
                generation = UUID(); work?.cancel(); work = nil
                loading = true; status = IVLUIText.importing
                publish()
            }
            Task { [weak self, loader] in
                do {
                    let document = try await loader.importLocalFile(url, intent: intent)
                    guard let self, self.edits[key] == edit, self.track?.stableKey == key else { return }
                    self.generation = UUID(); self.work?.cancel(); self.work = nil
                    loader.cancelLoading()
                    self.result = try JSONDecoder().decode(LyricsResult.self, from: document.lyricsJSON)
                    self.loading = false; self.status = ""
                    self.publish()
                } catch {
                    guard let self, self.edits[key] == edit, self.track?.stableKey == key else { return }
                    self.loading = false; self.status = IVLUIText.importFailed
                    self.publish()
                }
            }
        } catch {
            if track?.stableKey == key { status = IVLUIText.importFailed; publish() }
        }
    }

    func confirmRemoval(from presenter: UIViewController) {
        guard let captured = track, presenter.presentedViewController == nil else { return }
        let alert = UIAlertController(title: IVLUIText.remove, message: captured.title, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: IVLUIText.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: IVLUIText.remove, style: .destructive) { [weak self] _ in
            self?.removeLocal(for: captured)
        })
        presenter.present(alert, animated: true)
    }

    func removeLocal(for captured: TrackSnapshot) {
        let key = captured.stableKey
        edits[key] = UUID()
        do {
            try loader.removeLocalLyrics(track: Self.coreTrack(captured))
            if track?.stableKey == key { reload() }
        } catch {
            if track?.stableKey == key { status = IVLUIText.removeFailed; publish() }
        }
    }

    func seek(to milliseconds: Int64) {
        guard let track, let handler = seekHandler else { return }
        let target = track.durationMs > 0 ? min(track.durationMs, max(0, milliseconds)) : max(0, milliseconds)
        handler(target)
    }

    static func coreTrack(_ track: TrackSnapshot) -> IVLCoreTrack {
        IVLCoreTrack(title: track.title, artist: track.artist, album: track.album, spotifyID: track.mediaId,
                     isrc: track.isrc, durationMs: track.durationMs)
    }

    private enum UIError: Error { case invalidState }
}

enum IVLUIText {
    private static var korean: Bool { Locale.preferredLanguages.first?.hasPrefix("ko") == true }
    private static func text(_ english: String, _ koreanText: String) -> String { korean ? koreanText : english }
    static var chooseTrack: String { text("Play a song to view lyrics.", "노래를 재생하면 가사가 표시됩니다.") }
    static var loading: String { text("Finding lyrics…", "가사를 불러오는 중…") }
    static var noLyrics: String { text("No lyrics found. You can import an LRC or TXT file.", "가사를 찾지 못했습니다. LRC 또는 TXT 파일을 가져올 수 있습니다.") }
    static var loadFailed: String { text("Couldn't load lyrics. Retry or import a local file.", "가사를 불러오지 못했습니다. 다시 시도하거나 파일을 가져오세요.") }
    static var importing: String { text("Importing lyrics…", "가사를 가져오는 중…") }
    static var importFailed: String { text("Couldn't import this file. Choose a valid LRC or TXT file.", "파일을 가져오지 못했습니다. 올바른 LRC 또는 TXT 파일을 선택하세요.") }
    static var removeFailed: String { text("Couldn't remove local lyrics. Please retry.", "로컬 가사를 삭제하지 못했습니다. 다시 시도해 주세요.") }
    static var importFile: String { text("Import LRC / TXT", "LRC / TXT 가져오기") }
    static var remove: String { text("Remove local lyrics", "로컬 가사 삭제") }
    static var retry: String { text("Retry", "다시 시도") }
    static var cancel: String { text("Cancel", "취소") }
    static var done: String { text("Done", "완료") }
    static var fullLyrics: String { text("Full lyrics", "전체 가사") }
    static var options: String { text("Lyrics options", "가사 옵션") }
}
