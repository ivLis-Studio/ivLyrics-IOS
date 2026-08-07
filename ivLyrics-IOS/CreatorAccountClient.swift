import Foundation
import Security

@MainActor
final class CreatorAccountClient {
    struct Session: Codable, Equatable, Sendable {
        var authToken: String
        var userHash: String
        var expiresAt: Int64
    }

    struct Privacy: Equatable, Sendable {
        var isPrivate: Bool
        var profilePublic: Bool
    }

    private static let apiBaseURL = "https://lyrics.api.ivl.is"
    private static let discordStartEndpoint = apiBaseURL + "/user/discord/start"
    private static let discordSessionEndpoint = apiBaseURL + "/user/discord/session"
    private static let privacyEndpoint = apiBaseURL + "/user/creator-profile/privacy"
    private static let logoutEndpoint = apiBaseURL + "/user/logout"
    private static let keychainService = "kr.ivlis.ivlyrics.creator-account"
    private static let keychainAccount = "discord-session"
    private static let deviceUserHashKey = "creator_device_user_hash"
    private static let cloudSaveDeviceIdKey = "cloud_save_device_id"

    private let defaults: UserDefaults
    private var pendingLoginNonce: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func currentSession() -> Session? {
        guard let data = keychainData(),
              let session = try? JSONDecoder().decode(Session.self, from: data),
              !session.authToken.trimmed.isEmpty,
              !session.userHash.trimmed.isEmpty else {
            return nil
        }
        let now = Int64(Date().timeIntervalSince1970)
        if session.expiresAt > 0, session.expiresAt <= now + 30 {
            clearSession()
            return nil
        }
        return session
    }

    func cloudSaveDeviceId() -> String {
        let current = (defaults.string(forKey: Self.cloudSaveDeviceIdKey) ?? "").trimmed
        if current.range(of: #"^ios-[A-Za-z0-9-]{16,80}$"#, options: .regularExpression) != nil {
            return current
        }
        let generated = "ios-\(UUID().uuidString.lowercased())"
        defaults.set(generated, forKey: Self.cloudSaveDeviceIdKey)
        return generated
    }

    func startDiscordLogin(language: String) async throws -> URL {
        cancelPendingLogin()
        let clientNonce = try generateClientNonce()
        pendingLoginNonce = clientNonce
        do {
            let body: [String: Any] = [
                "currentUserHash": deviceUserHash(),
                "clientNonce": clientNonce
            ]
            let root = try await requestJSON(
                method: "POST",
                endpoint: Self.discordStartEndpoint,
                body: body,
                bearerToken: "",
                language: language
            )
            guard boolValue(root["success"], fallback: false),
                  let authorizeURL = URL(string: stringValue(root["authorizeUrl"])),
                  authorizeURL.scheme?.lowercased() == "https" else {
                throw HTTPStatusError(statusCode: 0, message: errorMessage(root, fallback: "Discord login could not be started"))
            }
            guard pendingLoginMatches(clientNonce) else {
                throw CancellationError()
            }
            return authorizeURL
        } catch {
            cancelPendingLogin(matching: clientNonce)
            throw error
        }
    }

    func finishDiscordLogin(loginToken: String, language: String) async throws -> Session {
        guard let expectedNonce = pendingLoginNonce, !expectedNonce.isEmpty else {
            throw HTTPStatusError(statusCode: 0, message: "Discord login was not started on this device")
        }
        // Consume the nonce before exchanging the one-time token. A duplicate
        // callback cannot reuse it, and a later login attempt cannot be cleared
        // by this request finishing out of order.
        pendingLoginNonce = nil
        let safeLoginToken = loginToken.trimmed
        guard !safeLoginToken.isEmpty else {
            throw HTTPStatusError(statusCode: 0, message: "Discord login token is missing")
        }
        var components = URLComponents(string: Self.discordSessionEndpoint)!
        components.queryItems = [URLQueryItem(name: "loginToken", value: safeLoginToken)]
        guard let endpoint = components.url?.absoluteString else {
            throw HTTPStatusError(statusCode: 0, message: "Discord login callback is invalid")
        }
        let root = try await requestJSON(
            method: "GET",
            endpoint: endpoint,
            body: nil,
            bearerToken: "",
            language: language
        )
        guard boolValue(root["success"], fallback: false),
              let data = root["data"] as? [String: Any] else {
            throw HTTPStatusError(statusCode: 0, message: errorMessage(root, fallback: "Discord login session could not be loaded"))
        }
        let returnedNonce = stringValue(data["clientNonce"])
        guard constantTimeEquals(expectedNonce, returnedNonce) else {
            throw HTTPStatusError(statusCode: 0, message: "Discord login session did not match this device")
        }
        let session = Session(
            authToken: stringValue(data["authToken"]),
            userHash: IvLyricsUtilities.firstNonEmpty(stringValue(data["userHash"]), stringValue(data["discordId"])),
            expiresAt: int64Value(data["authExpiresAt"])
        )
        guard !session.authToken.isEmpty, !session.userHash.isEmpty else {
            throw HTTPStatusError(statusCode: 0, message: "Discord login response did not include an authenticated session")
        }
        try saveSession(session)
        return session
    }

    func cancelPendingLogin() {
        pendingLoginNonce = nil
    }

    private func cancelPendingLogin(matching nonce: String) {
        guard pendingLoginMatches(nonce) else { return }
        pendingLoginNonce = nil
    }

    private func pendingLoginMatches(_ nonce: String) -> Bool {
        guard let pendingLoginNonce else { return false }
        return constantTimeEquals(pendingLoginNonce, nonce)
    }

    private func generateClientNonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw HTTPStatusError(statusCode: Int(status), message: "Could not securely start Discord login")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func getPrivacy(language: String) async throws -> Privacy {
        try await privacy(
            method: "GET",
            body: nil,
            language: language
        )
    }

    func setPrivacy(_ isPrivate: Bool, language: String) async throws -> Privacy {
        try await privacy(
            method: "PUT",
            body: ["isPrivate": isPrivate],
            language: language
        )
    }

    func logout(language: String) async throws {
        guard let session = currentSession() else {
            clearSession()
            return
        }
        do {
            _ = try await requestJSON(
                method: "POST",
                endpoint: Self.logoutEndpoint,
                body: nil,
                bearerToken: session.authToken,
                language: language
            )
            clearSession()
        } catch let error as HTTPStatusError where error.statusCode == 401 || error.statusCode == 403 {
            // The server no longer accepts this token, so the local session is
            // already effectively signed out and can be discarded safely.
            clearSession()
        }
    }

    func clearSession() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func privacy(method: String, body: [String: Any]?, language: String) async throws -> Privacy {
        guard let session = currentSession() else {
            throw HTTPStatusError(statusCode: 401, message: "Discord login is required")
        }
        do {
            let root = try await requestJSON(
                method: method,
                endpoint: Self.privacyEndpoint,
                body: body,
                bearerToken: session.authToken,
                language: language
            )
            guard boolValue(root["success"], fallback: false),
                  let data = root["data"] as? [String: Any] else {
                throw HTTPStatusError(statusCode: 0, message: errorMessage(root, fallback: "Creator profile privacy could not be loaded"))
            }
            let isPrivate = boolValue(data["isPrivate"], fallback: !boolValue(data["profilePublic"], fallback: true))
            return Privacy(
                isPrivate: isPrivate,
                profilePublic: boolValue(data["profilePublic"], fallback: !isPrivate)
            )
        } catch let error as HTTPStatusError where error.statusCode == 401 || error.statusCode == 403 {
            clearSession()
            throw error
        }
    }

    private func requestJSON(
        method: String,
        endpoint: String,
        body: [String: Any]?,
        bearerToken: String,
        language: String
    ) async throws -> [String: Any] {
        guard let url = URL(string: endpoint) else {
            throw HTTPStatusError(statusCode: 0, message: "Invalid creator account endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 18
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ivLyrics-iOS/1", forHTTPHeaderField: "User-Agent")
        request.setValue("https://xpui.app.spotify.com", forHTTPHeaderField: "Origin")
        request.setValue("https://xpui.app.spotify.com/", forHTTPHeaderField: "Referer")
        request.setValue("no-cache, no-store, must-revalidate", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        if !language.trimmed.isEmpty {
            request.setValue(language.trimmed, forHTTPHeaderField: "Accept-Language")
        }
        if !bearerToken.trimmed.isEmpty {
            request.setValue("Bearer \(bearerToken.trimmed)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPStatusError(statusCode: 0, message: "Invalid HTTP response")
        }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPStatusError(
                statusCode: http.statusCode,
                message: errorMessage(root, fallback: "HTTP \(http.statusCode)")
            )
        }
        return root
    }

    private func deviceUserHash() -> String {
        let current = (defaults.string(forKey: Self.deviceUserHashKey) ?? "").trimmed
        if current.range(of: #"^[A-Za-z0-9-]{8,64}$"#, options: .regularExpression) != nil {
            return current
        }
        let generated = "ios-\(UUID().uuidString.lowercased())"
        defaults.set(generated, forKey: Self.deviceUserHashKey)
        return generated
    }

    private func keychainData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    private func saveSession(_ session: Session) throws {
        let data = try JSONEncoder().encode(session)
        clearSession()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw HTTPStatusError(statusCode: Int(status), message: "Could not securely save the creator account session")
        }
    }

    private func stringValue(_ value: Any?) -> String {
        if let value = value as? String { return value.trimmed }
        if let value = value as? NSNumber { return value.stringValue.trimmed }
        return ""
    }

    private func boolValue(_ value: Any?, fallback: Bool) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.trimmed.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: break
            }
        }
        return fallback
    }

    private func int64Value(_ value: Any?) -> Int64 {
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value.trimmed) ?? 0 }
        return 0
    }

    private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = left.count ^ right.count
        let count = max(left.count, right.count)
        for index in 0..<count {
            let leftByte = index < left.count ? left[index] : 0
            let rightByte = index < right.count ? right[index] : 0
            difference |= Int(leftByte ^ rightByte)
        }
        return difference == 0
    }

    private func errorMessage(_ root: [String: Any], fallback: String) -> String {
        IvLyricsUtilities.firstNonEmpty(stringValue(root["message"]), IvLyricsUtilities.firstNonEmpty(stringValue(root["error"]), fallback))
    }
}
