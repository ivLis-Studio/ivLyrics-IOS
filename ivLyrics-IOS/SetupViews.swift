import SwiftUI
import UIKit

/// Presentation-only state, owned by the setup session so Back/view rebuilds cannot restart it.
/// No app language or output-language preference is written by the greeting rotation.
struct SetupWelcomeGreeting {
    static let interval: Duration = .milliseconds(3500)
    private var rotatingLanguage: String?
    private(set) var stopped = false

    func language(uiLanguage: String) -> String {
        rotatingLanguage ?? Self.fallbackLanguage(uiLanguage)
    }

    func title(uiLanguage: String) -> String {
        language(uiLanguage: uiLanguage) == "ko" ? "안녕하세요" : "Hello"
    }

    func canRotate(phase: Int, visible: Bool, active: Bool, reduceMotion: Bool, voiceOver: Bool) -> Bool {
        !stopped && phase == 0 && visible && active && !reduceMotion && !voiceOver
    }

    mutating func advance(uiLanguage: String) {
        guard !stopped else { return }
        rotatingLanguage = language(uiLanguage: uiLanguage) == "ko" ? "en" : "ko"
    }

    mutating func stop(uiLanguage: String) {
        rotatingLanguage = Self.fallbackLanguage(uiLanguage)
        stopped = true
    }

    private static func fallbackLanguage(_ uiLanguage: String) -> String {
        uiLanguage == "ko" ? "ko" : "en"
    }
}

/// Three useful decisions, with settings-backed drafts that survive Back and retries.
struct InitialSetupView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase
    @State private var welcomeVisible = false
    @State private var languagePicker = false
    @State private var setupHelp = false
    @State private var metadataCheck = false

    private var palette: SettingsPalette { SettingsTheme.palette(settings.settingsTheme) }
    private var phase: Int { min(2, max(0, model.onboardingStep)) }
    private var phaseKey: String { ["display", "connection", "credentials"][phase] }
    private var rotateWelcome: Bool {
        model.setupWelcomeGreeting.canRotate(
            phase: phase, visible: welcomeVisible && model.initialSetupPresented && !languagePicker,
            active: scenePhase == .active, reduceMotion: reduceMotion, voiceOver: voiceOver
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    progress.id("setup.top")
                    VStack(alignment: .leading, spacing: 8) {
                        title
                            .font(.largeTitle.weight(.bold))
                            .foregroundStyle(palette.text)
                            .accessibilityAddTraits(.isHeader)
                        Text(settings.t("onboarding.\(phaseKey).desc"))
                            .font(.subheadline)
                            .foregroundStyle(palette.text2)
                            .accessibilityIdentifier("onboarding.description")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    phaseContent
                    navigation.id(phase)
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("onboarding.scroll")
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: phase) { _, _ in
                if phase != 0 { stopWelcome() }
                endEditing()
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    proxy.scrollTo("setup.top", anchor: .top)
                }
            }
        }
        .background(palette.background.ignoresSafeArea())
        .environment(\.settingsPalette, palette)
        .environment(\.colorScheme, palette.colorScheme)
        .preferredColorScheme(palette.colorScheme)
        .interactiveDismissDisabled(!model.initialSetupComplete || model.spotifyCredentialsValidationInFlight)
        .onAppear { welcomeVisible = true }
        .onDisappear {
            welcomeVisible = false
            stopWelcome()
        }
        .onChange(of: settings.uiLang) { _, _ in stopWelcome() }
        .onChange(of: reduceMotion || voiceOver, initial: true) { _, staticGreeting in
            if staticGreeting { stopWelcome() }
        }
        .task(id: rotateWelcome) {
            guard rotateWelcome else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: SetupWelcomeGreeting.interval) }
                catch { return }
                guard !Task.isCancelled, rotateWelcome else { return }
                model.setupWelcomeGreeting.advance(uiLanguage: settings.uiLang)
            }
        }
        .sheet(isPresented: $languagePicker) {
            SettingsOptionSheet(
                title: settings.t("setting.ui_language"),
                options: AppI18n.uiLanguages.map { SettingsChoice(value: $0.code, title: $0.nativeName) },
                selection: settings.uiLang,
                searchPrompt: settings.t("settings.search"), closeLabel: settings.t("button.close"),
                emptyText: settings.t("settings.no_results")
            ) { value in
                model.setupWelcomeGreeting.stop(uiLanguage: value)
                settings.uiLang = value
                model.uiLanguageChanged()
            }
            .environment(\.settingsPalette, palette)
        }
    }

    @ViewBuilder
    private var title: some View {
        if phase == 0 {
            // Reserve both greetings' wrapped height so only opacity changes, even at AX sizes.
            ZStack(alignment: .topLeading) {
                Text("Hello").hidden().accessibilityHidden(true)
                Text("안녕하세요").hidden().accessibilityHidden(true)
                Text(model.setupWelcomeGreeting.title(uiLanguage: settings.uiLang))
                    .id(model.setupWelcomeGreeting.language(uiLanguage: settings.uiLang))
                    .transition(.opacity)
                    .accessibilityIdentifier("onboarding.title")
                    .debugSetupWelcomeState(settings, rotating: rotateWelcome, stopped: model.setupWelcomeGreeting.stopped)
            }
            // Keep the crossfade local: a greeting tick must not animate the
            // setup controls or their sheet presentation transaction.
            .animation(.easeInOut(duration: 0.3), value: model.setupWelcomeGreeting.language(uiLanguage: settings.uiLang))
            .allowsHitTesting(false)
        } else {
            Text(settings.t("onboarding.\(phaseKey).title"))
                .accessibilityIdentifier("onboarding.title")
        }
    }

    private func stopWelcome() {
        model.setupWelcomeGreeting.stop(uiLanguage: settings.uiLang)
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("ivLyrics").font(.subheadline.weight(.semibold)).foregroundStyle(palette.text2)
                Spacer(minLength: 0)
                Text(settings.tf("onboarding.step_format", phase + 1, 3))
                    .font(.footnote.monospacedDigit()).foregroundStyle(palette.text3)
                    .accessibilityIdentifier("onboarding.progress")
            }
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(index <= phase ? palette.ink : palette.surface4)
                        .frame(height: 3)
                }
            }
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case 0:
            SettingsGroup {
                SettingsStackRow(title: settings.t("setting.ui_language")) {
                    SettingsPickerButton(title: settings.t("setting.ui_language"),
                                         value: AppI18n.uiLanguages.first { $0.code == settings.uiLang }?.nativeName ?? settings.uiLang) {
                        stopWelcome()
                        languagePicker = true
                    }
                    .accessibilityIdentifier("onboarding.language")
                }
                SettingsStackRow(title: settings.t("settings.theme")) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { themeOption("dark"); themeOption("light") }
                        VStack(spacing: 8) { themeOption("dark"); themeOption("light") }
                    }
                }
            }
        case 1:
            SettingsGroup {
                SettingsSubhead(title: settings.t("spotify.source.app_remote"))
                SettingsNoteRow(text: settings.t("onboarding.connection.standard"), systemImage: "music.note")
                SettingsToggleRow(title: settings.t("setting.spotify_web_api"),
                                  isOn: Binding(get: { settings.spotifyWebAPIEnabled }, set: { model.setSpotifyWebAPIEnabled($0) }),
                                  identifier: "onboarding.web-api")
                SettingsNoteRow(text: settings.t("onboarding.connection.web_api"), systemImage: nil)
            }
        default:
            credentials
        }
    }

    private func themeOption(_ theme: String) -> some View {
        Button { settings.settingsTheme = theme } label: {
            HStack(spacing: 8) {
                Image(systemName: theme == "dark" ? "moon" : "sun.max").accessibilityHidden(true)
                Text(settings.t("settings.theme.\(theme)"))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: settings.settingsTheme == theme ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(settings.settingsTheme == theme ? palette.accentText : palette.text3)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(SettingsButtonStyle(fullWidth: true))
        .accessibilityAddTraits(settings.settingsTheme == theme ? [.isSelected] : [])
        .accessibilityIdentifier("onboarding.theme.\(theme)")
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup {
                SettingsStackRow(title: settings.t("field.spotify_client_id")) {
                    SetupCredentialInput(title: settings.t("field.spotify_client_id"), text: $settings.spotifyClientId,
                                         identifier: "onboarding.client-id")
                }
                SettingsStackRow(title: "") {
                    Button { metadataCheck.toggle() } label: {
                        SettingsButtonLabel(title: settings.t("onboarding.metadata_optional"),
                                            systemImage: metadataCheck ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(SettingsButtonStyle(fullWidth: true))
                    .accessibilityValue(settings.t(metadataCheck ? "label.on" : "label.off"))
                    .accessibilityIdentifier("onboarding.metadata")
                }
                if metadataCheck {
                    SettingsStackRow(title: settings.t("field.spotify_client_secret"),
                                     description: settings.t("field.spotify_client_secret_role")) {
                        SetupCredentialInput(title: settings.t("field.spotify_client_secret"), text: $settings.spotifyClientSecret,
                                             identifier: "onboarding.client-secret", secure: true)
                    }
                }
            }
            .disabled(model.spotifyCredentialsValidationInFlight)
            if !model.spotifyValidationStatus.trimmed.isEmpty {
                SettingsStatusLine(text: model.spotifyValidationStatus,
                                   dot: model.spotifyCredentialsValidationFailed ? palette.danger : nil,
                                   busy: model.spotifyCredentialsValidationInFlight)
                    .accessibilityIdentifier("onboarding.status")
            }
            Button { setupHelp.toggle() } label: {
                SettingsButtonLabel(title: settings.t("spotify.setup.instructions"),
                                    systemImage: setupHelp ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(SettingsButtonStyle(fullWidth: true))
            .accessibilityValue(settings.t(setupHelp ? "label.on" : "label.off"))
            .accessibilityIdentifier("onboarding.help")
            if setupHelp { SpotifySetupInstructionsPanel() }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var navigation: some View {
        VStack(spacing: 8) {
            Button {
                endEditing()
                if phase < 2 { model.advanceOnboarding() } else { model.finishInitialSetup(validateMetadata: metadataCheck) }
            } label: {
                SettingsButtonLabel(title: nextTitle, busy: model.spotifyCredentialsValidationInFlight)
            }
            .buttonStyle(SettingsButtonStyle(tone: .primary, fullWidth: true))
            .disabled(phase == 2 && (!model.initialSetupComplete || model.spotifyCredentialsValidationInFlight))
            .accessibilityIdentifier("onboarding.next")
            if phase > 0 {
                Button { model.retreatOnboarding() } label: {
                    SettingsButtonLabel(title: settings.t("button.previous"))
                }
                .buttonStyle(SettingsButtonStyle(fullWidth: true))
                .accessibilityIdentifier("onboarding.back")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var nextTitle: String {
        guard phase == 2 else { return settings.t("button.next") }
        if model.spotifyCredentialsValidationInFlight { return settings.t("spotify.validate_checking") }
        return settings.t(model.spotifyCredentialsValidationFailed ? "onboarding.retry" : "button.save_start")
    }

    private func endEditing() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// UIKit owns the whole 48pt input (including its AX frame), rather than a 22pt
/// SwiftUI text line inside decorative padding. Uses the settings field chrome.
private struct SetupCredentialInput: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.settingsPalette) private var palette
    let title: String
    @Binding var text: String
    let identifier: String
    var secure = false
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 0) {
            SetupNativeCredentialField(title: title, text: $text, identifier: identifier, secure: secure && !revealed)
                .frame(maxWidth: .infinity)
            if secure {
                SettingsIconButton(systemImage: revealed ? "eye.slash" : "eye",
                                   label: settings.t(revealed ? "settings.secret.hide" : "settings.secret.show")) {
                    revealed.toggle()
                }
            }
        }
        .background(palette.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.line2))
    }
}

private struct SetupNativeCredentialField: UIViewRepresentable {
    @Environment(\.settingsPalette) private var palette
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    @Binding var text: String
    let identifier: String
    let secure: Bool

    final class Field: UITextField {
        override func textRect(forBounds bounds: CGRect) -> CGRect { bounds.insetBy(dx: 12, dy: 0) }
        override func editingRect(forBounds bounds: CGRect) -> CGRect { textRect(forBounds: bounds) }
    }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.borderStyle = .none
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.keyboardType = .asciiCapable
        field.returnKeyType = .done
        field.adjustsFontForContentSizeCategory = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        if field.isSecureTextEntry != secure { field.isSecureTextEntry = secure }
        field.accessibilityIdentifier = identifier
        field.accessibilityLabel = title
        field.attributedPlaceholder = NSAttributedString(string: title, attributes: [.foregroundColor: UIColor(palette.text3)])
        field.font = font
        field.textColor = UIColor(palette.text)
        field.tintColor = UIColor(palette.accent)
        field.keyboardAppearance = palette.isDark ? .dark : .light
        field.isEnabled = isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Field, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: max(48, font.lineHeight + 20))
    }

    private var font: UIFont {
        let categories: [DynamicTypeSize: UIContentSizeCategory] = [
            .xSmall: .extraSmall, .small: .small, .medium: .medium, .large: .large,
            .xLarge: .extraLarge, .xxLarge: .extraExtraLarge, .xxxLarge: .extraExtraExtraLarge,
            .accessibility1: .accessibilityMedium, .accessibility2: .accessibilityLarge,
            .accessibility3: .accessibilityExtraLarge, .accessibility4: .accessibilityExtraExtraLarge,
            .accessibility5: .accessibilityExtraExtraExtraLarge,
        ]
        return UIFont.preferredFont(forTextStyle: .body,
                                    compatibleWith: UITraitCollection(preferredContentSizeCategory: categories[textSize] ?? .large))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SetupNativeCredentialField
        init(_ parent: SetupNativeCredentialField) { self.parent = parent }
        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }
        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.resignFirstResponder()
            return true
        }
    }
}

/// Content-sized in portrait, scrollable within the safe area at AX sizes and in landscape.
struct FirstLanguagePromptSheetView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let prompt: FirstLanguagePrompt
    @State private var translationEnabled = false
    @State private var pronunciationEnabled = false
    @State private var loadedRule = false
    @State private var contentHeight: CGFloat = 0

    private var palette: SettingsPalette { SettingsTheme.palette(settings.settingsTheme) }
    private var providerHintKeys: [String] {
        let snapshot = settings.snapshot
        var hints: [String] = []
        if translationEnabled && !snapshot.hasAnyTranslationProvider {
            hints.append("first_language.translation_provider_required")
        }
        if pronunciationEnabled && !snapshot.hasReadyAIProvider {
            hints.append("first_language.pronunciation_ai_provider_hint")
        }
        return hints
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.56).ignoresSafeArea()
                let availableHeight = max(0, geometry.size.height - 32)
                ScrollView {
                    panel.background {
                        GeometryReader { content in
                            Color.clear.preference(key: FirstLanguageContentHeight.self, value: content.size.height)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .accessibilityIdentifier("first-language.scroll")
                .frame(width: min(360, max(0, geometry.size.width - 32)),
                       height: min(contentHeight > 0 ? contentHeight : availableHeight, availableHeight))
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.line2))
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onPreferenceChange(FirstLanguageContentHeight.self) { contentHeight = $0 }
            }
        }
        .environment(\.settingsPalette, palette)
        .preferredColorScheme(palette.colorScheme)
        .accessibilityElement(children: .contain)
        .environment(\.colorScheme, palette.colorScheme)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { model.dismissFirstLanguagePrompt(prompt: prompt) }
        .onAppear {
            guard !loadedRule else { return }
            let rule = settings.languageRule(for: prompt.sourceLang)
            translationEnabled = rule.translationEnabled
            pronunciationEnabled = rule.pronunciationEnabled
            loadedRule = true
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 8) {
                Text(settings.tf("first_language.title_format", prompt.languageName))
                    .font(.headline)
                    .foregroundStyle(palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("first-language.title")
                SettingsIconButton(systemImage: "xmark", label: settings.t("first_language.not_now")) {
                    model.dismissFirstLanguagePrompt(prompt: prompt)
                }
                .accessibilityIdentifier("first-language.not-now")
            }
            Text(settings.t("first_language.message"))
                .font(.footnote)
                .foregroundStyle(palette.text2)
            SettingsGroup {
                SettingsToggleRow(title: settings.t("first_language.translation"), isOn: $translationEnabled,
                                  identifier: "first-language.translation")
                SettingsToggleRow(title: settings.t("first_language.pronunciation"), isOn: $pronunciationEnabled,
                                  identifier: "first-language.pronunciation")
            }
            if !providerHintKeys.isEmpty {
                Text(providerHintKeys.map { settings.t($0) }.joined(separator: "\n"))
                    .font(.footnote)
                    .foregroundStyle(palette.text2)
                    .accessibilityIdentifier("first-language.provider-hint")
            }
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                    model.applyFirstLanguagePromptChoice(choice, prompt: prompt)
                }
            } label: {
                SettingsButtonLabel(title: settings.t(translationEnabled || pronunciationEnabled ? "first_language.apply" : "first_language.original"))
            }
            .buttonStyle(SettingsButtonStyle(tone: .primary, fullWidth: true))
            .accessibilityIdentifier("first-language.apply")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .debugSettingsHitArea("first-language.panel")
    }

    private var choice: FirstLanguagePromptChoice {
        switch (translationEnabled, pronunciationEnabled) {
        case (true, true): return .both
        case (true, false): return .translation
        case (false, true): return .pronunciation
        case (false, false): return .original
        }
    }
}

private struct FirstLanguageContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
