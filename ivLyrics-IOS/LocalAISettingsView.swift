import SwiftUI

/// Settings for the Local AI provider: download, quality, processor and idle release.
/// The model is downloaded only from here, on an explicit tap.
struct LocalAISettingsPanel: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    @ObservedObject private var controller = LocalAIController.shared
    @State private var confirmingDelete = false

    private var tier: LocalAI.Tier { .stored(settings.localAITier) }
    private var phase: LocalAI.Phase { controller.state.phase(for: tier) }
    private var busy: Bool { phase == .downloading || phase == .loading }
    private var fileReady: Bool { controller.state.downloadedTiers.contains(tier) && phase != .downloading }

    private var configuration: LocalAI.Configuration {
        LocalAI.Configuration(
            tier: tier,
            processor: .stored(settings.localAIProcessor),
            idleMinutes: LocalAI.normalizedIdleMinutes(settings.localAIIdleMinutes)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusRow
            qualityRow
            processorRow
            idleRow
            Text(settings.t("local_ai.privacy"))
                .font(.pretendard(12))
                .foregroundStyle(SettingsDesign.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
        .onAppear { controller.refresh() }
        .onChange(of: settings.localAITier) { _, _ in
            confirmingDelete = false
            controller.configurationChanged(configuration)
        }
        .onChange(of: settings.localAIProcessor) { _, _ in
            controller.configurationChanged(configuration)
        }
    }

    // MARK: Status and actions

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(statusText)
                .font(.pretendard(13.5, weight: .semibold))
                .foregroundStyle(statusColor)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
            if phase == .downloading {
                ProgressView(value: downloadFraction)
                    .tint(SettingsDesign.accent)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 8) {
                if phase == .downloading {
                    actionButton(settings.t("local_ai.cancel")) { controller.cancelDownload() }
                } else if !fileReady {
                    actionButton(LocalAI.format(settings.t("local_ai.download"), ["size": LocalAI.formatGigabytes(tier.byteCount)])) {
                        confirmingDelete = false
                        controller.download(tier)
                    }
                    .disabled(busy)
                }
                if fileReady {
                    actionButton(controller.test == .running ? "…" : settings.t("local_ai.test")) {
                        controller.runTest(
                            targetLanguage: settings.snapshot.targetLanguage,
                            configuration: configuration,
                            uiLanguage: settings.uiLang
                        )
                    }
                    .disabled(busy || controller.test == .running)
                }
                if phase == .ready {
                    actionButton(settings.t("local_ai.unload")) { controller.freeMemory() }
                }
                if fileReady {
                    actionButton(settings.t(confirmingDelete ? "local_ai.confirm_remove" : "local_ai.remove"), role: .destructive) {
                        guard confirmingDelete else {
                            confirmingDelete = true
                            return
                        }
                        confirmingDelete = false
                        controller.delete(tier)
                    }
                    .disabled(busy)
                }
            }
            switch controller.test {
            case let .passed(message)?:
                testResult(message, color: SettingsDesign.mint)
            case let .failed(message)?:
                testResult(message, color: SettingsDesign.accent)
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .settingsRowSeparator()
    }

    private var statusText: String {
        let state = controller.state
        switch phase {
        case .downloading:
            let total = state.totalBytes > 0 ? state.totalBytes : tier.byteCount
            return LocalAI.format(settings.t("local_ai.status_downloading"), [
                "percent": String(LocalAI.downloadPercent(loaded: state.loadedBytes, total: total)),
                "loaded": String(LocalAI.megabytes(state.loadedBytes)),
                "total": String(LocalAI.megabytes(total))
            ])
        case .downloaded:
            return settings.t("local_ai.status_downloaded")
        case .loading:
            return settings.t("local_ai.status_loading")
        case .ready:
            return LocalAI.format(settings.t("local_ai.status_ready"), ["device": state.device ?? "GPU"])
        case .error:
            return LocalAI.format(settings.t("local_ai.status_error"), ["error": state.error ?? ""])
        case .missing:
            return settings.t("local_ai.status_not_downloaded")
        }
    }

    private var statusColor: Color {
        switch phase {
        case .ready: return SettingsDesign.mint
        case .error: return SettingsDesign.accent
        default: return SettingsDesign.secondary
        }
    }

    private var downloadFraction: Double {
        let total = controller.state.totalBytes > 0 ? controller.state.totalBytes : tier.byteCount
        return min(1, max(0, Double(controller.state.loadedBytes) / Double(max(1, total))))
    }

    private func testResult(_ message: String, color: Color) -> some View {
        Text(message)
            .font(.pretendard(12.5))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    // MARK: Quality

    private var qualityRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(settings.t("local_ai.quality"))
                    .font(.pretendard(15, weight: .semibold))
                    .foregroundStyle(SettingsDesign.text)
                Spacer(minLength: 8)
                Text(settings.t(tier.titleKey))
                    .font(.pretendard(13))
                    .foregroundStyle(SettingsDesign.secondary)
            }
            // A three-step slider the user drags; each step is one model file.
            SettingsSlider(value: tierBinding, in: 0...Double(LocalAI.Tier.allCases.count - 1), step: 1) { editing in
                if !editing { model.showSavedToast(settings.t("toast.settings_saved")) }
            }
            .disabled(busy)
            .accessibilityLabel(settings.t("local_ai.quality"))
            .accessibilityValue("\(settings.t(tier.titleKey)), \(LocalAI.formatGigabytes(tier.byteCount))")
            HStack(alignment: .top, spacing: 6) {
                ForEach(LocalAI.Tier.allCases) { step in
                    tierLabel(step)
                        .frame(maxWidth: .infinity, alignment: frameAlignment(step))
                }
            }
            Text(settings.t("local_ai.tier_hint"))
                .font(.pretendard(12.5))
                .foregroundStyle(SettingsDesign.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .settingsRowSeparator()
    }

    private var tierBinding: Binding<Double> {
        Binding(
            get: { Double(LocalAI.Tier.stored(settings.localAITier).sliderIndex) },
            set: { value in
                let next = LocalAI.Tier(sliderIndex: Int(value.rounded())).rawValue
                if next != settings.localAITier { settings.localAITier = next }
            }
        )
    }

    private func tierLabel(_ step: LocalAI.Tier) -> some View {
        VStack(alignment: stackAlignment(step), spacing: 2) {
            Text(settings.t(step.titleKey))
                .font(.pretendard(12.5, weight: step == tier ? .bold : .regular))
                .foregroundStyle(step == tier ? SettingsDesign.text : SettingsDesign.secondary)
            Text(LocalAI.formatGigabytes(step.byteCount))
                .font(.pretendard(11.5))
                .monospacedDigit()
                .foregroundStyle(SettingsDesign.muted)
            if controller.state.downloadedTiers.contains(step) {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(settings.t("local_ai.tier_downloaded"))
                        .font(.pretendard(11, weight: .semibold))
                }
                .foregroundStyle(SettingsDesign.mint)
            }
        }
        .multilineTextAlignment(textAlignment(step))
        .accessibilityElement(children: .combine)
    }

    private func frameAlignment(_ step: LocalAI.Tier) -> Alignment {
        step == .light ? .leading : step == .high ? .trailing : .center
    }

    private func stackAlignment(_ step: LocalAI.Tier) -> HorizontalAlignment {
        step == .light ? .leading : step == .high ? .trailing : .center
    }

    private func textAlignment(_ step: LocalAI.Tier) -> TextAlignment {
        step == .light ? .leading : step == .high ? .trailing : .center
    }

    // MARK: Processor and idle release

    private var processorRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(settings.t("local_ai.device"))
                .font(.pretendard(15, weight: .semibold))
                .foregroundStyle(SettingsDesign.text)
            SettingsSegmentedPicker(
                title: settings.t("local_ai.device"),
                selection: Binding(
                    get: { LocalAI.Processor.stored(settings.localAIProcessor).rawValue },
                    set: { value in
                        guard value != settings.localAIProcessor else { return }
                        settings.localAIProcessor = value
                        model.showSavedToast(settings.t("toast.settings_saved"))
                    }
                ),
                options: [
                    (LocalAI.Processor.auto.rawValue, settings.t("local_ai.device_auto")),
                    (LocalAI.Processor.cpu.rawValue, settings.t("local_ai.device_cpu"))
                ]
            )
            .disabled(busy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .settingsRowSeparator()
    }

    private var idleRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(settings.t("local_ai.idle_unload"))
                .font(.pretendard(15, weight: .semibold))
                .foregroundStyle(SettingsDesign.text)
            Picker(settings.t("local_ai.idle_unload"), selection: Binding(
                get: { LocalAI.normalizedIdleMinutes(settings.localAIIdleMinutes) },
                set: { minutes in
                    settings.localAIIdleMinutes = minutes
                    controller.setIdleMinutes(minutes)
                    model.showSavedToast(settings.t("toast.settings_saved"))
                }
            )) {
                ForEach(LocalAI.idleMinuteOptions, id: \.self) { minutes in
                    Text(idleLabel(minutes)).tag(minutes)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(.pretendard(14.5, weight: .semibold))
            .tint(SettingsDesign.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
            .background(SettingsDesign.control, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .settingsRowSeparator()
    }

    private func idleLabel(_ minutes: Int) -> String {
        if minutes == 0 { return settings.t("local_ai.idle_never") }
        if minutes % 60 == 0 {
            return LocalAI.format(settings.t("local_ai.idle_after_hours"), ["hours": String(minutes / 60)])
        }
        return LocalAI.format(settings.t("local_ai.idle_after"), ["minutes": String(minutes)])
    }

    private func actionButton(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.pretendard(13.5, weight: .semibold))
                .foregroundStyle(role == .destructive ? SettingsDesign.accent : SettingsDesign.text)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .padding(.horizontal, 10)
                .background(SettingsDesign.control, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(SettingsDesign.strongBorder))
        }
        .buttonStyle(SettingsActionButtonStyle())
    }
}

