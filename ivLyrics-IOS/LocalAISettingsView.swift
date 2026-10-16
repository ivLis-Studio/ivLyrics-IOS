import SwiftUI

/// Settings for the Local AI provider: download, quality, processor and idle release.
/// The model is downloaded only from here, on an explicit tap.
struct LocalAISettingsPanel: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.settingsPalette) private var palette
    @ObservedObject private var controller = LocalAIController.shared
    @State private var confirmingDelete = false
    @State private var choosingIdle = false

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
            qualityRow
            statusRow
            processorRow
            idleRow
            Text(settings.t("local_ai.privacy"))
                .font(.footnote)
                .foregroundStyle(palette.text3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .settingsRowSeparator()
        }
        .onAppear { controller.refresh() }
        .onDisappear { controller.clearTest() }
        .onChange(of: settings.snapshot.targetLanguage) { _, _ in controller.clearTest() }
        .onChange(of: settings.uiLang) { _, _ in controller.clearTest() }
        .onChange(of: settings.localAITier) { _, _ in
            confirmingDelete = false
            controller.configurationChanged(configuration)
        }
        .onChange(of: settings.localAIProcessor) { _, _ in
            controller.configurationChanged(configuration)
        }
        .sheet(isPresented: $choosingIdle) {
            SettingsOptionSheet(
                title: settings.t("local_ai.idle_unload"),
                options: LocalAI.idleMinuteOptions.map { SettingsChoice(value: String($0), title: idleLabel($0)) },
                selection: String(LocalAI.normalizedIdleMinutes(settings.localAIIdleMinutes)),
                searchPrompt: settings.t("button.search"),
                closeLabel: settings.t("button.close"),
                emptyText: settings.t("settings.no_results"),
                onSelect: { value in
                    guard let minutes = Int(value) else { return }
                    settings.localAIIdleMinutes = minutes
                    controller.setIdleMinutes(minutes)
                    model.showSavedToast(settings.t("toast.settings_saved"))
                }
            )
            .environment(\.settingsPalette, palette)
        }
    }

    // MARK: Status and actions

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(statusText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(statusColor)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
            if phase == .downloading {
                ProgressView(value: downloadFraction)
                    .tint(palette.accent)
                    .accessibilityHidden(true)
            }
            SettingsFlowLayout(spacing: 8, lineSpacing: 8) {
                if phase == .downloading {
                    actionButton(settings.t("local_ai.cancel")) { controller.cancelDownload() }
                } else if !fileReady {
                    actionButton(LocalAI.format(settings.t("local_ai.download"), ["size": LocalAI.formatGigabytes(tier.byteCount)]),
                                 tone: .primary, systemImage: "arrow.down.circle") {
                        confirmingDelete = false
                        controller.download(tier)
                    }
                    .disabled(busy)
                }
                if fileReady {
                    actionButton(settings.t("local_ai.test"), busy: controller.test == .running) {
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
                    actionButton(settings.t(confirmingDelete ? "local_ai.confirm_remove" : "local_ai.remove"), tone: .danger) {
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
            case let .passed(result)?:
                VStack(alignment: .leading, spacing: 4) {
                    testResult("✓ \(result.sample) → \(result.line)", color: palette.ok)
                    testResult(LocalAI.format(settings.t("local_ai.test_total_time"), [
                        "seconds": String(format: "%.1f", result.seconds)
                    ]), color: palette.text2)
                    if let performance = result.performance, let speed = performance.tokensPerSecond {
                        testResult(LocalAI.format(settings.t("local_ai.test_speed"), [
                            "speed": String(format: "%.1f", speed), "tokens": String(performance.tokens),
                            "seconds": String(format: "%.2f", performance.seconds)
                        ]), color: palette.text2)
                        testResult(settings.t("local_ai.test_speed_scope"), color: palette.text3)
                    } else {
                        testResult(settings.t("local_ai.test_speed_unavailable"), color: palette.text2)
                    }
                    if tier.sliderIndex > 0 {
                        testResult(LocalAI.format(settings.t("local_ai.test_smaller_hint"), [
                            "tier": settings.t(LocalAI.Tier(sliderIndex: tier.sliderIndex - 1).titleKey)
                        ]), color: palette.text3)
                    }
                }
                .accessibilityElement(children: .combine)
            case let .failed(message)?:
                testResult(message, color: palette.danger)
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
            return LocalAI.format(settings.t("local_ai.status_error"), ["error": state.failure?.message(uiLanguage: settings.uiLang) ?? ""])
        case .missing:
            return settings.t("local_ai.status_not_downloaded")
        }
    }

    private var statusColor: Color {
        switch phase {
        case .ready: return palette.ok
        case .error: return palette.danger
        default: return palette.text2
        }
    }

    private var downloadFraction: Double {
        let total = controller.state.totalBytes > 0 ? controller.state.totalBytes : tier.byteCount
        return min(1, max(0, Double(controller.state.loadedBytes) / Double(max(1, total))))
    }

    private func testResult(_ message: String, color: Color) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    // MARK: Quality

    private var qualityRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(settings.t("local_ai.quality"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(settings.t(tier.titleKey))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(palette.text3)
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
                .font(.footnote)
                .foregroundStyle(palette.text3)
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
                .font(.footnote.weight(step == tier ? .semibold : .regular))
                .foregroundStyle(step == tier ? palette.text : palette.text3)
            Text(LocalAI.formatGigabytes(step.byteCount))
                .font(.caption.monospacedDigit())
                .foregroundStyle(palette.text3)
            if controller.state.downloadedTiers.contains(step) {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2.weight(.semibold))
                    Text(settings.t("local_ai.tier_downloaded"))
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(palette.ok)
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
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.t("local_ai.device"))
                .font(.callout.weight(.medium))
                .foregroundStyle(palette.text)
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
                    (value: LocalAI.Processor.auto.rawValue, title: settings.t("local_ai.device_auto")),
                    (value: LocalAI.Processor.cpu.rawValue, title: settings.t("local_ai.device_cpu"))
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
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.t("local_ai.idle_unload"))
                .font(.callout.weight(.medium))
                .foregroundStyle(palette.text)
            SettingsPickerButton(
                title: settings.t("local_ai.idle_unload"),
                value: idleLabel(LocalAI.normalizedIdleMinutes(settings.localAIIdleMinutes))
            ) {
                choosingIdle = true
            }
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

    private func actionButton(_ title: String, tone: SettingsButtonStyle.Tone = .normal, systemImage: String? = nil,
                              busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(role: tone == .danger ? .destructive : nil, action: action) {
            SettingsButtonLabel(title: title, systemImage: systemImage, busy: busy)
        }
        .buttonStyle(SettingsButtonStyle(tone: tone))
    }
}

