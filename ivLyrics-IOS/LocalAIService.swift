import Foundation

/// One loaded model. Calls block; LocalAIService makes them one at a time on its engine queue.
protocol LocalAIInferenceEngine: AnyObject, Sendable {
    /// "GPU" or "CPU", shown as "Ready · {device}".
    var deviceLabel: String { get }
    var usesGPU: Bool { get }
    /// Runs the model on one user message. Throws CancellationError when shouldStop() turns true.
    func complete(prompt: String, maxTokens: Int, shouldStop: () -> Bool) throws -> LocalAI.Completion
}

/// Loads a model file. Runs on the engine queue and may take seconds.
typealias LocalAIEngineLoader = @Sendable (_ modelURL: URL, _ processor: LocalAI.Processor) throws -> any LocalAIInferenceEngine

extension LocalAI {
    enum Phase: Equatable, Sendable {
        case missing, downloading, downloaded, loading, ready, error
    }

    /// Status shared by the settings card and the engine.
    struct State: Equatable, Sendable {
        var revision = 0
        var downloadedTiers: Set<Tier> = []
        var downloadingTier: Tier?
        var loadedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var loadingTier: Tier?
        var readyTier: Tier?
        var device: String?
        var errorTier: Tier?
        /// English diagnostic for logs and checks; the card shows `failure` instead.
        var error: String?
        /// The same failure for the settings card, without engine details, file names or URLs.
        var failure: Failure?

        func phase(for tier: Tier) -> Phase {
            if downloadingTier == tier { return .downloading }
            if loadingTier == tier { return .loading }
            if readyTier == tier { return .ready }
            if errorTier == tier, error != nil { return .error }
            return downloadedTiers.contains(tier) ? .downloaded : .missing
        }
    }

    struct TestResult: Equatable, Sendable {
        var sample: String
        var line: String
        var seconds: Double
    }

    /// A failure the app can explain in its UI language.
    enum Failure: Equatable, Sendable {
        /// Already localized through LocalAI.Messages.
        case message(String)
        case unavailable, background, memoryPressure, emptyReply, promptTooLong
        case modelLoadFailed, outOfMemory, engine
        case downloadStatus(Int), downloadDamaged, network, storageFull
        case unknown

        init(_ error: Error) {
            switch error {
            case let error as LocalAIError:
                switch error {
                case let .notReady(message), let .downloadBusy(message), let .unsupportedLanguage(message):
                    self = .message(message)
                case .unavailable: self = .unavailable
                case .background: self = .background
                case .memoryPressure: self = .memoryPressure
                case .emptyReply: self = .emptyReply
                case .promptTooLong: self = .promptTooLong
                case .modelLoadFailed: self = .modelLoadFailed
                case .outOfMemory: self = .outOfMemory
                case .engine: self = .engine
                }
            case let error as LocalAIDownloadError:
                switch error {
                case let .httpStatus(status): self = .downloadStatus(status)
                case .sizeMismatch, .invalidFile: self = .downloadDamaged
                }
            case let error as CocoaError where error.code == .fileWriteOutOfSpace:
                self = .storageFull
            case let error as POSIXError where error.code == .ENOSPC:
                self = .storageFull
            case is URLError:
                self = .network
            default:
                self = .unknown
            }
        }
    }
}

/// Flags that a running generation reads on the engine queue.
final class LocalAIRunGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var interruptions = 0

    /// False while the app is in the background, where iOS refuses GPU work.
    var appActive: Bool {
        get { lock.lock(); defer { lock.unlock() }; return active }
        set { lock.lock(); active = newValue; lock.unlock() }
    }

    /// Changes when the system asks to release memory.
    var interruption: Int {
        lock.lock(); defer { lock.unlock() }
        return interruptions
    }

    func interrupt() {
        lock.lock(); interruptions += 1; lock.unlock()
    }
}

final class LocalAICancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

/// Owns the single engine instance. Requests are serialized block by block; lyrics on screen run
/// before prefetching for upcoming songs. A request never downloads: without the selected tier's
/// file it fails at once so the next provider translates.
actor LocalAIService {
    enum Priority: Sendable {
        /// Lyrics on screen (the caller shows lines as they finish).
        case interactive
        /// Prefetching for upcoming songs.
        case background
    }

    private struct Job {
        let id: UUID
        let run: () async -> Void
        let fail: (Error) -> Void
    }

    let directory: URL
    nonisolated let gate = LocalAIRunGate()
    private let loader: LocalAIEngineLoader?
    private let sleeper: @Sendable (Double) async throws -> Void
    private let downloader: LocalAIDownloader
    private let engineQueue = DispatchQueue(label: "ivLyrics.LocalAI.engine", qos: .userInitiated)

    private var engine: (any LocalAIInferenceEngine)?
    private var engineTier: LocalAI.Tier?
    private var engineProcessor: LocalAI.Processor?
    private var state = LocalAI.State()
    private var observer: (@Sendable (LocalAI.State) -> Void)?

    private var interactiveJobs: [Job] = []
    private var backgroundJobs: [Job] = []
    private var pumping = false
    private var releaseAfterJob = false
    private var idleMinutes = LocalAI.defaultIdleMinutes
    private var idleTask: Task<Void, Never>?
    private var idleToken = 0
    private var downloadTask: Task<Void, Never>?

    /// - Parameters:
    ///   - loader: nil when this build has no engine (iOS Simulator); requests then fail.
    ///   - sleeper: waits the idle time in seconds (replaceable in tests).
    init(
        directory: URL,
        loader: LocalAIEngineLoader?,
        sessionConfiguration: URLSessionConfiguration? = nil,
        sleeper: @escaping @Sendable (Double) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.directory = directory
        self.loader = loader
        self.sleeper = sleeper
        downloader = LocalAIDownloader(configuration: sessionConfiguration)
    }

    static var defaultDirectory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("LocalAI", isDirectory: true)
    }

    nonisolated func modelURL(for tier: LocalAI.Tier) -> URL {
        directory.appendingPathComponent(tier.fileName, isDirectory: false)
    }

    nonisolated func partialURL(for tier: LocalAI.Tier) -> URL {
        directory.appendingPathComponent(tier.fileName + ".part", isDirectory: false)
    }

    nonisolated func isDownloaded(_ tier: LocalAI.Tier) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: modelURL(for: tier).path)
        return (attributes?[.size] as? NSNumber)?.int64Value == tier.byteCount
    }

    // MARK: Status

    func setObserver(_ observer: (@Sendable (LocalAI.State) -> Void)?) {
        self.observer = observer
        publish()
    }

    func currentState() -> LocalAI.State { state }

    /// Rechecks the files and clears a stale error, like opening the settings card on PC.
    func refresh() {
        state.downloadedTiers = Set(LocalAI.Tier.allCases.filter(isDownloaded))
        if state.downloadingTier == nil && state.loadingTier == nil {
            state.error = nil
            state.failure = nil
            state.errorTier = nil
        }
        publish()
    }

    private func publish() {
        state.revision += 1
        observer?(state)
    }

    // MARK: App state

    nonisolated func setAppActive(_ active: Bool) {
        gate.appActive = active
    }

    /// iOS memory warning: stop the running generation, fail queued work and release the model.
    nonisolated func handleMemoryWarning() {
        gate.interrupt()
        Task { await self.releaseForMemoryWarning() }
    }

    private func releaseForMemoryWarning() async {
        let queued = interactiveJobs + backgroundJobs
        interactiveJobs.removeAll()
        backgroundJobs.removeAll()
        for job in queued { job.fail(LocalAIError.memoryPressure) }
        if pumping {
            releaseAfterJob = true
        } else {
            await unloadEngine()
        }
    }

    // MARK: Translation

    /// Translates lyric lines. Each line may hold simultaneous vocal parts separated by " / ".
    /// onLine reports finished lines as they become available.
    func translate(
        lines: [String],
        targetLanguage: String,
        configuration: LocalAI.Configuration,
        priority: Priority,
        messages: LocalAI.Messages,
        onLine: (@Sendable (Int, String) async -> Void)? = nil
    ) async throws -> [String] {
        let language = try LocalAI.resolveTargetLanguage(targetLanguage, messages: messages)
        try checkReady(configuration.tier, messages: messages)
        idleMinutes = LocalAI.normalizedIdleMinutes(configuration.idleMinutes)
        var job = LocalAI.LineJob(lines: lines)
        for row in job.takeReadyRows() { await onLine?(row.index, row.text) }
        for block in job.blocks {
            try Task.checkCancellation()
            let translated = try await schedule(priority) { cancellation in
                try await self.translateBlock(block, language: language, configuration: configuration,
                                              messages: messages, cancellation: cancellation)
            }
            job.fill(block, with: translated)
            for row in job.takeReadyRows() { await onLine?(row.index, row.text) }
        }
        return job.result
    }

    /// Translates the sample line into the current target language, loading the model if needed.
    func testTranslation(
        targetLanguage: String,
        configuration: LocalAI.Configuration,
        messages: LocalAI.Messages
    ) async throws -> LocalAI.TestResult {
        let sample = LocalAI.testSample(targetLanguage: targetLanguage)
        let started = ProcessInfo.processInfo.systemUptime
        let lines = try await translate(lines: [sample], targetLanguage: targetLanguage, configuration: configuration,
                                        priority: .interactive, messages: messages)
        guard let line = lines.first, !LocalAI.trimmed(line).isEmpty else { throw LocalAIError.emptyReply }
        return LocalAI.TestResult(sample: sample, line: line, seconds: ProcessInfo.processInfo.systemUptime - started)
    }

    private func checkReady(_ tier: LocalAI.Tier, messages: LocalAI.Messages) throws {
        if state.downloadingTier == tier {
            throw LocalAIError.downloadBusy(messages.downloadBusy)
        }
        guard isDownloaded(tier) else {
            if state.downloadedTiers.remove(tier) != nil { publish() }
            throw LocalAIError.notReady(messages.notReady)
        }
        guard loader != nil else { throw LocalAIError.unavailable }
    }

    private func translateBlock(
        _ block: [String],
        language: String,
        configuration: LocalAI.Configuration,
        messages: LocalAI.Messages,
        cancellation: LocalAICancellation
    ) async throws -> [String] {
        let engine = try await ensureLoaded(configuration, messages: messages)
        let usesGPU = engine.usesGPU
        let gate = self.gate
        guard !usesGPU || gate.appActive else { throw LocalAIError.background }
        let interruption = gate.interruption
        let shouldStop: @Sendable () -> Bool = {
            cancellation.isCancelled || gate.interruption != interruption || (usesGPU && !gate.appActive)
        }
        do {
            return try await runOnEngineQueue {
                try LocalAI.translateBlock(block, language: language) { prompt, maxTokens in
                    try engine.complete(prompt: prompt, maxTokens: maxTokens, shouldStop: shouldStop)
                }
            }
        } catch is CancellationError {
            // Stopped cleanly between tokens.
            if gate.interruption != interruption {
                await unloadEngine()
                throw LocalAIError.memoryPressure
            }
            if cancellation.isCancelled { throw CancellationError() }
            throw LocalAIError.background
        } catch {
            if gate.interruption != interruption {
                await unloadEngine()
                throw LocalAIError.memoryPressure
            }
            let backgrounded = usesGPU && !gate.appActive
            if (error as? LocalAIError)?.releasesEngine == true || backgrounded {
                // A failed Metal command buffer leaves the backend unusable: start fresh next time.
                await unloadEngine()
                if backgrounded { throw LocalAIError.background }
            }
            throw error
        }
    }

    private func ensureLoaded(_ configuration: LocalAI.Configuration, messages: LocalAI.Messages) async throws -> any LocalAIInferenceEngine {
        if let engine, engineTier == configuration.tier, engineProcessor == configuration.processor {
            return engine
        }
        try checkReady(configuration.tier, messages: messages)
        guard let loader else { throw LocalAIError.unavailable }
        if engine != nil { await unloadEngine() }
        // Loading onto the GPU submits Metal work as well.
        guard configuration.processor == .cpu || gate.appActive else { throw LocalAIError.background }
        let url = modelURL(for: configuration.tier)
        let processor = configuration.processor
        state.loadingTier = configuration.tier
        state.readyTier = nil
        state.device = nil
        state.error = nil
        state.failure = nil
        state.errorTier = nil
        publish()
        do {
            let loaded = try await runOnEngineQueue { try loader(url, processor) }
            engine = loaded
            engineTier = configuration.tier
            engineProcessor = processor
            state.loadingTier = nil
            state.readyTier = configuration.tier
            state.device = loaded.deviceLabel
            publish()
            return loaded
        } catch {
            state.loadingTier = nil
            state.error = error.localizedDescription
            state.failure = LocalAI.Failure(error)
            state.errorTier = configuration.tier
            publish()
            throw error is LocalAIError ? error : LocalAIError.engine(error.localizedDescription)
        }
    }

    // MARK: Engine lifetime

    /// "Free memory": runs after the block in progress.
    func releaseEngine() async {
        _ = try? await schedule(.interactive) { _ in await self.unloadEngine() }
    }

    /// The quality tier or processor changed: a loaded model of another kind is released.
    func configurationChanged(_ configuration: LocalAI.Configuration) async {
        idleMinutes = LocalAI.normalizedIdleMinutes(configuration.idleMinutes)
        if engine != nil, engineTier != configuration.tier || engineProcessor != configuration.processor {
            await releaseEngine()
        } else if !pumping {
            scheduleIdleUnload()
        }
    }

    var isEngineLoaded: Bool { engine != nil }

    private func unloadEngine() async {
        cancelIdleTimer()
        guard let engine else { return }
        self.engine = nil
        engineTier = nil
        engineProcessor = nil
        // The last reference goes away on the engine queue, after any call still using it.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            engineQueue.async {
                withExtendedLifetime(engine) {}
                continuation.resume()
            }
        }
        if state.readyTier != nil || state.loadingTier != nil || state.device != nil {
            state.readyTier = nil
            state.loadingTier = nil
            state.device = nil
            publish()
        }
    }

    private func runOnEngineQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            engineQueue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    // MARK: Scheduler

    private func schedule<T: Sendable>(
        _ priority: Priority,
        _ work: @escaping (LocalAICancellation) async throws -> T
    ) async throws -> T {
        let cancellation = LocalAICancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                let job = Job(id: id, run: {
                    if cancellation.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        continuation.resume(returning: try await work(cancellation))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }, fail: { error in
                    continuation.resume(throwing: error)
                })
                enqueue(job, priority: priority)
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.removeQueuedJob(id) }
        }
    }

    private func enqueue(_ job: Job, priority: Priority) {
        switch priority {
        case .interactive: interactiveJobs.append(job)
        case .background: backgroundJobs.append(job)
        }
        guard !pumping else { return }
        pumping = true
        cancelIdleTimer()
        Task { await self.pump() }
    }

    private func pump() async {
        while true {
            let job: Job
            if !interactiveJobs.isEmpty {
                job = interactiveJobs.removeFirst()
            } else if !backgroundJobs.isEmpty {
                job = backgroundJobs.removeFirst()
            } else {
                break
            }
            await job.run()
            if releaseAfterJob {
                releaseAfterJob = false
                await unloadEngine()
            }
        }
        pumping = false
        scheduleIdleUnload()
    }

    private func removeQueuedJob(_ id: UUID) {
        if let index = interactiveJobs.firstIndex(where: { $0.id == id }) {
            interactiveJobs.remove(at: index).fail(CancellationError())
        } else if let index = backgroundJobs.firstIndex(where: { $0.id == id }) {
            backgroundJobs.remove(at: index).fail(CancellationError())
        }
    }

    /// Blocks waiting for the engine, for the regression test.
    var queuedBlockCounts: (interactive: Int, background: Int) {
        (interactiveJobs.count, backgroundJobs.count)
    }

    // MARK: Idle release

    func setIdleMinutes(_ minutes: Int) {
        idleMinutes = LocalAI.normalizedIdleMinutes(minutes)
        if !pumping { scheduleIdleUnload() }
    }

    private func scheduleIdleUnload() {
        cancelIdleTimer()
        guard idleMinutes > 0, engine != nil else { return }
        let token = idleToken
        let seconds = Double(idleMinutes) * 60
        let sleeper = self.sleeper
        idleTask = Task { [weak self] in
            do { try await sleeper(seconds) } catch { return }
            await self?.idleExpired(token)
        }
    }

    private func idleExpired(_ token: Int) async {
        guard token == idleToken, !pumping, interactiveJobs.isEmpty, backgroundJobs.isEmpty else { return }
        idleTask = nil
        await unloadEngine()
    }

    private func cancelIdleTimer() {
        idleToken += 1
        idleTask?.cancel()
        idleTask = nil
    }

    // MARK: Files

    /// Downloads the tier's file. Only an explicit tap in the settings card calls this.
    func startDownload(_ tier: LocalAI.Tier) {
        guard state.downloadingTier == nil else { return }
        guard !isDownloaded(tier) else {
            refresh()
            return
        }
        let partial = (try? FileManager.default.attributesOfItem(atPath: partialURL(for: tier).path)[.size] as? NSNumber)?.int64Value ?? 0
        state.downloadingTier = tier
        state.loadedBytes = min(partial, tier.byteCount)
        state.totalBytes = tier.byteCount
        state.error = nil
        state.failure = nil
        state.errorTier = nil
        publish()
        downloadTask = Task { await self.runDownload(tier) }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Waits for the download in progress (tests and the host check).
    func waitForDownload() async {
        await downloadTask?.value
    }

    private func runDownload(_ tier: LocalAI.Tier) async {
        do {
            try prepareDirectory()
            try await downloader.download(from: tier.downloadURL, to: modelURL(for: tier),
                                          partialURL: partialURL(for: tier), expectedBytes: tier.byteCount) { loaded, total in
                Task { await self.downloadProgress(tier, loaded: loaded, total: total) }
            }
            state.downloadedTiers.insert(tier)
            state.loadedBytes = tier.byteCount
        } catch is CancellationError {
            state.loadedBytes = 0
        } catch {
            state.error = error.localizedDescription
            state.failure = LocalAI.Failure(error)
            state.errorTier = tier
        }
        state.downloadingTier = nil
        downloadTask = nil
        publish()
    }

    private func downloadProgress(_ tier: LocalAI.Tier, loaded: Int64, total: Int64) {
        guard state.downloadingTier == tier else { return }
        state.loadedBytes = loaded
        state.totalBytes = total > 0 ? total : tier.byteCount
        publish()
    }

    /// Deletes the tier's file (and any partial download) after the block in progress.
    func delete(_ tier: LocalAI.Tier) async throws {
        try await schedule(.interactive) { _ in
            await self.removeFiles(tier)
        }
    }

    private func removeFiles(_ tier: LocalAI.Tier) async {
        if engineTier == tier { await unloadEngine() }
        if state.downloadingTier == tier { downloadTask?.cancel() }
        try? FileManager.default.removeItem(at: modelURL(for: tier))
        try? FileManager.default.removeItem(at: partialURL(for: tier))
        state.downloadedTiers.remove(tier)
        if state.errorTier == tier {
            state.error = nil
            state.failure = nil
            state.errorTier = nil
        }
        publish()
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try url.setResourceValues(values)
    }
}

enum LocalAIDownloadError: LocalizedError, Equatable {
    case httpStatus(Int)
    case sizeMismatch(expected: Int64, actual: Int64)
    case invalidFile

    var errorDescription: String? {
        switch self {
        case let .httpStatus(status):
            return "Download failed (HTTP \(status))."
        case let .sizeMismatch(expected, actual):
            return "The downloaded file has \(actual) bytes instead of \(expected)."
        case .invalidFile:
            return "The downloaded file is not a model file."
        }
    }
}

/// Streams one file into "<name>.part", resumes with an HTTP Range request when a partial file
/// exists, and moves it into place only after its size equals the expected byte count.
final class LocalAIDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Progress = @Sendable (_ loaded: Int64, _ total: Int64) -> Void

    /// Used only on the delegate queue.
    private final class Transfer: @unchecked Sendable {
        let url: URL
        let destination: URL
        let partialURL: URL
        let expectedBytes: Int64
        let progress: Progress
        var continuation: CheckedContinuation<Void, Error>?
        var task: URLSessionDataTask?
        var handle: FileHandle?
        var offset: Int64 = 0
        var received: Int64 = 0
        var failure: Error?
        var restartable = true
        var restart = false
        var cancelled = false
        var lastReport: TimeInterval = 0

        init(url: URL, destination: URL, partialURL: URL, expectedBytes: Int64, progress: @escaping Progress) {
            self.url = url
            self.destination = destination
            self.partialURL = partialURL
            self.expectedBytes = expectedBytes
            self.progress = progress
        }
    }

    private static let magic = Data("GGUF".utf8)
    private static let progressInterval: TimeInterval = 0.25
    private static let freeSpaceMargin: Int64 = 64 * 1024 * 1024

    private let queue: OperationQueue
    private let configuration: URLSessionConfiguration
    private var session: URLSession?
    private var transfers: [Int: Transfer] = [:]

    init(configuration: URLSessionConfiguration? = nil) {
        let resolved = configuration ?? URLSessionConfiguration.default
        resolved.requestCachePolicy = .reloadIgnoringLocalCacheData
        resolved.urlCache = nil
        resolved.timeoutIntervalForRequest = 60
        resolved.timeoutIntervalForResource = 7 * 24 * 60 * 60
        self.configuration = resolved
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "ivLyrics.LocalAI.download"
        super.init()
    }

    func download(from url: URL, to destination: URL, partialURL: URL, expectedBytes: Int64,
                  progress: @escaping Progress) async throws {
        let transfer = Transfer(url: url, destination: destination, partialURL: partialURL,
                                expectedBytes: expectedBytes, progress: progress)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.addOperation {
                    transfer.continuation = continuation
                    self.begin(transfer)
                }
            }
        } onCancel: {
            queue.addOperation {
                transfer.cancelled = true
                if let task = transfer.task {
                    task.cancel()
                } else {
                    self.complete(transfer, with: CancellationError())
                }
            }
        }
    }

    // All methods below run on the delegate queue.

    private func begin(_ transfer: Transfer) {
        guard !transfer.cancelled else {
            complete(transfer, with: CancellationError())
            return
        }
        let fileManager = FileManager.default
        var existing = Self.fileSize(transfer.partialURL)
        if existing > transfer.expectedBytes {
            try? fileManager.removeItem(at: transfer.partialURL)
            existing = 0
        }
        if existing == transfer.expectedBytes {
            finish(transfer)
            return
        }
        do {
            try Self.ensureFreeSpace(transfer.expectedBytes - existing, near: transfer.partialURL.deletingLastPathComponent())
        } catch {
            complete(transfer, with: error)
            return
        }
        var request = URLRequest(url: transfer.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }
        transfer.offset = existing
        transfer.received = existing
        transfer.failure = nil
        transfer.restart = false
        let task = urlSession().dataTask(with: request)
        transfer.task = task
        transfers[task.taskIdentifier] = transfer
        transfer.progress(existing, transfer.expectedBytes)
        task.resume()
    }

    private func urlSession() -> URLSession {
        if let session { return session }
        let created = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        session = created
        return created
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let transfer = transfers[dataTask.taskIdentifier] else {
            completionHandler(.cancel)
            return
        }
        do {
            guard let http = response as? HTTPURLResponse else { throw LocalAIDownloadError.httpStatus(0) }
            switch http.statusCode {
            case 206:
                guard let range = Self.contentRange(http), range.start == transfer.offset else {
                    transfer.restart = true
                    throw LocalAIDownloadError.httpStatus(206)
                }
                if let total = range.total, total != transfer.expectedBytes {
                    throw LocalAIDownloadError.sizeMismatch(expected: transfer.expectedBytes, actual: total)
                }
                let handle = try FileHandle(forWritingTo: transfer.partialURL)
                try handle.seekToEnd()
                transfer.handle = handle
                transfer.received = transfer.offset
            case 200:
                if http.expectedContentLength > 0, http.expectedContentLength != transfer.expectedBytes {
                    throw LocalAIDownloadError.sizeMismatch(expected: transfer.expectedBytes, actual: http.expectedContentLength)
                }
                // The server ignored the range (or there was none): start over.
                guard FileManager.default.createFile(atPath: transfer.partialURL.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                transfer.handle = try FileHandle(forWritingTo: transfer.partialURL)
                transfer.received = 0
            case 416:
                transfer.restart = true
                throw LocalAIDownloadError.httpStatus(416)
            default:
                throw LocalAIDownloadError.httpStatus(http.statusCode)
            }
            report(transfer, force: true)
            completionHandler(.allow)
        } catch {
            transfer.failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = transfers[dataTask.taskIdentifier], transfer.failure == nil else { return }
        do {
            guard transfer.received + Int64(data.count) <= transfer.expectedBytes else {
                throw LocalAIDownloadError.sizeMismatch(expected: transfer.expectedBytes, actual: transfer.received + Int64(data.count))
            }
            try transfer.handle?.write(contentsOf: data)
            transfer.received += Int64(data.count)
            report(transfer, force: false)
        } catch {
            transfer.failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Keep the resume range on the CDN the model host redirects to.
        var redirected = request
        for header in ["Range", "Accept-Encoding"] {
            if let value = task.originalRequest?.value(forHTTPHeaderField: header) {
                redirected.setValue(value, forHTTPHeaderField: header)
            }
        }
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let transfer = transfers.removeValue(forKey: task.taskIdentifier) else { return }
        try? transfer.handle?.close()
        transfer.handle = nil
        transfer.task = nil
        if transfer.cancelled {
            complete(transfer, with: CancellationError())
        } else if transfer.restart && transfer.restartable {
            // The partial file no longer matches the server's file: download it again from the start.
            transfer.restartable = false
            try? FileManager.default.removeItem(at: transfer.partialURL)
            begin(transfer)
        } else if let failure = transfer.failure ?? error {
            // Keep the partial file for a later Range request unless it cannot belong to this model.
            switch failure as? LocalAIDownloadError {
            case .sizeMismatch?, .invalidFile?:
                try? FileManager.default.removeItem(at: transfer.partialURL)
            default:
                break
            }
            complete(transfer, with: failure)
        } else {
            finish(transfer)
        }
    }

    private func finish(_ transfer: Transfer) {
        let size = Self.fileSize(transfer.partialURL)
        guard size == transfer.expectedBytes else {
            if size > transfer.expectedBytes { try? FileManager.default.removeItem(at: transfer.partialURL) }
            complete(transfer, with: LocalAIDownloadError.sizeMismatch(expected: transfer.expectedBytes, actual: size))
            return
        }
        do {
            let handle = try FileHandle(forReadingFrom: transfer.partialURL)
            let header = try handle.read(upToCount: Self.magic.count) ?? Data()
            try? handle.close()
            guard header == Self.magic else {
                try? FileManager.default.removeItem(at: transfer.partialURL)
                throw LocalAIDownloadError.invalidFile
            }
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: transfer.destination.path) {
                try fileManager.removeItem(at: transfer.destination)
            }
            try fileManager.moveItem(at: transfer.partialURL, to: transfer.destination)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var destination = transfer.destination
            try? destination.setResourceValues(values)
            transfer.progress(transfer.expectedBytes, transfer.expectedBytes)
            complete(transfer, with: nil)
        } catch {
            complete(transfer, with: error)
        }
    }

    private func complete(_ transfer: Transfer, with error: Error?) {
        guard let continuation = transfer.continuation else { return }
        transfer.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private func report(_ transfer: Transfer, force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - transfer.lastReport >= Self.progressInterval else { return }
        transfer.lastReport = now
        transfer.progress(transfer.received, transfer.expectedBytes)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func ensureFreeSpace(_ needed: Int64, near directory: URL) throws {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage, available > 0,
           available < needed + freeSpaceMargin {
            throw CocoaError(.fileWriteOutOfSpace)
        }
    }

    /// "bytes 100-999/1000" → (100, 1000); "bytes 100-999/*" → (100, nil).
    static func contentRange(_ response: HTTPURLResponse) -> (start: Int64, total: Int64?)? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range"),
              let match = value.range(of: #"^\s*bytes\s+(\d+)-(\d+)/(\d+|\*)\s*$"#, options: .regularExpression) else {
            return nil
        }
        let parts = value[match].trimmingCharacters(in: .whitespaces).dropFirst("bytes".count)
            .trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == "-" || $0 == "/" })
        guard parts.count == 3, let start = Int64(parts[0]) else { return nil }
        return (start, Int64(parts[2]))
    }
}

