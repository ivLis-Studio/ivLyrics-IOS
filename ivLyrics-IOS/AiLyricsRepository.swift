import Foundation

actor AiLyricsRepository {
    private static let taggedOutputLinePattern = #"^\s*(?:[-*]\s*)?(?:\[?L(\d{1,4})\]?|(?:row|line)\s*(\d{1,4})|#?(\d{1,4}))\s*(?:\t|[:：|\-]|\.\s+|\s+)\s*(.*)$"#
    private static let taggedOutputLineRegex = try? NSRegularExpression(
        pattern: taggedOutputLinePattern,
        options: [.caseInsensitive]
    )
    private static let supplementOutputPrefixPattern = #"(?i)^\s*(translation|translated text|pronunciation|pronunciation text|romanization|furigana|ruby|reading|번역|발음|후리가나|후라가나)\s*[:：\-]\s*"#
    private static let supplementOutputPrefixRegex = try? NSRegularExpression(
        pattern: supplementOutputPrefixPattern
    )

    private let supplementPromptVersion = "v4-id-aligned-ai-only"
    private let supplementTaskPronunciation = "pronunciation"
    private let supplementTaskTranslation = "translation"
    private let tmiPromptVersion = "origin-v1"
    private let culturalAnnotationPromptVersion = "cultural-v3"
    private let diskCache = LyricsDiskCache(namespace: "ai_lyrics", maxEntries: 500)
    private let metadataDiskCache = RawResponseDiskCache(namespace: "ai_metadata_cache", maxEntries: 500)
    private let tmiDiskCache = RawResponseDiskCache(namespace: "ai_tmi_cache", maxEntries: 500)
    private let culturalAnnotationDiskCache = RawResponseDiskCache(
        namespace: "ai_cultural_annotations",
        maxEntries: 500,
        formatVersion: 3
    )
    private var memoryCache: [String: LyricsResult] = [:]
    private var metadataMemoryCache: [String: MetadataTranslation] = [:]
    private var tmiMemoryCache: [String: TmiInfo] = [:]
    private var culturalAnnotationMemoryCache: [String: [CulturalAnnotation]] = [:]
    private var lastPartialEmitUptime: TimeInterval = 0
    private let partialEmitMinInterval: TimeInterval = 0.6

    struct SupplementResponse: Sendable {
        var result: LyricsResult
        var logs: [String]
        var pronunciationLoading: Bool
        var translationLoading: Bool
        var hadError: Bool
    }

    struct MetadataTranslation: Codable, Sendable, Equatable {
        var title: String
        var artist: String
        var sourceLang: String
        var targetLang: String
    }

    struct MetadataTranslationResponse: Sendable {
        var translation: MetadataTranslation?
        var logs: [String]
        var hadError: Bool
    }

    struct TmiSource: Codable, Hashable, Sendable {
        var title: String
        var url: String

        init(title: String, url: String) {
            self.title = title.trimmed
            self.url = url.trimmed
        }

        var displayTitle: String {
            if !title.isEmpty { return title }
            guard let host = URL(string: url)?.host?.regexReplacing(#"^www\."#, with: ""), !host.trimmed.isEmpty else {
                return url
            }
            return host
        }
    }

    struct TmiInfo: Codable, Equatable, Sendable {
        var cacheKey: String
        var description: String
        var trivia: [String]
        var verifiedSources: [TmiSource]
        var relatedSources: [TmiSource]
        var otherSources: [TmiSource]
        var confidence: String
        var hasVerifiedSources: Bool
        var verifiedSourceCount: Int
        var relatedSourceCount: Int
        var totalSourceCount: Int
        var targetLang: String
        var savedAtMs: Int64

        init(
            cacheKey: String = "",
            description: String,
            trivia: [String],
            verifiedSources: [TmiSource],
            relatedSources: [TmiSource],
            otherSources: [TmiSource],
            confidence: String,
            hasVerifiedSources: Bool,
            verifiedSourceCount: Int,
            relatedSourceCount: Int,
            totalSourceCount: Int,
            targetLang: String,
            savedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
        ) {
            self.cacheKey = cacheKey.trimmed
            self.description = description.trimmed
            self.trivia = trivia.map(\.trimmed).filter { !$0.isEmpty }
            self.verifiedSources = verifiedSources.filter { !$0.url.isEmpty }
            self.relatedSources = relatedSources.filter { !$0.url.isEmpty }
            self.otherSources = otherSources.filter { !$0.url.isEmpty }
            self.confidence = confidence.trimmed
            self.hasVerifiedSources = hasVerifiedSources
            self.verifiedSourceCount = max(0, verifiedSourceCount)
            self.relatedSourceCount = max(0, relatedSourceCount)
            self.totalSourceCount = max(0, totalSourceCount)
            self.targetLang = AppSettings.normalizeLanguageCode(targetLang)
            self.savedAtMs = savedAtMs
        }

        var hasContent: Bool {
            !description.isEmpty || !trivia.isEmpty
        }

        var allSources: [TmiSource] {
            verifiedSources + relatedSources + otherSources
        }

        func withCacheKey(_ key: String) -> TmiInfo {
            TmiInfo(
                cacheKey: key,
                description: description,
                trivia: trivia,
                verifiedSources: verifiedSources,
                relatedSources: relatedSources,
                otherSources: otherSources,
                confidence: confidence,
                hasVerifiedSources: hasVerifiedSources,
                verifiedSourceCount: verifiedSourceCount,
                relatedSourceCount: relatedSourceCount,
                totalSourceCount: totalSourceCount,
                targetLang: targetLang
            )
        }
    }

    struct TmiResponse: Sendable {
        var trackKey: String
        var info: TmiInfo?
        var errorMessage: String
        var logs: [String]
    }

    struct CulturalAnnotationResponse: Sendable {
        var requestKey: String
        var annotations: [CulturalAnnotation]
        var logs: [String]
        var hadError: Bool
        var errorMessage: String
    }

    func loadSupplements(
        track: TrackSnapshot,
        baseResult: LyricsResult,
        settings: AppSettings.Snapshot,
        sourceLangOverride: String = "",
        bypassCache: Bool = false,
        partialUpdate: ((SupplementResponse) async -> Void)? = nil
    ) async -> SupplementResponse {
        lastPartialEmitUptime = 0
        var logs: [String] = []
        func log(_ message: String) { logs.append(message) }

        guard track.hasUsableMetadata, !baseResult.lines.isEmpty, settings.enabled else {
            return SupplementResponse(result: baseResult, logs: logs, pronunciationLoading: false, translationLoading: false, hadError: false)
        }

        let trackKey = track.stableKey
        let requests = buildSupplementRequests(baseResult.lines)
        guard !requests.isEmpty else {
            return SupplementResponse(result: baseResult, logs: logs, pronunciationLoading: false, translationLoading: false, hadError: false)
        }

        let textPayload = requests.map(\.text).joined(separator: "\n")
        let detectedSourceLang = Self.detectLanguage(textPayload)
        let normalizedOverride = AppSettings.normalizeLanguageCode(sourceLangOverride)
        let sourceLang = normalizedOverride.isEmpty || normalizedOverride.caseInsensitiveCompare("auto") == .orderedSame
            ? detectedSourceLang
            : normalizedOverride
        let rule = settings.ruleForSource(sourceLang)
        let targetLang = settings.resolveTargetLanguage(sourceLang: sourceLang)
        let pronunciationLang = settings.pronunciationLanguage
        let translationSkipped = settings.shouldSkipTranslation(sourceLang: sourceLang, resolvedTargetLang: targetLang)
        let needsPronunciation = rule.pronunciationEnabled
        let needsTranslation = rule.translationEnabled && !translationSkipped

        guard rule.enabled else {
            log("ai lyrics skipped for source=\(sourceLang): translation=false / pronunciation=false")
            return SupplementResponse(result: baseResult, logs: logs, pronunciationLoading: false, translationLoading: false, hadError: false)
        }

        let cacheKey = trackKey
            + "|source=\(sourceLang)"
            + "|detected=\(detectedSourceLang)"
            + "|prompt=\(supplementPromptVersion)"
            + "|\(settings.cacheKey)"
            + "|text=\(IvLyricsUtilities.sha256(textPayload))"
        if !bypassCache {
            if let cached = memoryCache[cacheKey] {
                let result = withBaseContributors(cached, baseResult: baseResult)
                memoryCache[cacheKey] = result
                log("ai lyrics cache hit: \(settings.provider.label)")
                return SupplementResponse(result: result, logs: logs, pronunciationLoading: false, translationLoading: false, hadError: false)
            }
            if let cached = diskCache.get(cacheKey) {
                let result = withBaseContributors(cached, baseResult: baseResult)
                memoryCache[cacheKey] = result
                log("ai lyrics disk cache hit: \(settings.provider.label)")
                return SupplementResponse(result: result, logs: logs, pronunciationLoading: false, translationLoading: false, hadError: false)
            }
        }

        guard settings.hasApiKey else {
            log("ai lyrics skipped: API key missing for \(settings.provider.label)")
            return SupplementResponse(result: baseResult, logs: logs, pronunciationLoading: false, translationLoading: false, hadError: true)
        }

        log("ai lyrics: provider=\(settings.provider.label) / model=\(settings.model) / source=\(sourceLang)\(sourceLang.caseInsensitiveCompare(detectedSourceLang) == .orderedSame ? "" : " / detected=\(detectedSourceLang)") / pronunciation=\(pronunciationLang) / target=\(targetLang) / translation=\(rule.translationEnabled) / pronunciation=\(rule.pronunciationEnabled)")
        if translationSkipped {
            log("ai translation skipped: source language matches target (\(sourceLang) -> \(targetLang))")
        }

        var pronunciationValues = Array(repeating: "", count: requests.count)
        var translationValues = Array(repeating: "", count: requests.count)
        var pronunciationLoading = needsPronunciation
        var translationLoading = needsTranslation
        var hadError = false
        let liveState = SupplementLiveState(
            pronunciation: pronunciationValues,
            translation: translationValues,
            pronunciationLoading: pronunciationLoading,
            translationLoading: translationLoading
        )

        func emitPartial() async {
            await emitSupplementPartial(
                baseResult: baseResult,
                requests: requests,
                settings: settings,
                sourceLang: sourceLang,
                targetLang: targetLang,
                pronunciationLang: pronunciationLang,
                rule: rule,
                translationSkipped: translationSkipped,
                liveState: liveState,
                partialUpdate: partialUpdate,
                force: true
            )
        }

        let pronunciationCacheKey = supplementTaskCacheKey(
            trackKey: trackKey,
            detectedSourceLang: detectedSourceLang,
            sourceLang: sourceLang,
            settings: settings,
            textPayload: textPayload,
            task: supplementTaskPronunciation,
            outputLang: pronunciationLang
        )
        let translationCacheKey = supplementTaskCacheKey(
            trackKey: trackKey,
            detectedSourceLang: detectedSourceLang,
            sourceLang: sourceLang,
            settings: settings,
            textPayload: textPayload,
            task: supplementTaskTranslation,
            outputLang: targetLang
        )

        if !bypassCache && needsPronunciation, let cached = cachedResult(pronunciationCacheKey) {
            pronunciationValues = extractSupplementValues(cached, requests: requests, pronunciation: true)
            pronunciationLoading = false
            await liveState.finish(task: supplementTaskPronunciation, values: pronunciationValues)
            log("ai pronunciation cache hit: \(settings.provider.label)")
        }
        if !bypassCache && needsTranslation, let cached = cachedResult(translationCacheKey) {
            translationValues = extractSupplementValues(cached, requests: requests, pronunciation: false)
            translationLoading = false
            await liveState.finish(task: supplementTaskTranslation, values: translationValues)
            log("ai translation cache hit: \(settings.provider.label)")
        }

        if (needsPronunciation != pronunciationLoading) || (needsTranslation != translationLoading) {
            await emitPartial()
        }

        if !pronunciationLoading && !translationLoading {
            let result = buildMergedSupplementResult(
                baseResult: baseResult,
                requests: requests,
                pronunciation: pronunciationValues,
                translation: translationValues,
                settings: settings,
                sourceLang: sourceLang,
                targetLang: targetLang,
                pronunciationLang: pronunciationLang,
                rule: rule,
                translationSkipped: translationSkipped
            )
            cacheResult(cacheKey, result: result)
            return SupplementResponse(result: result, logs: logs, pronunciationLoading: false, translationLoading: false, hadError: false)
        }

        await withTaskGroup(of: SupplementTaskOutcome.self) { group in
            if pronunciationLoading {
                group.addTask { [self] in
                    await loadSupplementTask(
                        settings: settings,
                        baseResult: baseResult,
                        requests: requests,
                        taskCacheKey: pronunciationCacheKey,
                        task: supplementTaskPronunciation,
                        sourceLang: sourceLang,
                        targetLang: targetLang,
                        pronunciationLang: pronunciationLang,
                        rule: rule,
                        translationSkipped: translationSkipped,
                        liveState: liveState,
                        partialUpdate: partialUpdate
                    )
                }
            }
            if translationLoading {
                group.addTask { [self] in
                    await loadSupplementTask(
                        settings: settings,
                        baseResult: baseResult,
                        requests: requests,
                        taskCacheKey: translationCacheKey,
                        task: supplementTaskTranslation,
                        sourceLang: sourceLang,
                        targetLang: targetLang,
                        pronunciationLang: pronunciationLang,
                        rule: rule,
                        translationSkipped: translationSkipped,
                        liveState: liveState,
                        partialUpdate: partialUpdate
                    )
                }
            }
            for await outcome in group {
                logs.append(contentsOf: outcome.logs)
            }
        }

        let finalSnapshot = await liveState.snapshot()
        pronunciationValues = finalSnapshot.pronunciation
        translationValues = finalSnapshot.translation
        hadError = finalSnapshot.hadError

        let result = buildMergedSupplementResult(
            baseResult: baseResult,
            requests: requests,
            pronunciation: pronunciationValues,
            translation: translationValues,
            settings: settings,
            sourceLang: sourceLang,
            targetLang: targetLang,
            pronunciationLang: pronunciationLang,
            rule: rule,
            translationSkipped: translationSkipped
        )
        if !hadError {
            cacheResult(cacheKey, result: result)
        }
        return SupplementResponse(result: result, logs: logs, pronunciationLoading: false, translationLoading: false, hadError: hadError)
    }

    private func loadSupplementTask(
        settings: AppSettings.Snapshot,
        baseResult: LyricsResult,
        requests: [SupplementRequest],
        taskCacheKey: String,
        task: String,
        sourceLang: String,
        targetLang: String,
        pronunciationLang: String,
        rule: AppSettings.LanguageRule,
        translationSkipped: Bool,
        liveState: SupplementLiveState,
        partialUpdate: ((SupplementResponse) async -> Void)?
    ) async -> SupplementTaskOutcome {
        var logs: [String] = []
        func log(_ message: String) { logs.append(message) }

        let pronunciation = task == supplementTaskPronunciation
        do {
            let prompt: String
            if pronunciation {
                prompt = buildPhoneticPrompt(requests: requests, lang: pronunciationLang)
                log("ai pronunciation stream request: lines=\(requests.count) / pronunciation=\(pronunciationLang)")
            } else {
                prompt = buildTranslationPrompt(requests: requests, lang: targetLang)
                log("ai translation stream request: lines=\(requests.count)")
            }
            let values = try await loadSupplementValuesStreamFirst(
                prompt: prompt,
                settings: settings,
                requests: requests,
                taskName: task,
                log: log
            ) { [self] index, value in
                await liveState.setValue(task: task, index: index, value: value)
                await emitSupplementPartial(
                    baseResult: baseResult,
                    requests: requests,
                    settings: settings,
                    sourceLang: sourceLang,
                    targetLang: targetLang,
                    pronunciationLang: pronunciationLang,
                    rule: rule,
                    translationSkipped: translationSkipped,
                    liveState: liveState,
                    partialUpdate: partialUpdate
                )
            }
            await liveState.finish(task: task, values: values)
            log("ai \(task) response: lines=\(values.count)")
            let taskResult = buildTaskResult(baseResult: baseResult, requests: requests, values: values, pronunciation: pronunciation)
            cacheResult(taskCacheKey, result: taskResult)
            await emitSupplementPartial(
                baseResult: baseResult,
                requests: requests,
                settings: settings,
                sourceLang: sourceLang,
                targetLang: targetLang,
                pronunciationLang: pronunciationLang,
                rule: rule,
                translationSkipped: translationSkipped,
                liveState: liveState,
                partialUpdate: partialUpdate,
                force: true
            )
            return SupplementTaskOutcome(logs: logs)
        } catch {
            await liveState.fail(task: task)
            log("ai \(task) error: \(error.localizedDescription)")
            await emitSupplementPartial(
                baseResult: baseResult,
                requests: requests,
                settings: settings,
                sourceLang: sourceLang,
                targetLang: targetLang,
                pronunciationLang: pronunciationLang,
                rule: rule,
                translationSkipped: translationSkipped,
                liveState: liveState,
                partialUpdate: partialUpdate,
                force: true
            )
            return SupplementTaskOutcome(logs: logs)
        }
    }

    private func emitSupplementPartial(
        baseResult: LyricsResult,
        requests: [SupplementRequest],
        settings: AppSettings.Snapshot,
        sourceLang: String,
        targetLang: String,
        pronunciationLang: String,
        rule: AppSettings.LanguageRule,
        translationSkipped: Bool,
        liveState: SupplementLiveState,
        partialUpdate: ((SupplementResponse) async -> Void)?,
        force: Bool = false
    ) async {
        guard let partialUpdate else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        guard force || uptime - lastPartialEmitUptime >= partialEmitMinInterval else { return }
        lastPartialEmitUptime = uptime
        let snapshot = await liveState.snapshot()
        let result = buildMergedSupplementResult(
            baseResult: baseResult,
            requests: requests,
            pronunciation: snapshot.pronunciation,
            translation: snapshot.translation,
            settings: settings,
            sourceLang: sourceLang,
            targetLang: targetLang,
            pronunciationLang: pronunciationLang,
            rule: rule,
            translationSkipped: translationSkipped
        )
        await partialUpdate(SupplementResponse(
            result: result,
            logs: [],
            pronunciationLoading: snapshot.pronunciationLoading,
            translationLoading: snapshot.translationLoading,
            hadError: snapshot.hadError
        ))
    }

    func loadMetadataTranslation(
        track: TrackSnapshot,
        settings: AppSettings.Snapshot,
        sourceLangOverride: String = "",
        bypassCache: Bool = false
    ) async -> MetadataTranslationResponse {
        var logs: [String] = []
        func log(_ message: String) { logs.append(message) }

        guard track.hasUsableMetadata else {
            return MetadataTranslationResponse(translation: nil, logs: logs, hadError: false)
        }
        let detectedSourceLang = Self.detectLanguage(track.title + "\n" + track.artist)
        let normalizedOverride = AppSettings.normalizeLanguageCode(sourceLangOverride)
        let sourceLang = normalizedOverride.isEmpty || normalizedOverride.caseInsensitiveCompare("auto") == .orderedSame
            ? detectedSourceLang
            : normalizedOverride
        let targetLang = settings.resolveTargetLanguage(sourceLang: sourceLang)
        guard settings.metadataTranslationEnabled,
              AppSettings.normalizeLanguageCode(sourceLang).caseInsensitiveCompare(targetLang) != .orderedSame else {
            return MetadataTranslationResponse(translation: nil, logs: logs, hadError: false)
        }
        guard settings.hasApiKey else {
            log("ai metadata skipped: API key missing for \(settings.provider.label)")
            return MetadataTranslationResponse(translation: nil, logs: logs, hadError: true)
        }
        let title = track.title.trimmed
        let artist = track.artist.trimmed
        guard !title.isEmpty || !artist.isEmpty else {
            return MetadataTranslationResponse(translation: nil, logs: logs, hadError: false)
        }
        let trackKey = track.stableKey
        let cacheKey = "metadata|"
            + trackKey
            + "|source=\(sourceLang)"
            + "|target=\(targetLang)"
            + "|provider=\(settings.provider.id)"
            + "|model=\(settings.model)"
            + "|url=\(settings.baseUrl)"
            + "|temp=\(settings.temperature)"
            + "|text=\(IvLyricsUtilities.sha256(title + "\n" + artist))"
        if !bypassCache {
            if let cached = metadataMemoryCache[cacheKey] {
                log("ai metadata cache hit: \(settings.provider.label)")
                return MetadataTranslationResponse(translation: cached, logs: logs, hadError: false)
            }
            if let persisted = metadataTranslationFromDisk(cacheKey) {
                metadataMemoryCache[cacheKey] = persisted
                log("ai metadata disk cache hit: \(settings.provider.label)")
                return MetadataTranslationResponse(translation: persisted, logs: logs, hadError: false)
            }
        }
        log("ai metadata: provider=\(settings.provider.label) / source=\(sourceLang)\(sourceLang.caseInsensitiveCompare(detectedSourceLang) == .orderedSame ? "" : " / detected=\(detectedSourceLang)") / target=\(targetLang)")
        do {
            let raw = try await callProviderRaw(prompt: buildMetadataTranslationPrompt(title: title, artist: artist, lang: targetLang), settings: settings)
            let lines = parseTextLines(raw, expectedLineCount: 2)
            let translation = MetadataTranslation(
                title: cleanMetadataOutputLine(lines.first ?? "", kind: "title", fallback: title),
                artist: cleanMetadataOutputLine(lines.dropFirst().first ?? "", kind: "artist", fallback: artist),
                sourceLang: sourceLang,
                targetLang: targetLang
            )
            metadataMemoryCache[cacheKey] = translation
            putMetadataTranslationToDisk(cacheKey: cacheKey, translation: translation)
            log("ai metadata response: title=\(!translation.title.isEmpty) / artist=\(!translation.artist.isEmpty)")
            return MetadataTranslationResponse(translation: translation, logs: logs, hadError: false)
        } catch {
            log("ai metadata error: \(error.localizedDescription)")
            return MetadataTranslationResponse(translation: nil, logs: logs, hadError: true)
        }
    }

    func loadTmi(track: TrackSnapshot, settings: AppSettings.Snapshot, bypassCache: Bool = false) async -> TmiResponse {
        var logs: [String] = []
        func log(_ message: String) { logs.append(message) }

        guard track.hasUsableMetadata else {
            return TmiResponse(trackKey: "", info: nil, errorMessage: "", logs: logs)
        }
        let title = track.title.trimmed
        let artist = track.artist.trimmed
        guard !title.isEmpty || !artist.isEmpty else {
            return TmiResponse(trackKey: track.stableKey, info: nil, errorMessage: "", logs: logs)
        }

        let trackKey = track.stableKey
        let targetLang = settings.pronunciationLanguage
        let cacheKey = "tmi|"
            + trackKey
            + "|lang=\(targetLang)"
            + "|prompt=\(tmiPromptVersion)"
            + "|provider=\(settings.provider.id)"
            + "|model=\(settings.model)"
            + "|url=\(settings.baseUrl)"
            + "|tok=\(settings.maxTokens)"
            + "|temp=\(settings.temperature)"
            + "|text=\(IvLyricsUtilities.sha256(title + "\n" + artist))"

        if !bypassCache {
            if let cached = tmiMemoryCache[cacheKey] {
                log("ai tmi cache hit: \(settings.provider.label)")
                return TmiResponse(trackKey: trackKey, info: cached, errorMessage: "", logs: logs)
            }
            if let persisted = tmiFromDisk(cacheKey) {
                tmiMemoryCache[cacheKey] = persisted
                log("ai tmi disk cache hit: \(settings.provider.label)")
                return TmiResponse(trackKey: trackKey, info: persisted, errorMessage: "", logs: logs)
            }
        }

        guard settings.hasApiKey else {
            log("ai tmi skipped: API key missing for \(settings.provider.label)")
            return TmiResponse(trackKey: trackKey, info: nil, errorMessage: "tmi.require_key", logs: logs)
        }

        log("ai tmi: provider=\(settings.provider.label) / model=\(settings.model) / target=\(targetLang)")
        do {
            let raw = try await callProviderRaw(prompt: buildTmiPrompt(title: title, artist: artist, lang: targetLang), settings: settings)
            let info = try parseTmiInfo(raw: raw, targetLang: targetLang).withCacheKey(cacheKey)
            tmiMemoryCache[cacheKey] = info
            putTmiToDisk(cacheKey: cacheKey, info: info)
            log("ai tmi response: description=\(!info.description.isEmpty) / trivia=\(info.trivia.count) / sources=\(info.allSources.count) / confidence=\(info.confidence)")
            return TmiResponse(trackKey: trackKey, info: info, errorMessage: "", logs: logs)
        } catch {
            let message = error.localizedDescription
            log("ai tmi error: \(message)")
            return TmiResponse(trackKey: trackKey, info: nil, errorMessage: message, logs: logs)
        }
    }

    func loadCulturalAnnotations(
        track: TrackSnapshot,
        baseResult: LyricsResult,
        settings: AppSettings.Snapshot,
        sourceLangOverride: String = "",
        bypassCache: Bool = false
    ) async -> CulturalAnnotationResponse {
        var logs: [String] = []
        func response(
            requestKey: String = "",
            annotations: [CulturalAnnotation] = [],
            hadError: Bool = false,
            errorMessage: String = ""
        ) -> CulturalAnnotationResponse {
            CulturalAnnotationResponse(
                requestKey: requestKey,
                annotations: annotations,
                logs: logs,
                hadError: hadError,
                errorMessage: errorMessage
            )
        }

        guard settings.culturalAnnotationsEnabled, !baseResult.lines.isEmpty else {
            return response()
        }
        let lineTexts = baseResult.lines.map(displayLineText)
        let textPayload = lineTexts.joined(separator: "\n")
        guard !textPayload.trimmed.isEmpty else {
            return response()
        }
        let detectedSourceLang = Self.detectLanguage(textPayload)
        let normalizedOverride = AppSettings.normalizeLanguageCode(sourceLangOverride)
        let sourceLang = normalizedOverride.isEmpty || normalizedOverride.caseInsensitiveCompare("auto") == .orderedSame
            ? detectedSourceLang
            : normalizedOverride
        let targetLang = settings.resolveTargetLanguage(sourceLang: sourceLang)
        let requestKey = "cultural|"
            + track.stableKey
            + "|source=\(sourceLang)"
            + "|target=\(targetLang)"
            + "|prompt=\(culturalAnnotationPromptVersion)"
            + "|provider=\(settings.provider.id)"
            + "|model=\(settings.model)"
            + "|url=\(settings.baseUrl)"
            + "|temp=\(settings.temperature)"
            + "|text=\(IvLyricsUtilities.sha256(textPayload))"

        if !bypassCache {
            if let cached = culturalAnnotationMemoryCache[requestKey] {
                logs.append("ai cultural annotations cache hit: \(settings.provider.label)")
                return response(requestKey: requestKey, annotations: cached)
            }
            if let cached = culturalAnnotationsFromDisk(requestKey) {
                culturalAnnotationMemoryCache[requestKey] = cached
                logs.append("ai cultural annotations disk cache hit: \(settings.provider.label)")
                return response(requestKey: requestKey, annotations: cached)
            }
        }
        guard settings.hasApiKey else {
            logs.append("ai cultural annotations skipped: API key missing for \(settings.provider.label)")
            return response(requestKey: requestKey, hadError: true, errorMessage: "API key missing")
        }
        guard !settings.model.trimmed.isEmpty else {
            logs.append("ai cultural annotations skipped: model missing for \(settings.provider.label)")
            return response(requestKey: requestKey, hadError: true, errorMessage: "AI model missing")
        }

        logs.append("ai cultural annotations: provider=\(settings.provider.label) / source=\(sourceLang) / target=\(targetLang)")
        do {
            let raw = try await callProviderRaw(
                prompt: buildCulturalAnnotationPrompt(
                    lineTexts: lineTexts,
                    sourceLang: sourceLang,
                    targetLang: targetLang
                ),
                settings: settings
            )
            let annotations = try parseCulturalAnnotations(raw: raw, lineTexts: lineTexts)
            culturalAnnotationMemoryCache[requestKey] = annotations
            putCulturalAnnotationsToDisk(cacheKey: requestKey, annotations: annotations)
            logs.append("ai cultural annotations response: \(annotations.count)")
            return response(requestKey: requestKey, annotations: annotations)
        } catch {
            let message = error.localizedDescription
            logs.append("ai cultural annotations error: \(message)")
            return response(requestKey: requestKey, hadError: true, errorMessage: message)
        }
    }

    func clearCache() {
        memoryCache.removeAll()
        metadataMemoryCache.removeAll()
        tmiMemoryCache.removeAll()
        culturalAnnotationMemoryCache.removeAll()
        diskCache.clear()
        metadataDiskCache.clear()
        tmiDiskCache.clear()
        culturalAnnotationDiskCache.clear()
    }

    func clearTrackCache(_ trackKey: String) {
        let key = trackKey.trimmed
        guard !key.isEmpty else { return }
        memoryCache = memoryCache.filter { !$0.key.hasPrefix(key + "|") }
        metadataMemoryCache = metadataMemoryCache.filter { !$0.key.hasPrefix("metadata|" + key + "|") }
        tmiMemoryCache = tmiMemoryCache.filter { !$0.key.hasPrefix("tmi|" + key + "|") }
        culturalAnnotationMemoryCache = culturalAnnotationMemoryCache.filter { !$0.key.hasPrefix("cultural|" + key + "|") }
        diskCache.removeByKeyPrefix(key + "|")
        metadataDiskCache.removeByKeyPrefix("metadata|" + key + "|")
        tmiDiskCache.removeByKeyPrefix("tmi|" + key + "|")
        culturalAnnotationDiskCache.removeByKeyPrefix("cultural|" + key + "|")
    }

    private func callProviderRaw(prompt: String, settings: AppSettings.Snapshot) async throws -> String {
        let keys = providerApiKeys(settings)
        guard !keys.isEmpty else { throw NSError(domain: "ivLyrics.AI", code: -1, userInfo: [NSLocalizedDescriptionKey: "API 키가 필요합니다"]) }
        guard !settings.model.trimmed.isEmpty else {
            throw NSError(
                domain: "ivLyrics.AI",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: "AI 모델을 선택하거나 모델 ID를 입력해야 합니다"]
            )
        }
        var lastError: Error?
        for apiKey in keys {
            for attempt in 0..<2 {
                do {
                    return try await callProviderRawOnce(prompt: prompt, settings: settings, apiKey: apiKey)
                } catch let error as HTTPStatusError {
                    lastError = error
                    if error.statusCode == 401 { throw error }
                    if error.statusCode == 403 || error.statusCode == 429 { break }
                    if attempt == 1 { throw error }
                    try await Task.sleep(nanoseconds: UInt64(900_000_000 * (attempt + 1)))
                } catch {
                    lastError = error
                    if attempt == 1 { throw error }
                    try await Task.sleep(nanoseconds: UInt64(900_000_000 * (attempt + 1)))
                }
            }
        }
        throw lastError ?? NSError(domain: "ivLyrics.AI", code: -2, userInfo: [NSLocalizedDescriptionKey: "AI 제공자 요청 실패"])
    }

    private func callProviderRawOnce(prompt: String, settings: AppSettings.Snapshot, apiKey: String) async throws -> String {
        switch settings.provider.id {
        case "gemini":
            return try await callGemini(prompt: prompt, settings: settings, apiKey: apiKey)
        case "claude":
            return try await callClaude(prompt: prompt, settings: settings, apiKey: apiKey)
        default:
            return try await callOpenAiCompatible(prompt: prompt, settings: settings, apiKey: apiKey)
        }
    }

    private func loadSupplementValuesStreamFirst(
        prompt: String,
        settings: AppSettings.Snapshot,
        requests: [SupplementRequest],
        taskName: String,
        log: (String) -> Void,
        onRow: ((Int, String) async -> Void)? = nil
    ) async throws -> [String] {
        let expectedLineCount = requests.count
        let accumulator = TaggedTextStreamAccumulator(expectedLineCount: expectedLineCount)
        do {
            let raw = try await callProviderStreamRaw(prompt: prompt, settings: settings) { delta in
                let rows = accumulator.append(delta) { [weak self] rawLine in
                    self?.streamRow(from: rawLine)
                }
                for row in rows {
                    await onRow?(row.index, row.value)
                }
            }
            for row in accumulator.finish(parse: { [weak self] rawLine in self?.streamRow(from: rawLine) }) {
                await onRow?(row.index, row.value)
            }
            if accumulator.duplicateCount > 0 {
                log("ai \(taskName) stream alignment: duplicate IDs ignored=\(accumulator.duplicateCount)")
            }
            if accumulator.matchedCount > 0 {
                log("ai \(taskName) stream rows=\(accumulator.matchedCount)/\(expectedLineCount)")
            }
            return parseTaggedTextLines(raw, expectedLineCount: expectedLineCount, taskName: taskName, log: log)
        } catch {
            log("ai \(taskName) stream fallback: \(error.localizedDescription)")
            let raw = try await callProviderRaw(prompt: prompt, settings: settings)
            return parseTaggedTextLines(raw, expectedLineCount: expectedLineCount, taskName: taskName, log: log)
        }
    }

    private func callProviderStreamRaw(
        prompt: String,
        settings: AppSettings.Snapshot,
        onDelta: ((String) async -> Void)? = nil
    ) async throws -> String {
        let keys = providerApiKeys(settings)
        guard !keys.isEmpty else { throw NSError(domain: "ivLyrics.AI", code: -1, userInfo: [NSLocalizedDescriptionKey: "API 키가 필요합니다"]) }
        guard !settings.model.trimmed.isEmpty else {
            throw NSError(
                domain: "ivLyrics.AI",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: "AI 모델을 선택하거나 모델 ID를 입력해야 합니다"]
            )
        }
        var lastError: Error?
        for apiKey in keys {
            for attempt in 0..<2 {
                do {
                    return try await callProviderStreamRawOnce(prompt: prompt, settings: settings, apiKey: apiKey, onDelta: onDelta)
                } catch let error as HTTPStatusError {
                    lastError = error
                    if error.statusCode == 401 { throw error }
                    if error.statusCode == 403 || error.statusCode == 429 { break }
                    if attempt == 1 { throw error }
                    try await Task.sleep(nanoseconds: UInt64(900_000_000 * (attempt + 1)))
                } catch {
                    lastError = error
                    if attempt == 1 { throw error }
                    try await Task.sleep(nanoseconds: UInt64(900_000_000 * (attempt + 1)))
                }
            }
        }
        throw lastError ?? NSError(domain: "ivLyrics.AI", code: -2, userInfo: [NSLocalizedDescriptionKey: "AI 제공자 스트림 요청 실패"])
    }

    private func callProviderStreamRawOnce(
        prompt: String,
        settings: AppSettings.Snapshot,
        apiKey: String,
        onDelta: ((String) async -> Void)? = nil
    ) async throws -> String {
        switch settings.provider.id {
        case "gemini":
            return try await callGeminiStream(prompt: prompt, settings: settings, apiKey: apiKey, onDelta: onDelta)
        case "claude":
            return try await callClaudeStream(prompt: prompt, settings: settings, apiKey: apiKey, onDelta: onDelta)
        default:
            return try await callOpenAiCompatibleStream(prompt: prompt, settings: settings, apiKey: apiKey, onDelta: onDelta)
        }
    }

    private func callGemini(prompt: String, settings: AppSettings.Snapshot, apiKey: String) async throws -> String {
        let endpoint = trimRight(settings.baseUrl, "/") + "/models/" + urlPath(settings.model) + ":generateContent?key=" + IvLyricsUtilities.urlEncode(apiKey)
        let body = geminiBody(prompt: prompt, settings: settings)
        let response = try await postJson(endpoint, body: body, headers: ["Content-Type": "application/json"])
        let root = try jsonObject(response)
        let candidates = root["candidates"] as? [[String: Any]] ?? []
        let parts = ((candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.trimmed.isEmpty else { throw NSError(domain: "ivLyrics.AI", code: -3, userInfo: [NSLocalizedDescriptionKey: "[Gemini] Empty response from API"]) }
        return text
    }

    private func callGeminiStream(
        prompt: String,
        settings: AppSettings.Snapshot,
        apiKey: String,
        onDelta: ((String) async -> Void)? = nil
    ) async throws -> String {
        let endpoint = trimRight(settings.baseUrl, "/") + "/models/" + urlPath(settings.model) + ":streamGenerateContent?alt=sse&key=" + IvLyricsUtilities.urlEncode(apiKey)
        return try await postJsonSse(endpoint, body: geminiBody(prompt: prompt, settings: settings), headers: ["Content-Type": "application/json"], onDelta: onDelta) { _, data in
            guard !data.trimmed.isEmpty, data.trimmed != "[DONE]" else { return "" }
            let root = try jsonObject(data)
            let candidates = root["candidates"] as? [[String: Any]] ?? []
            let parts = ((candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
            return parts.compactMap { $0["text"] as? String }.joined()
        }
    }

    private func geminiBody(prompt: String, settings: AppSettings.Snapshot) -> [String: Any] {
        [
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": prompt]]
                ]
            ],
            "generationConfig": [
                "maxOutputTokens": settings.maxTokens,
                "temperature": settings.temperature,
                "thinkingConfig": ["thinkingBudget": 0]
            ]
        ]
    }

    private func callClaude(prompt: String, settings: AppSettings.Snapshot, apiKey: String) async throws -> String {
        let endpoint = trimRight(settings.baseUrl, "/") + "/messages"
        let response = try await postJson(endpoint, body: claudeBody(prompt: prompt, settings: settings), headers: claudeHeaders(apiKey: apiKey))
        let root = try jsonObject(response)
        let content = root["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { $0["text"] as? String }.joined()
        guard !text.trimmed.isEmpty else { throw NSError(domain: "ivLyrics.AI", code: -4, userInfo: [NSLocalizedDescriptionKey: "[Claude] Empty response from API"]) }
        return text
    }

    private func callClaudeStream(
        prompt: String,
        settings: AppSettings.Snapshot,
        apiKey: String,
        onDelta: ((String) async -> Void)? = nil
    ) async throws -> String {
        let endpoint = trimRight(settings.baseUrl, "/") + "/messages"
        var body = claudeBody(prompt: prompt, settings: settings)
        body["stream"] = true
        return try await postJsonSse(endpoint, body: body, headers: claudeHeaders(apiKey: apiKey), onDelta: onDelta) { eventName, data in
            guard !data.trimmed.isEmpty, data.trimmed != "[DONE]" else { return "" }
            let root = try jsonObject(data)
            let type = stringValue(root["type"]).isEmpty ? eventName : stringValue(root["type"])
            guard type == "content_block_delta" else { return "" }
            let delta = root["delta"] as? [String: Any]
            return stringValue(delta?["text"])
        }
    }

    private func claudeBody(prompt: String, settings: AppSettings.Snapshot) -> [String: Any] {
        [
            "model": settings.model,
            "max_tokens": settings.maxTokens,
            "temperature": settings.temperature,
            "messages": [["role": "user", "content": prompt]]
        ]
    }

    private func claudeHeaders(apiKey: String) -> [String: String] {
        [
            "Content-Type": "application/json",
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01"
        ]
    }

    private func callOpenAiCompatible(prompt: String, settings: AppSettings.Snapshot, apiKey: String) async throws -> String {
        let endpoint = openAiEndpoint(settings)
        let response = try await postJson(endpoint, body: openAiCompatibleBody(prompt: prompt, settings: settings), headers: openAiCompatibleHeaders(settings: settings, apiKey: apiKey))
        let root = try jsonObject(response)
        let choices = root["choices"] as? [[String: Any]] ?? []
        let message = choices.first?["message"] as? [String: Any]
        let text = extractOpenAiContent(message?["content"])
        guard !text.trimmed.isEmpty else { throw NSError(domain: "ivLyrics.AI", code: -5, userInfo: [NSLocalizedDescriptionKey: "[\(settings.provider.label)] Empty response from API"]) }
        return text
    }

    private func callOpenAiCompatibleStream(
        prompt: String,
        settings: AppSettings.Snapshot,
        apiKey: String,
        onDelta: ((String) async -> Void)? = nil
    ) async throws -> String {
        let endpoint = openAiEndpoint(settings)
        var body = openAiCompatibleBody(prompt: prompt, settings: settings)
        body["stream"] = true
        return try await postJsonSse(endpoint, body: body, headers: openAiCompatibleHeaders(settings: settings, apiKey: apiKey), onDelta: onDelta) { _, data in
            guard !data.trimmed.isEmpty, data.trimmed != "[DONE]" else { return "" }
            let root = try jsonObject(data)
            let choices = root["choices"] as? [[String: Any]] ?? []
            let choice = choices.first
            if let delta = choice?["delta"] as? [String: Any] {
                return extractOpenAiContent(delta["content"])
            }
            let message = choice?["message"] as? [String: Any]
            return extractOpenAiContent(message?["content"])
        }
    }

    private func openAiCompatibleBody(prompt: String, settings: AppSettings.Snapshot) -> [String: Any] {
        var body: [String: Any] = [
            "model": settings.model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": settings.temperature
        ]
        body[tokenField(settings.provider.id)] = settings.maxTokens
        return body
    }

    private func openAiCompatibleHeaders(settings: AppSettings.Snapshot, apiKey: String) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "Authorization": "Bearer \(apiKey)"
        ]
        if settings.provider.id == "openrouter" {
            headers["HTTP-Referer"] = "https://github.com/ivLis-STUDIO/ivLyrics"
            headers["X-Title"] = "ivLyrics"
        }
        return headers
    }

    private func buildTranslationPrompt(requests: [SupplementRequest], lang: String) -> String {
        let langInfo = AppSettings.languageInfo(lang)
        let lineCount = requests.count
        return """
        You are a lyrics translator. Translate these \(lineCount) indexed rows of song lyrics into \(langInfo.name) (\(langInfo.nativeName)).

        CRITICAL RULES:
        - This is a TRANSLATION task - translate the MEANING of each line
        - Output must be written in \(langInfo.name) (\(langInfo.nativeName)) only
        - Do NOT output the original lyrics unchanged
        - Do NOT output romanization or pronunciation instead of translation
        - Input rows are ID-tagged as L0001, L0002, etc. Treat each ID as an immutable timing anchor
        - Output EXACTLY \(lineCount) rows, one output row for every input row
        - Preserve every row ID exactly and keep the same order
        - Output format must be: L0001<TAB>translated text
        - Row L000N in the output must translate ONLY row L000N from the input
        - Never merge adjacent rows, even if the sentence continues across rows
        - Never split one row into multiple rows, even if the translation is long
        - Never move a translation to the previous or next row
        - If an input row is a short fragment, translate that fragment on the same ID; do not complete it using neighboring rows
        - If an input row contains " / " between simultaneous vocal parts, preserve " / " and translate each part separately
        - If an input row is empty or untranslatable, output the same ID followed by a tab and nothing else
        - Keep music symbols and markers like [Chorus], (Yeah) as-is
        - Do NOT add extra row IDs, line numbers, prefixes, or explanations
        - Do NOT use JSON or code blocks
        - Just output the ID-tagged translated rows, nothing else

        INPUT_ROWS (tab-separated ID and source text):
        \(buildTaggedPayload(requests))

        ID alignment example (format only; use the target language above for the real output):
        Input:
        L0001\t生きていることとは
        L0002\t変わり続けることだ

        Correct output:
        L0001\t살아 있다는 것은
        L0002\t계속 변해 가는 것이다

        Wrong output:
        L0001\t살아 있다는 것은 계속 변해 가는 것이다
        L0002\t

        OUTPUT_ROWS (\(lineCount) rows, same IDs, tab-separated):
        """
    }

    private func buildPhoneticPrompt(requests: [SupplementRequest], lang: String) -> String {
        let langInfo = AppSettings.languageInfo(lang)
        let lineCount = requests.count
        let scriptInstruction = phoneticScriptInstruction(lang)
        let outputScript = pronunciationOutputScript(lang, langInfo: langInfo)
        return """
        You are a pronunciation converter. Convert these \(lineCount) indexed rows of lyrics into how they SOUND (pronunciation) for \(langInfo.name) speakers.
        \(scriptInstruction)

        CRITICAL RULES:
        - This is a PRONUNCIATION task, NOT a translation task
        - Output how each line SOUNDS when spoken aloud, written ONLY in \(outputScript)
        - Never use the input language's original script unless it is also \(outputScript)
        - Do NOT translate the meaning of the lyrics
        - Do NOT output the original lyrics unchanged
        - Input rows are ID-tagged as L0001, L0002, etc. Treat each ID as an immutable timing anchor
        - Output EXACTLY \(lineCount) rows, one output row for every input row
        - Preserve every row ID exactly and keep the same order
        - Output format must be: L0001<TAB>pronunciation text
        - Row L000N in the output must convert ONLY row L000N from the input
        - Never merge adjacent rows, even if the phrase continues across rows
        - Never split one row into multiple rows
        - Never move pronunciation to the previous or next row
        - If an input row is a short fragment, convert that fragment on the same ID; do not complete it using neighboring rows
        - If an input row contains " / " between simultaneous vocal parts, preserve " / " and convert each part separately
        - If an input row is empty or unpronounceable, output the same ID followed by a tab and nothing else
        - Keep music symbols and markers like [Chorus], (Yeah) as-is
        - Do NOT add extra row IDs, line numbers, prefixes, or explanations
        - Do NOT use JSON or code blocks
        - Just output the ID-tagged pronunciation rows, nothing else

        INPUT_ROWS (tab-separated ID and source text):
        \(buildTaggedPayload(requests))

        ID alignment example (format only; use the requested pronunciation script above for the real output):
        Input:
        L0001\t生きていることとは
        L0002\t変わり続けることだ

        Correct output for Korean pronunciation:
        L0001\t이키테이루 코토토와
        L0002\t카와리 츠즈케루 코토다

        Wrong output:
        L0001\t이키테이루 코토토와 카와리 츠즈케루 코토다
        L0002\t

        OUTPUT_ROWS (\(lineCount) rows, same IDs, tab-separated pronunciation only):
        """
    }

    private func buildMetadataTranslationPrompt(title: String, artist: String, lang: String) -> String {
        let langInfo = AppSettings.languageInfo(lang)
        return """
        You translate music metadata for a now-playing screen.
        Target language: \(langInfo.name) (\(langInfo.nativeName)).

        CRITICAL RULES:
        - Output exactly two lines and nothing else
        - Line 1: translated or localized song title
        - Line 2: localized artist display name
        - For the song title, translate the meaning naturally into the target language
        - For the artist, use a commonly known target-language name if it exists; otherwise use a natural phonetic transliteration
        - Do not add labels like Title: or Artist:
        - Do not add explanations, JSON, markdown, or code blocks
        - If a field should remain unchanged, repeat it unchanged on its line

        TITLE:
        \(title.trimmed)

        ARTIST:
        \(artist.trimmed)

        OUTPUT (2 lines):
        """
    }

    private func buildTmiPrompt(title: String, artist: String, lang: String) -> String {
        let langInfo = AppSettings.languageInfo(lang)
        return """
        You are a music knowledge expert. Generate interesting facts and trivia about the song "\(title.trimmed)" by "\(artist.trimmed)".

        LANGUAGE REQUIREMENT - FOLLOW STRICTLY:
        - Write ALL human-readable content in \(langInfo.name) (\(langInfo.nativeName))
        - This includes track.description and every string inside track.trivia
        - Do NOT write explanatory sentences in English unless the target language itself is English
        - Even if the song title, artist name, album, or source pages are English, your explanation sentences must still be in \(langInfo.nativeName)
        - The only text that may remain non-\(langInfo.nativeName) is:
          1. JSON keys
          2. URLs
          3. Proper nouns, official song titles, artist names, album names, and short quoted lyric fragments
          4. reliability.confidence enum values: "very_high", "high", "medium", "low", "none"

        Before returning, silently verify:
        - track.description is fully written in \(langInfo.nativeName)
        - every item in track.trivia is fully written in \(langInfo.nativeName)
        - if any sentence is mostly English, rewrite it into natural \(langInfo.nativeName) before returning

        Return ONLY valid JSON. Do not add any text before or after the JSON.

        **Output JSON Structure**:
        {
          "track": {
            "description": "2-3 sentence description in \(langInfo.nativeName)",
            "trivia": [
              "Fact 1 in \(langInfo.nativeName)",
              "Fact 2 in \(langInfo.nativeName)",
              "Fact 3 in \(langInfo.nativeName)"
            ],
            "sources": {
              "verified": [],
              "related": [],
              "other": []
            },
            "reliability": {
              "confidence": "medium",
              "has_verified_sources": false,
              "verified_source_count": 0,
              "related_source_count": 0,
              "total_source_count": 0
            }
          }
        }

        **Rules**:
        1. description: write 2-3 natural sentences in \(langInfo.nativeName)
        2. trivia: include 3-5 concise facts, each written in \(langInfo.nativeName)
        3. Prefer natural \(langInfo.nativeName) wording, not mixed-language fragments
        4. Be accurate - if you're not sure about a fact, mark confidence as "low"
        5. Do NOT use markdown code blocks
        6. Do NOT add any explanation outside the JSON
        """
    }

    private func parseTmiInfo(raw: String, targetLang: String) throws -> TmiInfo {
        let root = try parseJsonObjectResponse(raw)
        let track = (root["track"] as? [String: Any]) ?? root
        let sources = track["sources"] as? [String: Any]
        let reliability = track["reliability"] as? [String: Any]
        let verifiedSources = parseTmiSources(sources?["verified"] as? [Any])
        let relatedSources = parseTmiSources(sources?["related"] as? [Any])
        let otherSources = parseTmiSources(sources?["other"] as? [Any])
        let fallbackTotalSources = verifiedSources.count + relatedSources.count + otherSources.count
        let totalSources = intValue(reliability?["total_source_count"], fallback: fallbackTotalSources)
        return TmiInfo(
            description: stringValue(track["description"]),
            trivia: parseStringArray(track["trivia"] as? [Any]),
            verifiedSources: verifiedSources,
            relatedSources: relatedSources,
            otherSources: otherSources,
            confidence: stringValue(reliability?["confidence"]),
            hasVerifiedSources: boolValue(reliability?["has_verified_sources"], fallback: !verifiedSources.isEmpty),
            verifiedSourceCount: intValue(reliability?["verified_source_count"], fallback: verifiedSources.count),
            relatedSourceCount: intValue(reliability?["related_source_count"], fallback: relatedSources.count),
            totalSourceCount: totalSources,
            targetLang: targetLang
        )
    }

    private func cachedResult(_ key: String) -> LyricsResult? {
        if let cached = memoryCache[key] {
            return cached
        }
        if let cached = diskCache.get(key) {
            memoryCache[key] = cached
            return cached
        }
        return nil
    }

    private func cacheResult(_ key: String, result: LyricsResult) {
        guard !key.trimmed.isEmpty, !result.lines.isEmpty else { return }
        memoryCache[key] = result
        diskCache.put(key, result: result)
    }

    private func withBaseContributors(_ result: LyricsResult, baseResult: LyricsResult) -> LyricsResult {
        guard result.contributors != baseResult.contributors else { return result }
        return LyricsResult(
            lines: result.lines,
            providerLabel: result.providerLabel,
            detail: result.detail,
            karaoke: result.karaoke,
            isrc: result.isrc,
            spotifyTrackId: result.spotifyTrackId,
            contributors: baseResult.contributors,
            providerId: baseResult.providerId,
            selectionPolicyKey: baseResult.selectionPolicyKey
        )
    }

    private func supplementTaskCacheKey(
        trackKey: String,
        detectedSourceLang: String,
        sourceLang: String,
        settings: AppSettings.Snapshot,
        textPayload: String,
        task: String,
        outputLang: String
    ) -> String {
        trackKey
            + "|source=\(sourceLang)"
            + "|detected=\(detectedSourceLang)"
            + "|prompt=\(supplementPromptVersion)"
            + "|task=\(task)"
            + "|provider=\(settings.provider.id)"
            + "|model=\(settings.model)"
            + "|url=\(settings.baseUrl)"
            + "|tok=\(settings.maxTokens)"
            + "|temp=\(settings.temperature)"
            + "|output=\(outputLang)"
            + "|text=\(IvLyricsUtilities.sha256(textPayload))"
    }

    private func buildTaskResult(
        baseResult: LyricsResult,
        requests: [SupplementRequest],
        values: [String],
        pronunciation: Bool
    ) -> LyricsResult {
        var byLine: [Int: [SupplementResult]] = [:]
        for index in requests.indices {
            let request = requests[index]
            byLine[request.lineIndex, default: []].append(SupplementResult(
                request: request,
                pronunciation: pronunciation ? valueAt(values, index) : "",
                translation: pronunciation ? "" : valueAt(values, index)
            ))
        }
        let merged = baseResult.lines.enumerated().map { index, line in
            mergeSupplementLine(line, results: byLine[index])
        }
        return LyricsResult(
            lines: merged,
            providerLabel: baseResult.providerLabel,
            detail: baseResult.detail,
            karaoke: baseResult.karaoke,
            isrc: baseResult.isrc,
            spotifyTrackId: baseResult.spotifyTrackId,
            contributors: baseResult.contributors,
            providerId: baseResult.providerId,
            selectionPolicyKey: baseResult.selectionPolicyKey
        )
    }

    private func extractSupplementValues(
        _ result: LyricsResult,
        requests: [SupplementRequest],
        pronunciation: Bool
    ) -> [String] {
        guard !requests.isEmpty else { return [] }
        return requests.map { request in
            guard request.lineIndex >= 0, request.lineIndex < result.lines.count else { return "" }
            let line = result.lines[request.lineIndex]
            if request.partIndex >= 0, request.partIndex < line.vocalParts.count {
                let part = line.vocalParts[request.partIndex]
                return pronunciation ? part.pronunciationText : part.translationText
            }
            return pronunciation ? line.pronunciationText : line.translationText
        }
    }

    private func buildMergedSupplementResult(
        baseResult: LyricsResult,
        requests: [SupplementRequest],
        pronunciation: [String],
        translation: [String],
        settings: AppSettings.Snapshot,
        sourceLang: String,
        targetLang: String,
        pronunciationLang: String,
        rule: AppSettings.LanguageRule,
        translationSkipped: Bool
    ) -> LyricsResult {
        var byLine: [Int: [SupplementResult]] = [:]
        for index in requests.indices {
            let request = requests[index]
            byLine[request.lineIndex, default: []].append(SupplementResult(
                request: request,
                pronunciation: valueAt(pronunciation, index),
                translation: valueAt(translation, index)
            ))
        }

        let merged = baseResult.lines.enumerated().map { index, line in
            mergeSupplementLine(line, results: byLine[index])
        }
        let pronunciationApplied = rule.pronunciationEnabled && !pronunciation.isEmpty
        let translationApplied = rule.translationEnabled && !translationSkipped && !translation.isEmpty
        let taskLabel = translationSkipped
            ? (pronunciationApplied ? "translation skipped, pronunciation" : "translation skipped")
            : (translationApplied && pronunciationApplied ? "translation/pronunciation" : (translationApplied ? "translation" : (pronunciationApplied ? "pronunciation" : "none")))
        let detail = baseResult.detail + " AI \(settings.provider.label) \(taskLabel) applied. source=\(sourceLang), pronunciation=\(pronunciationLang), target=\(targetLang)."
        return LyricsResult(
            lines: merged,
            providerLabel: baseResult.providerLabel,
            detail: detail,
            karaoke: baseResult.karaoke,
            isrc: baseResult.isrc,
            spotifyTrackId: baseResult.spotifyTrackId,
            contributors: baseResult.contributors,
            providerId: baseResult.providerId,
            selectionPolicyKey: baseResult.selectionPolicyKey
        )
    }

    private func mergeSupplementLine(_ line: LyricsLine, results: [SupplementResult]?) -> LyricsLine {
        guard let results, !results.isEmpty else { return line }
        let pronunciationText = joinSupplementResults(results, pronunciation: true)
        let translationText = joinSupplementResults(results, pronunciation: false)
        guard !line.vocalParts.isEmpty else {
            return line.withSupplements(pronunciation: pronunciationText, translation: translationText)
        }
        var parts = line.vocalParts
        var changedPart = false
        for result in results {
            let partIndex = result.request.partIndex
            guard partIndex >= 0, partIndex < parts.count else { continue }
            let part = parts[partIndex]
            parts[partIndex] = part.withSupplements(pronunciation: result.pronunciation, translation: result.translation)
            changedPart = true
        }
        if !changedPart {
            return line.withSupplements(pronunciation: pronunciationText, translation: translationText)
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
            pronunciationText: pronunciationText,
            translationText: translationText,
            furiganaText: line.furiganaText
        )
    }

    private func joinSupplementResults(_ results: [SupplementResult], pronunciation: Bool) -> String {
        results.map { pronunciation ? $0.pronunciation : $0.translation }
            .map(\.trimmed)
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
    }

    private func buildSupplementRequests(_ lines: [LyricsLine]) -> [SupplementRequest] {
        var requests: [SupplementRequest] = []
        for (lineIndex, line) in lines.enumerated() {
            let vocalRequests = displayedVocalPartRequests(line, lineIndex: lineIndex)
            if vocalRequests.count > 1 {
                requests.append(contentsOf: vocalRequests)
            } else {
                requests.append(SupplementRequest(lineIndex: lineIndex, partIndex: -1, text: displayLineText(line)))
            }
        }
        return requests
    }

    private func displayedVocalPartRequests(_ line: LyricsLine, lineIndex: Int) -> [SupplementRequest] {
        guard !line.vocalParts.isEmpty else { return [] }
        var requests: [SupplementRequest] = []
        for (index, part) in line.vocalParts.enumerated() where part.role == "lead" {
            let text = displayPartText(part)
            if !text.isEmpty { requests.append(SupplementRequest(lineIndex: lineIndex, partIndex: index, text: text)) }
        }
        for (index, part) in line.vocalParts.enumerated() where part.role != "lead" {
            let text = displayPartText(part)
            if !text.isEmpty { requests.append(SupplementRequest(lineIndex: lineIndex, partIndex: index, text: text)) }
        }
        return requests
    }

    private func displayLineText(_ line: LyricsLine) -> String {
        if !line.text.trimmed.isEmpty { return line.text.trimmed }
        return line.vocalParts.map { $0.text.trimmed }.filter { !$0.isEmpty }.joined(separator: " / ")
    }

    private func displayPartText(_ part: LyricsLine.VocalPart) -> String {
        if !part.text.trimmed.isEmpty { return part.text.trimmed }
        return part.syllables.map(\.text).joined().trimmed
    }

    private func buildCulturalAnnotationPrompt(
        lineTexts: [String],
        sourceLang: String,
        targetLang: String
    ) -> String {
        let numberedLyrics = lineTexts.enumerated().map { index, text in
            "L\(index)\t\(promptRowText(text))"
        }.joined(separator: "\n")
        return """
        Analyze the lyrics line by line for a reader whose language is \(targetLang).
        The source language is \(sourceLang).

        Find ONLY expressions that cannot be understood from a normal translation without specific cultural background knowledge. Valid cases include a local institution or custom, traditional game, historical or religious implication, or a clearly identifiable quotation or parody.

        Be extremely strict:
        - Do not explain ordinary words, slang, conversational phrasing, code-switching, English weekdays, generic metaphors, moods, or expressions understandable from context.
        - Do not infer a country from the language alone.
        - Mention quotations or parodies only when certain.
        - Prefer zero annotations over a weak annotation.
        - Each note must be one short sentence in \(targetLang), at most 72 characters.
        - expression must be an exact substring of that original lyric line.
        - Return at most 3 annotations per line.

        Return JSON only in this exact shape:
        {"annotations":[{"lineIndex":0,"expression":"exact original expression","note":"brief explanation"}]}
        Use zero-based lineIndex. Return {"annotations":[]} when nothing truly requires cultural knowledge.

        \(numberedLyrics)
        """
    }

    private func parseCulturalAnnotations(raw: String, lineTexts: [String]) throws -> [CulturalAnnotation] {
        let root = try parseJsonObjectResponse(raw)
        guard let values = root["annotations"] as? [Any], !lineTexts.isEmpty else { return [] }
        var result: [CulturalAnnotation] = []
        var countByLine: [Int: Int] = [:]
        var seen: Set<String> = []
        for rawValue in values {
            guard let value = rawValue as? [String: Any] else { continue }
            let lineIndex = intValue(value["lineIndex"], fallback: -1)
            guard lineTexts.indices.contains(lineIndex) else { continue }
            let expression = stringValue(value["expression"])
            let note = CulturalAnnotation.compactNote(stringValue(value["note"]))
            let dedupeKey = "\(lineIndex)\n\(expression)"
            guard !expression.isEmpty,
                  !note.isEmpty,
                  lineTexts[lineIndex].contains(expression),
                  !seen.contains(dedupeKey),
                  countByLine[lineIndex, default: 0] < 3 else {
                continue
            }
            seen.insert(dedupeKey)
            countByLine[lineIndex, default: 0] += 1
            result.append(CulturalAnnotation(lineIndex: lineIndex, expression: expression, note: note))
        }
        return result.sorted {
            if $0.lineIndex != $1.lineIndex { return $0.lineIndex < $1.lineIndex }
            let text = lineTexts[$0.lineIndex]
            let left = text.range(of: $0.expression)?.lowerBound ?? text.endIndex
            let right = text.range(of: $1.expression)?.lowerBound ?? text.endIndex
            return left < right
        }
    }

    private func buildTaggedPayload(_ requests: [SupplementRequest]) -> String {
        requests.enumerated().map { index, request in
            "\(rowId(index))\t\(promptRowText(request.text))"
        }.joined(separator: "\n")
    }

    private func rowId(_ index: Int) -> String {
        String(format: "L%04d", index + 1)
    }

    private func promptRowText(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").trimmed
    }

    nonisolated private func streamRow(from rawLine: String) -> TaggedStreamRow? {
        guard let tagged = parseTaggedOutputLine(stripCodeFences(rawLine)) else { return nil }
        return TaggedStreamRow(index: tagged.index, value: cleanSupplementOutput(tagged.value))
    }

    private func parseTaggedTextLines(_ text: String, expectedLineCount: Int, taskName: String, log: (String) -> Void) -> [String] {
        var values = Array(repeating: "", count: expectedLineCount)
        guard expectedLineCount > 0 else { return values }
        let cleaned = stripCodeFences(text)
        var seen = Array(repeating: false, count: expectedLineCount)
        var matched = 0
        var duplicate = 0
        for rawLine in cleaned.components(separatedBy: .newlines) {
            guard let tagged = parseTaggedOutputLine(rawLine), tagged.index >= 0, tagged.index < expectedLineCount else { continue }
            let value = cleanSupplementOutput(tagged.value)
            if seen[tagged.index] {
                duplicate += 1
                if values[tagged.index].trimmed.isEmpty && !value.isEmpty {
                    values[tagged.index] = value
                }
                continue
            }
            seen[tagged.index] = true
            matched += 1
            values[tagged.index] = value
        }
        if matched == expectedLineCount {
            if duplicate > 0 { log("ai \(taskName) alignment: duplicate IDs ignored=\(duplicate)") }
            return values
        }
        if matched > 0 {
            log("ai \(taskName) alignment: matched=\(matched)/\(expectedLineCount), missing rows left empty")
            return values
        }
        log("ai \(taskName) alignment: no row IDs in response, using line-count fallback")
        return parseTextLines(text, expectedLineCount: expectedLineCount)
    }

    nonisolated private func parseTaggedOutputLine(_ value: String) -> TaggedOutputLine? {
        let regex: NSRegularExpression
        if let cached = Self.taggedOutputLineRegex {
            regex = cached
        } else {
            guard let fallback = try? NSRegularExpression(
                pattern: Self.taggedOutputLinePattern,
                options: [.caseInsensitive]
            ) else {
                return nil
            }
            regex = fallback
        }
        guard let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else {
            return nil
        }
        let rawNumber = [1, 2, 3].compactMap { group(match, $0, value) }.first(where: { !$0.isEmpty }) ?? ""
        guard let number = Int(rawNumber), number > 0 else { return nil }
        return TaggedOutputLine(index: number - 1, value: group(match, 4, value) ?? "")
    }

    private func parseTextLines(_ text: String, expectedLineCount: Int) -> [String] {
        var lines = stripCodeFences(text).trimmed.components(separatedBy: .newlines)
        if lines.count == expectedLineCount { return lines }
        if lines.count > expectedLineCount { return Array(lines.suffix(expectedLineCount)) }
        while lines.count < expectedLineCount { lines.append("") }
        return lines
    }

    nonisolated private func cleanSupplementOutput(_ value: String) -> String {
        let trimmed = value.trimmed
        var cleaned: String
        if let regex = Self.supplementOutputPrefixRegex {
            cleaned = regex.stringByReplacingMatches(
                in: trimmed,
                range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed),
                withTemplate: ""
            )
        } else {
            cleaned = trimmed.regexReplacing(Self.supplementOutputPrefixPattern, with: "")
        }
        if (cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"")) || (cleaned.hasPrefix("'") && cleaned.hasSuffix("'")) {
            cleaned = String(cleaned.dropFirst().dropLast()).trimmed
        }
        let lower = cleaned.lowercased()
        if ["<empty>", "[empty]", "(empty)", "empty"].contains(lower) || cleaned == "∅" {
            return ""
        }
        return cleaned
    }

    private func cleanMetadataOutputLine(_ value: String, kind: String, fallback: String) -> String {
        let pattern = kind == "artist"
            ? #"(?i)^\s*(artist|artist name|아티스트|가수|아티스트명)\s*[:：\-]\s*"#
            : #"(?i)^\s*(title|song title|track title|제목|곡 제목|노래 제목)\s*[:：\-]\s*"#
        let cleaned = stripCodeFences(value).regexReplacing(pattern, with: "").trimmed
        return cleaned.isEmpty ? fallback.trimmed : cleaned
    }

    private func phoneticScriptInstruction(_ lang: String) -> String {
        switch AppSettings.normalizeLanguageCode(lang) {
        case "ko":
            return "Use Korean Hangul syllables only. Example: こんにちは -> 콘니치와, ありがとう -> 아리가토, hello -> 헬로. Never output Japanese kana, Chinese characters, or Latin romanization for Korean pronunciation."
        case "en":
            return "Use Latin alphabet only (romanization). Example: こんにちは -> konnichiwa, 안녕하세요 -> annyeonghaseyo. Never output Hangul, kana, or Chinese characters for English romanization."
        case "ja":
            return "Use Japanese Katakana only. Example: hello -> ハロー, 안녕하세요 -> アンニョンハセヨ. Prefer Katakana over Hiragana for foreign pronunciation guides."
        case "zh-CN":
            return "Use Simplified Chinese characters only for a Chinese pronunciation guide. Do not output Latin pinyin unless the input itself is a non-pronounceable marker."
        case "zh-TW":
            return "Use Traditional Chinese characters only for a Chinese pronunciation guide. Do not output Latin pinyin unless the input itself is a non-pronounceable marker."
        case "hi":
            return "Use Devanagari script only for Hindi pronunciation. \(AppSettings.languageInfo(lang).phoneticDescription)"
        case "es":
            return "Use Spanish spelling conventions only for pronunciation guides. Write sounds naturally for Spanish speakers using the Latin alphabet; do not translate meanings."
        case "fr":
            return "Use French spelling conventions only for pronunciation guides. Write sounds naturally for French speakers using the Latin alphabet; do not translate meanings."
        case "ar":
            return "Use Arabic script only for Arabic pronunciation. \(AppSettings.languageInfo(lang).phoneticDescription)"
        case "fa":
            return "Use Persian script only for Persian pronunciation. \(AppSettings.languageInfo(lang).phoneticDescription)"
        case "de":
            return "Use German spelling conventions only for pronunciation guides. Write sounds naturally for German speakers using the Latin alphabet; do not translate meanings."
        case "cs":
            return "Use Czech spelling conventions only for pronunciation guides. Write sounds naturally for Czech speakers using the Latin alphabet and Czech diacritics; do not translate meanings."
        case "ru":
            return "Use Cyrillic script only for Russian pronunciation. \(AppSettings.languageInfo(lang).phoneticDescription)"
        case "sv":
            return "Use Swedish spelling conventions only for pronunciation guides. Write sounds naturally for Swedish speakers using the Latin alphabet; do not translate meanings."
        case "pt":
            return "Use Portuguese spelling conventions only for pronunciation guides. Write sounds naturally for Portuguese speakers using the Latin alphabet; do not translate meanings."
        case "bn":
            return "Use Bengali script only for Bengali pronunciation. \(AppSettings.languageInfo(lang).phoneticDescription)"
        case "it":
            return "Use Italian spelling conventions only for pronunciation guides. Write sounds naturally for Italian speakers using the Latin alphabet; do not translate meanings."
        case "th":
            return "Use Thai script only for Thai pronunciation. \(AppSettings.languageInfo(lang).phoneticDescription)"
        case "vi":
            return "Use Vietnamese Quốc Ngữ spelling only for pronunciation guides. Use Vietnamese diacritics where they help pronunciation; do not translate meanings."
        case "id":
            return "Use Indonesian spelling conventions only for pronunciation guides. Write sounds naturally for Indonesian speakers using the Latin alphabet; do not translate meanings."
        case "ms":
            return "Use Malay spelling conventions only for pronunciation guides. Write sounds naturally for Malay speakers using the Latin alphabet; do not translate meanings."
        case "tr":
            return "Use Turkish spelling conventions only for pronunciation guides. Write sounds naturally for Turkish speakers using the Latin alphabet and Turkish diacritics; do not translate meanings."
        default:
            return "Write pronunciation in \(AppSettings.languageInfo(lang).nativeName) spelling. \(AppSettings.languageInfo(lang).phoneticDescription)"
        }
    }

    private func pronunciationOutputScript(_ lang: String, langInfo: AppSettings.Language) -> String {
        switch AppSettings.normalizeLanguageCode(lang) {
        case "ko": return "Korean Hangul"
        case "en": return "Latin alphabet"
        case "ja": return "Japanese Katakana"
        case "zh-CN": return "Simplified Chinese"
        case "zh-TW": return "Traditional Chinese"
        case "hi": return "Devanagari"
        case "es": return "Spanish Latin spelling"
        case "fr": return "French Latin spelling"
        case "ar": return "Arabic script"
        case "fa": return "Persian script"
        case "de": return "German Latin spelling"
        case "cs": return "Czech Latin spelling"
        case "ru": return "Cyrillic"
        case "sv": return "Swedish Latin spelling"
        case "pt": return "Portuguese Latin spelling"
        case "bn": return "Bengali script"
        case "it": return "Italian Latin spelling"
        case "th": return "Thai script"
        case "vi": return "Vietnamese Quốc Ngữ"
        case "id": return "Indonesian Latin spelling"
        case "ms": return "Malay Latin spelling"
        case "tr": return "Turkish Latin spelling"
        default: return "\(langInfo.name) pronunciation spelling"
        }
    }

    private func providerApiKeys(_ settings: AppSettings.Snapshot) -> [String] {
        var keys: [String] = []
        if settings.provider.id == "pollinations", !settings.pollinationsAccessToken.trimmed.isEmpty {
            keys.append(settings.pollinationsAccessToken.trimmed)
        }
        for key in parseApiKeys(settings.apiKeys) where !keys.contains(key) {
            keys.append(key)
        }
        return keys
    }

    private func parseApiKeys(_ raw: String) -> [String] {
        let value = raw.trimmed
        guard !value.isEmpty else { return [] }
        if value.hasPrefix("["),
           let data = value.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            return array.map { stringValue($0) }.map(\.trimmed).filter { !$0.isEmpty }
        }
        return value.split { $0 == "\n" || $0 == "," }.map { String($0).trimmed }.filter { !$0.isEmpty }
    }

    private func postJson(_ endpoint: String, body: [String: Any], headers: [String: String]) async throws -> String {
        guard let url = URL(string: endpoint) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 70)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request, delegate: nil)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPStatusError(statusCode: 0, message: "Invalid HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPStatusError(
                statusCode: http.statusCode,
                message: extractProviderErrorMessage(data, statusCode: http.statusCode)
            )
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func postJsonSse(
        _ endpoint: String,
        body: [String: Any],
        headers: [String: String],
        onDelta: ((String) async -> Void)? = nil,
        transform: (String, String) throws -> String
    ) async throws -> String {
        guard let url = URL(string: endpoint) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 70)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPStatusError(statusCode: 0, message: "Invalid HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            var responseBody = ""
            for try await line in bytes.lines {
                responseBody += line
            }
            throw HTTPStatusError(
                statusCode: http.statusCode,
                message: extractProviderErrorMessage(Data(responseBody.utf8), statusCode: http.statusCode)
            )
        }

        var raw = ""
        var eventName = ""
        var data = ""

        func flushEvent() async throws {
            let delta = try transform(eventName, data)
            if !delta.isEmpty {
                raw += delta
                await onDelta?(delta)
            }
            eventName = ""
            data = ""
        }

        for try await line in bytes.lines {
            if line.isEmpty {
                try await flushEvent()
                continue
            }
            if line.hasPrefix(":") {
                continue
            }
            if line.hasPrefix("event:") {
                eventName = String(line.dropFirst("event:".count)).trimmed
                continue
            }
            if line.hasPrefix("data:") {
                if !data.isEmpty {
                    data += "\n"
                }
                data += String(line.dropFirst("data:".count)).trimmed
            }
        }
        if !data.isEmpty {
            try await flushEvent()
        }
        guard !raw.trimmed.isEmpty else {
            throw NSError(domain: "ivLyrics.AI", code: -6, userInfo: [NSLocalizedDescriptionKey: "Streaming returned no text"])
        }
        return raw
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        return object
    }

    private func parseJsonObjectResponse(_ raw: String) throws -> [String: Any] {
        var cleaned = stripCodeFences(raw).trimmed
        if !cleaned.hasPrefix("{"),
           let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}"),
           start < end {
            cleaned = String(cleaned[start...end])
        }
        return try jsonObject(cleaned)
    }

    private func extractProviderErrorMessage(_ data: Data, statusCode: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any] {
                let message = stringValue(error["message"])
                if !message.isEmpty {
                    return "HTTP \(statusCode): \(message)"
                }
            }
            let message = stringValue(object["message"])
            if !message.isEmpty {
                return "HTTP \(statusCode): \(message)"
            }
        }
        return "HTTP \(statusCode)"
    }

    private func parseStringArray(_ value: [Any]?) -> [String] {
        guard let value else { return [] }
        return value.map { stringValue($0) }.map(\.trimmed).filter { !$0.isEmpty }
    }

    private func parseTmiSources(_ value: [Any]?) -> [TmiSource] {
        guard let value else { return [] }
        var sources: [TmiSource] = []
        for raw in value {
            let source: TmiSource?
            if let object = raw as? [String: Any] {
                source = TmiSource(
                    title: stringValue(object["title"]),
                    url: IvLyricsUtilities.firstNonEmpty(stringValue(object["uri"]), stringValue(object["url"]))
                )
            } else if let string = raw as? String {
                source = TmiSource(title: "", url: string)
            } else {
                source = nil
            }
            if let source, !source.url.isEmpty {
                sources.append(source)
            }
        }
        return sources
    }

    private func metadataTranslationFromDisk(_ cacheKey: String) -> MetadataTranslation? {
        let raw = metadataDiskCache.get(cacheKey)
        guard !raw.trimmed.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(MetadataTranslation.self, from: data)
        } catch {
            metadataDiskCache.remove(cacheKey)
            return nil
        }
    }

    private func putMetadataTranslationToDisk(cacheKey: String, translation: MetadataTranslation) {
        guard (!translation.title.trimmed.isEmpty || !translation.artist.trimmed.isEmpty),
              let data = try? JSONEncoder().encode(translation),
              let raw = String(data: data, encoding: .utf8) else {
            return
        }
        metadataDiskCache.put(cacheKey, body: raw)
    }

    private func tmiFromDisk(_ cacheKey: String) -> TmiInfo? {
        let raw = tmiDiskCache.get(cacheKey)
        guard !raw.trimmed.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(TmiInfo.self, from: data)
        } catch {
            tmiDiskCache.remove(cacheKey)
            return nil
        }
    }

    private func putTmiToDisk(cacheKey: String, info: TmiInfo) {
        guard info.hasContent,
              let data = try? JSONEncoder().encode(info),
              let raw = String(data: data, encoding: .utf8) else {
            return
        }
        tmiDiskCache.put(cacheKey, body: raw)
    }

    private func culturalAnnotationsFromDisk(_ cacheKey: String) -> [CulturalAnnotation]? {
        let raw = culturalAnnotationDiskCache.get(cacheKey)
        guard !raw.trimmed.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode([CulturalAnnotation].self, from: data)
        } catch {
            culturalAnnotationDiskCache.remove(cacheKey)
            return nil
        }
    }

    private func putCulturalAnnotationsToDisk(
        cacheKey: String,
        annotations: [CulturalAnnotation]
    ) {
        guard let data = try? JSONEncoder().encode(annotations),
              let raw = String(data: data, encoding: .utf8) else {
            return
        }
        culturalAnnotationDiskCache.put(cacheKey, body: raw)
    }

    private func stringValue(_ value: Any?) -> String {
        if let string = value as? String { return string.trimmed }
        if let number = value as? NSNumber { return number.stringValue }
        if let value { return String(describing: value).trimmed }
        return ""
    }

    private func intValue(_ value: Any?, fallback: Int) -> Int {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String, let int = Int(string.trimmed) { return int }
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

    private func extractOpenAiContent(_ content: Any?) -> String {
        if let string = content as? String { return string }
        if let array = content as? [Any] {
            return array.map { item in
                if let object = item as? [String: Any] {
                    return stringValue(object["text"])
                }
                return String(describing: item)
            }.joined()
        }
        if let content { return String(describing: content) }
        return ""
    }

    private func openAiEndpoint(_ settings: AppSettings.Snapshot) -> String {
        let base = trimRight(settings.baseUrl, "/")
        if settings.provider.id == "pollinations" {
            return base + "/v1/chat/completions"
        }
        return base + "/chat/completions"
    }

    private func tokenField(_ providerId: String) -> String {
        providerId == "chatgpt" ? "max_completion_tokens" : "max_tokens"
    }

    private func trimRight(_ value: String, _ suffix: String) -> String {
        var result = value.trimmed
        while result.hasSuffix(suffix) {
            result.removeLast(suffix.count)
        }
        return result
    }

    private func urlPath(_ value: String) -> String {
        value.trimmed.replacingOccurrences(of: " ", with: "%20")
    }

    nonisolated private func stripCodeFences(_ value: String) -> String {
        value.regexReplacing(#"(?i)```[a-z]*\s*"#, with: "").replacingOccurrences(of: "```", with: "")
    }

    nonisolated private func group(_ match: NSTextCheckingResult, _ index: Int, _ source: String) -> String? {
        guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: source) else {
            return nil
        }
        return String(source[range])
    }

    private func valueAt(_ values: [String], _ index: Int) -> String {
        index >= 0 && index < values.count ? values[index] : ""
    }

    static func detectLanguage(_ text: String) -> String {
        LyricsLanguageDetector.detect(text) ?? "en"
    }

    private struct SupplementRequest: Sendable {
        var lineIndex: Int
        var partIndex: Int
        var text: String
    }

    private struct SupplementResult {
        var request: SupplementRequest
        var pronunciation: String
        var translation: String
    }

    private struct TaggedOutputLine {
        var index: Int
        var value: String
    }

    private struct TaggedStreamRow {
        var index: Int
        var value: String
    }

    private struct SupplementTaskOutcome: Sendable {
        var logs: [String]
    }

    private struct SupplementLiveSnapshot: Sendable {
        var pronunciation: [String]
        var translation: [String]
        var pronunciationLoading: Bool
        var translationLoading: Bool
        var hadError: Bool
    }

    private actor SupplementLiveState {
        private var pronunciation: [String]
        private var translation: [String]
        private var pronunciationLoading: Bool
        private var translationLoading: Bool
        private var hadError = false

        init(
            pronunciation: [String],
            translation: [String],
            pronunciationLoading: Bool,
            translationLoading: Bool
        ) {
            self.pronunciation = pronunciation
            self.translation = translation
            self.pronunciationLoading = pronunciationLoading
            self.translationLoading = translationLoading
        }

        func setValue(task: String, index: Int, value: String) {
            if task == "pronunciation" {
                guard index >= 0, index < pronunciation.count else { return }
                pronunciation[index] = value
            } else {
                guard index >= 0, index < translation.count else { return }
                translation[index] = value
            }
        }

        func finish(task: String, values: [String]) {
            if task == "pronunciation" {
                pronunciation = values
                pronunciationLoading = false
            } else {
                translation = values
                translationLoading = false
            }
        }

        func fail(task: String) {
            hadError = true
            if task == "pronunciation" {
                pronunciationLoading = false
            } else {
                translationLoading = false
            }
        }

        func snapshot() -> SupplementLiveSnapshot {
            SupplementLiveSnapshot(
                pronunciation: pronunciation,
                translation: translation,
                pronunciationLoading: pronunciationLoading,
                translationLoading: translationLoading,
                hadError: hadError
            )
        }
    }

    private final class TaggedTextStreamAccumulator {
        private let expectedLineCount: Int
        private var seen: [Bool]
        private var pending = ""
        private(set) var matchedCount = 0
        private(set) var duplicateCount = 0

        init(expectedLineCount: Int) {
            self.expectedLineCount = max(0, expectedLineCount)
            self.seen = Array(repeating: false, count: max(0, expectedLineCount))
        }

        func append(_ delta: String, parse: (String) -> TaggedStreamRow?) -> [TaggedStreamRow] {
            guard !delta.isEmpty, expectedLineCount > 0 else { return [] }
            pending += delta
            return drain(flush: false, parse: parse)
        }

        func finish(parse: (String) -> TaggedStreamRow?) -> [TaggedStreamRow] {
            drain(flush: true, parse: parse)
        }

        private func drain(flush: Bool, parse: (String) -> TaggedStreamRow?) -> [TaggedStreamRow] {
            var rows: [TaggedStreamRow] = []
            while let newline = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                let line = String(pending[..<newline])
                var removeEnd = pending.index(after: newline)
                if pending[newline] == "\r", removeEnd < pending.endIndex, pending[removeEnd] == "\n" {
                    removeEnd = pending.index(after: removeEnd)
                }
                pending.removeSubrange(..<removeEnd)
                if let row = emitLine(line, parse: parse) {
                    rows.append(row)
                }
            }
            if flush, !pending.isEmpty {
                let line = pending
                pending = ""
                if let row = emitLine(line, parse: parse) {
                    rows.append(row)
                }
            }
            return rows
        }

        private func emitLine(_ rawLine: String, parse: (String) -> TaggedStreamRow?) -> TaggedStreamRow? {
            guard let row = parse(rawLine), row.index >= 0, row.index < expectedLineCount else { return nil }
            if seen[row.index] {
                duplicateCount += 1
                return nil
            }
            seen[row.index] = true
            matchedCount += 1
            return row
        }
    }
}
