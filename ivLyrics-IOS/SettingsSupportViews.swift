import SwiftUI
import UIKit

/// Spotify developer-app setup guide (six steps, copy rows, dashboard link).
struct SpotifySetupInstructionsPanel: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.settingsPalette) private var palette
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var step = 0
    @State private var copiedMessage = ""

    private let stepCount = 6
    private let dashboardURL = "https://developer.spotify.com/dashboard"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(settings.t("spotify.setup.instructions"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SettingsPill(text: settings.tf("onboarding.step_format", step + 1, stepCount))
            }
            HStack(spacing: 4) {
                ForEach(0..<stepCount, id: \.self) { index in
                    Capsule()
                        .fill(index == step ? palette.accent : (index < step ? palette.accent.opacity(0.45) : palette.surface4))
                        .frame(height: 3)
                }
            }
            .accessibilityHidden(true)
            Text(stepTitle)
                .font(.callout.weight(.semibold))
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(stepDescription)
                .font(.footnote)
                .foregroundStyle(palette.text2)
                .fixedSize(horizontal: false, vertical: true)
            if let item = copyItem {
                copyRow(title: item.title, value: item.value)
            }
            if !copiedMessage.trimmed.isEmpty {
                Text(copiedMessage)
                    .font(.caption)
                    .foregroundStyle(palette.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            navigation
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.line))
    }

    @ViewBuilder
    private var navigation: some View {
        let open = Button {
            if let url = URL(string: dashboardURL) { openURL(url) }
        } label: {
            SettingsButtonLabel(title: settings.t("button.open_browser"), systemImage: "arrow.up.right.square")
        }
        .buttonStyle(SettingsButtonStyle())
        let steps = HStack(spacing: 8) {
            Button(settings.t("button.previous")) {
                step = max(0, step - 1)
            }
            .buttonStyle(SettingsButtonStyle())
            .disabled(step == 0)
            .accessibilityIdentifier("spotify.setup.previous")
            Button(step == stepCount - 1 ? settings.t("button.restart") : settings.t("button.next")) {
                step = step == stepCount - 1 ? 0 : step + 1
            }
            .buttonStyle(SettingsButtonStyle(tone: .primary))
            .accessibilityIdentifier("spotify.setup.next")
        }
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                if step == 0 { open }
                steps
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    if step == 0 { open }
                    Spacer(minLength: 0)
                    steps
                }
                VStack(alignment: .leading, spacing: 8) {
                    if step == 0 { open }
                    steps
                }
            }
        }
    }

    private var stepTitle: String {
        settings.t("spotify.step\(step).title")
    }

    private var stepDescription: String {
        settings.t("spotify.step\(step).desc")
    }

    private var copyItem: (title: String, value: String)? {
        switch step {
        case 0:
            return (settings.t("spotify.copy.dashboard_url"), dashboardURL)
        case 1:
            return (settings.t("spotify.copy.app_name"), "trackinfo")
        case 2:
            return (settings.t("spotify.copy.app_description"), "trackinfo")
        case 3:
            return (settings.t("spotify.copy.redirect_uri"), SpotifyRedirectConfiguration.uri)
        default:
            return nil
        }
    }

    private func copyRow(title: String, value: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(palette.text3)
                Text(value)
                    .font(.footnote.monospaced())
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                UIPasteboard.general.string = value
                copiedMessage = settings.tf("toast.copied_format", value)
            } label: {
                SettingsButtonLabel(title: settings.t("button.copy"), systemImage: "doc.on.doc")
            }
            .buttonStyle(SettingsButtonStyle())
        }
        .padding(10)
        .background(palette.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.line))
    }
}

struct SpeakerColorRow: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    let slot: AppSettings.SpeakerColorSlot

    var body: some View {
        HexColorEditorRow(
            title: slotTitle,
            hexColor: colorBinding,
            fallback: slot.defaultColor,
            onSave: { model.showSavedToast(settings.t("toast.speaker_colors_saved")) }
        )
    }

    private var colorBinding: Binding<String> {
        Binding(
            get: { settings.speakerColorSettings().hex(slot.id) },
            set: { settings.setSpeakerColor(slotId: slot.id, color: $0) }
        )
    }

    private var slotTitle: String {
        if slot.id == AppSettings.speakerColorNormal {
            return settings.t("speaker_color.normal")
        }
        let baseKey: String
        if slot.id.hasPrefix("duet") {
            baseKey = "speaker_color.duet"
        } else if slot.id.hasPrefix("male") {
            baseKey = "speaker_color.male"
        } else if slot.id.hasPrefix("female") {
            baseKey = "speaker_color.female"
        } else {
            return slot.label
        }
        guard let number = Int(slot.id.replacingOccurrences(of: #"^\D+"#, with: "", options: .regularExpression)) else {
            return settings.t(baseKey)
        }
        return "\(settings.t(baseKey)) \(number)"
    }
}

/// Colour well, system colour picker and a hex field; an invalid hex keeps the old colour.
struct HexColorEditorRow: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.settingsPalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var fieldWidth: CGFloat = 104
    let title: String
    @Binding var hexColor: String
    let fallback: String
    var onSave: (() -> Void)? = nil
    @State private var draft = ""
    @State private var invalidDraft = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    label
                    HStack(spacing: 10) { picker; hexField }
                }
            } else {
                HStack(spacing: 10) {
                    label
                    picker
                    hexField
                }
            }
        }
        .onAppear {
            draft = normalizedColor
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused {
                saveDraft()
            }
        }
        .onChange(of: hexColor) { _, _ in
            if !focused {
                draft = normalizedColor
                invalidDraft = false
            }
        }
    }

    private var label: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(hex: normalizedColor))
                .frame(width: 22, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(palette.line3))
                .accessibilityHidden(true)
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var picker: some View {
        ColorPicker(title, selection: colorBinding, supportsOpacity: false)
            .labelsHidden()
            .frame(width: 44, height: 44)
    }

    private var hexField: some View {
        TextField(fallback, text: $draft)
            .multilineTextAlignment(.trailing)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.callout.monospaced())
            .foregroundStyle(invalidDraft ? palette.danger : palette.text)
            .focused($focused)
            .onChange(of: draft) { _, value in
                invalidDraft = !value.trimmed.isEmpty && !AppSettings.isHexColor(value)
            }
            .onSubmit(saveDraft)
            .padding(.horizontal, 10)
            .frame(width: fieldWidth)
            .frame(minHeight: 44)
            .background(palette.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(invalidDraft ? palette.danger.opacity(0.6) : palette.line2))
            .accessibilityLabel(title)
    }

    private var normalizedColor: String {
        AppSettings.normalizeHexColor(hexColor, fallback: fallback)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: normalizedColor) },
            set: { color in
                guard let hex = color.hexRGB else { return }
                hexColor = hex
                draft = hex
                invalidDraft = false
                onSave?()
            }
        )
    }

    private func saveDraft() {
        guard AppSettings.isHexColor(draft) else {
            invalidDraft = true
            model.showSavedToast(settings.tf("toast.invalid_color_format", title))
            return
        }
        let normalized = AppSettings.normalizeHexColor(draft, fallback: fallback)
        hexColor = normalized
        draft = normalized
        invalidDraft = false
        onSave?()
    }
}

/// One additional OpenAI-compatible provider: switch, order, name, URL, key and model.
struct OpenAIConnectionEditor: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.settingsPalette) private var palette
    @Binding var connection: OpenAIConnection
    var position: Int
    var count: Int
    var onMove: (Int) -> Void
    var onRemove: () -> Void
    @State private var models: [AIProviderModels.Model] = []
    @State private var loadedConfiguration: AIProviderModels.Configuration?
    @State private var loading = false
    @State private var error = false
    @State private var requestID = UUID()
    @State private var revision = 0
    @State private var choosingModel = false

    private var configuration: AIProviderModels.Configuration {
        .init(provider: "chatgpt", baseURL: connection.baseUrl.trimmed.isEmpty ? "https://api.openai.com/v1" : connection.baseUrl,
              apiKeys: connection.apiKeys, pollinationsAccessToken: "")
    }

    private var availableModels: [AIProviderModels.Model] { loadedConfiguration == configuration ? models : [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $connection.enabled) {
                Text("\(position + 2). \(connection.name)")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(palette.text)
            }
            .toggleStyle(SettingsSwitchStyle())
            HStack(spacing: 2) {
                SettingsIconButton(systemImage: "chevron.up", label: settings.t("openai.move_up")) { onMove(-1) }
                    .disabled(position == 0)
                SettingsIconButton(systemImage: "chevron.down", label: settings.t("openai.move_down")) { onMove(1) }
                    .disabled(position == count - 1)
                Spacer(minLength: 8)
                Button(role: .destructive, action: onRemove) {
                    SettingsButtonLabel(title: settings.t("openai.remove_connection"), systemImage: "trash")
                }
                .buttonStyle(SettingsButtonStyle(tone: .danger))
            }
            field(settings.t("openai.connection_name")) {
                TextField(settings.t("openai.connection_name"), text: $connection.name)
                    .settingsFieldChrome()
            }
            field(settings.t("field.base_url")) {
                TextField(settings.t("field.base_url"), text: $connection.baseUrl)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .settingsFieldChrome()
            }
            field(settings.t("field.api_key")) {
                SettingsSecureField(title: settings.t("field.api_key"), text: $connection.apiKeys,
                                    showLabel: settings.t("settings.secret.show"), hideLabel: settings.t("settings.secret.hide"))
            }
            field(settings.t("field.model")) {
                HStack(spacing: 8) {
                    SettingsPickerButton(title: settings.t("field.model"), value: modelLabel) { choosingModel = true }
                        .disabled(loading || availableModels.isEmpty)
                    if loading {
                        ProgressView().frame(width: 44, height: 44)
                    } else {
                        SettingsIconButton(systemImage: "arrow.clockwise", label: settings.t("button.refresh_models")) { revision += 1 }
                    }
                }
            }
            TextField(settings.t("field.model_id"), text: $connection.model)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .settingsFieldChrome()
            if loading {
                Text(settings.t("status.models_loading")).font(.caption).foregroundStyle(palette.text3)
            } else if error {
                Text(settings.t("status.models_unavailable")).font(.caption).foregroundStyle(palette.warn)
            }
        }
        .padding(12)
        .background(palette.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.line))
        .task(id: configuration) { await loadModels() }
        .task(id: revision) { if revision > 0 { await loadModels() } }
        .sheet(isPresented: $choosingModel) {
            SettingsOptionSheet(
                title: settings.t("field.model"),
                options: modelChoices,
                selection: connection.model,
                searchPrompt: settings.t("button.search"),
                closeLabel: settings.t("button.close"),
                emptyText: settings.t("settings.no_results"),
                onSelect: { connection.model = $0 }
            )
            .environment(\.settingsPalette, palette)
        }
    }

    private var modelLabel: String {
        if let model = availableModels.first(where: { $0.id == connection.model }) { return model.displayName }
        return connection.model.isEmpty ? settings.t("field.model_required") : connection.model
    }

    private var modelChoices: [SettingsChoice] {
        var choices: [SettingsChoice] = []
        if !availableModels.contains(where: { $0.id == connection.model }) {
            choices.append(SettingsChoice(value: connection.model,
                                          title: connection.model.isEmpty ? settings.t("field.model_required") : connection.model))
        }
        choices += availableModels.map { SettingsChoice(value: $0.id, title: $0.displayName) }
        return choices
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(palette.text2)
            content()
        }
    }

    @MainActor private func loadModels() async {
#if DEBUG
        if DebugSettingsUIHarness.enabled { return }
#endif
        let context = configuration
        let id = UUID()
        requestID = id
        models = []
        loading = true
        error = false
        defer { if requestID == id { loading = false } }
        do {
            try await Task.sleep(for: .milliseconds(350))
            let catalog = try await AIProviderModels.fetch(context)
            try Task.checkCancellation()
            guard id == requestID, context == configuration else { return }
            models = catalog.models
            loadedConfiguration = context
            error = models.isEmpty
        } catch {
            if !Task.isCancelled, id == requestID, context == configuration { self.error = true }
        }
    }
}

