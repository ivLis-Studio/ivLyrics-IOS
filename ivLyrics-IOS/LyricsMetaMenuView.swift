import SwiftUI

enum LyricsMetaMenuTab: String, CaseIterable, Identifiable {
    case language
    case sync
    case video
    case background
    case lrclib

    var id: String { rawValue }

    var title: String {
        switch self {
        case .language:
            return "Language"
        case .sync:
            return "Sync"
        case .video:
            return "Video"
        case .background:
            return "Background"
        case .lrclib:
            return "LRCLIB"
        }
    }
}

struct LyricsMetaMenuOverlay: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    @Binding var visible: Bool
    @Binding var selectedTab: LyricsMetaMenuTab
    var screenHeight: CGFloat
    var openPictureInPicture: () -> Void = {}
    @State private var dragOffset: CGFloat = 0
    @State private var backgroundColorDraft = ""
    @State private var backgroundColorDraftInvalid = false
    @FocusState private var backgroundColorFieldFocused: Bool

    private var panelTopPadding: CGFloat {
        min(118, max(88, screenHeight * 0.12))
    }

    private var scrollableContentHeight: CGFloat {
        let available = max(220, screenHeight - panelTopPadding - 156)
        switch selectedTab {
        case .language:
            return 0
        case .sync:
            return min(available, 520)
        case .video:
            return min(available, 300)
        case .background:
            return min(available, model.currentTrackKey.isEmpty ? 150 : 540)
        case .lrclib:
            return min(available, 460)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    dismiss()
                }

            panel
                .frame(maxWidth: 430)
                .padding(.horizontal, 22)
                .padding(.top, panelTopPadding)
                .offset(y: max(0, dragOffset))
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var panel: some View {
        VStack(spacing: 0) {
            topRow
            tabRow
                .padding(.top, 10)

            if selectedTab == .language {
                languageTab
                    .padding(.top, 10)
            } else {
                ScrollView {
                    tabContent
                        .padding(.bottom, 2)
                }
                .scrollIndicators(.visible)
                .frame(height: scrollableContentHeight)
                .padding(.top, 10)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .foregroundStyle(.white)
        .background(
            Color(red: 18.0 / 255.0, green: 20.0 / 255.0, blue: 30.0 / 255.0)
                .opacity(236.0 / 255.0),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private var topRow: some View {
        Button {
            openPictureInPicture()
            dismiss()
        } label: {
            Text(settings.t("pip.open_lyrics"))
                .font(.pretendard(15, weight: .bold))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(dismissDragGesture)
    }

    private var tabRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(LyricsMetaMenuTab.allCases) { tab in
                        Button {
                            selectedTab = tab
                            if tab == .lrclib, model.manualCandidates.isEmpty {
                                model.searchManualCandidates()
                            }
                        } label: {
                            Text(tabTitle(tab))
                                .font(.pretendard(14, weight: .semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .frame(minWidth: 72)
                                .frame(height: 38)
                                .foregroundStyle(selectedTab == tab ? Color.black : Color.white)
                                .background(
                                    selectedTab == tab ? Color.white.opacity(0.96) : Color.white.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                        .id(tab.id)
                    }
                }
            }
            .onAppear {
                scrollSelectedTabIntoView(proxy, animated: false)
            }
            .onChange(of: selectedTab) { _, _ in
                scrollSelectedTabIntoView(proxy, animated: true)
            }
        }
    }

    private func scrollSelectedTabIntoView(_ proxy: ScrollViewProxy, animated: Bool) {
        let target: String
        switch selectedTab {
        case .language:
            target = LyricsMetaMenuTab.language.id
        case .lrclib:
            target = LyricsMetaMenuTab.sync.id
        case .sync, .video, .background:
            return
        }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(target, anchor: .leading)
                }
            } else {
                proxy.scrollTo(target, anchor: .leading)
            }
        }
    }

    private func tabTitle(_ tab: LyricsMetaMenuTab) -> String {
        switch tab {
        case .language:
            return settings.t("lyrics.tab.language")
        case .sync:
            return settings.t("lyrics.tab.sync")
        case .video:
            return settings.t("lyrics.tab.video")
        case .background:
            return settings.t("lyrics.tab.background")
        case .lrclib:
            return "LRCLIB"
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .language:
            languageTab
        case .sync:
            syncTab
        case .video:
            videoTab
        case .background:
            backgroundTab
        case .lrclib:
            lrclibTab
        }
    }

    private var languageTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(languageRuleSummary)
                .font(.pretendard(12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            Menu {
                Button("auto(\(model.effectiveDetectedLyricsSourceLang))") {
                    model.setSelectedRuleSourceLang("auto")
                }
                ForEach(AppSettings.languages) { language in
                    Button("\(language.nativeName) · \(language.name)") {
                        model.setSelectedRuleSourceLang(language.code)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(sourceStatusText)
                        .font(.pretendard(14, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .tint(.white)

            HStack(spacing: 8) {
                metaToggleCell(
                    settings.t("lyrics.translation"),
                    isOn: selectedRuleTranslationBinding
                )
                metaToggleCell(
                    settings.t("lyrics.pronunciation"),
                    isOn: selectedRulePronunciationBinding
                )
            }

            if settings.culturalAnnotationsEnabled {
                Button {
                    model.regenerateCulturalAnnotations()
                    dismiss()
                } label: {
                    Label(
                        settings.t("button.regenerate_cultural_annotations"),
                        systemImage: "arrow.clockwise"
                    )
                    .font(.pretendard(13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var syncTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            offsetBlock(
                title: settings.t("lyrics.global_sync.title"),
                detail: settings.t("lyrics.global_sync.help"),
                resetTitle: settings.t("lyrics.global_sync.reset"),
                value: model.globalOffsetMs,
                setValue: { model.setGlobalOffsetMs($0, notify: true) },
                isDimmed: false
            )
            offsetBlock(
                title: settings.t("lyrics.sync.title"),
                detail: trackSyncDetailText,
                resetTitle: settings.t("lyrics.sync.reset"),
                value: model.trackOffsetMs,
                setValue: { model.setTrackOffsetMs($0, notify: true) },
                isDimmed: model.currentTrackKey.isEmpty
            )
            offsetBlock(
                title: settings.t("lyrics.bluetooth_sync.title"),
                detail: bluetoothSyncDetailText,
                resetTitle: settings.t("lyrics.bluetooth_sync.reset"),
                value: model.bluetoothOffsetMs,
                setValue: { model.setBluetoothOffsetMs($0, notify: true) },
                isDimmed: !model.hasBluetoothAudioDevice
            )
        }
    }

    private var videoTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            offsetBlock(
                title: settings.t("lyrics.video_sync.title"),
                detail: videoSyncDetailText,
                resetTitle: settings.t("lyrics.video_sync.reset"),
                value: model.videoOffsetMs,
                setValue: { model.setVideoOffsetMs($0, notify: true) },
                isDimmed: model.currentTrackKey.isEmpty
            )
        }
    }

    private var backgroundTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(settings.t("lyrics.background.title"))
                .font(.pretendard(14, weight: .bold))
            Text(settings.t("lyrics.background.desc"))
                .font(.pretendard(11))
                .foregroundStyle(.white.opacity(0.66))
                .lineSpacing(2)

            metaToggleCell(
                settings.t("lyrics.background.override"),
                subtitle: settings.t("lyrics.background.override_desc"),
                isOn: trackBackgroundOverrideBinding
            )
                .disabled(model.currentTrackKey.isEmpty)

            if model.currentTrackKey.isEmpty {
                Text(settings.t("label.no_current_track"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
            } else {
                metaSettingGroup(
                    title: settings.t("setting.background_mode"),
                    subtitle: settings.t("lyrics.background.mode_desc")
                ) {
                    backgroundModeGrid
                }

                metaSliderGroup(
                    title: settings.t("setting.brightness"),
                    subtitle: settings.t("setting.brightness_desc"),
                    value: trackBackgroundBrightnessBinding,
                    range: 0...100
                )
                metaSliderGroup(
                    title: settings.t("setting.blur"),
                    subtitle: settings.t("setting.blur_desc"),
                    value: trackBackgroundBlurBinding,
                    range: 0...100
                )

                if editableTrackBackground.mode == AppSettings.backgroundVideo {
                    metaSliderGroup(
                        title: settings.t("setting.video_scale"),
                        subtitle: settings.t("setting.video_scale_desc"),
                        value: trackBackgroundVideoScaleBinding,
                        range: 100...180
                    )
                }

                metaToggleCell(
                    settings.t("setting.noise"),
                    subtitle: settings.t("setting.noise_desc"),
                    isOn: trackBackgroundNoiseBinding
                )
                metaToggleCell(
                    settings.t("setting.reduce_motion"),
                    subtitle: settings.t("setting.reduce_motion_desc"),
                    isOn: trackBackgroundReduceMotionBinding
                )

                if editableTrackBackground.mode == AppSettings.backgroundSolid {
                    metaSettingGroup(
                        title: settings.t("field.solid_color"),
                        subtitle: settings.t("field.solid_color_desc")
                    ) {
                        backgroundColorControl
                    }
                }

                Button {
                    settings.clearTrackBackgroundSettings(model.currentTrackKey)
                    model.refreshBackgroundForCurrentTrack()
                    model.showSavedToast(settings.t("toast.track_background_cleared"))
                } label: {
                    Text(settings.t("lyrics.background.reset"))
                        .font(.pretendard(13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var lrclibTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(settings.t("lyrics.lrclib_search.title"))
                .font(.pretendard(14, weight: .bold))
            Text(settings.t("lyrics.lrclib_search.desc"))
                .font(.pretendard(11))
                .foregroundStyle(.white.opacity(0.66))
                .lineSpacing(2)
                .padding(.top, 5)

            metaTextField(
                title: settings.t("lyrics.lrclib_search.field_title"),
                prompt: settings.t("lyrics.lrclib_search.title_hint"),
                text: $model.inputTitle
            )
            .padding(.top, 10)

            metaTextField(
                title: settings.t("lyrics.lrclib_search.field_artist"),
                prompt: settings.t("lyrics.lrclib_search.artist_hint"),
                text: $model.inputArtist
            )
            .padding(.top, 8)

            Button {
                model.searchManualCandidates()
            } label: {
                Text(settings.t("lyrics.lrclib_search.button"))
                    .font(.pretendard(14, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(model.searchingManualCandidates)
            .opacity(model.searchingManualCandidates ? 0.55 : 1)
            .padding(.top, 10)

            Text(model.manualLrclibStatus)
                .font(.pretendard(11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.67))
                .lineSpacing(2)
                .padding(.top, 9)

            VStack(spacing: 8) {
                if model.searchingManualCandidates {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, minHeight: 164)
                } else {
                    ForEach(model.manualCandidates) { candidate in
                        Button {
                            model.applyManualCandidate(candidate)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(manualLrclibTitleText(candidate))
                                    .font(.pretendard(14, weight: .semibold))
                                    .lineLimit(1)
                                if !manualLrclibArtistAlbumText(candidate).isEmpty {
                                    Text(manualLrclibArtistAlbumText(candidate))
                                        .font(.pretendard(12))
                                        .foregroundStyle(.white.opacity(0.64))
                                        .lineLimit(1)
                                }
                                Text(manualLrclibMetaText(candidate))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.50))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .top)
            .padding(8)
            .background(.white.opacity(22.0 / 255.0), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 8)
        }
    }

    private func offsetBlock(title: String, detail: String, resetTitle: String, value: Int, setValue: @escaping (Int) -> Void, isDimmed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.pretendard(14, weight: .bold))
            Text(detail)
                .font(.pretendard(11))
                .foregroundStyle(.white.opacity(0.66))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(formatSignedMs(value))
                .font(.pretendard(25, weight: .bold))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(.white.opacity(34.0 / 255.0), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.top, 4)

            offsetButtonRow([-100, -50, -10], value: value, setValue: setValue)
                .padding(.top, 2)
            offsetButtonRow([10, 50, 100], value: value, setValue: setValue)

            Button(resetTitle) {
                setValue(0)
            }
            .font(.pretendard(13, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .buttonStyle(.plain)
        }
        .opacity(isDimmed ? 0.52 : 1)
    }

    private func offsetButtonRow(_ deltas: [Int], value: Int, setValue: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 8) {
            ForEach(deltas, id: \.self) { delta in
                Button(delta > 0 ? "+\(delta)" : "\(delta)") {
                    setValue(value + delta)
                }
                .font(.pretendard(13, weight: .semibold))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .buttonStyle(.plain)
            }
        }
    }

    private func formatSignedMs(_ offsetMs: Int) -> String {
        offsetMs > 0 ? "+\(offsetMs)ms" : "\(offsetMs)ms"
    }

    private var trackSyncDetailText: String {
        let scope = model.currentTrackKey.isEmpty
            ? settings.t("lyrics.sync.no_track")
            : settings.tf("lyrics.sync.track_scope", model.titleText)
        return scope + "\n" + settings.t("lyrics.sync.help")
    }

    private var bluetoothSyncDetailText: String {
        let scope = model.hasBluetoothAudioDevice
            ? settings.tf("lyrics.bluetooth_sync.device_scope", model.bluetoothAudioDeviceName)
            : settings.t("lyrics.bluetooth_sync.no_device")
        return scope + "\n" + settings.t("lyrics.bluetooth_sync.help")
    }

    private var videoSyncDetailText: String {
        let scope = model.currentTrackKey.isEmpty
            ? settings.t("lyrics.video_sync.no_track")
            : settings.tf("lyrics.video_sync.track_scope", model.titleText)
        return scope + "\n" + settings.t("lyrics.video_sync.help")
    }

    private func manualLrclibTitleText(_ candidate: ManualLrclibCandidate) -> String {
        candidate.trackName.trimmed.isEmpty ? "LRCLIB #\(candidate.id)" : candidate.trackName
    }

    private func manualLrclibArtistAlbumText(_ candidate: ManualLrclibCandidate) -> String {
        if candidate.albumName.trimmed.isEmpty {
            return candidate.artistName
        }
        if candidate.artistName.trimmed.isEmpty {
            return candidate.albumName
        }
        return candidate.artistName + " · " + candidate.albumName
    }

    private func manualLrclibMetaText(_ candidate: ManualLrclibCandidate) -> String {
        var pieces = [manualLrclibKindLabel(candidate)]
        if candidate.durationSeconds > 0 {
            pieces.append(formatDurationSeconds(candidate.durationSeconds))
        }
        if !candidate.isrc.trimmed.isEmpty {
            pieces.append(candidate.isrc)
        }
        if candidate.id > 0 {
            pieces.append("#\(candidate.id)")
        }
        return pieces.joined(separator: " · ")
    }

    private func manualLrclibKindLabel(_ candidate: ManualLrclibCandidate) -> String {
        if candidate.instrumental {
            return settings.t("lyrics.lrclib_search.instrumental")
        }
        if candidate.synced {
            return settings.t("lyrics.lrclib_search.synced")
        }
        return settings.t("lyrics.lrclib_search.plain")
    }

    private func formatDurationSeconds(_ seconds: Double) -> String {
        let total = max(0, Int((seconds * 1000).rounded()) / 1000)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var backgroundModeGrid: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                backgroundModeButton(AppSettings.backgroundGradient, titleKey: "background.mode.gradient")
                backgroundModeButton(AppSettings.backgroundBlurGradient, titleKey: "background.mode.blur_gradient")
            }
            HStack(spacing: 8) {
                backgroundModeButton(AppSettings.backgroundVideo, titleKey: "background.mode.video")
                backgroundModeButton(AppSettings.backgroundSolid, titleKey: "background.mode.solid")
            }
        }
    }

    private func backgroundModeButton(_ mode: String, titleKey: String) -> some View {
        let selected = editableTrackBackground.mode == mode
        return Button {
            trackBackgroundModeBinding.wrappedValue = mode
        } label: {
            Text(settings.t(titleKey))
                .font(.pretendard(13, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(selected ? Color.black : Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(
                    selected ? Color.white.opacity(0.94) : Color.white.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }

    private func metaSettingGroup<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.pretendard(13, weight: .semibold))
            if !subtitle.trimmed.isEmpty {
                Text(subtitle)
                    .font(.pretendard(11))
                    .foregroundStyle(.white.opacity(150.0 / 255.0))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
            }
            content()
                .padding(.top, 10)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(30.0 / 255.0), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func metaSliderGroup(
        title: String,
        subtitle: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        metaSettingGroup(title: title, subtitle: subtitle) {
            HStack(spacing: 8) {
                Slider(value: value, in: range, step: 1, onEditingChanged: { editing in
                    if !editing {
                        model.refreshBackgroundForCurrentTrack()
                        model.showSavedToast(settings.t("toast.track_background_saved"))
                    }
                })
                .tint(Color(red: 116.0 / 255.0, green: 207.0 / 255.0, blue: 203.0 / 255.0))
                Text("\(Int(value.wrappedValue.rounded()))%")
                    .font(.pretendard(12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(180.0 / 255.0))
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }

    private func metaToggleCell(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.pretendard(14, weight: .semibold))
                    .lineLimit(subtitle == nil ? 1 : 2)
                if let subtitle, !subtitle.trimmed.isEmpty {
                    Text(subtitle)
                        .font(.pretendard(11))
                        .foregroundStyle(.white.opacity(0.64))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Color(red: 116.0 / 255.0, green: 207.0 / 255.0, blue: 203.0 / 255.0))
        }
        .padding(.horizontal, subtitle == nil ? 12 : 14)
        .padding(.vertical, subtitle == nil ? 0 : 12)
        .frame(maxWidth: .infinity)
        .frame(minHeight: subtitle == nil ? 48 : 62)
        .background(
            .white.opacity(subtitle == nil ? 0.14 : 34.0 / 255.0),
            in: RoundedRectangle(cornerRadius: subtitle == nil ? 10 : 12, style: .continuous)
        )
    }

    private var backgroundColorControl: some View {
        HStack(spacing: 10) {
            ColorPicker("", selection: trackBackgroundColorPickerBinding, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 42, height: 42)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(hex: normalizedTrackBackgroundColor))
                        .allowsHitTesting(false)
                }

            Text(settings.t("speaker_color.hex_hint"))
                .font(.pretendard(12))
                .foregroundStyle(.white.opacity(160.0 / 255.0))
                .frame(maxWidth: .infinity, alignment: .leading)

            TextField("#1e3a8a", text: $backgroundColorDraft)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.pretendard(12, weight: .semibold).monospaced())
                .foregroundStyle(backgroundColorDraftInvalid ? Color.red : Color.white)
                .frame(width: 112, height: 42)
                .background(.white.opacity(38.0 / 255.0), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .focused($backgroundColorFieldFocused)
                .onChange(of: backgroundColorDraft) { _, value in
                    backgroundColorDraftInvalid = !value.trimmed.isEmpty && !AppSettings.isHexColor(value)
                }
                .onSubmit(saveBackgroundColorDraft)
        }
        .onAppear {
            backgroundColorDraft = normalizedTrackBackgroundColor
        }
        .onChange(of: backgroundColorFieldFocused) { _, focused in
            if !focused {
                saveBackgroundColorDraft()
            }
        }
        .onChange(of: editableTrackBackground.solidColor) { _, _ in
            if !backgroundColorFieldFocused {
                backgroundColorDraft = normalizedTrackBackgroundColor
                backgroundColorDraftInvalid = false
            }
        }
    }

    private var normalizedTrackBackgroundColor: String {
        AppSettings.normalizeHexColor(editableTrackBackground.solidColor, fallback: "#1e3a8a")
    }

    private var trackBackgroundColorPickerBinding: Binding<Color> {
        Binding(
            get: { Color(hex: normalizedTrackBackgroundColor) },
            set: { color in
                guard let hex = color.hexRGB else { return }
                trackBackgroundSolidColorBinding.wrappedValue = hex
                backgroundColorDraft = hex
                backgroundColorDraftInvalid = false
                model.refreshBackgroundForCurrentTrack()
                model.showSavedToast(settings.t("toast.track_background_saved"))
            }
        )
    }

    private func saveBackgroundColorDraft() {
        guard AppSettings.isHexColor(backgroundColorDraft) else {
            backgroundColorDraftInvalid = true
            model.showSavedToast(settings.tf("toast.invalid_color_format", settings.t("field.solid_color")))
            return
        }
        let normalized = AppSettings.normalizeHexColor(backgroundColorDraft, fallback: "#1e3a8a")
        guard normalized != normalizedTrackBackgroundColor else {
            backgroundColorDraft = normalized
            backgroundColorDraftInvalid = false
            return
        }
        trackBackgroundSolidColorBinding.wrappedValue = normalized
        backgroundColorDraft = normalized
        backgroundColorDraftInvalid = false
        model.refreshBackgroundForCurrentTrack()
        model.showSavedToast(settings.t("toast.track_background_saved"))
    }

    private func metaTextField(title: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.pretendard(14, weight: .semibold))
                .foregroundStyle(.white)
            TextField(prompt, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.pretendard(14))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(8)
        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func statusText(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.white.opacity(0.54))
            Spacer(minLength: 16)
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.white.opacity(0.82))
        }
        .font(.caption)
    }

    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                let shouldClose = dragOffset > screenHeight * 0.18
                    || (value.predictedEndTranslation.height > 150 && dragOffset > 36)
                if shouldClose {
                    dismiss()
                } else {
                    withAnimation(.easeOut(duration: 0.18)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private func dismiss() {
        dragOffset = 0
        withAnimation(.easeOut(duration: 0.18)) {
            visible = false
        }
    }

    private var effectiveRuleSourceLang: String {
        model.effectiveSelectedRuleSourceLang
    }

    private var selectedRule: AppSettings.LanguageRule {
        _ = settings.languageRulesRevision
        return settings.languageRule(for: effectiveRuleSourceLang)
    }

    private var selectedRuleTranslationBinding: Binding<Bool> {
        Binding(
            get: { selectedRule.translationEnabled },
            set: { enabled in
                let rule = selectedRule
                settings.setLanguageRule(
                    sourceLang: effectiveRuleSourceLang,
                    translationEnabled: enabled,
                    pronunciationEnabled: rule.pronunciationEnabled,
                    targetLang: settings.outputLang
                )
                model.reloadLyrics(bypassCache: true)
            }
        )
    }

    private var selectedRulePronunciationBinding: Binding<Bool> {
        Binding(
            get: { selectedRule.pronunciationEnabled },
            set: { enabled in
                let rule = selectedRule
                settings.setLanguageRule(
                    sourceLang: effectiveRuleSourceLang,
                    translationEnabled: rule.translationEnabled,
                    pronunciationEnabled: enabled,
                    targetLang: settings.outputLang
                )
                model.reloadLyrics(bypassCache: true)
            }
        )
    }

    private var languageRuleSummary: String {
        let translation = selectedRule.translationEnabled ? settings.t("label.on") : settings.t("label.off")
        let pronunciation = selectedRule.pronunciationEnabled ? settings.t("label.on") : settings.t("label.off")
        return "\(settings.t("lyrics.rule.track_language")): \(sourceStatusText)\n"
            + "\(settings.t("lyrics.rule.save_target")): \(selectedRuleTargetLabel)\n"
            + "\(settings.t("lyrics.translation")): \(translation) · "
            + "\(settings.t("lyrics.pronunciation")): \(pronunciation)"
    }

    private var sourceStatusText: String {
        if model.selectedRuleSourceLang == "auto" {
            return "auto(\(model.effectiveDetectedLyricsSourceLang))"
        }
        let language = AppSettings.languageInfo(effectiveRuleSourceLang)
        return "\(language.nativeName) · \(language.name)"
    }

    private var selectedRuleTargetLabel: String {
        let target = settings.snapshot.resolveTargetLanguage(sourceLang: effectiveRuleSourceLang)
        let language = AppSettings.languageInfo(target)
        return "\(language.nativeName) · \(language.name)"
    }

    private var currentTrackHasBackgroundOverride: Bool {
        _ = settings.backgroundSettingsRevision
        return settings.trackBackgroundSettings(model.currentTrackKey) != nil
    }

    private var editableTrackBackground: AppSettings.BackgroundSettings {
        _ = settings.backgroundSettingsRevision
        return settings.effectiveBackgroundSettings(trackKey: model.currentTrackKey)
    }

    private var trackBackgroundOverrideBinding: Binding<Bool> {
        Binding(
            get: { currentTrackHasBackgroundOverride },
            set: { enabled in
                guard !model.currentTrackKey.isEmpty else { return }
                if enabled {
                    settings.setTrackBackgroundSettings(model.currentTrackKey, settings.globalBackgroundSettings)
                    model.showSavedToast(settings.t("toast.track_background_saved"))
                } else {
                    settings.clearTrackBackgroundSettings(model.currentTrackKey)
                    model.showSavedToast(settings.t("toast.track_background_cleared"))
                }
                model.refreshBackgroundForCurrentTrack()
            }
        )
    }

    private var trackBackgroundModeBinding: Binding<String> {
        Binding(
            get: { editableTrackBackground.mode },
            set: { value in
                updateTrackBackground { $0.mode = value }
                model.refreshBackgroundForCurrentTrack()
                model.showSavedToast(settings.t("toast.track_background_saved"))
            }
        )
    }

    private var trackBackgroundBrightnessBinding: Binding<Double> {
        Binding(
            get: { Double(editableTrackBackground.brightness) },
            set: { value in updateTrackBackground { $0.brightness = Int(value.rounded()) } }
        )
    }

    private var trackBackgroundBlurBinding: Binding<Double> {
        Binding(
            get: { Double(editableTrackBackground.blur) },
            set: { value in updateTrackBackground { $0.blur = Int(value.rounded()) } }
        )
    }

    private var trackBackgroundVideoScaleBinding: Binding<Double> {
        Binding(
            get: { Double(editableTrackBackground.videoScale) },
            set: { value in updateTrackBackground { $0.videoScale = AppSettings.clampBackgroundVideoScale(Int(value.rounded())) } }
        )
    }

    private var trackBackgroundNoiseBinding: Binding<Bool> {
        Binding(
            get: { editableTrackBackground.noise },
            set: { value in
                updateTrackBackground { $0.noise = value }
                model.showSavedToast(settings.t("toast.track_background_saved"))
            }
        )
    }

    private var trackBackgroundReduceMotionBinding: Binding<Bool> {
        Binding(
            get: { editableTrackBackground.reduceMotion },
            set: { value in
                updateTrackBackground { $0.reduceMotion = value }
                model.showSavedToast(settings.t("toast.track_background_saved"))
            }
        )
    }

    private var trackBackgroundSolidColorBinding: Binding<String> {
        Binding(
            get: { editableTrackBackground.solidColor },
            set: { value in updateTrackBackground { $0.solidColor = value } }
        )
    }

    private func updateTrackBackground(_ update: (inout AppSettings.BackgroundSettings) -> Void) {
        guard !model.currentTrackKey.isEmpty else { return }
        var next = editableTrackBackground
        update(&next)
        settings.setTrackBackgroundSettings(model.currentTrackKey, next)
    }
}
