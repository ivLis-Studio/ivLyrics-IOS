import Foundation

/// Local AI: a translation-only provider that runs a small translation model on this device
/// through llama.cpp. Everything in this file is pure logic shared by the app, the host check
/// and the regression tests (scripts/test-local-ai.py). The line algorithm and prompts match
/// the PC addon (Addon_AI_LocalModel.js) so both platforms translate lyrics the same way.
enum LocalAI {
    static let providerId = "local-ai"
    /// A product name like "Google Translate": never localized.
    static let label = "Local AI"

    static let modelBaseURL = "https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/main/"

    /// Quality tiers chosen with the three-step slider. One model file per tier.
    enum Tier: String, CaseIterable, Identifiable, Sendable {
        case light
        case medium
        case high

        /// The product owner chose Local Light as the mobile default (the PC defaults to Local High).
        static let mobileDefault: Tier = .light

        var id: String { rawValue }

        var fileName: String {
            switch self {
            case .light: return "Hy-MT2-1.8B-Q4_K_M.gguf"
            case .medium: return "Hy-MT2-1.8B-Q6_K.gguf"
            case .high: return "Hy-MT2-1.8B-Q8_0.gguf"
            }
        }

        /// Exact size of the published file. A download is only kept when it matches.
        var byteCount: Int64 {
            switch self {
            case .light: return 1_133_080_448
            case .medium: return 1_474_785_120
            case .high: return 1_908_528_192
            }
        }

        var downloadURL: URL { URL(string: LocalAI.modelBaseURL + fileName)! }
        var titleKey: String { "local_ai.tier_\(rawValue)" }
        var sliderIndex: Int { Self.allCases.firstIndex(of: self) ?? 0 }

        init(sliderIndex: Int) {
            let tiers = Self.allCases
            self = tiers[min(tiers.count - 1, max(0, sliderIndex))]
        }

        static func stored(_ raw: String?) -> Tier {
            Tier(rawValue: (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? mobileDefault
        }
    }

    enum Processor: String, CaseIterable, Sendable {
        /// The GPU (Metal) first, the CPU when the GPU cannot load the model.
        case auto
        case cpu

        static func stored(_ raw: String?) -> Processor {
            (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == Processor.cpu.rawValue ? .cpu : .auto
        }
    }

    /// "Free memory when idle" choices in minutes; 0 keeps the model loaded.
    static let idleMinuteOptions = [10, 30, 60, 0]
    static let defaultIdleMinutes = 10

    static func normalizedIdleMinutes(_ value: Int?) -> Int {
        guard let value, idleMinuteOptions.contains(value) else { return defaultIdleMinutes }
        return value
    }

    /// The settings a request runs with, captured from the app settings snapshot.
    struct Configuration: Equatable, Sendable {
        var tier: Tier = .mobileDefault
        var processor: Processor = .auto
        var idleMinutes: Int = LocalAI.defaultIdleMinutes
    }

    // MARK: Engine parameters

    static let contextLength: UInt32 = 4096
    static let batchSize: UInt32 = 512

    /// Model-card sampling. The penalty window and min-p are llama.cpp's defaults, which the PC
    /// (wllama's embedded llama-server) also applies; prompt tokens enter the penalty window there too.
    struct Sampling: Equatable, Sendable {
        var temperature: Float = 0.7
        var topP: Float = 0.6
        var topK: Int32 = 20
        var repeatPenalty: Float = 1.05
        var penaltyLastN: Int32 = 64
        var minP: Float = 0.05
    }

    static let sampling = Sampling()

    // MARK: Translation algorithm (identical to the PC addon)

    static let blockMaxParts = 8
    static let blockMaxCharacters = 480
    static let partSeparator = " / "
    private static let maxOutputTokens = 1536

    struct GenerationPerformance: Equatable, Sendable {
        var tokens: Int
        var seconds: Double

        var tokensPerSecond: Double? {
            guard tokens > 0, seconds.isFinite, seconds > 0 else { return nil }
            let speed = Double(tokens) / seconds
            return speed.isFinite ? speed : nil
        }
    }

    struct Completion: Equatable, Sendable {
        var text: String
        /// The reply ended because it reached the token budget (finish_reason "length").
        var stoppedAtLimit: Bool
        /// Actual sampled output tokens and monotonic generation time, after prompt prefill.
        var performance: GenerationPerformance? = nil
    }

    /// Characters are counted in UTF-16 code units, like JavaScript's String.length on PC.
    static func characterCount(_ text: String) -> Int { text.utf16.count }

    static func outputBudget(for text: String) -> Int {
        min(maxOutputTokens, 48 + 3 * characterCount(text))
    }

    static func blockPrompt(_ parts: [String], language: String) -> String {
        "Please accurately translate the following text into \(language).\nYou must retain the exact same number of delimiters in the translation. Strictly do not omit, escape, or translate these symbols, and pay close attention to their placement.\n\n"
            + parts.joined(separator: "\n")
    }

    static func linePrompt(_ part: String, language: String) -> String {
        "Translate the following text into \(language). Note that you should only output the translated result without any additional explanation:\n\n\(part)"
    }

    private static let protectedPartRegex = try? NSRegularExpression(pattern: #"^\s*\[.*\]\s*$"#)

    /// Section markers such as [Instrumental] stay unchanged.
    static func isProtectedPart(_ part: String) -> Bool {
        guard let regex = protectedPartRegex else { return false }
        return regex.firstMatch(in: part, range: NSRange(part.startIndex..., in: part)) != nil
    }

    static func isTranslatablePart(_ part: String) -> Bool {
        !trimmed(part).isEmpty && !isProtectedPart(part)
    }

    static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Up to 8 parts and 480 characters per prompt keep the first lines quick and the prompt far
    /// below the 4096-token context. A longer part still gets a block of its own.
    static func buildBlocks(_ parts: [String]) -> [[String]] {
        var blocks: [[String]] = []
        var block: [String] = []
        var characters = 0
        for part in parts {
            if !block.isEmpty && (block.count >= blockMaxParts || characters + characterCount(part) > blockMaxCharacters) {
                blocks.append(block)
                block = []
                characters = 0
            }
            block.append(part)
            characters += characterCount(part) + 1
        }
        if !block.isEmpty { blocks.append(block) }
        return blocks
    }

    /// A block reply is used only when it kept one non-empty line per part and finished on its own.
    static func acceptedBlockLines(_ reply: String, partCount: Int, stoppedAtLimit: Bool) -> [String]? {
        guard !stoppedAtLimit else { return nil }
        let lines = trimmed(normalizedNewlines(reply)).components(separatedBy: "\n").map(trimmed)
        guard lines.count == partCount, lines.allSatisfy({ !$0.isEmpty }) else { return nil }
        return lines
    }

    /// A single-part reply: newlines collapse to spaces.
    static func singleLine(_ reply: String) -> String {
        trimmed(reply.replacingOccurrences(of: #"\s*\n+\s*"#, with: " ", options: .regularExpression))
    }

    static func normalizedNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Translates one block: the whole block in one prompt, then part by part when the reply lost,
    /// merged or truncated a line. complete(prompt, maxTokens) runs the model once.
    static func translateBlock(
        _ parts: [String],
        language: String,
        complete: (String, Int) throws -> Completion
    ) throws -> [String] {
        if parts.count > 1 {
            let reply = try complete(blockPrompt(parts, language: language), outputBudget(for: parts.joined(separator: "\n")))
            if let lines = acceptedBlockLines(reply.text, partCount: parts.count, stoppedAtLimit: reply.stoppedAtLimit) {
                return lines
            }
        }
        var translated: [String] = []
        for part in parts {
            let reply = try complete(linePrompt(part, language: language), outputBudget(for: part))
            let line = singleLine(reply.text)
            guard !line.isEmpty else { throw LocalAIError.emptyReply }
            translated.append(line)
        }
        return translated
    }

    /// Lyrics rows split into simultaneous vocal parts ("a / b"). Each unique trimmed part is
    /// translated once, in first-appearance order; repeats, blanks and markers are filled in.
    struct LineJob: Sendable {
        let rows: [[String]]
        /// Unique trimmed parts that need the model, in first-appearance order.
        let pending: [String]
        private(set) var translations: [String: String] = [:]
        private var emitted: [Bool]

        init(lines: [String]) {
            // A row is one lyric line; stray newlines inside a row cannot become extra rows.
            rows = lines.map { line in
                LocalAI.normalizedNewlines(line).replacingOccurrences(of: "\n", with: " ")
                    .components(separatedBy: LocalAI.partSeparator)
            }
            var seen = Set<String>()
            var pending: [String] = []
            for parts in rows {
                for part in parts where LocalAI.isTranslatablePart(part) {
                    let key = LocalAI.trimmed(part)
                    if seen.insert(key).inserted { pending.append(key) }
                }
            }
            self.pending = pending
            emitted = Array(repeating: false, count: rows.count)
        }

        init(text: String) {
            self.init(lines: LocalAI.normalizedNewlines(text).components(separatedBy: "\n"))
        }

        var blocks: [[String]] { LocalAI.buildBlocks(pending) }

        func rowText(_ row: Int) -> String {
            rows[row].map { part -> String in
                if LocalAI.trimmed(part).isEmpty { return "" }
                return LocalAI.isTranslatablePart(part) ? (translations[LocalAI.trimmed(part)] ?? "") : part
            }.joined(separator: LocalAI.partSeparator)
        }

        var result: [String] { rows.indices.map(rowText) }

        mutating func fill(_ block: [String], with translated: [String]) {
            for (part, value) in zip(block, translated) { translations[part] = value }
        }

        /// Rows whose parts are all available and that were not reported yet.
        mutating func takeReadyRows() -> [(index: Int, text: String)] {
            var ready: [(index: Int, text: String)] = []
            for (row, parts) in rows.enumerated() where !emitted[row] {
                let complete = parts.allSatisfy { part in
                    !LocalAI.isTranslatablePart(part) || !(translations[LocalAI.trimmed(part)] ?? "").isEmpty
                }
                guard complete else { continue }
                emitted[row] = true
                ready.append((row, rowText(row)))
            }
            return ready
        }
    }

    // MARK: Languages

    /// Prompt language names by target code (the model's prompts use English names).
    static let targetLanguageNames: [String: String] = [
        "ko": "Korean", "en": "English", "ja": "Japanese",
        "zh": "Chinese", "zh-cn": "Chinese", "zh-hans": "Chinese", "zh-sg": "Chinese",
        "zh-tw": "Traditional Chinese", "zh-hk": "Traditional Chinese", "zh-hant": "Traditional Chinese",
        "es": "Spanish", "fr": "French", "de": "German", "it": "Italian", "ru": "Russian", "pt": "Portuguese",
        "hi": "Hindi", "ar": "Arabic", "fa": "Persian", "bn": "Bengali", "cs": "Czech", "th": "Thai",
        "tr": "Turkish", "vi": "Vietnamese", "id": "Indonesian", "ms": "Malay", "pl": "Polish", "nl": "Dutch",
        "uk": "Ukrainian", "he": "Hebrew", "tl": "Filipino", "fil": "Filipino", "km": "Khmer", "my": "Burmese",
        "gu": "Gujarati", "ur": "Urdu", "te": "Telugu", "mr": "Marathi", "ta": "Tamil", "bo": "Tibetan",
        "kk": "Kazakh", "mn": "Mongolian", "ug": "Uyghur", "yue": "Cantonese"
    ]

    static func targetLanguageName(for code: String) -> String? {
        let normalized = trimmed(code.isEmpty ? "en" : code).replacingOccurrences(of: "_", with: "-").lowercased()
        if let name = targetLanguageNames[normalized] { return name }
        return normalized.split(separator: "-").first.flatMap { targetLanguageNames[String($0)] }
    }

    /// Localized messages for failures the user can act on. The app fills them from AppI18n.
    struct Messages: Sendable {
        var notReady: String
        var downloadBusy: String
        /// Template with {language}.
        var unsupportedLanguage: String
        var uiLanguage: String

        func unsupported(_ code: String) -> String {
            let name = Locale(identifier: uiLanguage).localizedString(forIdentifier: code) ?? code
            return LocalAI.format(unsupportedLanguage, ["language": name])
        }
    }

    static func resolveTargetLanguage(_ code: String, messages: Messages) throws -> String {
        guard let name = targetLanguageName(for: code) else {
            throw LocalAIError.unsupportedLanguage(messages.unsupported(code))
        }
        return name
    }

    // MARK: Chat template

    struct ChatTemplateChoice: Equatable, Sendable {
        /// Passed to llama_chat_apply_template: a built-in template name or the model's own template.
        var template: String
        /// Text the model's template emits before the first message.
        var prefix: String
    }

    /// Renders one user turn exactly like the model's own Jinja template, which the PC renders with
    /// wllama (jinja: true): <｜hy_begin▁of▁sentence｜><｜hy_User｜>{text}<｜hy_Assistant｜>.
    /// llama.cpp b11364's template detection classifies this template as HunyuanVL (content before
    /// <｜hy_User｜>, no assistant marker), so templates that put the user marker before the content
    /// use the built-in Hunyuan dense layout plus the template's leading begin-of-sentence marker.
    static func chatTemplateChoice(modelTemplate: String) -> ChatTemplateChoice {
        let userBeforeContent = modelTemplate.range(of: #"<｜hy_User｜>\s*\{\{"#, options: .regularExpression) != nil
        guard userBeforeContent, modelTemplate.contains("<｜hy_Assistant｜>") else {
            return ChatTemplateChoice(template: modelTemplate, prefix: "")
        }
        let beginOfSentence = "<｜hy_begin▁of▁sentence｜>"
        return ChatTemplateChoice(template: "hunyuan-dense", prefix: modelTemplate.contains(beginOfSentence) ? beginOfSentence : "")
    }

    // MARK: Formatting

    /// Replaces {name} placeholders; unknown placeholders stay as written.
    static func format(_ template: String, _ values: [String: String]) -> String {
        var result = template
        for (name, value) in values {
            result = result.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return result
    }

    /// "1.13GB" like the PC (decimal gigabytes, two decimals).
    static func formatGigabytes(_ bytes: Int64) -> String {
        String(format: "%.2fGB", locale: Locale(identifier: "en_US_POSIX"), Double(bytes) / 1e9)
    }

    static func downloadPercent(loaded: Int64, total: Int64) -> Int {
        guard total > 0 else { return 0 }
        return Int((min(1, Double(loaded) / Double(total)) * 100).rounded(.down))
    }

    static func megabytes(_ bytes: Int64) -> Int { Int((Double(bytes) / 1e6).rounded()) }

    /// The test sample: Japanese lyrics, or English when the target itself is Japanese.
    static func testSample(targetLanguage: String) -> String {
        targetLanguage.lowercased().hasPrefix("ja") ? "The night is still young." : "今夜はまだ始まったばかり"
    }
}

enum LocalAIError: LocalizedError, Equatable {
    /// The selected tier is not downloaded (localized).
    case notReady(String)
    /// The selected tier is still downloading (localized).
    case downloadBusy(String)
    /// The model cannot translate into the target language (localized).
    case unsupportedLanguage(String)
    /// This build has no on-device engine (iOS Simulator builds).
    case unavailable
    /// GPU work is not allowed while the app is in the background.
    case background
    /// The system ran low on memory and the model was released.
    case memoryPressure
    case emptyReply
    case promptTooLong
    /// The model file could not be loaded.
    case modelLoadFailed
    /// There was not enough memory to create the model's context.
    case outOfMemory
    /// Native load or inference failure; the engine must be released.
    case engine(String)

    var errorDescription: String? {
        switch self {
        case let .notReady(message), let .downloadBusy(message), let .unsupportedLanguage(message):
            return message
        case .unavailable:
            return "[Local AI] The on-device engine is not available in this build."
        case .background:
            return "[Local AI] Paused while the app is in the background."
        case .memoryPressure:
            return "[Local AI] Memory was released because the system is low on memory."
        case .emptyReply:
            return "[Local AI] The model returned an empty line."
        case .promptTooLong:
            return "[Local AI] The lyrics are too long for the local model."
        case .modelLoadFailed:
            return "[Local AI] The model could not be loaded."
        case .outOfMemory:
            return "[Local AI] Not enough memory to start the model."
        case let .engine(message):
            return "[Local AI] " + message
        }
    }

    var releasesEngine: Bool {
        if case .engine = self { return true }
        return false
    }
}

