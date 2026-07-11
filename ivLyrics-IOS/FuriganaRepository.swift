import Foundation
import WebKit

@MainActor
final class FuriganaRepository: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private static let rubyAnnotationRegex = try? NSRegularExpression(
        pattern: #"<ruby>([^<>]+)<rt>([^<>]*)</rt></ruby>"#,
        options: [.caseInsensitive]
    )
    private static let rubyAnnotationCache: NSCache<NSString, RubyAnnotationCacheEntry> = {
        let cache = NSCache<NSString, RubyAnnotationCacheEntry>()
        cache.countLimit = 512
        return cache
    }()

    private let cacheVersion = "furigana-js-kuromoji-v2"
    private let requestTimeoutNs: UInt64 = 45_000_000_000
    private let diskCache = LyricsDiskCache(namespace: "furigana_lyrics", maxEntries: 500)
    private var cacheGeneration = 0
    private var memoryCache: [String: LyricsResult] = [:]
    private var pendingRequests: [String: PendingRequest] = [:]
    private var queuedScripts: [String] = []
    private var webView: WKWebView?
    private var pageLoaded = false
    private var nextRequestId = 0

    struct Response: Sendable {
        var result: LyricsResult
        var logs: [String]
        var hadError: Bool
    }

    func loadFurigana(track: TrackSnapshot, baseResult: LyricsResult, bypassCache: Bool = false) async -> Response {
        guard track.hasUsableMetadata, !baseResult.lines.isEmpty else {
            return Response(result: baseResult, logs: [], hadError: false)
        }
        let requests = Self.buildRequests(baseResult.lines)
        let payload = requests.map(\.text).joined(separator: "\n")
        guard !requests.isEmpty, Self.containsKanji(payload) else {
            return Response(result: baseResult, logs: [], hadError: false)
        }

        let trackKey = track.stableKey
        let cacheKey = trackKey
            + "|source=kuromoji"
            + "|version=\(cacheVersion)"
            + "|text=\(IvLyricsUtilities.sha256(payload))"
        if !bypassCache {
            if let cached = memoryCache[cacheKey] {
                return Response(result: Self.mergeFurigana(baseResult: baseResult, furiganaResult: cached), logs: ["furigana js cache hit"], hadError: false)
            }
            let diskCached = await cachedResultFromDisk(for: cacheKey)
            if let cached = diskCached {
                memoryCache[cacheKey] = cached
                return Response(result: Self.mergeFurigana(baseResult: baseResult, furiganaResult: cached), logs: ["furigana js disk cache hit"], hadError: false)
            }
        }

        cancelPending(for: trackKey)
        nextRequestId += 1
        let requestId = "f\(nextRequestId)"
        ensureWebView()
        return await withCheckedContinuation { continuation in
            let pending = PendingRequest(
                requestId: requestId,
                trackKey: trackKey,
                cacheKey: cacheKey,
                baseResult: baseResult,
                requests: requests,
                continuation: continuation
            )
            pendingRequests[requestId] = pending
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: self?.requestTimeoutNs ?? 45_000_000_000)
                self?.handleTimeout(requestId)
            }
            evaluateWhenReady(Self.buildRequestScript(requestId: requestId, requests: requests))
        }
    }

    func clearMemoryCache() {
        memoryCache.removeAll()
    }

    func clearTrackCache(_ trackKey: String) {
        let prefix = trackKey.trimmed + "|"
        guard !prefix.isEmpty else { return }
        cacheGeneration += 1
        memoryCache = memoryCache.filter { !$0.key.hasPrefix(prefix) }
        diskCache.removeByKeyPrefix(prefix)
    }

    func clearCache() {
        cacheGeneration += 1
        memoryCache.removeAll()
        diskCache.clear()
    }

    private func cachedResultFromDisk(for cacheKey: String) async -> LyricsResult? {
        let generation = cacheGeneration
        let cached = await Task.detached { [diskCache, cacheKey] in
            diskCache.get(cacheKey)
        }.value
        guard generation == cacheGeneration else { return nil }
        return cached
    }

    private func cancelPending(for trackKey: String) {
        let ids = pendingRequests.values.filter { $0.trackKey == trackKey }.map(\.requestId)
        for id in ids {
            if let pending = pendingRequests.removeValue(forKey: id) {
                pending.resume(result: .init(result: pending.baseResult, logs: ["furigana js request canceled"], hadError: true))
            }
        }
    }

    private func ensureWebView() {
        guard webView == nil else { return }
        let contentController = WKUserContentController()
        contentController.add(self, name: "furiganaReady")
        contentController.add(self, name: "furiganaResult")
        contentController.add(self, name: "furiganaLog")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.isHidden = true
        webView = view
        pageLoaded = false
        view.loadHTMLString(
            Self.bridgeHTML,
            baseURL: URL(string: "https://cdn.jsdelivr.net/npm/kuromoji@0.1.2/")
        )
    }

    private func evaluateWhenReady(_ script: String) {
        guard let webView else { return }
        if !pageLoaded {
            queuedScripts.append(script)
            return
        }
        webView.evaluateJavaScript(script)
    }

    private func flushQueuedScripts() {
        guard let webView, !queuedScripts.isEmpty else { return }
        let scripts = queuedScripts
        queuedScripts.removeAll()
        for script in scripts {
            webView.evaluateJavaScript(script)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        flushQueuedScripts()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "furiganaReady":
            pageLoaded = true
            flushQueuedScripts()
        case "furiganaResult":
            guard let object = message.body as? [String: Any] else { return }
            handleResult(requestId: object["requestId"] as? String ?? "", payload: object["payload"] as? [String: Any] ?? [:])
        case "furiganaLog":
            let text = (message.body as? String) ?? ((message.body as? [String: Any])?["message"] as? String) ?? ""
            handleLog(text)
        default:
            break
        }
    }

    private func handleTimeout(_ requestId: String) {
        guard let pending = pendingRequests.removeValue(forKey: requestId) else { return }
        pending.resume(result: .init(result: pending.baseResult, logs: ["후리가나 JS 처리 시간이 초과되었습니다"], hadError: true))
    }

    private func handleResult(requestId: String, payload: [String: Any]) {
        guard let pending = pendingRequests.removeValue(forKey: requestId) else { return }
        guard Self.boolValue(payload["ok"]) else {
            let error = Self.stringValue(payload["error"])
            pending.resume(result: .init(result: pending.baseResult, logs: [error.isEmpty ? "Kuromoji JS request failed" : error], hadError: true))
            return
        }
        let lines = payload["lines"] as? [String] ?? []
        let annotated = Self.buildAnnotatedResult(baseResult: pending.baseResult, requests: pending.requests, annotations: lines)
        memoryCache[pending.cacheKey] = annotated
        let cacheKey = pending.cacheKey
        Task.detached { [diskCache, cacheKey, annotated] in
            diskCache.put(cacheKey, result: annotated)
        }
        pending.resume(result: .init(result: annotated, logs: ["furigana js response: lines=\(lines.count)"], hadError: false))
    }

    private func handleLog(_ message: String) {
        guard !message.trimmed.isEmpty, let first = pendingRequests.values.first else { return }
        first.appendLog(message)
    }

    private static func buildRequestScript(requestId: String, requests: [FuriganaRequest]) -> String {
        let payload = ["lines": requests.map(\.text)]
        let payloadData = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        let payloadString = String(data: payloadData, encoding: .utf8) ?? "{}"
        let encodedRequestId = jsString(requestId)
        let encodedPayload = jsString(payloadString)
        return "window.ivLyricsFurigana.request(\(encodedRequestId),\(encodedPayload));"
    }

    private static func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let raw = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(raw.dropFirst().dropLast())
    }

    private static func buildAnnotatedResult(baseResult: LyricsResult, requests: [FuriganaRequest], annotations: [String]) -> LyricsResult {
        var valuesByLine: [Int: [FuriganaValue]] = [:]
        let count = min(requests.count, annotations.count)
        for index in 0..<count {
            let request = requests[index]
            let value = sanitizeRubyText(annotations[index], original: request.text)
            guard !value.isEmpty else { continue }
            valuesByLine[request.lineIndex, default: []].append(FuriganaValue(partIndex: request.partIndex, value: value))
        }
        return mergeFurigana(baseResult: baseResult, valuesByLine: valuesByLine)
    }

    private static func mergeFurigana(baseResult: LyricsResult, furiganaResult: LyricsResult?) -> LyricsResult {
        guard let furiganaResult else {
            return mergeFurigana(baseResult: baseResult, valuesByLine: [:])
        }
        var valuesByLine: [Int: [FuriganaValue]] = [:]
        let count = min(baseResult.lines.count, furiganaResult.lines.count)
        for index in 0..<count {
            let line = furiganaResult.lines[index]
            var values: [FuriganaValue] = []
            for (partIndex, part) in line.vocalParts.enumerated() where !part.furiganaText.trimmed.isEmpty {
                values.append(FuriganaValue(partIndex: partIndex, value: part.furiganaText))
            }
            if values.isEmpty, !line.furiganaText.trimmed.isEmpty {
                values.append(FuriganaValue(partIndex: -1, value: line.furiganaText))
            }
            if !values.isEmpty {
                valuesByLine[index] = values
            }
        }
        return mergeFurigana(baseResult: baseResult, valuesByLine: valuesByLine)
    }

    private static func mergeFurigana(baseResult: LyricsResult, valuesByLine: [Int: [FuriganaValue]]) -> LyricsResult {
        let lines = baseResult.lines.enumerated().map { index, line in
            mergeLine(line, values: valuesByLine[index])
        }
        let suffix = " JS furigana applied."
        let detail = baseResult.detail.contains(suffix.trimmed) ? baseResult.detail : baseResult.detail + suffix
        return LyricsResult(
            lines: lines,
            providerLabel: baseResult.providerLabel,
            detail: detail,
            karaoke: baseResult.karaoke,
            isrc: baseResult.isrc,
            spotifyTrackId: baseResult.spotifyTrackId,
            contributors: baseResult.contributors
        )
    }

    private static func mergeLine(_ line: LyricsLine, values: [FuriganaValue]?) -> LyricsLine {
        let clearedParts = line.vocalParts.map { $0.withSupplements(pronunciation: $0.pronunciationText, translation: $0.translationText, furigana: "") }
        guard let values, !values.isEmpty else {
            return LyricsLine(
                startTimeMs: line.startTimeMs,
                endTimeMs: line.endTimeMs,
                text: line.text,
                syllables: line.syllables,
                speaker: line.speaker,
                speakerColor: line.speakerColor,
                speakerFallback: line.speakerFallback,
                kind: line.kind,
                vocalParts: clearedParts,
                pronunciationText: line.pronunciationText,
                translationText: line.translationText,
                furiganaText: ""
            )
        }
        guard !line.vocalParts.isEmpty else {
            return line.withSupplements(pronunciation: line.pronunciationText, translation: line.translationText, furigana: firstLineLevelValue(values))
        }
        var parts = clearedParts
        var changedPart = false
        for value in values where value.partIndex >= 0 && value.partIndex < parts.count {
            let part = parts[value.partIndex]
            parts[value.partIndex] = part.withSupplements(pronunciation: part.pronunciationText, translation: part.translationText, furigana: value.value)
            changedPart = true
        }
        var lineFurigana: String
        if changedPart {
            lineFurigana = parts.map(\.furiganaText).map(\.trimmed).filter { !$0.isEmpty }.joined(separator: " / ")
        } else {
            lineFurigana = firstLineLevelValue(values)
            applyLineLevelFuriganaToMatchingPart(parts: &parts, furigana: lineFurigana)
        }
        return LyricsLine(
            startTimeMs: line.startTimeMs,
            endTimeMs: line.endTimeMs,
            text: line.text,
            syllables: line.syllables,
            speaker: line.speaker,
            speakerColor: line.speakerColor,
            speakerFallback: line.speakerFallback,
            kind: line.kind,
            vocalParts: parts,
            pronunciationText: line.pronunciationText,
            translationText: line.translationText,
            furiganaText: lineFurigana
        )
    }

    private static func applyLineLevelFuriganaToMatchingPart(parts: inout [LyricsLine.VocalPart], furigana: String) {
        guard !parts.isEmpty, !furigana.trimmed.isEmpty else { return }
        let plain = stripRubyMarkup(furigana)
        var fallbackIndex = parts.count == 1 ? 0 : -1
        for (index, part) in parts.enumerated() where displayPartText(part) == plain {
            fallbackIndex = index
            break
        }
        guard fallbackIndex >= 0, fallbackIndex < parts.count else { return }
        let part = parts[fallbackIndex]
        parts[fallbackIndex] = part.withSupplements(pronunciation: part.pronunciationText, translation: part.translationText, furigana: furigana.trimmed)
    }

    private static func firstLineLevelValue(_ values: [FuriganaValue]) -> String {
        values.first { $0.partIndex < 0 && !$0.value.trimmed.isEmpty }?.value.trimmed
            ?? values.first { !$0.value.trimmed.isEmpty }?.value.trimmed
            ?? ""
    }

    private static func buildRequests(_ lines: [LyricsLine]) -> [FuriganaRequest] {
        var requests: [FuriganaRequest] = []
        for (lineIndex, line) in lines.enumerated() {
            let vocal = displayedVocalPartRequests(line, lineIndex: lineIndex)
            if vocal.count > 1 {
                requests.append(contentsOf: vocal)
            } else {
                requests.append(FuriganaRequest(lineIndex: lineIndex, partIndex: -1, text: displayLineText(line)))
            }
        }
        return requests
    }

    private static func displayedVocalPartRequests(_ line: LyricsLine, lineIndex: Int) -> [FuriganaRequest] {
        var requests: [FuriganaRequest] = []
        for (index, part) in line.vocalParts.enumerated() where part.role == "lead" {
            let text = displayPartText(part)
            if !text.isEmpty { requests.append(FuriganaRequest(lineIndex: lineIndex, partIndex: index, text: text)) }
        }
        for (index, part) in line.vocalParts.enumerated() where part.role != "lead" {
            let text = displayPartText(part)
            if !text.isEmpty { requests.append(FuriganaRequest(lineIndex: lineIndex, partIndex: index, text: text)) }
        }
        return requests
    }

    private static func displayLineText(_ line: LyricsLine) -> String {
        if !line.text.trimmed.isEmpty { return line.text.trimmed }
        return line.vocalParts.map(displayPartText).filter { !$0.isEmpty }.joined(separator: " / ")
    }

    private static func displayPartText(_ part: LyricsLine.VocalPart) -> String {
        if !part.text.trimmed.isEmpty { return part.text.trimmed }
        return part.syllables.map(\.text).joined().trimmed
    }

    private static func sanitizeRubyText(_ value: String, original: String) -> String {
        let cleaned = value.trimmed
        guard !cleaned.isEmpty, cleaned.contains("<ruby>"), stripRubyMarkup(cleaned) == original.trimmed else { return "" }
        let pattern = #"<ruby>([^<>]+)<rt>([^<>]*)</rt></ruby>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return "" }
        var cursor = cleaned.startIndex
        var output = ""
        let matches = regex.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned))
        for match in matches {
            guard let range = Range(match.range, in: cleaned),
                  let baseRange = Range(match.range(at: 1), in: cleaned),
                  let readingRange = Range(match.range(at: 2), in: cleaned) else { return "" }
            let before = String(cleaned[cursor..<range.lowerBound])
            if before.contains("<") || before.contains(">") { return "" }
            output += before
            let base = String(cleaned[baseRange])
            let reading = String(cleaned[readingRange])
            if base.trimmed.isEmpty || reading.trimmed.isEmpty { return "" }
            output += containsKanji(base) ? "<ruby>\(base)<rt>\(reading)</rt></ruby>" : base
            cursor = range.upperBound
        }
        let tail = String(cleaned[cursor...])
        if tail.contains("<") || tail.contains(">") { return "" }
        output += tail
        return output
    }

    static func stripRubyMarkup(_ value: String) -> String {
        value.replacingOccurrences(of: #"<ruby>([^<>]+)<rt>[^<>]*</rt></ruby>"#, with: "$1", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    static func rubyAnnotations(text: String, markup: String) -> [RubyAnnotation] {
        guard !markup.isEmpty, markup.contains("<ruby>") else { return [] }
        let cacheKey = markup + "\u{1f}" + text
        if let cached = rubyAnnotationCache.object(forKey: cacheKey as NSString) {
            return cached.annotations
        }

        let cleaned = markup.trimmed
        let annotations: [RubyAnnotation] = {
            let plain = stripRubyMarkup(cleaned)
            let leadingOffset: Int
            if plain == text {
                leadingOffset = 0
            } else if plain == text.trimmed {
                leadingOffset = text.prefix { $0.isWhitespace }.count
            } else {
                return []
            }

            guard let regex = rubyAnnotationRegex else { return [] }
            var annotations: [RubyAnnotation] = []
            var cursor = cleaned.startIndex
            var sourceOffset = leadingOffset
            for match in regex.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)) {
                guard let range = Range(match.range, in: cleaned),
                      let baseRange = Range(match.range(at: 1), in: cleaned),
                      let readingRange = Range(match.range(at: 2), in: cleaned) else {
                    return []
                }
                sourceOffset += cleaned[cursor..<range.lowerBound].count
                let base = String(cleaned[baseRange])
                let reading = String(cleaned[readingRange]).trimmed
                guard !base.isEmpty, !reading.isEmpty else { return [] }
                annotations.append(RubyAnnotation(start: sourceOffset, length: base.count, reading: reading))
                sourceOffset += base.count
                cursor = range.upperBound
            }
            return annotations
        }()
        rubyAnnotationCache.setObject(RubyAnnotationCacheEntry(annotations), forKey: cacheKey as NSString)
        return annotations
    }

    private final class RubyAnnotationCacheEntry: NSObject {
        let annotations: [RubyAnnotation]

        init(_ annotations: [RubyAnnotation]) {
            self.annotations = annotations
        }
    }

    struct RubyAnnotation: Equatable {
        var start: Int
        var length: Int
        var reading: String

        var end: Int { start + length }

        func reading(overlapStart: Int, overlapEnd: Int) -> String {
            let safeStart = max(start, overlapStart)
            let safeEnd = min(end, overlapEnd)
            guard safeStart < safeEnd, !reading.isEmpty else { return "" }
            guard safeStart != start || safeEnd != end else { return reading }

            let readingCharacters = reading.map(String.init)
            guard length > 1, !readingCharacters.isEmpty else { return reading }
            let charactersPerBase = max(1, readingCharacters.count / length)
            var result = ""
            for sourceIndex in safeStart..<safeEnd {
                let relativeIndex = sourceIndex - start
                let readStart = min(readingCharacters.count, relativeIndex * charactersPerBase)
                let readEnd = relativeIndex == length - 1
                    ? readingCharacters.count
                    : min(readingCharacters.count, (relativeIndex + 1) * charactersPerBase)
                guard readStart < readEnd else { continue }
                result += readingCharacters[readStart..<readEnd].joined()
            }
            return result
        }
    }

    private static func containsKanji(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3400...0x4dbf).contains(Int(scalar.value))
                || (0x4e00...0x9fff).contains(Int(scalar.value))
                || (0xf900...0xfaff).contains(Int(scalar.value))
        }
    }

    private static func stringValue(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return value.caseInsensitiveCompare("true") == .orderedSame || value == "1" }
        return false
    }

    private struct FuriganaRequest {
        var lineIndex: Int
        var partIndex: Int
        var text: String
    }

    private struct FuriganaValue {
        var partIndex: Int
        var value: String
    }

    private final class PendingRequest {
        let requestId: String
        let trackKey: String
        let cacheKey: String
        let baseResult: LyricsResult
        let requests: [FuriganaRequest]
        private let continuation: CheckedContinuation<Response, Never>
        private var logs: [String]
        private var resumed = false

        init(
            requestId: String,
            trackKey: String,
            cacheKey: String,
            baseResult: LyricsResult,
            requests: [FuriganaRequest],
            continuation: CheckedContinuation<Response, Never>
        ) {
            self.requestId = requestId
            self.trackKey = trackKey
            self.cacheKey = cacheKey
            self.baseResult = baseResult
            self.requests = requests
            self.continuation = continuation
            self.logs = ["furigana js request: lines=\(requests.count)"]
        }

        func appendLog(_ message: String) {
            logs.append(message)
        }

        func resume(result: Response) {
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: Response(result: result.result, logs: logs + result.logs, hadError: result.hadError))
        }
    }

    private static let bridgeHTML = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <script src="build/kuromoji.js"></script>
      <script>
        (function () {
          var tokenizer = null;
          var initPromise = null;
          var conversionCache = new Map();
          var maxCacheSize = 1000;
          var dictPaths = [
            "dict",
            "https://unpkg.com/kuromoji@0.1.2/dict"
          ];

          function post(name, payload) {
            try {
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[name]) {
                window.webkit.messageHandlers[name].postMessage(payload);
              }
            } catch (error) {}
          }

          function log(message) {
            post("furiganaLog", String(message || ""));
          }

          function reply(requestId, payload) {
            post("furiganaResult", { requestId: String(requestId || ""), payload: payload || {} });
          }

          function buildTokenizer(dictPath) {
            return new Promise(function (resolve, reject) {
              if (!window.kuromoji) {
                reject(new Error("Kuromoji library not loaded"));
                return;
              }
              window.kuromoji.builder({ dicPath: dictPath }).build(function (error, builtTokenizer) {
                if (error) {
                  reject(error);
                  return;
                }
                resolve(builtTokenizer);
              });
            });
          }

          function init() {
            if (tokenizer) {
              return Promise.resolve(tokenizer);
            }
            if (initPromise) {
              return initPromise;
            }
            initPromise = (async function () {
              var lastError = null;
              for (var i = 0; i < dictPaths.length; i++) {
                try {
                  tokenizer = await buildTokenizer(dictPaths[i]);
                  log("furigana js: kuromoji ready / dict=" + dictPaths[i]);
                  post("furiganaReady", "ready");
                  return tokenizer;
                } catch (error) {
                  lastError = error;
                  log("furigana js: dict failed / dict=" + dictPaths[i] + " / error=" + String(error && error.message ? error.message : error));
                }
              }
              throw lastError || new Error("Kuromoji dictionary load failed");
            })();
            return initPromise;
          }

          function containsKanji(text) {
            return /[\\u3400-\\u4DBF\\u4E00-\\u9FFF\\uF900-\\uFAFF]/.test(String(text || ""));
          }

          function katakanaToHiragana(value) {
            return String(value || "").split("").map(function (char) {
              var code = char.charCodeAt(0);
              if (code >= 0x30a1 && code <= 0x30f6) {
                return String.fromCharCode(code - 0x60);
              }
              return char;
            }).join("");
          }

          function convertToFurigana(text) {
            text = typeof text === "string" ? text : String(text || "");
            if (!text || !containsKanji(text)) {
              return text;
            }
            if (conversionCache.has(text)) {
              return conversionCache.get(text);
            }
            if (!tokenizer) {
              return text;
            }
            try {
              var tokens = tokenizer.tokenize(text);
              var result = "";
              for (var tokenIndex = 0; tokenIndex < tokens.length; tokenIndex++) {
                var token = tokens[tokenIndex];
                var surface = token.surface_form || "";
                var reading = token.reading || token.pronunciation || "";
                if (reading && containsKanji(surface)) {
                  var hiragana = katakanaToHiragana(reading);
                  var tokenResult = "";
                  var readingIndex = 0;
                  var i = 0;
                  while (i < surface.length) {
                    var char = surface[i];
                    if (containsKanji(char)) {
                      var kanjiSequence = char;
                      i++;
                      while (i < surface.length && containsKanji(surface[i])) {
                        kanjiSequence += surface[i];
                        i++;
                      }
                      var nextKana = "";
                      var tempI = i;
                      while (tempI < surface.length && !containsKanji(surface[tempI])) {
                        nextKana += surface[tempI];
                        tempI++;
                      }
                      var kanjiReading = "";
                      if (nextKana.length > 0) {
                        var remainingReading = hiragana.substring(readingIndex);
                        var kanaIndex = remainingReading.indexOf(nextKana);
                        if (kanaIndex > 0) {
                          kanjiReading = remainingReading.substring(0, kanaIndex);
                        } else if (kanaIndex < 0) {
                          kanjiReading = remainingReading;
                        }
                      } else {
                        kanjiReading = hiragana.substring(readingIndex);
                      }
                      if (kanjiReading) {
                        tokenResult += "<ruby>" + kanjiSequence + "<rt>" + kanjiReading + "</rt></ruby>";
                        readingIndex += kanjiReading.length;
                      } else {
                        tokenResult += kanjiSequence;
                      }
                    } else {
                      tokenResult += char;
                      readingIndex++;
                      i++;
                    }
                  }
                  result += tokenResult;
                } else {
                  result += surface;
                }
              }
              if (conversionCache.size >= maxCacheSize) {
                conversionCache.delete(conversionCache.keys().next().value);
              }
              conversionCache.set(text, result);
              return result;
            } catch (error) {
              return text;
            }
          }

          window.ivLyricsFurigana = {
            request: async function (requestId, rawPayload) {
              try {
                var payload = typeof rawPayload === "string" ? JSON.parse(rawPayload) : (rawPayload || {});
                var lines = Array.isArray(payload.lines) ? payload.lines : [];
                await init();
                reply(requestId, {
                  ok: true,
                  lines: lines.map(function (line) {
                    return convertToFurigana(line);
                  })
                });
              } catch (error) {
                reply(requestId, {
                  ok: false,
                  error: String(error && error.message ? error.message : error)
                });
              }
            }
          };

          init().catch(function (error) {
            log("furigana js init failed: " + String(error && error.message ? error.message : error));
          });
        })();
      </script>
    </head>
    <body></body>
    </html>
    """
}
