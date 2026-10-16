import SwiftUI
import UIKit

struct LrclibEndpointSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.settingsPalette) private var palette
    @State private var draft = ""
    @State private var attemptedSave = false
    @FocusState private var focused: Bool

    private var invalid: Bool { LrclibEndpoint.normalized(draft) == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(settings.t("lyrics.lrclib_endpoint.title"))
                .font(.callout.weight(.medium))
                .foregroundStyle(palette.text)
            TextField("https://lrclib.net/api", text: $draft)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focused)
                .settingsFieldChrome()
                .accessibilityLabel(settings.t("lyrics.lrclib_endpoint.title"))
                .accessibilityHint(settings.t(attemptedSave && invalid ? "lyrics.lrclib_endpoint.invalid" : "lyrics.lrclib_endpoint.description"))
                .accessibilityIdentifier("settings.lrclib.endpoint")
                .onSubmit(save)
            Text(settings.t("lyrics.lrclib_endpoint.description"))
                .font(.footnote)
                .foregroundStyle(palette.text3)
                .fixedSize(horizontal: false, vertical: true)
            Text(settings.t("lyrics.lrclib_endpoint.scope"))
                .font(.footnote)
                .foregroundStyle(palette.text3)
                .fixedSize(horizontal: false, vertical: true)
            Text(settings.t("lyrics.lrclib_endpoint.transport"))
                .font(.footnote)
                .foregroundStyle(palette.text3)
                .fixedSize(horizontal: false, vertical: true)
            if attemptedSave && invalid {
                Label(settings.t("lyrics.lrclib_endpoint.invalid"), systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.lrclib.endpoint.error")
            }
            Button(action: save) {
                SettingsButtonLabel(title: settings.t("lyrics.lrclib_endpoint.save"), systemImage: "checkmark")
            }
            .buttonStyle(SettingsButtonStyle())
            .accessibilityIdentifier("settings.lrclib.endpoint.save")
        }
        .onAppear { draft = settings.lrclibCustomEndpoint }
        .onChange(of: settings.lrclibCustomEndpoint) { _, value in draft = value }
    }

    private func save() {
        attemptedSave = true
        guard !invalid, model.updateLrclibCustomEndpoint(draft) else {
            focused = true
            UIAccessibility.post(notification: .announcement, argument: settings.t("lyrics.lrclib_endpoint.invalid"))
            return
        }
        draft = settings.lrclibCustomEndpoint
        focused = false
        model.showSavedToast(settings.t("toast.settings_saved"))
    }
}
