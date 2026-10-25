#if DEBUG
import SwiftUI
import UIKit

/// Only the explicit Debug launch argument enables this route. No URL/deep-link enables it.
enum DebugSettingsUIHarness {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--ivlyrics-ui-test") }
    static let credentialService = "kr.ivlis.ivlyrics.debug-ui.\(UUID().uuidString)"
    static let defaults = UserDefaults(suiteName: "ivlyrics-ui-\(ProcessInfo.processInfo.environment["IVLYRICS_UI_DEFAULTS_ID"] ?? UUID().uuidString)")!
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
private struct DebugSettingsGeometryProbe: UIViewRepresentable {
    var identifier: String
    var label: String
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = identifier
        view.accessibilityLabel = label
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

extension View {
    @ViewBuilder
    func debugSetupWelcomeState(_ settings: AppSettings, rotating: Bool, stopped: Bool) -> some View {
        if DebugSettingsUIHarness.enabled {
            let state = "ui=\(settings.uiLang);savedUI=\(DebugSettingsUIHarness.defaults.string(forKey: "ui_lang") ?? "unset");output=\(settings.outputLang);savedOutput=\(DebugSettingsUIHarness.defaults.string(forKey: "output_lang") ?? "unset");rotating=\(rotating);stopped=\(stopped);reducedMotion=\(UIAccessibility.isReduceMotionEnabled)"
            accessibilityValue(state)
        } else { self }
    }

    func debugSettingsHitArea(_ identifier: String) -> some View {
        background {
            if DebugSettingsUIHarness.enabled {
                DebugSettingsGeometryProbe(identifier: "ui.hit.\(identifier)", label: "Native toggle hit area")
            }
        }
    }

    /// Measure the actual Text before its badge frame adds space around it.
    func debugSettingsBadgeTextBounds(_ identifier: String) -> some View {
        background {
            if DebugSettingsUIHarness.enabled {
                DebugSettingsGeometryProbe(identifier: "ui.badge.\(identifier).text", label: "Native badge text bounds")
            }
        }
    }

    func debugSettingsBadgeBounds(_ identifier: String) -> some View {
        background {
            if DebugSettingsUIHarness.enabled {
                DebugSettingsGeometryProbe(identifier: "ui.badge.\(identifier).frame", label: "Native badge frame")
            }
        }
        .accessibilityElement(children: .contain)
        // Decorations stay hidden in normal launches; only the isolated fixture exposes the probes.
        .accessibilityHidden(!DebugSettingsUIHarness.enabled)
    }
}

/// Hosts production settings/popup/player with isolated settings and no live services.
struct DebugSettingsUIRoot: View {
    @StateObject private var settings: AppSettings
    @StateObject private var model: AppViewModel
    @State private var showingSettings = false
    @State private var showingPopup = false
    @State private var tab: LyricsMetaMenuTab

    init() {
        let defaults = DebugSettingsUIHarness.defaults
        defaults.set(ProcessInfo.processInfo.environment["IVLYRICS_UI_LANGUAGE"] ?? "en", forKey: "ui_lang")
        defaults.set(ProcessInfo.processInfo.environment["IVLYRICS_UI_THEME"] ?? "dark", forKey: "settings_theme")
        defaults.set(true, forKey: "cultural_annotations_enabled")
        if DebugSettingsUIHarness.surface == "player" {
            // Layout assertions take many AX snapshots on CI. Test auto-hide
            // separately instead of racing its production 2.8-second timer.
            defaults.set(ProcessInfo.processInfo.environment["IVLYRICS_UI_AUTO_HIDE"] == "1",
                         forKey: "landscape_auto_hide_controls")
        }
        // Explicit provider flags stop credential migration; this suite never uses real saved settings.
        defaults.set("{\"google-translate\":false,\"bing-translate\":false}", forKey: "ai_provider_enabled_v1")
        if ProcessInfo.processInfo.environment["IVLYRICS_UI_TRANSLATION_PROVIDER"] == "keyless" {
            defaults.set("{\"google-translate\":true,\"bing-translate\":true}", forKey: "ai_provider_enabled_v1")
        }
        if ProcessInfo.processInfo.environment["IVLYRICS_UI_CONFIGURED_LANGUAGE"] == "1" {
            defaults.set(true, forKey: "translation_enabled")
            defaults.set(true, forKey: "pronunciation_enabled")
        }
        let settings = AppSettings(defaults: defaults)
        if let imported = ProcessInfo.processInfo.environment["IVLYRICS_UI_IMPORT_COVER_TAP"] {
            settings.importCloudSettings(["vinyl_cover_tap_enabled": imported == "1"])
        }
        if ProcessInfo.processInfo.environment["IVLYRICS_UI_SAVED_SECRET"] == "1" {
            settings.spotifyClientSecret = "fixture-stale-secret"
        }
        _settings = StateObject(wrappedValue: settings)
        let model = AppViewModel(settings: settings)
        if let state = ProcessInfo.processInfo.environment["IVLYRICS_UI_VIDEO_SHARE"], state != "0" {
            model.applyDebugVideoSharingFixture()
        }
        _model = StateObject(wrappedValue: model)
        _tab = State(initialValue: LyricsMetaMenuTab(rawValue: DebugSettingsUIHarness.surface) ?? .language)
    }

    var body: some View {
        Group {
            if DebugSettingsUIHarness.surface == "player" {
                ContentView()
            } else {
                popupContent
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
        .fullScreenCover(isPresented: $model.initialSetupPresented) {
            InitialSetupView()
                .environmentObject(settings)
                .environmentObject(model)
                .environment(\.dynamicTypeSize, DebugSettingsUIHarness.textSize)
        }
        .onAppear {
            showingSettings = DebugSettingsUIHarness.surface == "settings"
            if DebugSettingsUIHarness.surface == "onboarding" {
                model.showInitialSetup()
            } else if DebugSettingsUIHarness.surface == "first-language" {
                if settings.shouldPromptForFirstLanguage("ja") || ProcessInfo.processInfo.environment["IVLYRICS_UI_FORCE_PROMPT"] == "1" {
                    model.applyDebugFirstLanguagePrompt()
                }
            } else if DebugSettingsUIHarness.surface != "player" {
                showingPopup = !showingSettings
            }
        }
    }

    private var popupContent: some View {
        GeometryReader { geometry in
            ZStack {
                SettingsDesign.background.ignoresSafeArea()
                VStack(spacing: 12) {
                    Text(model.titleText).font(.title).multilineTextAlignment(.center)
                    Text(model.artistText).font(.body)
                    Text(model.lyricsResult.lines.first?.translationText ?? "").font(.body)
                    Text("Offline UI fixture").accessibilityIdentifier("ui.harness.offline")
                    Text(verbatim: model.debugLastVideoTimingShare.map { "\($0.videoId)@\($0.startTime)" } ?? "none")
                        .accessibilityIdentifier("ui.harness.video-share")
                    Text("Actions: \(model.debugSettingsUIActionCount)")
                        .accessibilityIdentifier("ui.harness.actions")
                    Text("\(SettingsView.debugMenuContentSize)")
                        .accessibilityIdentifier("ui.harness.navigation-content-bytes")
                    Text("translation=\(settings.languageRule(for: "ja").translationEnabled);pronunciation=\(settings.languageRule(for: "ja").pronunciationEnabled);prompt=\(settings.shouldPromptForFirstLanguage("ja"));rule=\(settings.snapshot.languageRules["ja"] != nil);webAPI=\(settings.spotifyWebAPIEnabled);ai=\(settings.snapshot.hasEnabledAIProvider);auth=\(model.spotifyAppRemoteConnected || model.spotifyWebAPIConnected);reducedMotion=\(UIAccessibility.isReduceMotionEnabled);secretRetained=\(!settings.spotifyClientSecret.trimmed.isEmpty)")
                        .accessibilityIdentifier("ui.harness.preferences")
                    if !showingSettings && !showingPopup && !model.initialSetupPresented && model.firstLanguagePrompt == nil {
                        Text("Closed").accessibilityIdentifier("ui.harness.closed")
                    }
                }
                .foregroundStyle(.white)
                .padding(24)
                // Debug diagnostics can exceed a landscape window at AX5. They
                // must not enlarge the overlay's proposed viewport beyond it.
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .accessibilityHidden(showingPopup || showingSettings || model.initialSetupPresented || model.firstLanguagePrompt != nil)
                if showingPopup {
                    LyricsMetaMenuOverlay(visible: $showingPopup, selectedTab: $tab, screenHeight: geometry.size.height)
                }
                if let prompt = model.firstLanguagePrompt {
                    FirstLanguagePromptSheetView(prompt: prompt)
                        .id(prompt.id)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
#endif

#if !DEBUG
import SwiftUI
extension View {
    func debugSetupWelcomeState(_ settings: AppSettings, rotating: Bool, stopped: Bool) -> some View { self }
    func debugSettingsHitArea(_ identifier: String) -> some View { self }
    func debugSettingsBadgeTextBounds(_ identifier: String) -> some View { self }
    func debugSettingsBadgeBounds(_ identifier: String) -> some View { accessibilityHidden(true) }
}
#endif
