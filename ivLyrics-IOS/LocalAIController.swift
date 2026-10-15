import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

extension LocalAI.Messages {
    /// Failure messages in the app's UI language.
    static func app(uiLanguage: String) -> LocalAI.Messages {
        LocalAI.Messages(
            notReady: AppI18n.t(uiLanguage, "local_ai.not_ready"),
            downloadBusy: AppI18n.t(uiLanguage, "local_ai.download_busy"),
            unsupportedLanguage: AppI18n.t(uiLanguage, "local_ai.unsupported_language"),
            uiLanguage: uiLanguage
        )
    }
}

extension LocalAI.Failure {
    /// The failure in the app's UI language. Engine details, model file names and URLs stay in
    /// the log.
    func message(uiLanguage: String) -> String {
        let key: String
        switch self {
        case let .message(text):
            return text
        case let .downloadStatus(status):
            return LocalAI.format(AppI18n.t(uiLanguage, "local_ai.error_download_status"), ["status": String(status)])
        case .unavailable: key = "local_ai.error_unavailable"
        case .background: key = "local_ai.error_background"
        case .memoryPressure: key = "local_ai.error_memory_pressure"
        case .emptyReply: key = "local_ai.error_empty_reply"
        case .promptTooLong: key = "local_ai.error_prompt_too_long"
        case .modelLoadFailed: key = "local_ai.error_model_load_failed"
        case .outOfMemory: key = "local_ai.error_out_of_memory"
        case .engine, .unknown: key = "local_ai.error_generic"
        case .downloadDamaged: key = "local_ai.error_download_damaged"
        case .network: key = "local_ai.error_network"
        case .storageFull: key = "local_ai.error_storage_full"
        }
        return AppI18n.t(uiLanguage, key)
    }
}

/// Connects LocalAIService to SwiftUI and to iOS: memory warnings release the model and the GPU
/// is left alone while the app is in the background.
@MainActor
final class LocalAIController: ObservableObject {
    static let shared = LocalAIController()

    enum TestState: Equatable {
        case running
        case passed(String)
        case failed(String)
    }

    @Published private(set) var state = LocalAI.State()
    @Published private(set) var test: TestState?

    private let service: LocalAIService
    private var started = false
    private var observers: [NSObjectProtocol] = []
    private var testToken = 0

    init(service: LocalAIService = .shared) {
        self.service = service
    }

    /// Called once at launch.
    func start() {
        guard !started else { return }
        started = true
        let service = self.service
        Task {
            // The controller lives for the whole process (LocalAIController.shared).
            await service.setObserver { state in
                Task { @MainActor in self.apply(state) }
            }
            await service.refresh()
        }
        #if canImport(UIKit)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            service.handleMemoryWarning()
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            service.setAppActive(false)
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            service.setAppActive(true)
        })
        #endif
    }

    private func apply(_ newState: LocalAI.State) {
        guard newState.revision > state.revision else { return }
        state = newState
    }

    func refresh() {
        let service = self.service
        Task { await service.refresh() }
    }

    func download(_ tier: LocalAI.Tier) {
        test = nil
        let service = self.service
        Task { await service.startDownload(tier) }
    }

    func cancelDownload() {
        let service = self.service
        Task { await service.cancelDownload() }
    }

    func delete(_ tier: LocalAI.Tier) {
        test = nil
        let service = self.service
        Task { try? await service.delete(tier) }
    }

    func freeMemory() {
        let service = self.service
        Task { await service.releaseEngine() }
    }

    func configurationChanged(_ configuration: LocalAI.Configuration) {
        test = nil
        let service = self.service
        Task {
            await service.configurationChanged(configuration)
            await service.refresh()
        }
    }

    func setIdleMinutes(_ minutes: Int) {
        let service = self.service
        Task { await service.setIdleMinutes(minutes) }
    }

    /// "Test translation": loads the model if needed and translates the sample line.
    func runTest(targetLanguage: String, configuration: LocalAI.Configuration, uiLanguage: String) {
        testToken += 1
        let token = testToken
        test = .running
        let service = self.service
        Task {
            let outcome: TestState
            do {
                let result = try await service.testTranslation(
                    targetLanguage: targetLanguage,
                    configuration: configuration,
                    messages: .app(uiLanguage: uiLanguage)
                )
                outcome = .passed("✓ \(result.sample) → \(result.line) (\(String(format: "%.1f", result.seconds))s)")
            } catch {
                outcome = .failed("✗ \(LocalAI.Failure(error).message(uiLanguage: uiLanguage))")
            }
            if token == testToken { test = outcome }
        }
    }

    func clearTest() {
        testToken += 1
        test = nil
    }
}

