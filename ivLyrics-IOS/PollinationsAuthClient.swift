import Foundation

final class PollinationsAuthClient: Sendable {
    static let authBaseURL = "https://enter.pollinations.ai"
    static let apiBaseURL = "https://gen.pollinations.ai"

    private static let clientId = "pk_r7hWynUBrOgSV9SJ"
    private static let authScope = "generate"
    private static let authBudget = 999
    private static let authExpiryDays = 365
    private static let defaultPollIntervalMs: Int64 = 5_000

    struct DeviceCode: Sendable {
        var deviceCode: String
        var userCode: String
        var verificationURL: URL
        var intervalMs: Int64
        var expiresAt: Date
    }

    struct TokenPollResult: Sendable {
        var pending: Bool
        var slowDown: Bool
        var accessToken: String

        static func pending(slowDown: Bool) -> TokenPollResult {
            TokenPollResult(pending: true, slowDown: slowDown, accessToken: "")
        }

        static func success(_ accessToken: String) -> TokenPollResult {
            TokenPollResult(pending: false, slowDown: false, accessToken: accessToken.trimmed)
        }
    }

    struct KeyInfo: Sendable {
        var valid: Bool
        var type: String
        var expiresInSeconds: Int64
    }

    func requestDeviceCode() async throws -> DeviceCode {
        let data = try await postJson("\(Self.authBaseURL)/api/device/code", body: ["client_id": Self.clientId], bearerToken: "")
        let deviceCode = stringValue(data["device_code"])
        let userCode = stringValue(data["user_code"])
        guard !deviceCode.isEmpty, !userCode.isEmpty else {
            throw NSError(domain: "ivLyrics.Pollinations", code: -1, userInfo: [NSLocalizedDescriptionKey: "Pollinations device authorization response is missing a code."])
        }
        let intervalMs = max(Self.defaultPollIntervalMs, int64Value(data["interval"], fallback: 0) * 1000)
        let expiresInSeconds = max(Int64(60), int64Value(data["expires_in"], fallback: 600))
        return DeviceCode(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: try buildAuthorizeURL(userCode: userCode),
            intervalMs: intervalMs,
            expiresAt: Date(timeIntervalSinceNow: TimeInterval(expiresInSeconds))
        )
    }

    func pollDeviceToken(deviceCode: String) async throws -> TokenPollResult {
        let data = try await postJsonAllowPollPending(
            "\(Self.authBaseURL)/api/device/token",
            body: ["device_code": deviceCode.trimmed]
        )
        let error = stringValue(data["error"])
        if error == "authorization_pending" || error == "slow_down" {
            return .pending(slowDown: error == "slow_down")
        }
        let accessToken = stringValue(data["access_token"])
        guard !accessToken.isEmpty else {
            throw NSError(domain: "ivLyrics.Pollinations", code: -2, userInfo: [NSLocalizedDescriptionKey: "Pollinations login completed without an access token."])
        }
        return .success(accessToken)
    }

    func fetchKeyInfo(accessToken: String) async throws -> KeyInfo {
        let data = try await getJson("\(Self.apiBaseURL)/account/key", bearerToken: accessToken)
        return KeyInfo(
            valid: boolValue(data["valid"], fallback: true),
            type: stringValue(data["type"], fallback: "API"),
            expiresInSeconds: int64Value(data["expiresIn"], fallback: 0)
        )
    }

    private func buildAuthorizeURL(userCode: String) throws -> URL {
        var components = URLComponents(string: Self.authBaseURL + "/authorize")
        components?.queryItems = [
            URLQueryItem(name: "user_code", value: userCode),
            URLQueryItem(name: "app_key", value: Self.clientId),
            URLQueryItem(name: "scope", value: Self.authScope),
            URLQueryItem(name: "budget", value: String(Self.authBudget)),
            URLQueryItem(name: "expiry", value: String(Self.authExpiryDays))
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        return url
    }

    private func postJson(_ endpoint: String, body: [String: Any], bearerToken: String) async throws -> [String: Any] {
        let data = try await requestJson(endpoint, method: "POST", body: body, bearerToken: bearerToken, acceptedStatus: 200..<300)
        return try jsonObject(data)
    }

    private func postJsonAllowPollPending(_ endpoint: String, body: [String: Any]) async throws -> [String: Any] {
        let (data, http) = try await rawRequest(endpoint, method: "POST", body: body, bearerToken: "", acceptedStatus: 200..<500)
        let object = (try? jsonObject(data)) ?? [:]
        let error = stringValue(object["error"])
        if error == "authorization_pending" || error == "slow_down" {
            return object
        }
        guard (200..<300).contains(http.statusCode), error.isEmpty else {
            throw NSError(domain: "ivLyrics.Pollinations", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: extractErrorMessage(data, code: http.statusCode)])
        }
        return object
    }

    private func getJson(_ endpoint: String, bearerToken: String) async throws -> [String: Any] {
        let data = try await requestJson(endpoint, method: "GET", body: nil, bearerToken: bearerToken, acceptedStatus: 200..<300)
        return try jsonObject(data)
    }

    private func requestJson(
        _ endpoint: String,
        method: String,
        body: [String: Any]?,
        bearerToken: String,
        acceptedStatus: Range<Int>
    ) async throws -> Data {
        try await rawRequest(endpoint, method: method, body: body, bearerToken: bearerToken, acceptedStatus: acceptedStatus).0
    }

    private func rawRequest(
        _ endpoint: String,
        method: String,
        body: [String: Any]?,
        bearerToken: String,
        acceptedStatus: Range<Int>
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: endpoint) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ivLyrics-Android", forHTTPHeaderField: "User-Agent")
        if !bearerToken.trimmed.isEmpty {
            request.setValue("Bearer \(bearerToken.trimmed)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request, delegate: nil)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPStatusError(statusCode: 0, message: "Invalid HTTP response")
        }
        guard acceptedStatus.contains(http.statusCode) else {
            throw NSError(domain: "ivLyrics.Pollinations", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: extractErrorMessage(data, code: http.statusCode)])
        }
        return (data, http)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        if data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        return object
    }

    private func extractErrorMessage(_ data: Data, code: Int) -> String {
        let raw = String(data: data, encoding: .utf8) ?? ""
        if let object = try? jsonObject(Data(raw.utf8)) {
            if let error = object["error"] as? [String: Any] {
                let message = stringValue(error["message"])
                if !message.isEmpty { return message }
            }
            let description = stringValue(object["error_description"])
            if !description.isEmpty { return description }
            let message = stringValue(object["message"])
            if !message.isEmpty { return message }
            let errorText = stringValue(object["error"])
            if !errorText.isEmpty { return errorText }
        }
        return "Pollinations HTTP \(code)"
    }

    private func stringValue(_ value: Any?, fallback: String = "") -> String {
        if let string = value as? String { return string.trimmed }
        if let number = value as? NSNumber { return number.stringValue }
        if let value { return String(describing: value).trimmed }
        return fallback
    }

    private func boolValue(_ value: Any?, fallback: Bool) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.trimmed.lowercased() {
            case "1", "true", "yes", "y": return true
            case "0", "false", "no", "n": return false
            default: break
            }
        }
        return fallback
    }

    private func int64Value(_ value: Any?, fallback: Int64) -> Int64 {
        if let int = value as? Int { return Int64(int) }
        if let int64 = value as? Int64 { return int64 }
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String, let int64 = Int64(string.trimmed) { return int64 }
        return fallback
    }
}
