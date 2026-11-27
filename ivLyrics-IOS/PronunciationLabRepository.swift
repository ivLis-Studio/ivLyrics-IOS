import Foundation
import WebKit

/// Pronunciation Lab: rule- and dictionary-based line pronunciation. It is not AI and needs no
/// key; it is listed with the AI providers like the keyless Bing and Google translators, but it
/// only writes plain line pronunciation (AppSettings.Provider.pronunciationOnly).
///
/// Resources/PronunciationLabPage.html is generated in the ivLyrics PC repository by
/// .github/scripts/build_pronunciation_lab_mobile.mjs (from pronunciationLabEngine.mjs and
/// pronunciationLabMobileBridge.mjs); edit those sources, not the page. The page holds only the
/// shared ivLyrics engine. When the first request arrives, the engine imports the newest
/// pronunciation-lab release (https://github.com/ivLis-Studio/pronunciation-lab, GPL-3.0) from
/// jsDelivr, so the library is never part of the app (NOTICE.md).
///
/// One hidden web view lives for the whole session, so the library and the dictionaries it
/// downloaded stay loaded: the first Japanese request downloads about 20 MB and takes seconds,
/// later ones answer at once. Requests made before the page posts "ready" wait for it, requests
/// run side by side under their own ids, and each fails after 90 seconds. When the web content
/// process ends, the waiting requests fail and the next request builds a new web view.
@MainActor
final class PronunciationLabRepository: NSObject, WKNavigationDelegate {
    nonisolated static let providerId = "pronunciation-lab"
    nonisolated static let label = "Pronunciation Lab"
    /// The page posts to window.webkit.messageHandlers.ivLyricsPronunciationLab.
    nonisolated static let messageHandlerName = "ivLyricsPronunciationLab"
    /// The first request of a session downloads the library and a language's dictionaries.
    nonisolated static let requestTimeout: Duration = .seconds(90)
    /// The engine imports the library from jsDelivr; this origin makes those imports same-origin.
    private static let pageBaseURL = URL(string: "https://cdn.jsdelivr.net/")

    static let shared = PronunciationLabRepository()

    struct Conversion: Equatable, Sendable {
        /// One pronunciation per requested line, in order. Empty lines stay empty; lines without
        /// letters (♪) and section labels ([Chorus]) come back unchanged.
        var lines: [String]
        /// The pronunciation-lab release that wrote them, e.g. "1.0.2" ("latest" when the
        /// release lookup failed, empty when no line needed the library).
        var version: String
    }

    private struct PendingRequest {
        let lineCount: Int
        let continuation: CheckedContinuation<Conversion, Error>
        let timeout: Task<Void, Never>
    }

    private let timeout: Duration
    private let keepsHTTPCache: Bool
    private let loadPage: () -> String?
    private var webView: WKWebView?
    /// The page posted "ready": window.ivLyricsPronunciationLab exists.
    private var pageReady = false
    /// convert calls made before the page was ready, in request order.
    private var queuedCalls: [(id: String, call: String)] = []
    private var pendingRequests: [String: PendingRequest] = [:]
    private var nextRequestNumber = 0

    init(
        timeout: Duration = PronunciationLabRepository.requestTimeout,
        keepsHTTPCache: Bool = true,
        loadPage: @escaping () -> String? = PronunciationLabRepository.bundledPage
    ) {
        self.timeout = timeout
        self.keepsHTTPCache = keepsHTTPCache
        self.loadPage = loadPage
        super.init()
    }

    nonisolated static func bundledPage() -> String? {
        guard let url = Bundle.main.url(forResource: "PronunciationLabPage", withExtension: "html") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Line pronunciation of lyric lines, one result per line in the same order.
    /// - Parameters:
    ///   - sourceLang: the song language as the AI pronunciation prompts get it ("ja", "auto", ...).
    ///   - lang: the pronunciation language ("ko", "en", ...).
    ///   - notation: "translation" (the language's own script), "latin" or "ipa".
    /// - Throws: PronunciationLabError, or CancellationError when the calling task is cancelled
    ///   (the page stops the request as well).
    func convert(lines: [String], sourceLang: String, lang: String, notation: String) async throws -> Conversion {
        try Task.checkCancellation()
        guard !lines.isEmpty else { return Conversion(lines: [], version: "") }
        nextRequestNumber += 1
        let id = "ivlyrics-\(nextRequestNumber)"
        let request = Self.requestJSON(lines: lines, sourceLang: sourceLang, lang: lang, notation: notation)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(id: id, request: request, lineCount: lines.count, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    private func start(
        id: String,
        request: String,
        lineCount: Int,
        continuation: CheckedContinuation<Conversion, Error>
    ) {
        let timeout = self.timeout
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.finish(id, .failure(PronunciationLabError.timedOut), stopPageRequest: true)
        }
        pendingRequests[id] = PendingRequest(lineCount: lineCount, continuation: continuation, timeout: timer)
        guard prepareWebView() else {
            finish(id, .failure(PronunciationLabError.pageMissing), stopPageRequest: false)
            return
        }
        let call = "window.ivLyricsPronunciationLab.convert(\(Self.jsString(id)), \(Self.jsString(request)))"
        if pageReady {
            send(call, for: id)
        } else {
            queuedCalls.append((id, call))
        }
    }

    private func cancel(_ id: String) {
        finish(id, .failure(CancellationError()), stopPageRequest: true)
    }

    /// Resolves a request once; later answers for the same id are ignored.
    private func finish(_ id: String, _ result: Result<Conversion, Error>, stopPageRequest: Bool) {
        guard let request = pendingRequests.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        queuedCalls.removeAll { $0.id == id }
        if stopPageRequest, pageReady, let webView {
            webView.evaluateJavaScript("window.ivLyricsPronunciationLab.cancel(\(Self.jsString(id))); true")
        }
        request.continuation.resume(with: result)
    }

    /// Starts a convert call. Its Promise is not a value WebKit can return, so the call is wrapped
    /// to answer true, or the message of an error thrown before the request could start.
    private func send(_ call: String, for id: String) {
        guard let webView else { return }
        let script = "(function () { try { \(call); return true; } catch (error) { return String((error && error.message) || error); } })()"
        webView.evaluateJavaScript(script) { [weak self] value, error in
            if let error {
                self?.finish(id, .failure(PronunciationLabError.failed(error.localizedDescription)), stopPageRequest: false)
            } else if let message = value as? String {
                self?.finish(id, .failure(PronunciationLabError.failed(message)), stopPageRequest: false)
            }
        }
    }

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            pageReady = true
            let calls = queuedCalls
            queuedCalls.removeAll()
            for entry in calls where pendingRequests[entry.id] != nil {
                send(entry.call, for: entry.id)
            }
        case "result":
            guard let id = message["id"] as? String, let request = pendingRequests[id] else { return }
            guard let lines = message["lines"] as? [String], lines.count == request.lineCount else {
                finish(id, .failure(PronunciationLabError.failed("The page answered with a different number of lines")),
                       stopPageRequest: false)
                return
            }
            finish(id, .success(Conversion(lines: lines, version: message["version"] as? String ?? "")), stopPageRequest: false)
        case "error":
            guard let id = message["id"] as? String else { return }
            let error = PronunciationLabError(code: message["code"] as? String ?? "", message: message["message"] as? String ?? "")
            finish(id, .failure(error), stopPageRequest: false)
        default:
            // "line" messages come only with request.stream, which the app never sets.
            break
        }
    }

    /// Builds the hidden web view on first use, and again after its web content process ended.
    private func prepareWebView() -> Bool {
        if webView != nil { return true }
        guard let html = loadPage() else { return false }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(WeakScriptMessageHandler(self), name: Self.messageHandlerName)
        // The persistent store keeps jsDelivr's files in the HTTP cache between launches
        // (scripts/test-pronunciation-lab.py uses a store that leaves nothing on disk).
        configuration.websiteDataStore = keepsHTTPCache ? .default() : .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.isHidden = true
        webView = view
        pageReady = false
        view.loadHTMLString(html, baseURL: Self.pageBaseURL)
        return true
    }

    /// Fails every waiting request and drops the web view; the next request builds a new one.
    private func discardWebView(failing error: PronunciationLabError) {
        if let webView {
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
            webView.stopLoading()
        }
        webView = nil
        pageReady = false
        queuedCalls.removeAll()
        let failed = pendingRequests
        pendingRequests.removeAll()
        for request in failed.values {
            request.timeout.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        discardWebView(failing: .webContentTerminated)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageDidNotLoad(webView, error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageDidNotLoad(webView, error)
    }

    private func pageDidNotLoad(_ webView: WKWebView, _ error: Error) {
        guard webView === self.webView, !pageReady else { return }
        discardWebView(failing: .failed("The page did not load: \(error.localizedDescription)"))
    }

    private static func requestJSON(lines: [String], sourceLang: String, lang: String, notation: String) -> String {
        // No "stream" field: the page answers once with every line.
        let request: [String: Any] = ["lines": lines, "sourceLang": sourceLang, "lang": lang, "notation": notation]
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A JavaScript string literal for any text (JSON string syntax, line separators escaped).
    private static func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}

/// WKUserContentController keeps its handlers strongly, and the repository keeps the web view;
/// the handler holds the repository weakly so the two do not keep each other alive.
@MainActor
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: PronunciationLabRepository?

    init(_ target: PronunciationLabRepository) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message.body)
    }
}

/// Why a Pronunciation Lab request failed. Every case is a provider failure, so the next provider
/// in the user's order is tried. The first six cases are the page's PRONUNCIATION_LAB_* codes.
enum PronunciationLabError: Error, Equatable, Sendable {
    /// The library cannot read the song's language (e.g. Russian).
    case unsupportedSource(String)
    /// The library cannot write pronunciation in this language and notation (e.g. Chinese).
    case unsupportedTarget(String)
    /// The library or its dictionaries did not download; a later request tries again.
    case loadFailed(String)
    case aborted(String)
    case badRequest(String)
    /// PRONUNCIATION_LAB_FAILED, an unknown code, or a failed call into the page.
    case failed(String)
    /// No answer within PronunciationLabRepository.requestTimeout.
    case timedOut
    /// The web content process ended while the request waited.
    case webContentTerminated
    /// Resources/PronunciationLabPage.html is missing from the app bundle.
    case pageMissing

    init(code: String, message: String) {
        switch code {
        case "PRONUNCIATION_LAB_UNSUPPORTED_SOURCE": self = .unsupportedSource(message)
        case "PRONUNCIATION_LAB_UNSUPPORTED_TARGET": self = .unsupportedTarget(message)
        case "PRONUNCIATION_LAB_LOAD_FAILED": self = .loadFailed(message)
        case "PRONUNCIATION_LAB_ABORTED": self = .aborted(message)
        case "PRONUNCIATION_LAB_BAD_REQUEST": self = .badRequest(message)
        case "PRONUNCIATION_LAB_FAILED": self = .failed(message)
        default: self = .failed(code.isEmpty ? message : "\(code): \(message)")
        }
    }

    /// The page's code, or a name for failures outside the page; for logs.
    var code: String {
        switch self {
        case .unsupportedSource: return "PRONUNCIATION_LAB_UNSUPPORTED_SOURCE"
        case .unsupportedTarget: return "PRONUNCIATION_LAB_UNSUPPORTED_TARGET"
        case .loadFailed: return "PRONUNCIATION_LAB_LOAD_FAILED"
        case .aborted: return "PRONUNCIATION_LAB_ABORTED"
        case .badRequest: return "PRONUNCIATION_LAB_BAD_REQUEST"
        case .failed: return "PRONUNCIATION_LAB_FAILED"
        case .timedOut: return "timeout"
        case .webContentTerminated: return "web-content-terminated"
        case .pageMissing: return "page-missing"
        }
    }

    /// The message for the user in the app language. The failures a user can act on are
    /// localized; a request that ran out of time was almost always still downloading, so it gets
    /// the download message. The rest keep their English description, like the other keyless
    /// providers' errors.
    func message(uiLanguage: String) -> String {
        switch self {
        case .unsupportedSource:
            return AppI18n.t(uiLanguage, "pronunciation_lab.error.unsupported_source")
        case .unsupportedTarget:
            return AppI18n.t(uiLanguage, "pronunciation_lab.error.unsupported_target")
        case .loadFailed, .timedOut:
            return AppI18n.t(uiLanguage, "pronunciation_lab.error.load_failed")
        default:
            return errorDescription ?? code
        }
    }
}

extension PronunciationLabError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .unsupportedSource(detail), let .unsupportedTarget(detail), let .loadFailed(detail),
             let .aborted(detail), let .badRequest(detail), let .failed(detail):
            return detail.isEmpty ? "Pronunciation Lab request failed (\(code))." : detail
        case .timedOut:
            return "Pronunciation Lab did not answer within 90 seconds."
        case .webContentTerminated:
            return "The Pronunciation Lab web view stopped."
        case .pageMissing:
            return "The Pronunciation Lab page is missing from the app."
        }
    }
}
