#if DEBUG
import SwiftUI
import UIKit

/// Only the explicit Debug launch argument enables this route. No URL/deep-link enables it.
enum DebugSettingsUIHarness {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--ivlyrics-ui-test") }
    static let credentialService = "kr.ivlis.ivlyrics.debug-ui.\(UUID().uuidString)"
    static var surface: String { ProcessInfo.processInfo.environment["IVLYRICS_UI_SURFACE"] ?? "settings" }
    static var textSize: DynamicTypeSize {
        switch ProcessInfo.processInfo.environment["IVLYRICS_UI_TEXT_SIZE"] {
        case "accessibility3": return .accessibility3
        case "accessibility5": return .accessibility5
        default: return .large
        }
    }
}

/// Non-interactive, Debug-only AX geometry probe for the real laid-out hit area.
/// The switch itself retains its native intrinsic visual size (usually 51 x 31pt).
private struct DebugSettingsHitAreaProbe: UIViewRepresentable {
    var identifier: String
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "ui.hit.\(identifier)"
        view.accessibilityLabel = "Native toggle hit area"
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

extension View {
    func debugSettingsHitArea(_ identifier: String) -> some View {
        background {
            if DebugSettingsUIHarness.enabled { DebugSettingsHitAreaProbe(identifier: identifier) }
        }
    }
}

/// Hosts the real production settings/popup. Never constructs ContentView or starts its live services.
struct DebugSettingsUIRoot: View {
    @StateObject private var settings: AppSettings
    @StateObject private var model: AppViewModel
    @State private var showingSettings = false
    @State private var showingPopup = false
    @State private var tab: LyricsMetaMenuTab

    init() {
        let defaults = UserDefaults(suiteName: "ivlyrics-ui-\(UUID().uuidString)")!
        defaults.set(ProcessInfo.processInfo.environment["IVLYRICS_UI_LANGUAGE"] ?? "en", forKey: "ui_lang")
        defaults.set(true, forKey: "cultural_annotations_enabled")
        // Explicitly empty profiles stop credential migration; this suite never uses real saved settings.
        defaults.set("{}", forKey: "ai_provider_enabled_v1")
        let settings = AppSettings(defaults: defaults)
        _settings = StateObject(wrappedValue: settings)
        _model = StateObject(wrappedValue: AppViewModel(settings: settings))
        _tab = State(initialValue: LyricsMetaMenuTab(rawValue: DebugSettingsUIHarness.surface) ?? .language)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                SettingsDesign.background.ignoresSafeArea()
                VStack(spacing: 12) {
                    Text(model.titleText).font(.title).multilineTextAlignment(.center)
                    Text(model.artistText).font(.body)
                    Text(model.lyricsResult.lines.first?.translationText ?? "").font(.body)
                    Text("Offline UI fixture").accessibilityIdentifier("ui.harness.offline")
                    Text("Actions: \(model.debugSettingsUIActionCount)")
                        .accessibilityIdentifier("ui.harness.actions")
                    if !showingSettings && !showingPopup {
                        Text("Closed").accessibilityIdentifier("ui.harness.closed")
                    }
                }
                .foregroundStyle(.white)
                .padding(24)
                .accessibilityHidden(showingPopup || showingSettings)
                if showingPopup {
                    LyricsMetaMenuOverlay(visible: $showingPopup, selectedTab: $tab, screenHeight: geometry.size.height)
                }
            }
        }
        .environmentObject(settings)
        .environmentObject(model)
        .environmentObject(model.playbackClock)
        .environment(\.dynamicTypeSize, DebugSettingsUIHarness.textSize)
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(model)
                .environmentObject(model.playbackClock)
                .environment(\.dynamicTypeSize, DebugSettingsUIHarness.textSize)
        }
        .onAppear {
            showingSettings = DebugSettingsUIHarness.surface == "settings"
            showingPopup = !showingSettings
        }
    }
}
#endif

#if !DEBUG
import SwiftUI
extension View {
    func debugSettingsHitArea(_ identifier: String) -> some View { self }
}
#endif
