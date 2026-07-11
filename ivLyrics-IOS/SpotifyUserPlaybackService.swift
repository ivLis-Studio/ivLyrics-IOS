import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security

#if os(iOS)
import UIKit
#endif

@MainActor
final class SpotifyUserPlaybackService: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    private let authorizeEndpoint = "https://accounts.spotify.com/authorize"
    private let tokenEndpoint = "https://accounts.spotify.com/api/token"
    private let playbackStateEndpoint = "https://api.spotify.com/v1/me/player"
    private let currentlyPlayingEndpoint = "https://api.spotify.com/v1/me/player/currently-playing"
    private let redirectURI = SpotifyRedirectConfiguration.uri
    private let callbackScheme = SpotifyRedirectConfiguration.scheme
    private let scopes = [
        "user-read-currently-playing",
        "user-read-playback-state",
        "user-modify-playback-state"
    ]
    private let defaults = UserDefaults.standard
    private let clientIdKey = "spotify_user_client_id"
    private let redirectURIKey = "spotify_user_redirect_uri"

    @Published private(set) var connected = false
    @Published private(set) var authorizing = false
    @Published private(set) var lastError = ""
    private var authenticationPresentationAnchor: ASPresentationAnchor?
    private var authenticationSession: ASWebAuthenticationSession?
    private var authorizationTask: Task<Void, Error>?
    private var authorizationClientId = ""

    override init() {
        super.init()
        if defaults.string(forKey: redirectURIKey) != redirectURI {
            clearTokens()
            defaults.set(redirectURI, forKey: redirectURIKey)
        }
        connected = !refreshToken.isEmpty || validAccessToken() != nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        guard let anchor = authenticationPresentationAnchor ?? Self.activePresentationAnchor() else {
            preconditionFailure("Spotify OAuth requires an active presentation anchor.")
        }
        return anchor
        #else
        return ASPresentationAnchor()
        #endif
    }

    func authorize(clientId: String) async throws {
        let safeClientId = clientId.trimmed
        guard !safeClientId.isEmpty else {
            throw NSError(domain: "ivLyrics.SpotifyOAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Spotify Client ID가 필요합니다"])
        }
        if connected {
            return
        }
        if let authorizationTask {
            guard authorizationClientId == safeClientId else {
                throw NSError(domain: "ivLyrics.SpotifyOAuth", code: -8, userInfo: [NSLocalizedDescriptionKey: "다른 Spotify 계정 연결이 이미 진행 중입니다"])
            }
            try await authorizationTask.value
            return
        }

        authorizationClientId = safeClientId
        authorizing = true
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performAuthorization(clientId: safeClientId)
        }
        authorizationTask = task
        defer {
            authorizationTask = nil
            authorizationClientId = ""
            authorizing = false
        }
        try await task.value
    }

    private func performAuthorization(clientId safeClientId: String) async throws {
        prepare(clientId: safeClientId)
        let verifier = Self.randomVerifier()
        let challenge = Self.codeChallenge(verifier)
        let state = Self.randomVerifier(length: 32)
        var components = URLComponents(string: authorizeEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: safeClientId),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "show_dialog", value: "false")
        ]
        guard let url = components.url else {
            throw NSError(domain: "ivLyrics.SpotifyOAuth", code: -2, userInfo: [NSLocalizedDescriptionKey: "Spotify OAuth URL 생성 실패"])
        }
        let callback = try await runAuthenticationSession(url: url)
        let returned = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        let returnedState = returned?.queryItems?.first(where: { $0.name == "state" })?.value ?? ""
        guard returnedState == state else {
            throw NSError(domain: "ivLyrics.SpotifyOAuth", code: -3, userInfo: [NSLocalizedDescriptionKey: "Spotify OAuth state mismatch"])
        }
        if let error = returned?.queryItems?.first(where: { $0.name == "error" })?.value, !error.isEmpty {
            throw NSError(domain: "ivLyrics.SpotifyOAuth", code: -4, userInfo: [NSLocalizedDescriptionKey: "Spotify OAuth error: \(error)"])
        }
        guard let code = returned?.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw NSError(domain: "ivLyrics.SpotifyOAuth", code: -5, userInfo: [NSLocalizedDescriptionKey: "Spotify authorization code가 없습니다"])
        }
        try await exchangeAuthorizationCode(code, verifier: verifier, clientId: safeClientId)
        defaults.set(safeClientId, forKey: clientIdKey)
        lastError = ""
        connected = true
    }

    func disconnect() {
        authorizationTask?.cancel()
        authenticationSession?.cancel()
        clearTokens()
        defaults.removeObject(forKey: clientIdKey)
        connected = false
    }

    func prepare(clientId: String) {
        let safeClientId = clientId.trimmed
        guard !safeClientId.isEmpty else { return }
        let storedClientId = defaults.string(forKey: clientIdKey)?.trimmed ?? ""
        if storedClientId.isEmpty {
            defaults.set(safeClientId, forKey: clientIdKey)
            return
        }
        guard storedClientId != safeClientId else { return }
        clearTokens()
        defaults.set(safeClientId, forKey: clientIdKey)
        connected = false
    }

    private func clearTokens() {
        defaults.removeObject(forKey: "spotify_user_access_token")
        defaults.removeObject(forKey: "spotify_user_refresh_token")
        defaults.removeObject(forKey: "spotify_user_expires_at_ms")
        defaults.removeObject(forKey: "spotify_user_scope")
    }

    func currentPlayback(clientId: String) async throws -> SpotifyPlaybackSnapshot? {
        prepare(clientId: clientId)
        guard let token = try await accessToken(clientId: clientId) else { return nil }
        if let playback = try await requestPlaybackSnapshot(endpoint: playbackStateEndpoint, token: token) {
            return playback
        }
        return try await requestPlaybackSnapshot(endpoint: currentlyPlayingEndpoint, token: token)
    }

    private func requestPlaybackSnapshot(endpoint: String, token: String) async throws -> SpotifyPlaybackSnapshot? {
        var components = URLComponents(string: endpoint)!
        components.queryItems = [URLQueryItem(name: "additional_types", value: "track")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 204 { return nil }
        if http.statusCode == 401 {
            defaults.removeObject(forKey: "spotify_user_access_token")
            defaults.removeObject(forKey: "spotify_user_expires_at_ms")
            throw HTTPStatusError(statusCode: http.statusCode, message: String(data: data, encoding: .utf8) ?? "")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPStatusError(statusCode: http.statusCode, message: String(data: data, encoding: .utf8) ?? "")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = root["item"] as? [String: Any],
              (item["type"] as? String ?? "track") == "track",
              let track = parseTrack(item: item, root: root) else {
            return nil
        }
        let progress = int64Value(root["progress_ms"])
        let playing = boolValue(root["is_playing"])
        let device = (root["device"] as? [String: Any])?["name"] as? String ?? ""
        return SpotifyPlaybackSnapshot(track: track.withPlayback(positionMs: progress, playing: playing), progressMs: progress, playing: playing, fetchedAt: Date(), deviceName: device)
    }

    func setPlayback(playing: Bool, clientId: String) async throws {
        try await playerCommand(method: "PUT", path: playing ? "play" : "pause", clientId: clientId)
    }

    func seek(positionMs: Int64, clientId: String) async throws {
        try await playerCommand(method: "PUT", path: "seek", params: ["position_ms": String(max(0, positionMs))], clientId: clientId)
    }

    func skipToNext(clientId: String) async throws {
        try await playerCommand(method: "POST", path: "next", clientId: clientId)
    }

    func skipToPrevious(clientId: String) async throws {
        try await playerCommand(method: "POST", path: "previous", clientId: clientId)
    }

    private func accessToken(clientId: String) async throws -> String? {
        if let token = validAccessToken() {
            return token
        }
        guard !refreshToken.isEmpty else {
            connected = false
            return nil
        }
        try await refreshAccessToken(clientId: clientId.trimmed)
        return validAccessToken()
    }

    private func playerCommand(method: String, path: String, params: [String: String] = [:], clientId: String) async throws {
        prepare(clientId: clientId)
        guard let token = try await accessToken(clientId: clientId) else {
            throw NSError(domain: "ivLyrics.SpotifyPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Spotify OAuth 연결이 필요합니다"])
        }
        var components = URLComponents(string: "https://api.spotify.com/v1/me/player/\(path)")!
        if !params.isEmpty {
            components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPStatusError(statusCode: http.statusCode, message: String(data: data, encoding: .utf8) ?? "")
        }
    }

    private func validAccessToken() -> String? {
        let token = defaults.string(forKey: "spotify_user_access_token") ?? ""
        let expiresAt = Int64(defaults.double(forKey: "spotify_user_expires_at_ms"))
        guard !token.isEmpty, expiresAt > Int64(Date().timeIntervalSince1970 * 1000) + 30_000 else {
            return nil
        }
        return token
    }

    private var refreshToken: String {
        defaults.string(forKey: "spotify_user_refresh_token") ?? ""
    }

    private func runAuthenticationSession(url: URL) async throws -> URL {
        guard authenticationSession == nil else {
            throw NSError(domain: "ivLyrics.SpotifyOAuth", code: -9, userInfo: [NSLocalizedDescriptionKey: "Spotify OAuth 연결이 이미 진행 중입니다"])
        }
        #if os(iOS)
        guard let anchor = Self.activePresentationAnchor() else {
            throw NSError(domain: "ivLyrics.SpotifyOAuth", code: -12, userInfo: [NSLocalizedDescriptionKey: "Spotify OAuth를 표시할 활성 화면이 없습니다"])
        }
        authenticationPresentationAnchor = anchor
        #endif
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                self.authenticationSession = nil
                self.authenticationPresentationAnchor = nil
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: NSError(domain: "ivLyrics.SpotifyOAuth", code: -6, userInfo: [NSLocalizedDescriptionKey: "Spotify OAuth callback이 없습니다"]))
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.authenticationSession = session
            if !session.start() {
                self.authenticationSession = nil
                self.authenticationPresentationAnchor = nil
                continuation.resume(throwing: NSError(domain: "ivLyrics.SpotifyOAuth", code: -7, userInfo: [NSLocalizedDescriptionKey: "Spotify OAuth 세션을 시작하지 못했습니다"]))
            }
        }
    }

    #if os(iOS)
    private static func activePresentationAnchor() -> ASPresentationAnchor? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: { $0.isKeyWindow }) {
            return window
        }
        if let scene = scenes.first {
            return ASPresentationAnchor(windowScene: scene)
        }
        return nil
    }
    #endif

    private func exchangeAuthorizationCode(_ code: String, verifier: String, clientId: String) async throws {
        let params = [
            "client_id": clientId,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier
        ]
        let object = try await postTokenRequest(params)
        saveTokenResponse(object)
    }

    private func refreshAccessToken(clientId: String) async throws {
        guard !clientId.isEmpty, !refreshToken.isEmpty else { return }
        let params = [
            "client_id": clientId,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        let object = try await postTokenRequest(params)
        saveTokenResponse(object, keepExistingRefreshToken: true)
    }

    private func postTokenRequest(_ params: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: tokenEndpoint)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = IvLyricsUtilities.encodeParams(params).data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ivLyrics.SpotifyOAuth", code: -8, userInfo: [NSLocalizedDescriptionKey: "Spotify token response가 없습니다"])
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPStatusError(statusCode: http.statusCode, message: String(data: data, encoding: .utf8) ?? "")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "ivLyrics.SpotifyOAuth", code: -9, userInfo: [NSLocalizedDescriptionKey: "Spotify token JSON 파싱 실패"])
        }
        return object
    }

    private func saveTokenResponse(_ object: [String: Any], keepExistingRefreshToken: Bool = false) {
        let access = stringValue(object["access_token"])
        if !access.isEmpty {
            defaults.set(access, forKey: "spotify_user_access_token")
        }
        let refresh = stringValue(object["refresh_token"])
        if !refresh.isEmpty {
            defaults.set(refresh, forKey: "spotify_user_refresh_token")
        } else if !keepExistingRefreshToken {
            defaults.removeObject(forKey: "spotify_user_refresh_token")
        }
        let expires = max(60, int64Value(object["expires_in"], fallback: 3600))
        defaults.set(Double(Int64(Date().timeIntervalSince1970 * 1000) + expires * 1000), forKey: "spotify_user_expires_at_ms")
        defaults.set(stringValue(object["scope"]), forKey: "spotify_user_scope")
        connected = !access.isEmpty || !refresh.isEmpty
    }

    private func parseTrack(item: [String: Any], root: [String: Any]) -> TrackSnapshot? {
        let id = stringValue(item["id"])
        let title = stringValue(item["name"])
        let artists = item["artists"] as? [[String: Any]] ?? []
        let artist = artists.map { stringValue($0["name"]) }.filter { !$0.isEmpty }.joined(separator: ", ")
        let albumObject = item["album"] as? [String: Any]
        let album = stringValue(albumObject?["name"])
        let durationMs = int64Value(item["duration_ms"])
        let externalIds = item["external_ids"] as? [String: Any]
        let isrc = TrackSnapshot.normalizeIsrc(stringValue(externalIds?["isrc"]))
        let image = bestArtworkURL(albumObject?["images"] as? [[String: Any]] ?? [])
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        return TrackSnapshot(
            title: title,
            artist: artist,
            album: album,
            packageName: "spotify.web-api",
            mediaId: id,
            isrc: isrc,
            durationMs: durationMs,
            positionMs: int64Value(root["progress_ms"]),
            lastPositionUpdate: Date(),
            playbackSpeed: 1,
            playing: boolValue(root["is_playing"]),
            artworkURL: image
        )
    }

    private func bestArtworkURL(_ images: [[String: Any]]) -> URL? {
        let sorted = images.sorted { intValue($0["width"]) > intValue($1["width"]) }
        return sorted.compactMap { URL(string: stringValue($0["url"])) }.first
    }

    private static func randomVerifier(length: Int = 64) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    private static func codeChallenge(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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

    private func intValue(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String, let parsed = Int(value.trimmed) { return parsed }
        return 0
    }

    private func boolValue(_ value: Any?, fallback: Bool = false) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return value.caseInsensitiveCompare("true") == .orderedSame || value == "1" }
        return fallback
    }
}
