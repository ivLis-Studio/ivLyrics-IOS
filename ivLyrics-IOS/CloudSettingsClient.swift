import Foundation

@MainActor
final class CloudSettingsClient {
    struct Record {
        var exists: Bool
        var revision: Int64
        var updatedAt: Int64
        var settings: [String: Any]

        static let empty = Record(exists: false, revision: 0, updatedAt: 0, settings: [:])
    }

    struct CloudError: LocalizedError {
        var code: String
        var statusCode: Int
        var message: String

        var errorDescription: String? { message }
    }

    private struct Capability {
        var token: String
        var apiBaseURL: String
        var expiresAt: Int64
        var ownerUserHash: String
    }

    private static let tokenEndpoint = "https://lyrics.api.ivl.is/user/cloud-save-token"
    private let accountClient: CreatorAccountClient
    private var cachedSyncCapability: Capability?

    init(accountClient: CreatorAccountClient) {
        self.accountClient = accountClient
    }

    func load(language: String) async throws -> Record {
        let capability = try await syncCapability(language: language)
        let response = try await requestJSON(
            method: "GET",
            endpoint: capability.apiBaseURL + "/settings/ios",
            body: nil,
            bearerToken: capability.token,
            language: language
        )
        if response.statusCode == 404 {
            return .empty
        }
        return try record(from: requireSuccess(response, fallback: "Cloud settings could not be loaded"))
    }

    func save(settings: [String: Any], baseRevision: Int64, language: String) async throws -> Record {
        let capability = try await syncCapability(language: language)
        let body: [String: Any] = [
            "schemaVersion": 1,
            "baseRevision": max(0, baseRevision),
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "deviceId": accountClient.cloudSaveDeviceId(),
            "settings": settings
        ]
        let response = try await requestJSON(
            method: "PUT",
            endpoint: capability.apiBaseURL + "/settings/ios",
            body: body,
            bearerToken: capability.token,
            language: language
        )
        return try record(from: requireSuccess(response, fallback: "Cloud settings could not be saved"))
    }

    func delete(language: String) async throws {
        let capability = try await capability(scope: "delete", language: language)
        let response = try await requestJSON(
            method: "DELETE",
            endpoint: capability.apiBaseURL + "/settings/ios",
            body: nil,
            bearerToken: capability.token,
            language: language
        )
        _ = try requireSuccess(response, fallback: "Cloud settings could not be deleted")
    }

    private func syncCapability(language: String) async throws -> Capability {
        let now = Int64(Date().timeIntervalSince1970)
        let ownerUserHash = accountClient.currentSession()?.userHash ?? ""
        if let cachedSyncCapability,
           !ownerUserHash.isEmpty,
           cachedSyncCapability.ownerUserHash == ownerUserHash,
           cachedSyncCapability.expiresAt > now + 30 {
            return cachedSyncCapability
        }
        let capability = try await capability(scope: "sync", language: language)
        cachedSyncCapability = capability
        return capability
    }

    private func capability(scope: String, language: String) async throws -> Capability {
        guard let session = accountClient.currentSession() else {
            throw CloudError(code: "discord_login_required", statusCode: 401, message: "Discord login is required")
        }
        let response = try await requestJSON(
            method: "POST",
            endpoint: Self.tokenEndpoint,
            body: ["scope": scope],
            bearerToken: session.authToken,
            language: language
        )
        let data = try requireSuccess(response, fallback: "Cloud access could not be verified")
        let token = stringValue(data["token"])
        let apiBaseURL = stringValue(data["apiBaseUrl"]).replacingOccurrences(
            of: #"/+$"#,
            with: "",
            options: .regularExpression
        )
        guard !token.isEmpty, !apiBaseURL.isEmpty else {
            throw CloudError(code: "invalid_capability", statusCode: 0, message: "Cloud capability response is incomplete")
        }
        return Capability(
            token: token,
            apiBaseURL: apiBaseURL,
            expiresAt: int64Value(data["expiresAt"]),
            ownerUserHash: session.userHash
        )
    }

    private func record(from data: [String: Any]) throws -> Record {
        guard let settings = data["settings"] as? [String: Any] else {
            throw CloudError(code: "invalid_record", statusCode: 0, message: "Cloud settings are invalid")
        }
        return Record(
            exists: true,
            revision: max(0, int64Value(data["revision"])),
            updatedAt: max(0, int64Value(data["updatedAt"])),
            settings: settings
        )
    }

    private func requireSuccess(_ response: JSONResponse, fallback: String) throws -> [String: Any] {
        if (200..<300).contains(response.statusCode),
           boolValue(response.root["success"]),
           let data = response.root["data"] as? [String: Any] {
            return data
        }
        var code = stringValue(response.root["code"])
        var message = stringValue(response.root["error"])
        if let error = response.root["error"] as? [String: Any] {
            code = IvLyricsUtilities.firstNonEmpty(stringValue(error["code"]), code)
            message = IvLyricsUtilities.firstNonEmpty(stringValue(error["message"]), message)
        }
        throw CloudError(
            code: code,
            statusCode: response.statusCode,
            message: IvLyricsUtilities.firstNonEmpty(message, fallback)
        )
    }

    private func requestJSON(
        method: String,
        endpoint: String,
        body: [String: Any]?,
        bearerToken: String,
        language: String
    ) async throws -> JSONResponse {
        guard let url = URL(string: endpoint) else {
            throw CloudError(code: "invalid_endpoint", statusCode: 0, message: "Invalid cloud endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 18
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ivLyrics-iOS/1", forHTTPHeaderField: "User-Agent")
        request.setValue("https://xpui.app.spotify.com", forHTTPHeaderField: "Origin")
        request.setValue("no-cache, no-store, must-revalidate", forHTTPHeaderField: "Cache-Control")
        if !language.trimmed.isEmpty {
            request.setValue(language.trimmed, forHTTPHeaderField: "Accept-Language")
        }
        if !bearerToken.trimmed.isEmpty {
            request.setValue("Bearer \(bearerToken.trimmed)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            guard JSONSerialization.isValidJSONObject(body) else {
                throw CloudError(code: "invalid_request", statusCode: 0, message: "Cloud settings are invalid")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudError(code: "invalid_response", statusCode: 0, message: "Invalid HTTP response")
        }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return JSONResponse(statusCode: http.statusCode, root: root)
    }

    private func stringValue(_ value: Any?) -> String {
        if let value = value as? String { return value.trimmed }
        if let value = value as? NSNumber { return value.stringValue.trimmed }
        return ""
    }

    private func int64Value(_ value: Any?) -> Int64 {
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value.trimmed) ?? 0 }
        return 0
    }

    private func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return false
    }

    private struct JSONResponse {
        var statusCode: Int
        var root: [String: Any]
    }
}
