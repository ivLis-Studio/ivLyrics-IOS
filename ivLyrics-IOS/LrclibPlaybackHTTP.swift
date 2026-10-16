import Foundation

enum LrclibLookupError: Error {
    case stageExhausted
}

/// One instance is shared by every query in a host's stage, including English fallback.
final class LrclibLookupStage {
    let base: String
    let isOfficial: Bool
    private let deadline: TimeInterval

    init(base: String, startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.base = base
        isOfficial = base == LrclibEndpoint.officialBase
        deadline = startedAt + 20
    }

    func timeout(default requested: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> TimeInterval {
        try Task.checkCancellation()
        if isOfficial { return requested }
        let remaining = deadline - now
        guard remaining > 0 else { throw LrclibLookupError.stageExhausted }
        return min(5, remaining)
    }

    func continueAfter(_ error: Error) throws {
        try Task.checkCancellation()
        if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
        if error is LrclibLookupError { throw error }
        guard !isOfficial else { return }
        if let status = error as? HTTPStatusError,
           status.statusCode == 401 || status.statusCode == 403 || status.statusCode == 429 || status.statusCode >= 500 {
            throw LrclibLookupError.stageExhausted
        }
        if let network = error as? URLError, network.code != .cannotParseResponse,
           network.code != .dataLengthExceedsMaximum {
            throw LrclibLookupError.stageExhausted
        }
    }
}

/// Isolated, bounded GETs: no shared cookies, URL cache, credentials, or redirects.
/// Rejecting redirects also prevents a mirror from contacting the official host early.
final class LrclibHTTPClient {
    static let maximumResponseBytes = 2 * 1024 * 1024
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    func get(base: String, path: String, params: [String: String] = [:], timeout: TimeInterval) async throws -> String {
        guard path == "get" || path == "search" || (path.hasPrefix("get/") && Int64(path.dropFirst(4)).map { $0 > 0 } == true),
              var url = URLComponents(string: base + "/" + path),
              url.user == nil, url.password == nil, url.fragment == nil, url.query == nil,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw URLError(.badURL) }
        if !params.isEmpty {
            url.queryItems = params.keys.sorted().map { URLQueryItem(name: $0, value: params[$0]) }
        }
        guard let target = url.url else { throw URLError(.badURL) }
        let config = configuration.copy() as! URLSessionConfiguration
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.httpAdditionalHeaders = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let receiver = LrclibReadOnlyDelegate()
        let session = URLSession(configuration: config, delegate: receiver, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ivLyrics-iOS/0.1", forHTTPHeaderField: "User-Agent")
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                receiver.start(session: session, request: request, continuation: continuation)
            }
        } onCancel: {
            receiver.cancel()
        }
    }
}

private final class LrclibReadOnlyDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var continuation: CheckedContinuation<String, Error>?
    private var task: URLSessionDataTask?
    private var cancelled = false

    func start(session: URLSession, request: URLRequest, continuation: CheckedContinuation<String, Error>) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let task = session.dataTask(with: request)
        self.task = task
        lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
        complete(.failure(CancellationError()))
    }

    private func complete(_ result: Result<String, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            complete(.failure(URLError(.badServerResponse)))
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            completionHandler(.cancel)
            complete(.failure(HTTPStatusError(statusCode: http.statusCode, message: "HTTP \(http.statusCode)")))
            return
        }
        guard response.expectedContentLength <= Int64(LrclibHTTPClient.maximumResponseBytes) else {
            completionHandler(.cancel)
            complete(.failure(URLError(.dataLengthExceedsMaximum)))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        let overflow = chunk.count > LrclibHTTPClient.maximumResponseBytes - data.count
        if !overflow { data.append(chunk) }
        lock.unlock()
        if overflow {
            complete(.failure(URLError(.dataLengthExceedsMaximum)))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { complete(.failure(error)); return }
        lock.lock()
        let body = String(data: data, encoding: .utf8)
        lock.unlock()
        if let body { complete(.success(body)) }
        else { complete(.failure(URLError(.cannotParseResponse))) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
