import Combine
import Foundation

#if os(iOS)
import UIKit
@preconcurrency import SpotifyiOS

@MainActor
final class SpotifyAppRemotePlaybackService: NSObject, ObservableObject, SPTAppRemoteDelegate, SPTAppRemotePlayerStateDelegate {
    private let redirectURL = SpotifyRedirectConfiguration.url
    private let accessTokenKey = "spotify_app_remote_access_token"
    private let clientIdKey = "spotify_app_remote_client_id"
    private let redirectURIKey = "spotify_app_remote_redirect_uri"
    private var appRemote: SPTAppRemote?
    private var configuredClientId = ""
    private var pendingFallback: (() -> Void)?
    private var attemptedStoredToken = false

    @Published private(set) var connected = false
    @Published private(set) var connecting = false

    var onPlaybackSnapshot: ((SpotifyPlaybackSnapshot) -> Void)?
    var onLog: ((String) -> Void)?
    var onConnectionChanged: ((Bool) -> Void)?
    var lastSnapshot: SpotifyPlaybackSnapshot?

    var hasStoredAuthorization: Bool {
        !(storedAccessToken?.trimmed.isEmpty ?? true)
    }

    func start(clientId: String, fallback: @escaping () -> Void) {
        let safeClientId = clientId.trimmed
        guard !safeClientId.isEmpty else {
            fallback()
            return
        }
#if targetEnvironment(simulator)
        log("spotify app remote: unavailable in simulator; using Web API")
        fallback()
#else
        guard !connecting else {
            log("spotify app remote: connection already in progress")
            return
        }
        pendingFallback = fallback
        configureIfNeeded(clientId: safeClientId)
        if connected {
            pendingFallback = nil
            refreshPlayerState()
            return
        }
        connecting = true
        if let token = storedAccessToken, !token.isEmpty {
            attemptedStoredToken = true
            appRemote?.connectionParameters.accessToken = token
            appRemote?.connect()
            log("spotify app remote: connect with stored token")
        } else {
            authorize()
        }
#endif
    }

    func stop() {
        pendingFallback = nil
        attemptedStoredToken = false
        connecting = false
        connected = false
        onConnectionChanged?(false)
        appRemote?.playerAPI?.delegate = nil
        appRemote?.disconnect()
    }

    func suspend() {
        guard !connecting else {
            log("spotify app remote: preserving authorization while app is inactive")
            return
        }
        pendingFallback = nil
        attemptedStoredToken = false
        connecting = false
        connected = false
        onConnectionChanged?(false)
        appRemote?.playerAPI?.delegate = nil
        appRemote?.disconnect()
    }

    func disconnectAndForget() {
        stop()
        UserDefaults.standard.removeObject(forKey: accessTokenKey)
        UserDefaults.standard.removeObject(forKey: clientIdKey)
    }

    func handleOpenURL(_ url: URL) -> Bool {
        guard let appRemote else { return false }
        guard let parameters = appRemote.authorizationParameters(from: url) else { return false }
        if let accessToken = parameters[SPTAppRemoteAccessTokenKey], !accessToken.isEmpty {
            storedAccessToken = accessToken
            attemptedStoredToken = false
            appRemote.connectionParameters.accessToken = accessToken
            connecting = true
            log("spotify app remote: authorization callback received")
            appRemote.connect()
            return true
        }
        if let error = parameters[SPTAppRemoteErrorDescriptionKey], !error.isEmpty {
            log("spotify app remote auth failed: \(error)")
            connecting = false
            runFallback()
            return true
        }
        return false
    }

    func refreshPlayerState() {
        guard connected else { return }
        appRemote?.playerAPI?.getPlayerState { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.log("spotify app remote state failed: \(error.localizedDescription)")
                    return
                }
                guard let playerState = result as? SPTAppRemotePlayerState else { return }
                self.apply(playerState: playerState)
            }
        }
    }

    func setPlayback(playing: Bool) {
        guard connected else { return }
        let callback = commandCallback("playback")
        if playing {
            appRemote?.playerAPI?.resume(callback)
        } else {
            appRemote?.playerAPI?.pause(callback)
        }
    }

    func seek(positionMs: Int64) {
        guard connected else { return }
        appRemote?.playerAPI?.seek(toPosition: Int(max(0, positionMs)), callback: commandCallback("seek"))
    }

    func skipToNext() {
        guard connected else { return }
        appRemote?.playerAPI?.skip(toNext: commandCallback("next"))
    }

    func skipToPrevious() {
        guard connected else { return }
        appRemote?.playerAPI?.skip(toPrevious: commandCallback("previous"))
    }

    func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        connected = true
        onConnectionChanged?(true)
        connecting = false
        attemptedStoredToken = false
        pendingFallback = nil
        appRemote.playerAPI?.delegate = self
        appRemote.playerAPI?.subscribe { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.log("spotify app remote subscribe failed: \(error.localizedDescription)")
                    return
                }
                self.log("spotify app remote: player state subscribed")
                self.refreshPlayerState()
            }
        }
    }

    func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        connected = false
        onConnectionChanged?(false)
        log("spotify app remote connect failed" + (error.map { ": \($0.localizedDescription)" } ?? ""))
        if attemptedStoredToken {
            attemptedStoredToken = false
            storedAccessToken = nil
            appRemote.connectionParameters.accessToken = nil
            connecting = true
            log("spotify app remote: stored token rejected; authorization restarting")
            authorize()
            return
        }
        connecting = false
        runFallback()
    }

    func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        connected = false
        onConnectionChanged?(false)
        connecting = false
        appRemote.playerAPI?.delegate = nil
        log("spotify app remote disconnected" + (error.map { ": \($0.localizedDescription)" } ?? ""))
    }

    func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        apply(playerState: playerState)
    }

    private func configureIfNeeded(clientId: String) {
        if appRemote != nil, configuredClientId == clientId { return }
        if appRemote != nil {
            appRemote?.playerAPI?.delegate = nil
            appRemote?.disconnect()
        }
        let defaults = UserDefaults.standard
        let storedClientId = defaults.string(forKey: clientIdKey)?.trimmed ?? ""
        let storedRedirectURI = defaults.string(forKey: redirectURIKey) ?? ""
        if (!storedClientId.isEmpty && storedClientId != clientId)
            || storedRedirectURI != SpotifyRedirectConfiguration.uri {
            defaults.removeObject(forKey: accessTokenKey)
        }
        defaults.set(clientId, forKey: clientIdKey)
        defaults.set(SpotifyRedirectConfiguration.uri, forKey: redirectURIKey)
        configuredClientId = clientId
        let configuration = SPTConfiguration(clientID: clientId, redirectURL: redirectURL)
        configuration.playURI = ""
        let remote = SPTAppRemote(configuration: configuration, logLevel: .error)
        remote.connectionParameters.accessToken = storedAccessToken
        remote.delegate = self
        appRemote = remote
    }

    private func authorize() {
        attemptedStoredToken = false
        log("spotify app remote: authorization starting")
        appRemote?.authorizeAndPlayURI("") { [weak self] spotifyInstalled in
            let service = self
            Task { @MainActor in
                guard let service else { return }
                if !spotifyInstalled {
                    service.log("spotify app remote: Spotify app is not installed")
                    service.connecting = false
                    service.runFallback()
                }
            }
        }
    }

    private func apply(playerState: SPTAppRemotePlayerState) {
        guard let snapshot = playbackSnapshot(from: playerState) else { return }
        lastSnapshot = snapshot
        onPlaybackSnapshot?(snapshot)
    }

    private func playbackSnapshot(from playerState: SPTAppRemotePlayerState) -> SpotifyPlaybackSnapshot? {
        let track = playerState.track
        guard !track.isAdvertisement else { return nil }
        let title = track.name.trimmed
        let artist = track.artist.name.trimmed
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        let duration = Int64(track.duration)
        let position = Int64(playerState.playbackPosition)
        let playing = !playerState.isPaused
        let snapshotTrack = TrackSnapshot(
            title: title,
            artist: artist,
            album: track.album.name,
            packageName: "com.spotify.client",
            mediaId: track.uri,
            durationMs: duration,
            positionMs: position,
            playbackSpeed: Double(playerState.playbackSpeed),
            playing: playing,
            artworkURL: artworkURL(from: track.imageIdentifier)
        )
        return SpotifyPlaybackSnapshot(
            track: snapshotTrack.withPlayback(positionMs: position, playing: playing),
            progressMs: position,
            playing: playing,
            fetchedAt: Date(),
            deviceName: "Spotify App Remote"
        )
    }

    private func artworkURL(from imageIdentifier: String?) -> URL? {
        let value = imageIdentifier?.trimmed ?? ""
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("spotify:image:") {
            let imageId = String(value.dropFirst("spotify:image:".count)).trimmed
            return imageId.isEmpty ? nil : URL(string: "https://i.scdn.co/image/\(imageId)")
        }
        if value.range(of: #"^[A-Za-z0-9]+$"#, options: .regularExpression) != nil {
            return URL(string: "https://i.scdn.co/image/\(value)")
        }
        return URL(string: value)
    }

    private func commandCallback(_ action: String) -> SPTAppRemoteCallback {
        { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.log("spotify app remote \(action) failed: \(error.localizedDescription)")
                } else {
                    self.refreshPlayerState()
                }
            }
        }
    }

    private func runFallback() {
        let fallback = pendingFallback
        pendingFallback = nil
        fallback?()
    }

    private func log(_ message: String) {
        onLog?(message)
    }

    private var storedAccessToken: String? {
        get { UserDefaults.standard.string(forKey: accessTokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: accessTokenKey) }
    }
}

#else
@MainActor
final class SpotifyAppRemotePlaybackService: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    var onPlaybackSnapshot: ((SpotifyPlaybackSnapshot) -> Void)?
    var onLog: ((String) -> Void)?
    var onConnectionChanged: ((Bool) -> Void)?
    var lastSnapshot: SpotifyPlaybackSnapshot?
    var hasStoredAuthorization: Bool { false }
    func start(clientId: String, fallback: @escaping () -> Void) { fallback() }
    func stop() {}
    func suspend() {}
    func disconnectAndForget() {}
    func handleOpenURL(_ url: URL) -> Bool { false }
    func refreshPlayerState() {}
    func setPlayback(playing: Bool) {}
    func seek(positionMs: Int64) {}
    func skipToNext() {}
    func skipToPrevious() {}
}
#endif
