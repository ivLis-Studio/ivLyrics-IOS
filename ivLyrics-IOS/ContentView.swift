import Combine
import SwiftUI
import WebKit

#if os(iOS)
import UIKit
#endif

private struct LyricsSegmentationLocaleKey: EnvironmentKey {
    static let defaultValue = "auto"
}

private struct CoveredPageDecorationsPausedKey: EnvironmentKey {
    static let defaultValue = false
}

private struct PlaybackAdvancingKey: EnvironmentKey {
    static let defaultValue = false
}

private struct OriginalLyricsVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

private struct InterludeMotionEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var interludeMotionEnabled: Bool {
        get { self[InterludeMotionEnabledKey.self] }
        set { self[InterludeMotionEnabledKey.self] = newValue }
    }
    var originalLyricsVisible: Bool {
        get { self[OriginalLyricsVisibleKey.self] }
        set { self[OriginalLyricsVisibleKey.self] = newValue }
    }
    var lyricsSegmentationLocale: String {
        get { self[LyricsSegmentationLocaleKey.self] }
        set { self[LyricsSegmentationLocaleKey.self] = newValue }
    }

    /// True while the portrait main page sits fully covered by the lyrics page or vinyl mode.
    /// Its time-driven decorations stop ticking; they draw the current time again in the update
    /// that starts uncovering the page.
    var coveredPageDecorationsPaused: Bool {
        get { self[CoveredPageDecorationsPausedKey.self] }
        set { self[CoveredPageDecorationsPausedKey.self] = newValue }
    }

    /// True while playback runs, when the playback clock already updates the visible page on every
    /// display frame and time-driven decorations can follow the display at little extra cost. While
    /// playback is paused a decoration tick is the page's only update and re-runs the whole page, so
    /// those decorations keep their previous cadence there.
    var playbackAdvancing: Bool {
        get { self[PlaybackAdvancingKey.self] }
        set { self[PlaybackAdvancingKey.self] = newValue }
    }
}

private struct AndroidSlidingMetadataText: View {
    private static let edgeHoldSeconds = 1.05
    private static let minimumMoveSeconds = 1.8
    private static let maximumMoveSeconds = 5.6
    private static let pointsPerSecond: CGFloat = 46

    let text: String
    let typography: AppSettings.TypographySettings
    let slotId: String
    let baseSize: CGFloat
    let color: Color

    @Environment(\.coveredPageDecorationsPaused) private var coveredPageDecorationsPaused
    @Environment(\.playbackAdvancing) private var playbackAdvancing
    @State private var animationStart = Date()

    var body: some View {
        let font = measuredFont
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let lineHeight = ceil(font.lineHeight)

        GeometryReader { proxy in
            let availableWidth = max(0, proxy.size.width)
            let overflowing = textWidth > availableWidth + 0.5

            // Display rate while playback runs (the page already updates every frame); the previous
            // 1/30 s cadence while it is paused, when each tick would be the page's only update.
            TimelineView(.animation(
                minimumInterval: playbackAdvancing ? nil : 1.0 / 30.0,
                paused: !overflowing || coveredPageDecorationsPaused
            )) { timeline in
#if DEBUG && os(iOS)
                let _ = debugProbeTimeline(.marqueeTick, timeline.date)
#endif
                Text(text)
                    .font(typography.font(slotId: slotId, baseSize: baseSize))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: true)
                    .offset(x: horizontalOffset(
                        at: timeline.date,
                        textWidth: textWidth,
                        availableWidth: availableWidth
                    ))
                    .frame(width: availableWidth, alignment: .leading)
            }
            .frame(width: availableWidth, height: lineHeight, alignment: .leading)
            .clipped()
        }
        .frame(height: lineHeight)
        .accessibilityLabel(Text(text))
        .onChange(of: animationKey) { _, _ in
            animationStart = Date()
        }
    }

    private var style: AppSettings.TypographyStyle {
        typography.style(slotId)
    }

    private var pointSize: CGFloat {
        typography.scaledSize(slotId: slotId, baseSize: baseSize)
    }

    private var measuredFont: UIFont {
        if let font = UIFont(name: fontName, size: pointSize) {
            return font
        }
        return UIFont.systemFont(ofSize: pointSize, weight: fallbackWeight)
    }

    private var fontName: String {
        switch style.weight {
        case AppSettings.typoWeightBold:
            return "Pretendard-Bold"
        case AppSettings.typoWeightSemibold:
            return "Pretendard-SemiBold"
        default:
            return "Pretendard-Regular"
        }
    }

    private var fallbackWeight: UIFont.Weight {
        switch style.weight {
        case AppSettings.typoWeightBold:
            return .bold
        case AppSettings.typoWeightSemibold:
            return .semibold
        default:
            return .regular
        }
    }

    private var animationKey: String {
        "\(text)|\(pointSize)|\(style.weight)"
    }

    private func horizontalOffset(at date: Date, textWidth: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let travel = max(0, textWidth - availableWidth)
        guard travel > 0 else { return 0 }

        let moveSeconds = min(
            Self.maximumMoveSeconds,
            max(Self.minimumMoveSeconds, Double(travel / Self.pointsPerSecond))
        )
        let cycleSeconds = (Self.edgeHoldSeconds + moveSeconds) * 2
        var elapsed = date.timeIntervalSince(animationStart).truncatingRemainder(dividingBy: cycleSeconds)
        if elapsed < 0 {
            elapsed += cycleSeconds
        }
        if elapsed < Self.edgeHoldSeconds {
            return 0
        }
        elapsed -= Self.edgeHoldSeconds
        if elapsed < moveSeconds {
            return -travel * smoothStep(elapsed / moveSeconds)
        }
        elapsed -= moveSeconds
        if elapsed < Self.edgeHoldSeconds {
            return -travel
        }
        elapsed -= Self.edgeHoldSeconds
        return -travel * (1 - smoothStep(elapsed / moveSeconds))
    }

    private func smoothStep(_ value: Double) -> CGFloat {
        let progress = max(0, min(1, value))
        return CGFloat(progress * progress * (3 - 2 * progress))
    }
}

@main
struct IvLyricsIOSApp: App {
    init() {
        IvLyricsFontLoader.registerPretendard()
    }

    var body: some Scene {
        WindowGroup {
#if DEBUG
            if DebugSettingsUIHarness.enabled { DebugSettingsUIRoot() }
            else { ProductionAppRoot() }
#else
            ProductionAppRoot()
#endif
        }
    }
}

private struct ProductionAppRoot: View {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var viewModel = AppViewModel(settings: .shared)

    init() { LocalAIController.shared.start() }

    var body: some View {
            ContentView()
                .environmentObject(settings)
                .environmentObject(viewModel)
                .environmentObject(viewModel.playbackClock)
                .onOpenURL { url in
                    viewModel.handleOpenURL(url)
                }
    }
}

struct ContentView: View {
    private static let lyricsMetaTipShownKey = "lyrics_meta_menu_tip_shown"
    /// Never advances. The covered main page observes it instead of the live clock.
    private static let coveredPagePlaybackClock = PlaybackClock()
    /// Longer than the covering transitions (lyrics page 0.33s, vinyl 0.36-0.42s).
    private static let coveredPageFreezeDelay: TimeInterval = 0.6

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var showingSettings = false
    @State private var showingLogs = false
    @State private var landscapeControlsVisible = true
    @State private var landscapeAutoHideToken = UUID()
    @State private var lyricsPageVisible = false
    @State private var lyricsPageDragOffset: CGFloat = 0
    @State private var lyricsPageAnimationHeight: CGFloat = 1
    @State private var showingLyricsMetaMenu = false
    @State private var lyricsMetaMenuTab: LyricsMetaMenuTab = .language
    @State private var lyricsMetaTipVisible = false
    @State private var lyricsMetaTipToken = UUID()
    @State private var inAppBrowserDragOffset: CGFloat = 0
    @State private var vinylModeVisible = false
    @State private var mainPageFrozen = false
    @State private var mainPageCoverToken = UUID()

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            rootContent(
                isLandscape: isLandscape,
                size: geometry.size,
                safeAreaInsets: geometry.safeAreaInsets
            )
            .environment(\.lyricsSegmentationLocale, model.effectiveSelectedRuleSourceLang)
            .environment(\.playbackAdvancing, model.currentTrack?.playing == true)
            .statusBarHidden(isLandscape)
            .persistentSystemOverlays(isLandscape ? .hidden : .automatic)
            .contentShape(Rectangle())
            .onTapGesture {
                showLandscapeControlsTemporarily(isLandscape: isLandscape)
            }
            .font(.pretendard(16))
            .onAppear {
                lyricsPageAnimationHeight = max(1, geometry.size.height)
                applyKeepScreenOn(settings.keepScreenOn)
                updateLandscapeAutoHide(isLandscape: isLandscape)
                model.maybeShowInitialSetup()
                model.maybeStartAutomaticUpdateCheck()
                model.resumeSpotifyLiveIfAuthorized()
                applyDebugPresentationOverrides()
            }
            .onDisappear {
                landscapeAutoHideToken = UUID()
            }
            .onChange(of: settings.keepScreenOn) { _, enabled in
                applyKeepScreenOn(enabled)
            }
            .onChange(of: mainPageCovered(isLandscape: isLandscape)) { _, covered in
                updateMainPageFreeze(covered: covered)
            }
            .onChange(of: geometry.size.height) { _, height in
                lyricsPageAnimationHeight = max(1, height)
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    model.appDidBecomeActive()
                case .background:
                    model.appDidEnterBackground()
                case .inactive:
                    model.appWillResignActive()
                @unknown default:
                    break
                }
            }
            .onChange(of: settings.landscapeAutoHideControls) { _, _ in
                updateLandscapeAutoHide(isLandscape: isLandscape)
            }
            .onChange(of: isLandscape) { _, landscape in
                if landscape {
                    showLyricsPage(false)
                    showingLyricsMetaMenu = false
                    dismissLyricsMetaTip()
                }
                updateLandscapeAutoHide(isLandscape: landscape)
            }
            .onChange(of: showingSettings) { _, _ in
                updateLandscapeAutoHide(isLandscape: isLandscape)
            }
            .onChange(of: showingLogs) { _, _ in
                updateLandscapeAutoHide(isLandscape: isLandscape)
            }
            .onChange(of: model.tmiPresented) { _, _ in
                updateLandscapeAutoHide(isLandscape: isLandscape)
            }
            .onChange(of: model.researchTokenConsentPresented) { _, _ in
                updateLandscapeAutoHide(isLandscape: isLandscape)
            }
            .onChange(of: showingLyricsMetaMenu) { _, _ in
                if showingLyricsMetaMenu {
                    dismissLyricsMetaTip()
                }
                updateLandscapeAutoHide(isLandscape: isLandscape)
            }
            .onChange(of: model.inAppBrowserURL) { _, _ in
                inAppBrowserDragOffset = 0
                updateLandscapeAutoHide(isLandscape: isLandscape)
            }
            .onChange(of: model.currentTrack?.hasUsableMetadata == true) { _, available in
                if !available && vinylModeVisible {
                    withAnimation(.easeOut(duration: 0.26)) {
                        vinylModeVisible = false
                    }
                }
            }
            .fullScreenCover(isPresented: $showingSettings) {
                SettingsView()
                    .environmentObject(settings)
                    .environmentObject(model)
                    .environmentObject(model.playbackClock)
            }
            .fullScreenCover(isPresented: $model.initialSetupPresented) {
                InitialSetupView()
                    .environmentObject(settings)
                    .environmentObject(model)
            }
        }
    }

    private func rootContent(isLandscape: Bool, size: CGSize, safeAreaInsets: EdgeInsets) -> some View {
        ZStack {
            LyricsPictureInPictureHostView(controller: model.pictureInPictureController)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            PlayerBackgroundView(isLandscape: isLandscape)
            primaryContent(
                isLandscape: isLandscape,
                size: size,
                safeAreaInsets: safeAreaInsets
            )
            // The portrait main page stays mounted (artwork, marquee and preview state) while the
            // lyrics page or vinyl mode covers it, but stops repainting on every display frame.
            // The live clock and its time-driven decorations return in the same update that
            // starts uncovering it.
            .environmentObject(
                mainPageFrozen && mainPageCovered(isLandscape: isLandscape)
                    ? Self.coveredPagePlaybackClock
                    : model.playbackClock
            )
            .environment(
                \.coveredPageDecorationsPaused,
                mainPageFrozen && mainPageCovered(isLandscape: isLandscape)
            )
            .opacity(vinylModeVisible ? 0 : 1)
            .scaleEffect(vinylModeVisible ? 0.985 : 1)
            .allowsHitTesting(!vinylModeVisible)
            .accessibilityHidden(
                vinylModeVisible
                    || showingLyricsMetaMenu
                    || model.researchTokenConsentPresented
                    || model.tmiPresented
                    || model.updateDialogPresented
                    || model.firstLanguagePrompt != nil
            )
            .animation(
                settings.vinylAnimationsEnabled && !accessibilityReduceMotion
                    ? .timingCurve(0.22, 0.74, 0.28, 1, duration: 0.36)
                    : nil,
                value: vinylModeVisible
            )
            if vinylModeVisible {
                VinylPlayerModeView(isPresented: $vinylModeVisible)
                    .transition(
                        settings.vinylAnimationsEnabled && !accessibilityReduceMotion
                            ? .opacity.combined(with: .scale(scale: 0.975))
                            : .identity
                    )
                    .zIndex(4)
            }
            overlayContent(
                isLandscape: isLandscape,
                size: size,
                safeAreaInsets: safeAreaInsets
            )
#if DEBUG
            if ProcessInfo.processInfo.environment["IVLYRICS_DEBUG_KARAOKE_PREVIEW"] == "1" {
                KaraokeDebugPreview()
                    .zIndex(100)
            }
            if ProcessInfo.processInfo.environment["IVLYRICS_DEBUG_MOTION_PREVIEW"] == "1" {
                LyricsMotionDebugPreview()
                    .zIndex(100)
            }
            if ProcessInfo.processInfo.environment["IVLYRICS_DEBUG_EFFECT_PREVIEW"] == "1" {
                KaraokeEffectsDebugPreview()
                    .zIndex(100)
            }
            if ProcessInfo.processInfo.environment["IVLYRICS_DEBUG_PIP_LAYOUT"] == "1" {
                PictureInPictureLayoutDebugPreview(controller: model.pictureInPictureController)
                    .zIndex(100)
            }
            if ProcessInfo.processInfo.environment["IVLYRICS_DEBUG_MAIN_PREVIEW"] == "1" {
                MainLyricPreviewSlideDebugPreview()
                    .zIndex(100)
            }
#endif
        }
    }

    @ViewBuilder
    private func primaryContent(isLandscape: Bool, size: CGSize, safeAreaInsets: EdgeInsets) -> some View {
        Group {
            if isLandscape {
                landscapeContent(size: size)
            } else {
                portraitContent(safeAreaInsets: safeAreaInsets)
            }
        }
        .mask(alignment: .top) {
            Rectangle()
                .frame(height: mainPageRevealHeight(
                    isLandscape: isLandscape,
                    screenHeight: size.height,
                    safeAreaTop: safeAreaInsets.top
                ))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func mainPageRevealHeight(
        isLandscape: Bool,
        screenHeight: CGFloat,
        safeAreaTop: CGFloat
    ) -> CGFloat {
        guard !isLandscape, lyricsPageVisible else { return screenHeight }
        return min(screenHeight, max(0, lyricsPageDragOffset - safeAreaTop))
    }

    /// Portrait only: the landscape pane shows the lyric list itself, and holding it would turn
    /// the vinyl dismissal into a catch-up scroll.
    private func mainPageCovered(isLandscape: Bool) -> Bool {
        guard !isLandscape else { return false }
        return vinylModeVisible || (lyricsPageVisible && lyricsPageDragOffset == 0)
    }

    private func updateMainPageFreeze(covered: Bool) {
        let token = UUID()
        mainPageCoverToken = token
        guard covered else {
            mainPageFrozen = false
            return
        }
        // The covering transition still shows the page; hold it only once fully covered.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coveredPageFreezeDelay) {
            guard mainPageCoverToken == token else { return }
            mainPageFrozen = true
        }
    }

    @ViewBuilder
    private func overlayContent(isLandscape: Bool, size: CGSize, safeAreaInsets: EdgeInsets) -> some View {
        if !isLandscape && lyricsPageVisible {
            LyricsPageOverlay(
                visible: $lyricsPageVisible,
                dragOffset: $lyricsPageDragOffset,
                showingMetaMenu: $showingLyricsMetaMenu,
                selectedMetaMenuTab: $lyricsMetaMenuTab,
                metaTipVisible: $lyricsMetaTipVisible,
                screenHeight: size.height,
                safeAreaTop: safeAreaInsets.top,
                safeAreaBottom: safeAreaInsets.bottom
            )
            .zIndex(5)
        }
        if showingLyricsMetaMenu {
            LyricsMetaMenuOverlay(
                visible: $showingLyricsMetaMenu,
                selectedTab: $lyricsMetaMenuTab,
                screenHeight: size.height,
                openPictureInPicture: openSystemLyricsPictureInPicture
            )
            .zIndex(8)
        }
        if let browserURL = model.inAppBrowserURL {
            InAppBrowserOverlay(
                visible: inAppBrowserVisibleBinding,
                dragOffset: $inAppBrowserDragOffset,
                url: browserURL,
                screenHeight: size.height,
                onCreatorAuthRedirect: { model.handleCreatorAuthRedirect($0) }
            )
            .transition(.move(edge: .bottom))
            .zIndex(10)
        }
        if showingLogs {
            LogsView(visible: $showingLogs)
                .transition(.opacity)
                .zIndex(11)
        }
        if model.tmiPresented {
            TmiSheetView()
                .transition(.opacity)
                .zIndex(12)
        }
        if model.updateDialogPresented {
            UpdateSheetView()
                .transition(.opacity)
                .zIndex(13)
        }
        if let prompt = model.firstLanguagePrompt {
            FirstLanguagePromptSheetView(prompt: prompt)
                .id(prompt.id)
                .transition(accessibilityReduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.975)))
                .zIndex(14)
        }
        if model.researchTokenConsentPresented {
            ResearchTokenConsentSheetView()
                .transition(.opacity.combined(with: .scale(scale: 0.975)))
                .zIndex(15)
        }
        if !model.toastMessage.trimmed.isEmpty {
            ToastBanner(
                message: model.toastMessage,
                bottomPadding: isLandscape ? 24 : (lyricsPageVisible ? 24 : 86)
            )
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .zIndex(20)
        }
    }

    private var inAppBrowserVisibleBinding: Binding<Bool> {
        Binding(
            get: { model.inAppBrowserURL != nil },
            set: { visible in
                if !visible {
                    closeInAppBrowser()
                }
            }
        )
    }

    private func portraitContent(safeAreaInsets: EdgeInsets) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let fullHeight = height + safeAreaInsets.top + safeAreaInsets.bottom
            let horizontalPadding: CGFloat = 24
            let contentWidth = max(0, width - horizontalPadding * 2)
            let artworkSize = max(180, min(contentWidth, fullHeight * 0.45))
            let typography = settings.typographySettings()
            let artworkMetadataSpacing = min(30, max(18, height * 0.034))
            let metadataControlsSpacing = min(38, max(28, height * 0.045))

            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    Color.clear
                    Button {
                        showingSettings = true
                    } label: {
                        AndroidMoreIcon()
                            .frame(width: 18, height: 18)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .accessibilityLabel(settings.t("settings.title"))
                    .padding(.top, 8)
                }
                .frame(height: 56)

                Spacer(minLength: 0)
                    .frame(maxHeight: 20)

                ArtworkView(size: artworkSize, cornerRadius: 24, onTap: presentVinylMode)
                    .padding(.bottom, 8)

                Color.clear
                    .frame(height: artworkMetadataSpacing)

                VStack(alignment: .leading, spacing: 7) {
                    AndroidSlidingMetadataText(
                        text: model.titleText.trimmed.isEmpty ? "ivLyrics" : model.titleText,
                        typography: typography,
                        slotId: AppSettings.typoMainTitle,
                        baseSize: 28,
                        color: .white
                    )
                    AndroidSlidingMetadataText(
                        text: model.artistText.trimmed.isEmpty
                            ? settings.t("status.waiting_spotify")
                            : model.artistText,
                        typography: typography,
                        slotId: AppSettings.typoMainArtist,
                        baseSize: 18,
                        color: .white.opacity(190.0 / 255.0)
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.handleTitleTap()
                }
                .onLongPressGesture {
                    performMainMetaHaptic()
                    lyricsMetaMenuTab = .language
                    showingLyricsMetaMenu = true
                }

                PortraitPlayerProgressSection(metadataControlsSpacing: metadataControlsSpacing)

                androidTransportControls
                    .frame(maxWidth: .infinity, minHeight: 76, maxHeight: 76)
                    .padding(.top, 8)

                Spacer(minLength: 12)

                MainLyricPreviewPanel(chromeless: true)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        showLyricsPage(true)
                    }
            }
            .frame(width: contentWidth, height: max(0, height))
            .padding(.horizontal, horizontalPadding)
            .foregroundStyle(.white)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onEnded { value in
                    if value.translation.height < -56 {
                        showLyricsPage(true)
                    }
                }
        )
    }

    private var androidTransportControls: some View {
        HStack(spacing: 30) {
            Button {
                model.skipToPreviousTrack()
            } label: {
                Color.clear
            }
            .buttonStyle(AndroidTransportButtonStyle(kind: .previous, size: 62))
            .accessibilityLabel(settings.t("button.prev_track"))

            Button {
                model.togglePlayback()
            } label: {
                Color.clear
            }
            .buttonStyle(AndroidTransportButtonStyle(
                kind: .playPause,
                primary: true,
                playing: model.currentTrack?.playing == true,
                size: 72
            ))
            .accessibilityLabel(settings.t("debug.play_pause"))

            Button {
                model.skipToNextTrack()
            } label: {
                Color.clear
            }
            .buttonStyle(AndroidTransportButtonStyle(kind: .next, size: 62))
            .accessibilityLabel(settings.t("button.next_track"))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(238.0 / 255.0))
    }

    private func performMainMetaHaptic() {
#if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
#endif
    }

    private func applyDebugPresentationOverrides() {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["IVLYRICS_DEBUG_LYRICS_LOADING"] == "1" {
            model.applyDebugLyricsLoadingState()
        }
        if DebugKaraokeFixture.isEnabled {
            model.applyDebugKaraokeFixture()
        }
        if environment["IVLYRICS_DEBUG_SHOW_VINYL"] == "1" {
            DispatchQueue.main.async {
                presentVinylMode()
            }
        }
        // Uncover the main page after a delay to verify it resumes the live clock immediately.
        if let rawDelay = environment["IVLYRICS_DEBUG_REVEAL_MAIN_AFTER_S"], let delay = Double(rawDelay) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
#if os(iOS)
                DebugFrameProbe.shared.recordEvent("revealMain")
#endif
                if vinylModeVisible {
                    withAnimation(.timingCurve(0.22, 0.74, 0.28, 1, duration: 0.36)) {
                        vinylModeVisible = false
                    }
                } else if lyricsPageVisible {
                    lyricsPageDragOffset = 240
                }
            }
        }
        // Scripted playback changes for headless runs (vinyl play/pause and track sequences,
        // decoration cadence while playback is paused).
        if let raw = environment["IVLYRICS_DEBUG_FIXTURE_PAUSE_AFTER_S"], let delay = Double(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
#if os(iOS)
                DebugFrameProbe.shared.recordEvent("debugPause")
#endif
                model.pausePlayback()
            }
        }
        if let raw = environment["IVLYRICS_DEBUG_FIXTURE_PLAY_AFTER_S"], let delay = Double(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
#if os(iOS)
                DebugFrameProbe.shared.recordEvent("debugPlay")
#endif
                if model.currentTrack?.playing == false {
                    model.togglePlayback()
                }
            }
        }
        if let raw = environment["IVLYRICS_DEBUG_FIXTURE_NEXT_TRACK_AFTER_S"], let delay = Double(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
#if os(iOS)
                DebugFrameProbe.shared.recordEvent("debugNextTrack")
#endif
                model.debugAdvanceFixtureTrack()
            }
        }
#if os(iOS)
        DebugFrameProbe.shared.scheduleFromEnvironment()
#endif
        if let rawDragOffset = environment["IVLYRICS_DEBUG_LYRICS_DRAG_OFFSET"],
           let debugDragOffset = Double(rawDragOffset) {
            DispatchQueue.main.async {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    lyricsPageVisible = true
                    lyricsPageDragOffset = min(
                        lyricsPageAnimationHeight,
                        max(0, CGFloat(debugDragOffset))
                    )
                }
            }
        } else if environment["IVLYRICS_DEBUG_SHOW_LYRICS"] == "1" {
            DispatchQueue.main.async {
                showLyricsPage(true)
            }
        }
        if environment["IVLYRICS_DEBUG_SHOW_META_MENU"] == "1" {
            if let rawTab = environment["IVLYRICS_DEBUG_META_TAB"],
               let tab = LyricsMetaMenuTab(rawValue: rawTab) {
                lyricsMetaMenuTab = tab
            }
            DispatchQueue.main.async {
                showLyricsPage(true)
                showingLyricsMetaMenu = true
            }
        }
        if environment["IVLYRICS_DEBUG_SHOW_SETTINGS"] == "1" {
            DispatchQueue.main.async {
                showingSettings = true
            }
        }
        if environment["IVLYRICS_DEBUG_SHOW_LOGS"] == "1" {
            DispatchQueue.main.async {
                showingLogs = true
            }
        }
        if environment["IVLYRICS_DEBUG_SHOW_TMI"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                model.showTmiForCurrentTrack(bypassCache: false)
            }
        }
        if environment["IVLYRICS_DEBUG_SHOW_UPDATE"] == "1" {
            DispatchQueue.main.async {
                model.updateDialogPresented = true
            }
        }
        if environment["IVLYRICS_DEBUG_SHOW_FIRST_LANGUAGE"] == "1" {
            DispatchQueue.main.async {
                model.applyDebugFirstLanguagePrompt()
            }
        }
        if environment["IVLYRICS_DEBUG_SHOW_ONBOARDING"] == "1" {
            DispatchQueue.main.async {
                model.initialSetupPresented = true
            }
        }
        if environment["IVLYRICS_DEBUG_START_PIP"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                openSystemLyricsPictureInPicture()
            }
        }
#endif
    }

    private func landscapeContent(size: CGSize) -> some View {
        let controlsShown = shouldShowLandscapeControls
        let centerPlayer = shouldCenterLandscapePlayer
        let horizontalPadding: CGFloat = 22
        let spacing: CGFloat = centerPlayer ? 0 : 18
        let availableWidth = max(320, size.width - horizontalPadding * 2 - spacing)
        let playerWidth = centerPlayer
            ? min(size.width - horizontalPadding * 2, size.width > 900 ? 720 : 560)
            : availableWidth * 0.44
        let lyricsWidth = availableWidth - playerWidth

        return HStack(spacing: spacing) {
            LandscapePlayerPane(
                controlsVisible: controlsShown,
                centered: centerPlayer,
                containerSize: size,
                onOpenVinyl: presentVinylMode
            )
            .frame(width: playerWidth, height: max(1, size.height - 32))

            if !centerPlayer {
                LandscapeLyricsPane()
                    .frame(width: max(280, lyricsWidth), height: max(1, size.height - 32))
                    .transition(.opacity.animation(.easeInOut(duration: 0.18)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 16)
        .overlay(alignment: .topTrailing) {
            Group {
                if controlsShown {
                    LandscapeCommandBar(
                        showingSettings: $showingSettings
                    )
                    .transition(.opacity)
                } else {
                    // Keep the settings corner from passing taps to the lyric rows
                    // underneath while the controls are auto-hidden; a tap here
                    // brings the controls back instead of seeking the lyrics.
                    Color.clear
                        .frame(
                            width: LandscapeCommandBar.hitTargetSize,
                            height: LandscapeCommandBar.hitTargetSize
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            showLandscapeControlsTemporarily(isLandscape: true)
                        }
                        .accessibilityHidden(true)
                }
            }
            .padding(.top, 16)
            .padding(.trailing, 22)
        }
        .animation(.easeInOut(duration: controlsShown ? 0.18 : 0.26), value: controlsShown)
    }

    private var shouldShowLandscapeControls: Bool {
        !settings.landscapeAutoHideControls
            || showingSettings
            || showingLogs
            || landscapeControlsVisible
    }

    private var shouldCenterLandscapePlayer: Bool {
        settings.landscapeCenterNoLyrics
            && model.status != .loading
            && model.lyricsResult.lines.isEmpty
    }

    private func showLandscapeControlsTemporarily(isLandscape: Bool) {
        guard isLandscape, settings.landscapeAutoHideControls else {
            landscapeControlsVisible = true
            return
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            landscapeControlsVisible = true
        }
        scheduleLandscapeControlsAutoHide(isLandscape: isLandscape)
    }

    private func presentVinylMode() {
        guard model.currentTrack?.hasUsableMetadata == true else {
            model.showSavedToast(settings.t("status.waiting_current_track"))
            return
        }
        showLyricsPage(false)
        showingLyricsMetaMenu = false
        dismissLyricsMetaTip()
        withAnimation(settings.vinylAnimationsEnabled && !accessibilityReduceMotion
            ? .timingCurve(0.18, 0.80, 0.22, 1, duration: 0.42)
            : nil) {
            vinylModeVisible = true
        }
    }

    private func updateLandscapeAutoHide(isLandscape: Bool) {
        landscapeAutoHideToken = UUID()
        landscapeControlsVisible = true
        guard isLandscape,
              settings.landscapeAutoHideControls,
              !showingSettings,
              !showingLogs else {
            return
        }
        scheduleLandscapeControlsAutoHide(isLandscape: isLandscape)
    }

    private func scheduleLandscapeControlsAutoHide(isLandscape: Bool) {
        guard isLandscape,
              settings.landscapeAutoHideControls,
              !showingSettings,
              !showingLogs else {
            return
        }
        let token = UUID()
        landscapeAutoHideToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            guard landscapeAutoHideToken == token,
                  settings.landscapeAutoHideControls,
                  !showingSettings,
                  !showingLogs else {
                return
            }
            withAnimation(.easeInOut(duration: 0.26)) {
                landscapeControlsVisible = false
            }
        }
    }

    private func showLyricsPage(_ show: Bool) {
        if show {
            guard !lyricsPageVisible else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                lyricsPageDragOffset = lyricsPageAnimationHeight
                lyricsPageVisible = true
            }
            DispatchQueue.main.async {
                guard lyricsPageVisible else { return }
                withAnimation(.easeOut(duration: 0.33)) {
                    lyricsPageDragOffset = 0
                }
            }
            scheduleLyricsMetaTip()
        } else {
            guard lyricsPageVisible else { return }
            dismissLyricsMetaTip()
            withAnimation(.easeOut(duration: 0.28)) {
                lyricsPageDragOffset = lyricsPageAnimationHeight
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                guard lyricsPageDragOffset >= lyricsPageAnimationHeight * 0.9 else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    lyricsPageVisible = false
                    lyricsPageDragOffset = 0
                }
            }
        }
    }

    private func scheduleLyricsMetaTip() {
        guard !UserDefaults.standard.bool(forKey: Self.lyricsMetaTipShownKey) else { return }
        let token = UUID()
        lyricsMetaTipToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            guard lyricsMetaTipToken == token,
                  lyricsPageVisible,
                  !showingLyricsMetaMenu else { return }
            UserDefaults.standard.set(true, forKey: Self.lyricsMetaTipShownKey)
            withAnimation(.easeOut(duration: 0.18)) {
                lyricsMetaTipVisible = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) {
                guard lyricsMetaTipToken == token else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    lyricsMetaTipVisible = false
                }
            }
        }
    }

    private func dismissLyricsMetaTip() {
        lyricsMetaTipToken = UUID()
        withAnimation(.easeOut(duration: 0.18)) {
            lyricsMetaTipVisible = false
        }
    }

    private func closeInAppBrowser() {
        inAppBrowserDragOffset = 0
        withAnimation(.easeOut(duration: 0.26)) {
            model.closeInAppBrowser()
        }
    }

    private func openSystemLyricsPictureInPicture() {
        showingLyricsMetaMenu = false
        #if targetEnvironment(simulator)
        model.showSavedToast(settings.t("pip.simulator_unavailable"))
        #else
        if !model.startLyricsPictureInPicture() {
            model.showSavedToast(settings.t("pip.unavailable"))
        }
        #endif
    }

    private func applyKeepScreenOn(_ enabled: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = enabled
        #endif
    }
}

private struct PortraitPlayerProgressSection: View {
    @EnvironmentObject private var model: AppViewModel
    // Subscribed (not read directly) so this view re-renders with the display-rate playback clock driving model.nowPositionMs.
    @EnvironmentObject private var playbackClock: PlaybackClock
    var metadataControlsSpacing: CGFloat

    var body: some View {
        Group {
            PlayerProgressBar(
                positionMs: model.nowPositionMs,
                durationMs: model.durationMs,
                height: 24,
                onSeek: model.seek(toPlaybackPositionMs:)
            )
            .padding(.horizontal, 2)
            .padding(.top, metadataControlsSpacing)

            HStack(spacing: 0) {
                Text(androidPlayerTime(model.nowPositionMs))
                    .foregroundStyle(.white.opacity(204.0 / 255.0))
                Spacer()
                Text("-" + androidPlayerTime(max(0, model.durationMs - model.nowPositionMs)))
                    .foregroundStyle(.white.opacity(174.0 / 255.0))
            }
            .font(.pretendard(12))
        }
    }
}

private func androidPlayerTime(_ milliseconds: Int64) -> String {
    let total = max(0, Int(milliseconds / 1000))
    let minutes = Int32(truncatingIfNeeded: total / 60)
    let seconds = total % 60
    if seconds < 10 {
        return "\(minutes):0\(seconds)"
    }
    return "\(minutes):\(seconds)"
}

private struct AndroidMoreIcon: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            let radius = 1.65 * scale
            for x in [5.0, 12.0, 19.0] {
                let center = CGPoint(x: x * scale, y: 12 * scale)
                let dot = CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                context.fill(Path(ellipseIn: dot), with: .color(.white))
            }
        }
    }
}

private enum AndroidTransportButtonKind {
    case previous
    case playPause
    case next
}

private struct AndroidTransportButtonStyle: ButtonStyle {
    var kind: AndroidTransportButtonKind
    var primary = false
    var playing = false
    var size: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        AndroidTransportButtonFace(
            kind: kind,
            primary: primary,
            playing: playing,
            pressed: configuration.isPressed
        )
        .frame(width: size, height: size)
        .contentShape(Circle())
    }
}

private struct AndroidTransportButtonFace: View {
    var kind: AndroidTransportButtonKind
    var primary: Bool
    var playing: Bool
    var pressed: Bool

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)

            if primary {
                let fill = pressed
                    ? Color(red: 226.0 / 255.0, green: 226.0 / 255.0, blue: 232.0 / 255.0)
                    : Color(red: 246.0 / 255.0, green: 246.0 / 255.0, blue: 250.0 / 255.0)
                let radius = side * 0.48
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )),
                    with: .color(fill)
                )
            } else if pressed {
                let radius = side * 0.42
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )),
                    with: .color(.white.opacity(28.0 / 255.0))
                )
            }

            let iconColor = primary
                ? Color(red: 14.0 / 255.0, green: 15.0 / 255.0, blue: 20.0 / 255.0)
                : Color.white.opacity(pressed ? 1 : 232.0 / 255.0)

            switch kind {
            case .playPause:
                if playing {
                    drawPause(in: &context, center: center, side: side, color: iconColor)
                } else {
                    drawPlay(in: &context, center: center, side: side, color: iconColor)
                }
            case .previous:
                drawSkip(in: &context, center: center, side: side, next: false, color: iconColor)
            case .next:
                drawSkip(in: &context, center: center, side: side, next: true, color: iconColor)
            }
        }
    }

    private func drawPlay(
        in context: inout GraphicsContext,
        center: CGPoint,
        side: CGFloat,
        color: Color
    ) {
        let width = side * 0.26
        let height = side * 0.34
        let left = center.x - width * 0.32 - side * 0.005
        var path = Path()
        path.move(to: CGPoint(x: left, y: center.y - height / 2))
        path.addLine(to: CGPoint(x: left, y: center.y + height / 2))
        path.addLine(to: CGPoint(x: left + width, y: center.y))
        path.closeSubpath()
        context.fill(path, with: .color(color))
    }

    private func drawPause(
        in context: inout GraphicsContext,
        center: CGPoint,
        side: CGFloat,
        color: Color
    ) {
        let barWidth = side * 0.088
        let height = side * 0.34
        let gap = side * 0.105
        let cornerRadius = barWidth * 0.42
        let left = center.x - gap / 2 - barWidth
        let y = center.y - height / 2
        for x in [left, center.x + gap / 2] {
            let rect = CGRect(x: x, y: y, width: barWidth, height: height)
            context.fill(
                RoundedRectangle(cornerRadius: cornerRadius).path(in: rect),
                with: .color(color)
            )
        }
    }

    private func drawSkip(
        in context: inout GraphicsContext,
        center: CGPoint,
        side: CGFloat,
        next: Bool,
        color: Color
    ) {
        let triangleWidth = side * 0.30
        let triangleHeight = side * 0.44
        let gap = side * 0.045
        let barWidth = max(2.5, side * 0.065)
        let totalWidth = triangleWidth + gap + barWidth
        let left = center.x - totalWidth / 2
        let top = center.y - triangleHeight / 2
        let bottom = center.y + triangleHeight / 2
        let barX = next ? left + triangleWidth + gap : left
        let triangleLeft = next ? left : left + barWidth + gap
        let triangleRight = triangleLeft + triangleWidth

        var triangle = Path()
        if next {
            triangle.move(to: CGPoint(x: triangleLeft, y: top))
            triangle.addLine(to: CGPoint(x: triangleRight, y: center.y))
            triangle.addLine(to: CGPoint(x: triangleLeft, y: bottom))
        } else {
            triangle.move(to: CGPoint(x: triangleRight, y: top))
            triangle.addLine(to: CGPoint(x: triangleLeft, y: center.y))
            triangle.addLine(to: CGPoint(x: triangleRight, y: bottom))
        }
        triangle.closeSubpath()
        context.fill(triangle, with: .color(color))

        let bar = CGRect(x: barX, y: top, width: barWidth, height: triangleHeight)
        context.fill(
            RoundedRectangle(cornerRadius: barWidth * 0.24).path(in: bar),
            with: .color(color)
        )
    }
}

struct PlayerBackgroundView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    var isLandscape = false

    var body: some View {
        let background = effectiveBackground
        Group {
            if backgroundShouldAnimate(background) {
                TimelineView(.animation) { context in
                    backgroundContent(background: background, date: context.date)
                }
            } else {
                backgroundContent(background: background, date: nil)
            }
        }
    }

    @ViewBuilder
    private func backgroundContent(background: AppSettings.BackgroundSettings, date: Date?) -> some View {
        ZStack {
            if background.mode == AppSettings.backgroundVideo {
                let fallback = videoFallback(background)
                backgroundFallback(background: fallback, date: date)
                if let info = model.youtubeInfo {
                    YouTubeBackdropSection(info: info, background: background, isLandscape: isLandscape)
                }
            } else {
                backgroundFallback(background: background, date: date)
            }
            if background.noise {
                NoiseOverlay()
                    .opacity(0.18)
                    .ignoresSafeArea()
            }
        }
        .allowsHitTesting(false)
    }

    private func videoFallback(_ background: AppSettings.BackgroundSettings) -> AppSettings.BackgroundSettings {
        var fallback = background
        fallback.mode = background.videoFallback
        return fallback
    }

    @ViewBuilder
    private func backgroundFallback(background: AppSettings.BackgroundSettings, date: Date?) -> some View {
        ZStack {
            if background.mode == AppSettings.backgroundGradient, let url = model.currentTrack?.artworkURL {
                MovingArtworkBlurLayer(
                    url: url,
                    blur: background.blur,
                    opacity: 1,
                    scale: background.reduceMotion ? 1 : 1.08,
                    date: date,
                    reduceMotion: background.reduceMotion
                )
                .ignoresSafeArea()
                AndroidArtworkDimmingGradient(brightness: background.brightness)
                    .ignoresSafeArea()
            } else {
                backgroundBase(background: background, date: date)
            }
            if background.mode != AppSettings.backgroundGradient {
                Color.black.opacity(0.24).ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private func backgroundBase(background: AppSettings.BackgroundSettings, date: Date?) -> some View {
        switch background.mode {
        case AppSettings.backgroundSolid:
            Color(hex: background.solidColor).ignoresSafeArea()
        default:
            AnimatedGradientBackgroundLayer(background: background, date: date)
            .ignoresSafeArea()
        }
    }

    private var effectiveBackground: AppSettings.BackgroundSettings {
        _ = settings.backgroundSettingsRevision
        return settings.effectiveBackgroundSettings(trackKey: model.currentTrackKey)
    }
}

private struct YouTubeBackdropSection: View {
    @EnvironmentObject private var model: AppViewModel
    // Subscribed (not read directly) so this view re-renders with the display-rate playback clock driving model.nowPositionMs.
    @EnvironmentObject private var playbackClock: PlaybackClock
    var info: YouTubeVideoInfo
    var background: AppSettings.BackgroundSettings
    var isLandscape: Bool
    @State private var videoVisible = false

    var body: some View {
        ZStack {
            YouTubeBackdropView(
                info: info,
                playerSeconds: model.youtubePlayerSeconds,
                playing: model.currentTrack?.playing ?? false,
                firstLyricSeconds: model.youtubeFirstLyricSeconds,
                offsetSeconds: model.youtubeOffsetSeconds,
                hasCaptionStartTime: info.hasCaptionStartTime,
                captionStartTimeSeconds: info.captionStartTimeSeconds,
                autoMatchedUnknownCaptionStart: info.isAutoMatchedUnknownCaptionStart,
                brightness: background.brightness,
                blur: background.blur,
                videoScale: background.videoScale,
                videoAspect: background.videoAspect,
                videoVisible: $videoVisible
            )
            .blur(radius: youtubeBackgroundBlurRadius(background.blur))
            Color.black.opacity(videoVisible ? AppearancePolicy.videoDimOpacity(background.brightness) : 0)
        }
        // The decorative video and dimming always cover the home indicator area.
        // Keep landscape top/side insets when edge-to-edge is disabled.
        .ignoresSafeArea(.container, edges: background.videoEdgeToEdge || !isLandscape ? .all : .bottom)
    }
}

private func backgroundShouldAnimate(_ background: AppSettings.BackgroundSettings) -> Bool {
    guard !background.reduceMotion else { return false }
    return background.mode == AppSettings.backgroundGradient || background.mode == AppSettings.backgroundBlurGradient
}

private struct AnimatedGradientBackgroundLayer: View {
    private static let blobColors = [
        Color(red: 0.28, green: 0.25, blue: 0.49),
        Color(red: 0.57, green: 0.33, blue: 0.51),
        Color(red: 0.24, green: 0.37, blue: 0.51),
        Color(red: 0.25, green: 0.45, blue: 0.40),
        Color(red: 0.50, green: 0.23, blue: 0.33),
        Color(red: 0.18, green: 0.30, blue: 0.48)
    ]
    private static let radii: [CGFloat] = [0.80, 0.70, 0.55, 0.75, 0.50, 0.90]

    var background: AppSettings.BackgroundSettings
    var date: Date?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Color(red: 0.08, green: 0.10, blue: 0.14)
                ForEach(0..<Self.blobColors.count, id: \.self) { index in
                    blob(index: index, size: size)
                }
                LinearGradient(
                    colors: [
                        Color(red: 0.02, green: 0.03, blue: 0.07).opacity(0.45),
                        Color(red: 0.07, green: 0.05, blue: 0.13).opacity(0.42),
                        Color(red: 0.03, green: 0.04, blue: 0.08).opacity(0.52)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }

    private func blob(index: Int, size: CGSize) -> some View {
        let radius = max(size.width, size.height) * Self.radii[index] * (0.6 + CGFloat(min(100, max(0, background.blur))) * 0.02)
        let center = blobCenter(index: index, size: size)
        let alpha = max(0.16, 0.35 - Double(index) * 0.025)
        return Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Self.blobColors[index].opacity(alpha),
                        Self.blobColors[index].opacity(alpha * 0.45),
                        .clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: radius
                )
            )
            .frame(width: radius * 2, height: radius * 2)
            .position(center)
    }

    private func blobCenter(index: Int, size: CGSize) -> CGPoint {
        let seconds = date?.timeIntervalSinceReferenceDate ?? 0
        let speed = 0.010 + Double(index) * 0.0027
        let phaseX = 0.83 * Double(index) + 0.71
        let phaseY = 0.61 * Double(index) + 1.37
        let x = animatedBackgroundValue(seconds: seconds, speed: speed, phase: phaseX, min: -0.18, max: 1.18, reduceMotion: background.reduceMotion)
        let y = animatedBackgroundValue(seconds: seconds, speed: speed * 1.21, phase: phaseY, min: -0.18, max: 1.18, reduceMotion: background.reduceMotion)
        return CGPoint(x: size.width * x, y: size.height * y)
    }
}

private struct MovingArtworkBlurLayer: View {
    var url: URL
    var blur: Int
    var opacity: Double
    var scale: CGFloat = 1.34
    var date: Date?
    var reduceMotion: Bool

    var body: some View {
        GeometryReader { proxy in
            let transform = artworkTransform(size: proxy.size)
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.clear
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .scaleEffect(transform.scale)
            .offset(transform.offset)
            .blur(radius: CGFloat(min(100, max(0, blur))) * 0.72)
            .opacity(opacity)
            .clipped()
        }
    }

    private func artworkTransform(size: CGSize) -> (scale: CGFloat, offset: CGSize) {
        let effectiveScale: CGFloat = reduceMotion ? max(1, scale * 0.92) : scale
        guard !reduceMotion else {
            return (effectiveScale, .zero)
        }
        let seconds = date?.timeIntervalSinceReferenceDate ?? 0
        let maxX = max(0, (effectiveScale - 1) * size.width * 0.38)
        let maxY = max(0, (effectiveScale - 1) * size.height * 0.38)
        let x = maxX * (0.72 * CGFloat(sin(seconds * 0.034 + 0.71)) + 0.28 * CGFloat(sin(seconds * 0.016 + 1.93)))
        let y = maxY * (0.70 * CGFloat(sin(seconds * 0.030 + 1.37)) + 0.30 * CGFloat(sin(seconds * 0.014 + 0.29)))
        return (effectiveScale, CGSize(width: x, height: y))
    }
}

private struct AndroidArtworkDimmingGradient: View {
    var brightness: Int

    var body: some View {
        let dim = max(0, min(255, Int((214.0 - Double(brightness) * 1.28).rounded())))
        LinearGradient(
            stops: [
                .init(color: Color(red: 6.0 / 255.0, green: 8.0 / 255.0, blue: 18.0 / 255.0).opacity(Double(max(50, dim - 52)) / 255.0), location: 0),
                .init(color: Color(red: 18.0 / 255.0, green: 13.0 / 255.0, blue: 34.0 / 255.0).opacity(Double(max(68, dim - 24)) / 255.0), location: 0.52),
                .init(color: Color(red: 7.0 / 255.0, green: 9.0 / 255.0, blue: 20.0 / 255.0).opacity(Double(max(86, dim)) / 255.0), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private func animatedBackgroundValue(seconds: Double, speed: Double, phase: Double, min: CGFloat, max: CGFloat, reduceMotion: Bool) -> CGFloat {
    if reduceMotion {
        return (min + max) * 0.5
    }
    let wave = (sin(seconds * speed + phase) + 1.0) * 0.5
    return min + (max - min) * CGFloat(wave)
}

private func youtubeBackgroundBlurRadius(_ blur: Int) -> CGFloat {
    let effectiveBlur = min(200, max(0, blur * 2))
    return effectiveBlur <= 0 ? 0 : min(36, CGFloat(effectiveBlur) * 0.16)
}

private struct ToastBanner: View {
    let message: String
    let bottomPadding: CGFloat

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            Text(message)
                .font(.pretendard(14, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
                .padding(.horizontal, 18)
                .padding(.bottom, bottomPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

struct NoiseOverlay: View {
    var body: some View {
        Canvas { context, size in
            var generator = SeededRandomNumberGenerator(seed: UInt64(size.width.rounded()) << 32 ^ UInt64(size.height.rounded()) ^ 0x9e3779b97f4a7c15)
            let count = min(1400, max(280, Int(size.width * size.height / 620)))
            for _ in 0..<count {
                let x = Double.random(in: 0...Double(max(1, size.width)), using: &generator)
                let y = Double.random(in: 0...Double(max(1, size.height)), using: &generator)
                let alpha = Double.random(in: 0.05...0.20, using: &generator)
                let rect = CGRect(x: x, y: y, width: 1, height: 1)
                context.fill(Path(rect), with: .color(.white.opacity(alpha)))
            }
        }
        .blendMode(.overlay)
        .allowsHitTesting(false)
    }
}

struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x123456789abcdef : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}

struct HeaderBar: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    @Binding var showingSettings: Bool
    @Binding var showingLogs: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image("IvLyricsOverlaySymbol")
                .resizable()
                .scaledToFit()
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("ivLyrics")
                    .font(.pretendard(21, weight: .bold))
                Text(model.status == .loading
                    ? model.lyricsLoadingText
                    : model.status.text(settings: settings))
                    .font(.pretendard(12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            Button {
                showingLogs = true
            } label: {
                Image(systemName: "terminal")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
        .foregroundStyle(.white)
    }
}

struct ManualTrackPanel: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ArtworkView()
                VStack(spacing: 8) {
                    TextField(settings.t("field.title"), text: $model.inputTitle)
                        .textInputAutocapitalization(.words)
                    TextField(settings.t("field.artist"), text: $model.inputArtist)
                        .textInputAutocapitalization(.words)
                    TextField(settings.t("field.album"), text: $model.inputAlbum)
                        .textInputAutocapitalization(.words)
                }
                .frame(minWidth: 0, maxWidth: .infinity)
                .layoutPriority(1)
                .textFieldStyle(PlayerTextFieldStyle())
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                TextField(settings.t("field.duration_hint"), text: $model.inputDuration)
                    .keyboardType(.numbersAndPunctuation)
                    .frame(width: 104)
                TextField(settings.t("field.spotify_id"), text: $model.inputSpotifyId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minWidth: 0, maxWidth: .infinity)
                Button {
                    model.resolveSpotifyMetadata()
                } label: {
                    Image(systemName: model.resolvingSpotifyMetadata ? "hourglass" : "link.badge.plus")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.bordered)
                .disabled(!model.canResolveSpotifyMetadata || model.resolvingSpotifyMetadata)
            }
            .frame(maxWidth: .infinity)
            .textFieldStyle(PlayerTextFieldStyle())

            HStack(spacing: 8) {
                TextField(settings.t("field.isrc"), text: $model.inputIsrc)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button {
                    model.applyManualTrack()
                } label: {
                    Label(settings.t("button.load"), systemImage: "arrow.down.circle")
                        .frame(minWidth: 92)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.hasTrackInput)
            }
            .frame(maxWidth: .infinity)
            .textFieldStyle(PlayerTextFieldStyle())

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button {
                        model.spotifyLivePolling ? model.stopSpotifyLivePolling() : model.connectSpotifyUserAndStartPolling()
                    } label: {
                        Label(
                            model.spotifyLivePolling ? settings.t("spotify.live.connected") : settings.t("spotify.live.connect"),
                            systemImage: model.spotifyLivePolling ? "dot.radiowaves.left.and.right" : "person.crop.circle.badge.plus"
                        )
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        Task { await model.refreshSpotifyPlayback(loadLyricsIfNeeded: true) }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.spotifyUserConnected)
                }
                Text(spotifyLiveStatusText)
                    .font(.pretendard(12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.09)))
    }

    private var spotifyLiveStatusText: String {
        if model.spotifyAppRemoteConnected {
            return settings.t("spotify.source.app_remote")
        }
        if !model.spotifyDeviceName.trimmed.isEmpty {
            return model.spotifyDeviceName
        }
        return model.spotifyUserConnected ? settings.t("spotify.source.web_api") : settings.t("spotify.source.off")
    }
}

private struct LyricsPageOverlay: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    @Binding var visible: Bool
    @Binding var dragOffset: CGFloat
    @Binding var showingMetaMenu: Bool
    @Binding var selectedMetaMenuTab: LyricsMetaMenuTab
    @Binding var metaTipVisible: Bool
    var screenHeight: CGFloat
    var safeAreaTop: CGFloat
    var safeAreaBottom: CGFloat

    var body: some View {
        ZStack {
            Color.black
                .opacity(0.10)
                .ignoresSafeArea()
            Color(red: 6.0 / 255.0, green: 7.0 / 255.0, blue: 12.0 / 255.0)
                .opacity(54.0 / 255.0)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                header
                    .padding(.top, headerTopPadding)
                    .padding(.horizontal, 24)
                    .contentShape(Rectangle())
                    .gesture(dismissDragGesture)

                if let loadingText = model.lyricsGenerationLoadingText {
                    LyricsGenerationLoadingPill(text: loadingText)
                        .padding(.top, 8)
                        .padding(.horizontal, 24)
                }

                LyricsTimelineScrollView(
                    topPadding: model.lyricsGenerationLoadingText == nil ? 16 : 10,
                    bottomPadding: safeAreaBottom + 28,
                    horizontalPadding: 24,
                    centerAnchorY: 0.42
                )
            }
            LyricsProviderAttribution()
                .padding(.horizontal, 24)
                .padding(.bottom, safeAreaBottom + 12)
        }
        .clipShape(RoundedRectangle(cornerRadius: dragOffset > 1 ? 28 : 0, style: .continuous))
        .offset(y: dragOffset)
        .ignoresSafeArea()
    }

    private var headerTopPadding: CGFloat {
        let collapse = min(1, max(0, dragOffset) / 120)
        let expanded = safeAreaTop + 10
        let compact: CGFloat = 22
        return expanded + (compact - expanded) * collapse
    }

    private var header: some View {
        let _ = settings.typographyRevision
        let typography = settings.typographySettings()
        return VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Button {
                    dismiss()
                } label: {
                    Capsule()
                        .fill(.white.opacity(0.32))
                        .frame(width: 42, height: 3)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24, alignment: .top)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxHeight: .infinity, alignment: .top)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.titleText.trimmed.isEmpty ? "ivLyrics" : model.titleText)
                        .font(typography.font(slotId: AppSettings.typoLyricsHeaderTitle, baseSize: 19))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(model.artistText.trimmed.isEmpty ? " " : model.artistText)
                            .font(typography.font(slotId: AppSettings.typoLyricsHeaderArtist, baseSize: 14))
                            .foregroundStyle(.white.opacity(0.74))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(1)
                        Spacer(minLength: 8)
                        if model.status == .loading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        LyricsMetaStrip(inline: true) {
                            openMetaMenu(.language)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(2)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.handleTitleTap()
                }
                .onLongPressGesture {
                    openMetaMenu(.language)
                }
                .frame(height: 54)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 66)

            if metaTipVisible && !showingMetaMenu {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        metaTipVisible = false
                    }
                } label: {
                    Text(settings.t("lyrics.menu_tip"))
                        .font(.pretendard(12, weight: .semibold))
                        .lineSpacing(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                        .frame(maxWidth: 278, alignment: .leading)
                        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
    }

    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                dragOffset = min(screenHeight, max(0, value.translation.height))
            }
            .onEnded { value in
                let shouldClose = dragOffset > screenHeight * 0.30
                    || (value.predictedEndTranslation.height > 160 && dragOffset > 42)
                if shouldClose {
                    dismiss()
                } else {
                    withAnimation(.easeOut(duration: 0.21)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.28)) {
            dragOffset = screenHeight
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            guard dragOffset >= screenHeight * 0.9 else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                visible = false
                dragOffset = 0
            }
        }
    }

    private func openMetaMenu(_ tab: LyricsMetaMenuTab) {
        selectedMetaMenuTab = tab
        metaTipVisible = false
        withAnimation(.easeOut(duration: 0.18)) {
            showingMetaMenu = true
        }
    }
}

private struct InAppBrowserOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var visible: Bool
    @Binding var dragOffset: CGFloat
    var url: URL
    var screenHeight: CGFloat
    var onCreatorAuthRedirect: (URL) -> Bool
    @State private var loading = true

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                InAppBrowserWebView(
                    initialURL: url,
                    colorScheme: colorScheme,
                    loading: $loading,
                    onCreatorAuthRedirect: onCreatorAuthRedirect
                )
                .background(browserBackground)
                .overlay {
                    if loading {
                        InAppBrowserLoadingView()
                            .transition(.opacity)
                    }
                }
            }
            .background(browserBackground)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(alignment: .top) {
                handle
            }
            .padding(.top, sheetTopMargin)
            .offset(y: dragOffset)
            .animation(.easeOut(duration: 0.21), value: dragOffset)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var handle: some View {
        Button {
            dismiss()
        } label: {
            Capsule()
                .fill(handleColor)
                .frame(width: 42, height: 3)
                .padding(.top, 12)
                .padding(.bottom, 19)
                .frame(width: 110, height: 34)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .gesture(dismissDragGesture)
    }

    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                let shouldClose = dragOffset > screenHeight * 0.24
                    || (value.predictedEndTranslation.height > 150 && dragOffset > 36)
                if shouldClose {
                    dismiss()
                } else {
                    withAnimation(.easeOut(duration: 0.21)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private var browserBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.055, green: 0.067, blue: 0.086)
            : Color(red: 0.984, green: 0.984, blue: 0.988)
    }

    private var handleColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.34)
            : Color.black.opacity(0.30)
    }

    private var sheetTopMargin: CGFloat {
        18
    }

    private func dismiss() {
        dragOffset = 0
        withAnimation(.easeOut(duration: 0.26)) {
            visible = false
        }
    }
}

private struct InAppBrowserLoadingView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                skeleton(width: 118, height: 16, radius: 8, strong: true)
                Spacer()
                skeleton(width: 40, height: 34, radius: 17)
                skeleton(width: 76, height: 34, radius: 17)
            }
            .frame(height: 44)

            VStack(spacing: 16) {
                HStack(spacing: 16) {
                    skeleton(width: 78, height: 78, radius: 39, strong: true)
                    VStack(alignment: .leading, spacing: 10) {
                        skeleton(width: 142, height: 24, radius: 10, strong: true)
                        skeleton(width: 190, height: 14, radius: 7)
                        skeleton(width: 98, height: 14, radius: 7)
                    }
                    Spacer()
                }
                HStack(spacing: 10) {
                    skeleton(width: nil, height: 54, radius: 14)
                    skeleton(width: nil, height: 54, radius: 14)
                }
            }
            .padding(20)
            .background(surfaceColor, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            HStack(spacing: 8) {
                skeleton(width: 92, height: 34, radius: 17, strong: true)
                skeleton(width: 82, height: 34, radius: 17)
                Spacer()
            }

            ForEach(0..<4, id: \.self) { index in
                HStack(spacing: 12) {
                    skeleton(width: 44, height: 44, radius: 14)
                    VStack(alignment: .leading, spacing: 9) {
                        skeleton(width: index % 2 == 0 ? 184 : 138, height: 17, radius: 8, strong: true)
                        skeleton(width: index % 3 == 0 ? 126 : 162, height: 13, radius: 7)
                    }
                    Spacer()
                    skeleton(width: 34, height: 34, radius: 17)
                }
                .padding(14)
                .background(surfaceColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .padding(.bottom, 18)
        .background(backgroundColor)
        .opacity(pulse ? 1 : 0.58)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.86).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private func skeleton(width: CGFloat?, height: CGFloat, radius: CGFloat, strong: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(strong ? skeletonStrongColor : skeletonColor)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
    }

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(red: 0.055, green: 0.067, blue: 0.086)
            : Color(red: 0.984, green: 0.984, blue: 0.988)
    }

    private var surfaceColor: Color {
        colorScheme == .dark
            ? Color(red: 0.098, green: 0.110, blue: 0.133)
            : .white
    }

    private var skeletonColor: Color {
        colorScheme == .dark
            ? Color(red: 0.176, green: 0.192, blue: 0.227)
            : Color(red: 0.925, green: 0.933, blue: 0.945)
    }

    private var skeletonStrongColor: Color {
        colorScheme == .dark
            ? Color(red: 0.227, green: 0.247, blue: 0.282)
            : Color(red: 0.878, green: 0.890, blue: 0.910)
    }
}

#if os(iOS)
private struct InAppBrowserWebView: UIViewRepresentable {
    var initialURL: URL
    var colorScheme: ColorScheme
    @Binding var loading: Bool
    var onCreatorAuthRedirect: (URL) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            initialURL: initialURL,
            colorScheme: colorScheme,
            loading: $loading,
            onCreatorAuthRedirect: onCreatorAuthRedirect
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.backgroundColor = browserUIColor
        webView.scrollView.backgroundColor = browserUIColor
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: initialURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.colorScheme = colorScheme
        context.coordinator.onCreatorAuthRedirect = onCreatorAuthRedirect
        if context.coordinator.initialURL != initialURL {
            context.coordinator.initialURL = initialURL
            webView.load(URLRequest(url: initialURL))
        }
        webView.backgroundColor = browserUIColor
        webView.scrollView.backgroundColor = browserUIColor
    }

    private var browserUIColor: UIColor {
        colorScheme == .dark
            ? UIColor(red: 14 / 255, green: 17 / 255, blue: 22 / 255, alpha: 1)
            : UIColor(red: 251 / 255, green: 251 / 255, blue: 252 / 255, alpha: 1)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var initialURL: URL
        var colorScheme: ColorScheme
        @Binding var loading: Bool
        var onCreatorAuthRedirect: (URL) -> Bool

        init(
            initialURL: URL,
            colorScheme: ColorScheme,
            loading: Binding<Bool>,
            onCreatorAuthRedirect: @escaping (URL) -> Bool
        ) {
            self.initialURL = initialURL
            self.colorScheme = colorScheme
            self.onCreatorAuthRedirect = onCreatorAuthRedirect
            _loading = loading
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            loading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            injectProfileChrome(into: webView, url: webView.url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self.loading = false
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            loading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            loading = false
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.targetFrame?.isMainFrame != false,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if onCreatorAuthRedirect(url) {
                loading = false
                decisionHandler(.cancel)
                return
            }
            if shouldOpenExternally(url) {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        private func shouldOpenExternally(_ url: URL) -> Bool {
            let scheme = url.scheme?.lowercased() ?? ""
            if url.absoluteString.hasPrefix("about:") || url.absoluteString.hasPrefix("data:") {
                return false
            }
            guard scheme == "http" || scheme == "https" else {
                return false
            }
            if normalizedBrowserURL(url) == normalizedBrowserURL(initialURL) {
                return false
            }
            if sameLyricsProfileNavigation(url, initialURL) {
                return false
            }
            if isCreatorLoginWebURL(initialURL), isCreatorLoginWebURL(url) {
                return false
            }
            return true
        }

        private func isCreatorLoginWebURL(_ url: URL) -> Bool {
            let scheme = url.scheme?.lowercased() ?? ""
            guard scheme == "https" else { return false }
            let host = url.host?.lowercased() ?? ""
            return host == "discord.com"
                || host.hasSuffix(".discord.com")
                || host == "discordapp.com"
                || host.hasSuffix(".discordapp.com")
                || host == "ivl.is"
                || host == "lyrics.ivl.is"
                || host == "lyrics.api.ivl.is"
        }

        private func injectProfileChrome(into webView: WKWebView, url: URL?) {
            guard let url, isLyricsProfileURL(url) else { return }
            let theme = colorScheme == .dark ? "dark" : "light"
            let css = """
            .login-btn,.credit[href*="github.com/ivLis-Studio/ivLyrics"],.theme-toggle,.topbar .handle,.topbar .handle .dot{display:none!important;}
            html,body,.page,.shell,.profile,.tracks,.track,*{-webkit-user-select:none!important;user-select:none!important;-webkit-touch-callout:none!important;}
            img,a{-webkit-user-drag:none!important;user-drag:none!important;}
            .page{padding-bottom:28px!important;}
            """
            let js = """
            (function(){
            var theme=\(Self.jsString(theme));
            try{localStorage.setItem('ivlyrics_profile_theme',theme);}catch(error){}
            document.documentElement.dataset.theme=theme;
            document.documentElement.style.colorScheme=theme;
            var id='ivlyrics-ios-profile-style';
            var old=document.getElementById(id);
            if(old){old.remove();}
            var style=document.createElement('style');
            style.id=id;
            style.textContent=\(Self.jsString(css));
            (document.head||document.documentElement).appendChild(style);
            var block=function(event){event.preventDefault();return false;};
            document.addEventListener('contextmenu',block,true);
            document.addEventListener('selectstart',block,true);
            document.addEventListener('dragstart',block,true);
            document.oncontextmenu=function(){return false;};
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        private func isLyricsProfileURL(_ url: URL) -> Bool {
            (url.host?.lowercased() == "lyrics.ivl.is") && url.path.hasPrefix("/@")
        }

        private func sameLyricsProfileNavigation(_ nextURL: URL, _ initialURL: URL) -> Bool {
            let nextPath = lyricsProfilePath(nextURL)
            let initialPath = lyricsProfilePath(initialURL)
            return !nextPath.isEmpty && nextPath == initialPath
        }

        private func lyricsProfilePath(_ url: URL) -> String {
            let scheme = url.scheme?.lowercased() ?? ""
            guard (scheme == "http" || scheme == "https"),
                  url.host?.lowercased() == "lyrics.ivl.is" else {
                return ""
            }
            var path = url.path
            while path.hasSuffix("/") && path.count > 1 {
                path.removeLast()
            }
            guard path.hasPrefix("/@"), path.dropFirst(2).contains("/") == false else {
                return ""
            }
            return path
        }

        private func normalizedBrowserURL(_ url: URL) -> String {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            var value = (components?.url ?? url).absoluteString
            while value.hasSuffix("/") {
                value.removeLast()
            }
            return value
        }

        private static func jsString(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [value]),
                  let encoded = String(data: data, encoding: .utf8) else {
                return "\"\""
            }
            return String(encoded.dropFirst().dropLast())
        }
    }
}
#else
private struct InAppBrowserWebView: View {
    var initialURL: URL
    var colorScheme: ColorScheme
    @Binding var loading: Bool
    var onCreatorAuthRedirect: (URL) -> Bool

    var body: some View {
        Text(initialURL.absoluteString)
            .onAppear { loading = false }
    }
}
#endif

private struct AndroidLandscapePlayerLayout: Layout {
    var tablet: Bool
    var contentSpacing: CGFloat = 10

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count >= 2 else { return }
        let childProposal = ProposedViewSize(width: bounds.width, height: nil)
        let heroSize = subviews[0].sizeThatFits(childProposal)
        let controlsSize = subviews[1].sizeThatFits(childProposal)
        let remaining = max(0, bounds.height - heroSize.height - controlsSize.height - contentSpacing)
        let topWeight: CGFloat = tablet ? 0.42 : 0.38
        let bottomWeight: CGFloat = tablet ? 0.26 : 0.24
        let topSpace = remaining * topWeight / max(0.01, topWeight + bottomWeight)
        let centerX = bounds.midX

        subviews[0].place(
            at: CGPoint(x: centerX, y: bounds.minY + topSpace),
            anchor: .top,
            proposal: ProposedViewSize(width: bounds.width, height: heroSize.height)
        )
        subviews[1].place(
            at: CGPoint(x: centerX, y: bounds.minY + topSpace + heroSize.height + contentSpacing),
            anchor: .top,
            proposal: ProposedViewSize(width: bounds.width, height: controlsSize.height)
        )
    }
}

private struct LandscapePlayerPane: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    var controlsVisible: Bool
    var centered: Bool
    var containerSize: CGSize
    var onOpenVinyl: () -> Void

    var body: some View {
        let _ = settings.typographyRevision
        let typography = settings.typographySettings()
        AndroidLandscapePlayerLayout(tablet: containerSize.width > 900) {
            VStack(spacing: metadataSpacing) {
                if settings.landscapeArtworkEnabled {
                    LandscapeArtworkView(size: artworkSize, onTap: onOpenVinyl)
                        .scaleEffect(controlsVisible ? 1 : 1.08)
                }
                VStack(spacing: 4) {
                    Text(model.titleText.trimmed.isEmpty ? settings.t("label.no_current_track") : model.titleText)
                        .font(typography.font(slotId: AppSettings.typoMainTitle, baseSize: 23))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(model.artistText.trimmed.isEmpty ? " " : model.artistText)
                        .font(typography.font(slotId: AppSettings.typoMainArtist, baseSize: 15))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                .contentShape(Rectangle())
                .onTapGesture { model.handleTitleTap() }
            }
            .offset(y: controlsVisible ? 0 : hiddenHeroOffset)

            LandscapeTransportControls()
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
                .accessibilityHidden(!controlsVisible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: controlsVisible ? 0.18 : 0.26), value: controlsVisible)
        .accessibilityElement(children: .contain)
    }

    private var artworkSize: CGFloat {
        let tablet = containerSize.width > 900
        let heightFraction: CGFloat = tablet ? 0.53 : 0.45
        let widthFraction: CGFloat = centered ? (tablet ? 0.28 : 0.30) : (tablet ? 0.28 : 0.23)
        let rawSize = min(containerSize.height * heightFraction, containerSize.width * widthFraction)
        let minimum: CGFloat = tablet ? 190 : 132
        return max(minimum, rawSize)
    }

    private var metadataSpacing: CGFloat {
        if containerSize.width > 900 {
            return controlsVisible ? 24 : 34
        }
        return controlsVisible ? 12 : 24
    }

    private var hiddenHeroOffset: CGFloat {
        containerSize.width > 900 ? 54 : 66
    }
}

private struct LandscapeArtworkView: View {
    @EnvironmentObject private var model: AppViewModel
    var size: CGFloat
    var onTap: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(red: 34.0 / 255.0, green: 35.0 / 255.0, blue: 40.0 / 255.0))
            if let url = model.currentTrack?.artworkURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.clear
                }
                .clipShape(RoundedRectangle(cornerRadius: 20))
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .artworkSwipeActions(size: size, onTap: onTap)
    }
}

private struct LandscapeTransportControls: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    // Subscribed (not read directly) so this view re-renders with the display-rate playback clock driving model.nowPositionMs.
    @EnvironmentObject private var playbackClock: PlaybackClock

    var body: some View {
        VStack(spacing: 5) {
            PlayerProgressBar(
                positionMs: model.nowPositionMs,
                durationMs: model.durationMs,
                height: 22,
                onSeek: model.seek(toPlaybackPositionMs:)
            )

            HStack {
                Text(timeText(model.nowPositionMs))
                Spacer()
                Text("-" + timeText(max(0, model.durationMs - model.nowPositionMs)))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.74))

            HStack(spacing: 13) {
                Button { model.skipToPreviousTrack() } label: {
                    Color.clear
                }
                .buttonStyle(AndroidTransportButtonStyle(kind: .previous, size: 54))
                .accessibilityLabel(settings.t("button.prev_track"))
                Button { model.togglePlayback() } label: {
                    Color.clear
                }
                .buttonStyle(AndroidTransportButtonStyle(
                    kind: .playPause,
                    primary: true,
                    playing: model.currentTrack?.playing == true,
                    size: 62
                ))
                .accessibilityLabel(settings.t("debug.play_pause"))
                Button { model.skipToNextTrack() } label: {
                    Color.clear
                }
                .buttonStyle(AndroidTransportButtonStyle(kind: .next, size: 54))
                .accessibilityLabel(settings.t("button.next_track"))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
    }

    private func timeText(_ ms: Int64) -> String {
        androidPlayerTime(ms)
    }
}

private struct PlayerProgressBar: View {
    var positionMs: Int64
    var durationMs: Int64
    var height: CGFloat = 28
    var onSeek: (Int64) -> Void

    @State private var dragPositionMs: Int64?

    private let trackStroke: CGFloat = 3.6
    private let thumbRadius: CGFloat = 5.0

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let track = trackRange(width: width)
            Canvas { context, size in
                let centerY = size.height * 0.5
                let endX = track.start + (track.end - track.start) * CGFloat(progress)
                var basePath = Path()
                basePath.move(to: CGPoint(x: track.start, y: centerY))
                basePath.addLine(to: CGPoint(x: track.end, y: centerY))
                context.stroke(
                    basePath,
                    with: .color(.white.opacity(66.0 / 255.0)),
                    style: StrokeStyle(lineWidth: trackStroke, lineCap: .round)
                )

                var progressPath = Path()
                progressPath.move(to: CGPoint(x: track.start, y: centerY))
                progressPath.addLine(to: CGPoint(x: endX, y: centerY))
                context.stroke(
                    progressPath,
                    with: .color(.white.opacity(217.0 / 255.0)),
                    style: StrokeStyle(lineWidth: trackStroke, lineCap: .round)
                )

                var thumbPath = Path()
                thumbPath.addEllipse(in: CGRect(
                    x: endX - thumbRadius,
                    y: centerY - thumbRadius,
                    width: thumbRadius * 2,
                    height: thumbRadius * 2
                ))
                context.fill(thumbPath, with: .color(.white.opacity(242.0 / 255.0)))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard canSeek else { return }
                        dragPositionMs = position(for: value.location.x, width: width)
                    }
                    .onEnded { value in
                        guard canSeek else {
                            dragPositionMs = nil
                            return
                        }
                        let target = position(for: value.location.x, width: width)
                        dragPositionMs = nil
                        onSeek(target)
                    }
            )
        }
        .frame(height: height)
        .opacity(canSeek ? 1 : 0.58)
        .focusable(canSeek)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .return], phases: [.down, .repeat]) { press in
            handleKeyPress(press)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(timeText(displayPositionMs)) / \(timeText(durationMs))")
        .accessibilityAdjustableAction { direction in
            guard canSeek else { return }
            switch direction {
            case .increment:
                seekBy(5_000)
            case .decrement:
                seekBy(-5_000)
            default:
                break
            }
        }
    }

    private var canSeek: Bool {
        durationMs > 0
    }

    private var displayPositionMs: Int64 {
        clamp(dragPositionMs ?? positionMs)
    }

    private var progress: Double {
        guard durationMs > 0 else { return 0 }
        return max(0, min(1, Double(displayPositionMs) / Double(durationMs)))
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard canSeek else { return .ignored }
        switch press.key {
        case .leftArrow:
            seekBy(press.modifiers.contains(.shift) ? -30_000 : -5_000)
            return .handled
        case .rightArrow:
            seekBy(press.modifiers.contains(.shift) ? 30_000 : 5_000)
            return .handled
        case .return:
            onSeek(displayPositionMs)
            return .handled
        default:
            return .ignored
        }
    }

    private func seekBy(_ deltaMs: Int64) {
        onSeek(clamp(displayPositionMs + deltaMs))
    }

    private func position(for x: CGFloat, width: CGFloat) -> Int64 {
        let track = trackRange(width: max(1, width))
        let fraction = track.end <= track.start ? 0 : max(0, min(1, (x - track.start) / (track.end - track.start)))
        return clamp(Int64((Double(durationMs) * Double(fraction)).rounded()))
    }

    private func trackRange(width: CGFloat) -> (start: CGFloat, end: CGFloat) {
        let horizontalInset = thumbRadius + max(1, trackStroke * 0.25)
        let start = min(horizontalInset, width * 0.5)
        let end = max(start, width - horizontalInset)
        return (start, end)
    }

    private func clamp(_ value: Int64) -> Int64 {
        if durationMs > 0 {
            return max(0, min(durationMs, value))
        }
        return max(0, value)
    }

    private func timeText(_ ms: Int64) -> String {
        androidPlayerTime(ms)
    }
}

private struct LandscapeCommandBar: View {
    static let hitTargetSize: CGFloat = 44

    @EnvironmentObject private var settings: AppSettings
    @Binding var showingSettings: Bool

    var body: some View {
        Button {
            showingSettings = true
        } label: {
            AndroidMoreIcon()
                .frame(width: 18, height: 18)
                .frame(width: Self.hitTargetSize, height: Self.hitTargetSize)
                // The plain-style label only hit-tests the 18 pt icon it draws, so taps
                // beside it fell through to the lyric rows; claim the whole 44 pt frame.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(settings.t("settings.title"))
    }
}

private struct LandscapeLyricsPane: View {
    @EnvironmentObject private var model: AppViewModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        LyricsTimelineScrollView(
            topPadding: 6,
            bottomPadding: 6,
            trailingPadding: 8,
            centerEmptyContent: true
        )
        .environment(\.originalLyricsVisible, settings.landscapeOriginalLyricsEnabled)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            LyricsProviderAttribution(includesSyncContributors: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
        .overlay(alignment: .topTrailing) {
            if let loadingText = model.lyricsGenerationLoadingText {
                LyricsGenerationLoadingPill(text: loadingText)
                    .padding(.top, 8)
                    .padding(.horizontal, 12)
            }
        }
    }
}

private struct LyricsGenerationLoadingPill: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text(text)
                .font(.pretendard(12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.84))
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(.black.opacity(0.34), in: Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
    }
}

struct ArtworkView: View {
    @EnvironmentObject private var model: AppViewModel
    var size: CGFloat = 88
    var cornerRadius: CGFloat = 8
    var onTap: (() -> Void)? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color(red: 34.0 / 255.0, green: 35.0 / 255.0, blue: 40.0 / 255.0))
            if let url = model.currentTrack?.artworkURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.clear
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .artworkSwipeActions(size: size, onTap: onTap)
    }
}

private struct ArtworkSwipeActionsModifier: ViewModifier {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    @State private var swipeOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var suppressTapUntil = Date.distantPast

    var size: CGFloat
    var onTap: (() -> Void)?

    func body(content: Content) -> some View {
        let maxOffset = max(26, size * 0.12)
        content
            .offset(x: swipeOffset)
            .rotationEffect(.degrees(Double(swipeOffset / max(maxOffset, 1)) * 1.6))
            .animation(.easeOut(duration: 0.15), value: swipeOffset)
            .onLongPressGesture {
                suppressTapUntil = Date().addingTimeInterval(0.45)
                performLongPressHaptic()
                model.showTmiForCurrentTrack(bypassCache: false)
            }
            .onTapGesture {
                guard Date() >= suppressTapUntil else { return }
                onTap?()
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 16)
                    .onChanged { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard isDragging || (abs(dx) > 16 && abs(dx) > abs(dy) * 1.15) else {
                            return
                        }
                        isDragging = true
                        swipeOffset = max(-maxOffset, min(maxOffset, dx * 0.16))
                    }
                    .onEnded { value in
                        defer { settle() }
                        guard isDragging else { return }
                        let dx = value.translation.width
                        let predictedDx = value.predictedEndTranslation.width
                        let quickSwipe = abs(predictedDx - dx) > max(70, size * 0.22)
                        let shouldSwitch = abs(dx) > size * 0.18 || quickSwipe
                        guard shouldSwitch else { return }
                        if dx < 0 {
                            model.skipToNextTrack()
                        } else {
                            model.skipToPreviousTrack()
                        }
                    }
            )
            .accessibilityHint(onTap == nil
                ? settings.t("vinyl.tmi_hint")
                : settings.t("vinyl.open_hint") + ". " + settings.t("vinyl.tmi_hint"))
    }

    private func settle() {
        isDragging = false
        swipeOffset = 0
    }

    private func performLongPressHaptic() {
#if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
#endif
    }
}

private extension View {
    func artworkSwipeActions(size: CGFloat, onTap: (() -> Void)? = nil) -> some View {
        modifier(ArtworkSwipeActionsModifier(size: size, onTap: onTap))
    }
}

private struct ResearchTokenConsentSheetView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    private let amber = Color(red: 251.0 / 255.0, green: 191.0 / 255.0, blue: 36.0 / 255.0)

    var body: some View {
        GeometryReader { geometry in
            let cardWidth = min(440, max(300, geometry.size.width - 32))
            let cardHeight = min(420, max(240, geometry.size.height - 32))
            ZStack {
                Color.black.opacity(0.56)
                    .ignoresSafeArea()
                    .onTapGesture { dismissDialog() }

                ScrollView {
                    VStack(spacing: 0) {
                        ZStack {
                            Circle()
                                .fill(amber.opacity(0.16))
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(amber)
                        }
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)

                        Text(settings.t("tmi.title"))
                            .font(.pretendard(11, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(amber)
                            .padding(.top, 14)

                        Text(settings.t("research.token_consent_title"))
                            .font(.pretendard(20, weight: .bold))
                            .foregroundStyle(Color(red: 248.0 / 255.0, green: 250.0 / 255.0, blue: 252.0 / 255.0))
                            .multilineTextAlignment(.center)
                            .padding(.top, 7)

                        Text(settings.t("research.token_consent_body"))
                            .font(.pretendard(14.5))
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                            .padding(.top, 12)

                        HStack(alignment: .top, spacing: 9) {
                            Circle()
                                .fill(amber)
                                .frame(width: 6, height: 6)
                                .padding(.top, 6)
                                .accessibilityHidden(true)
                            Text(settings.t("research.token_consent_note"))
                                .font(.pretendard(12.5))
                                .foregroundStyle(Color(red: 254.0 / 255.0, green: 243.0 / 255.0, blue: 199.0 / 255.0))
                                .lineSpacing(2.5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .background(amber.opacity(0.11), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(amber.opacity(0.24), lineWidth: 1)
                        }
                        .padding(.top, 16)

                        HStack(spacing: 8) {
                            Button(settings.t("button.cancel")) {
                                dismissDialog()
                            }
                            .font(.pretendard(13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 92)
                            .frame(minHeight: 48)
                            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                            Button {
                                withAnimation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.16)) {
                                    model.acceptResearchTokenConsent()
                                }
                            } label: {
                                Text(settings.t("research.token_consent_agree"))
                                    .font(.pretendard(13, weight: .semibold))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, minHeight: 48)
                            }
                            .foregroundStyle(Color(red: 30.0 / 255.0, green: 24.0 / 255.0, blue: 10.0 / 255.0))
                            .background(amber, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .padding(.top, 18)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 22)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: cardWidth, height: cardHeight)
                .background(
                    Color(red: 18.0 / 255.0, green: 20.0 / 255.0, blue: 30.0 / 255.0),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(amber.opacity(0.18), lineWidth: 1)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func dismissDialog() {
        withAnimation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.16)) {
            model.dismissResearchTokenConsent()
        }
    }
}

private struct TmiSheetView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    @State private var researchTextScale: CGFloat = 1

    private var track: TrackSnapshot? {
        model.tmiTrack ?? model.currentTrack
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.52)
                    .ignoresSafeArea()
                    .onTapGesture { dismissDialog() }

                VStack(alignment: .leading, spacing: 0) {
                    header

                    Text(settings.t("tmi.disclaimer"))
                        .font(.pretendard(11.5))
                        .foregroundStyle(.white.opacity(0.60))
                        .lineSpacing(2)
                        .padding(.top, 10)

                    ScrollViewReader { proxy in
                        VStack(alignment: .leading, spacing: 10) {
                            if let research = model.tmiInfo?.research {
                                researchNavigation(research, proxy: proxy)
                            }
                            ScrollView {
                                content
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                    }
                    .frame(height: tmiBodyHeight(geometry.size.height))
                    .padding(.top, 14)

                    HStack(spacing: 8) {
                        Button(settings.t("tmi.regenerate")) {
                            model.regenerateTmiForCurrentTrack()
                        }
                        .androidDebugButton()
                        .disabled(model.tmiLoading)
                        .opacity(model.tmiLoading ? 0.52 : 1)

                        Button(settings.t("button.close")) {
                            dismissDialog()
                        }
                        .androidDebugButton()
                    }
                    .padding(.top, 14)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .foregroundStyle(.white)
                .frame(maxWidth: min(430, max(300, geometry.size.width - 32)))
                .background(
                    Color(red: 18.0 / 255.0, green: 20.0 / 255.0, blue: 30.0 / 255.0),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
                .padding(.horizontal, 16)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func tmiBodyHeight(_ screenHeight: CGFloat) -> CGFloat {
        min(460, max(220, screenHeight * 0.54))
    }

    private func dismissDialog() {
        withAnimation(.easeOut(duration: 0.16)) {
            model.tmiPresented = false
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.10))
                if let url = track?.artworkURL {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Image(systemName: "music.note")
                            .foregroundStyle(.white.opacity(0.58))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Image(systemName: "music.note")
                        .foregroundStyle(.white.opacity(0.58))
                }
            }
            .frame(width: 56, height: 56)
            .clipped()

            VStack(alignment: .leading, spacing: 0) {
                Text(settings.t("tmi.title"))
                    .font(.pretendard(11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.67))
                    .lineLimit(1)
                Text(track?.title.trimmed.isEmpty == false ? track!.title : settings.t("label.no_current_track"))
                    .font(.pretendard(17, weight: .bold))
                    .lineLimit(1)
                    .padding(.top, 6)
                Text(track?.artist.trimmed.isEmpty == false ? track!.artist : " ")
                    .font(.pretendard(13))
                    .foregroundStyle(.white.opacity(0.80))
                    .lineLimit(1)
                    .padding(.top, 5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                researchTextScale = max(0.8, researchTextScale - 0.1)
            } label: {
                Text("A−").font(.pretendard(12, weight: .semibold)).frame(width: 34, height: 38)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(settings.t("research.font_decrease"))

            Button {
                researchTextScale = min(1.4, researchTextScale + 0.1)
            } label: {
                Text("A+").font(.pretendard(12, weight: .semibold)).frame(width: 34, height: 38)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(settings.t("research.font_increase"))

            Button {
                dismissDialog()
            } label: {
                Text("×")
                    .font(.pretendard(25))
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(settings.t("button.close"))
        }
    }

    @ViewBuilder
    private var content: some View {
        if let info = model.tmiInfo, info.hasContent {
            VStack(alignment: .leading, spacing: 12) {
                if model.tmiWebSearchFallback || info.webSearchFallback == true { webSearchWarning }
                tmiInfoContent(info)
                if model.tmiLoading {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text(settings.t("research.generating_more"))
                            .font(.pretendard(12 * researchTextScale, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.64))
                    }
                    .padding(.top, 4)
                }
            }
        } else if model.tmiLoading {
            VStack(alignment: .leading, spacing: 10) {
                if model.tmiWebSearchFallback { webSearchWarning }
                HStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text(model.tmiLoadingText)
                        .font(.pretendard(13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.86))
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(28.0 / 255.0), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        } else if !model.tmiError.trimmed.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Label(settings.t("tmi.error_fetch"), systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold))
                Text(model.tmiError)
                    .font(.pretendard(13))
                    .foregroundStyle(.white.opacity(0.70))
            }
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        } else {
            Text(settings.t("tmi.no_data"))
                .font(.pretendard(13))
                .foregroundStyle(.white.opacity(0.68))
                .frame(maxWidth: .infinity, minHeight: 140)
        }
    }

    private func tmiInfoContent(_ info: AiLyricsRepository.TmiInfo) -> some View {
        Group {
            if let research = info.research {
                researchContent(research)
            } else {
                legacyTmiContent(info)
            }
        }
    }

    private func legacyTmiContent(_ info: AiLyricsRepository.TmiInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !info.description.isEmpty {
                Text(info.description)
                    .font(.pretendard(14))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            if !info.trivia.isEmpty {
                Text(settings.t("tmi.did_you_know"))
                    .font(.pretendard(14, weight: .bold))
                ForEach(Array(info.trivia.enumerated()), id: \.offset) { _, value in
                    Text(value)
                        .font(.pretendard(13))
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }

            if !info.confidence.isEmpty {
                Text(settings.tf("tmi.confidence_format", info.confidence))
                    .font(.pretendard(11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
            }

            sourceGroup(title: settings.t("tmi.verified_sources"), sources: info.verifiedSources)
            sourceGroup(title: settings.t("tmi.related_sources"), sources: info.relatedSources)
            sourceGroup(title: settings.t("tmi.other_sources"), sources: info.otherSources)
        }
    }

    private var webSearchWarning: some View {
        Text(settings.t("research.web_fallback_warning"))
            .font(.pretendard(11.5 * researchTextScale))
            .foregroundStyle(Color(red: 244 / 255, green: 190 / 255, blue: 92 / 255))
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(Color(red: 244 / 255, green: 190 / 255, blue: 92 / 255).opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
    }

    private func researchContent(_ research: ResearchDocument) -> some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if !research.hook.isEmpty {
                Text(research.hook)
                    .font(.pretendard(13 * researchTextScale, weight: .semibold))
                    .foregroundStyle(Color(red: 82 / 255, green: 220 / 255, blue: 143 / 255))
            }
            if !research.thesis.isEmpty || !research.thesisExpanded.isEmpty {
                researchCard {
                    Text(settings.t("research.thesis"))
                        .font(.pretendard(13 * researchTextScale, weight: .bold))
                    if !research.thesis.isEmpty { researchParagraph(research.thesis) }
                    if !research.thesisExpanded.isEmpty { researchParagraph(research.thesisExpanded) }
                }
                .id("research-thesis")
            }
            ForEach(research.mediaGallery ?? []) { media in
                if let imageURL = URL(string: media.displayImageURL), !media.displayImageURL.isEmpty {
                    researchCard {
                        AsyncImage(url: imageURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            ZStack {
                                Color.white.opacity(0.06)
                                ProgressView().tint(.white)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 170)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        if !media.title.isEmpty { researchParagraph(media.title) }
                        if let destination = URL(string: media.url.isEmpty ? media.sourceURL : media.url) {
                            Link(settings.t("research.source_note"), destination: destination)
                                .font(.pretendard(10.5 * researchTextScale, weight: .semibold))
                                .foregroundStyle(Color(red: 82 / 255, green: 220 / 255, blue: 143 / 255))
                        }
                    }
                }
            }
            ForEach(research.sections) { section in
                researchCard {
                    let sectionTitle = researchSectionTitle(section)
                    Text(sectionTitle)
                        .font(.pretendard(13 * researchTextScale, weight: .bold))
                    if !section.headline.isEmpty && section.headline != sectionTitle {
                        Text(section.headline)
                            .font(.pretendard(16 * researchTextScale, weight: .semibold))
                    }
                    ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        researchParagraph(paragraph)
                    }
                    ForEach(Array(section.details.enumerated()), id: \.offset) { _, detail in
                        researchParagraph("• \(detail)")
                    }
                }
                .id("research-\(section.id)")
            }
            if !research.funFacts.isEmpty {
                Text(settings.t("research.fun_facts"))
                    .font(.pretendard(14 * researchTextScale, weight: .bold))
                    .padding(.top, 6)
                    .id("research-fun_facts")
                ForEach(research.funFacts) { fact in
                    researchCard {
                        if !fact.title.isEmpty { Text(fact.title).font(.pretendard(13 * researchTextScale, weight: .bold)) }
                        if !fact.body.isEmpty { researchParagraph(fact.body) }
                        if !fact.whyInteresting.isEmpty { researchParagraph(fact.whyInteresting) }
                        sourceFootnote(fact.sourceURL)
                    }
                }
            }
            if !research.timeline.isEmpty {
                Text(settings.t("research.timeline"))
                    .font(.pretendard(14 * researchTextScale, weight: .bold))
                    .padding(.top, 6)
                    .id("research-timeline")
                ForEach(research.timeline) { event in
                    researchCard {
                        researchParagraph((event.date.isEmpty ? "" : event.date + "  ") + event.event)
                        if !event.whyItMatters.isEmpty { researchParagraph(event.whyItMatters) }
                        sourceFootnote(event.sourceURL)
                    }
                }
            }
            if !research.pullQuote.isEmpty {
                Text("“\(research.pullQuote)”")
                    .font(.pretendard(17 * researchTextScale, weight: .semibold))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(red: 82 / 255, green: 220 / 255, blue: 143 / 255).opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            }
            if !research.sources.isEmpty {
                Text(settings.t("research.sources"))
                    .font(.pretendard(14 * researchTextScale, weight: .bold))
                    .padding(.top, 6)
                    .id("research-sources")
                ForEach(research.sources) { source in
                    if let url = URL(string: source.url) {
                        Link(source.displayTitle, destination: url)
                            .font(.pretendard(12.5 * researchTextScale, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    private func researchNavigation(_ research: ResearchDocument, proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if !research.thesis.isEmpty || !research.thesisExpanded.isEmpty {
                    researchNavButton(settings.t("research.thesis"), id: "research-thesis", proxy: proxy)
                }
                ForEach(research.sections) { section in
                    researchNavButton(researchSectionTitle(section), id: "research-\(section.id)", proxy: proxy)
                }
                if !research.funFacts.isEmpty {
                    researchNavButton(settings.t("research.fun_facts"), id: "research-fun_facts", proxy: proxy)
                }
                if !research.timeline.isEmpty {
                    researchNavButton(settings.t("research.timeline"), id: "research-timeline", proxy: proxy)
                }
                if !research.sources.isEmpty {
                    researchNavButton(settings.t("research.sources"), id: "research-sources", proxy: proxy)
                }
            }
        }
    }

    private func researchNavButton(_ title: String, id: String, proxy: ScrollViewProxy) -> some View {
        Button(title) {
            withAnimation(.easeInOut(duration: 0.22)) { proxy.scrollTo(id, anchor: .top) }
        }
        .font(.pretendard(10.5, weight: .semibold))
        .buttonStyle(.plain)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.white.opacity(0.08), in: Capsule())
    }

    private func researchSectionTitle(_ section: ResearchDocument.Section) -> String {
        let key = "research.section.\(section.id)"
        let localized = settings.t(key)
        if localized != key { return localized }
        return section.headline.isEmpty ? settings.t("research.section.overview") : section.headline
    }

    private func researchCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
    }

    private func researchParagraph(_ value: String) -> some View {
        Text(value)
            .font(.pretendard(13 * researchTextScale))
            .foregroundStyle(.white.opacity(0.86))
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func sourceFootnote(_ value: String) -> some View {
        if let url = URL(string: value), !value.isEmpty {
            Link(settings.t("research.source_note"), destination: url)
                .font(.pretendard(10.5 * researchTextScale, weight: .semibold))
                .foregroundStyle(Color(red: 82 / 255, green: 220 / 255, blue: 143 / 255))
        }
    }

    @ViewBuilder
    private func sourceGroup(title: String, sources: [AiLyricsRepository.TmiSource]) -> some View {
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.pretendard(14, weight: .bold))
                ForEach(sources, id: \.self) { source in
                    if let url = URL(string: source.url) {
                        Link(destination: url) {
                            HStack(spacing: 8) {
                                Image(systemName: "link")
                                    .font(.caption.weight(.bold))
                                Text(source.displayTitle)
                                    .font(.pretendard(13, weight: .semibold))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right")
                                    .font(.caption.weight(.bold))
                            }
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
            }
        }
    }
}

struct TransportPanel: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    // Subscribed (not read directly) so this view re-renders with the display-rate playback clock driving model.nowPositionMs.
    @EnvironmentObject private var playbackClock: PlaybackClock

    var body: some View {
        let _ = settings.typographyRevision
        let typography = settings.typographySettings()
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.titleText.trimmed.isEmpty ? settings.t("label.no_current_track") : model.titleText)
                        .font(typography.font(slotId: AppSettings.typoMainTitle, baseSize: 21))
                        .lineLimit(1)
                    Text(model.artistText.trimmed.isEmpty ? " " : model.artistText)
                        .font(typography.font(slotId: AppSettings.typoMainArtist, baseSize: 15))
                        .foregroundStyle(.white.opacity(0.70))
                        .lineLimit(1)
                }
                Spacer()
                Text(timeText(model.nowPositionMs) + " / " + timeText(model.durationMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.66))
            }
            PlayerProgressBar(
                positionMs: model.nowPositionMs,
                durationMs: model.durationMs,
                height: 28,
                onSeek: model.seek(toPlaybackPositionMs:)
            )
            HStack(spacing: 14) {
                Button { model.skipToPreviousTrack() } label: {
                    Image(systemName: "backward.end.fill")
                        .frame(width: 40, height: 36)
                }
                Button { model.togglePlayback() } label: {
                    Image(systemName: model.currentTrack?.playing == true ? "pause.fill" : "play.fill")
                        .font(.title3.weight(.bold))
                        .frame(width: 52, height: 40)
                }
                .buttonStyle(.borderedProminent)
                Button { model.skipToNextTrack() } label: {
                    Image(systemName: "forward.end.fill")
                        .frame(width: 40, height: 36)
                }
                Spacer()
                if model.hasBluetoothAudioDevice {
                    Text(model.bluetoothAudioDeviceName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
            }
            .buttonStyle(.bordered)

            VStack(spacing: 6) {
                compactOffsetRow(
                    title: settings.t("lyrics.global_sync.title"),
                    value: model.globalOffsetMs,
                    decrement: { model.adjustGlobalOffsetMs(-100) },
                    increment: { model.adjustGlobalOffsetMs(100) }
                )
                compactOffsetRow(
                    title: settings.t("lyrics.sync.title"),
                    value: model.trackOffsetMs,
                    decrement: { model.adjustTrackOffsetMs(-100) },
                    increment: { model.adjustTrackOffsetMs(100) }
                )
                compactOffsetRow(
                    title: settings.t("lyrics.bluetooth_sync.title"),
                    value: model.bluetoothOffsetMs,
                    enabled: model.hasBluetoothAudioDevice,
                    decrement: { model.adjustBluetoothOffsetMs(-100) },
                    increment: { model.adjustBluetoothOffsetMs(100) }
                )
                compactOffsetRow(
                    title: settings.t("lyrics.video_sync.title"),
                    value: model.videoOffsetMs,
                    decrement: { model.adjustVideoOffsetMs(-100) },
                    increment: { model.adjustVideoOffsetMs(100) }
                )
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .foregroundStyle(.white)
        .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.09)))
    }

    private func compactOffsetRow(
        title: String,
        value: Int,
        enabled: Bool = true,
        decrement: @escaping () -> Void,
        increment: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            OffsetStepper(title: title, value: value, decrement: decrement, increment: increment)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    private func timeText(_ ms: Int64) -> String {
        androidPlayerTime(ms)
    }
}

struct OffsetStepper: View {
    var title: String
    var value: Int
    var decrement: () -> Void
    var increment: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: decrement) { Image(systemName: "minus") }
            Text(formatSignedMs(value))
                .font(.caption.monospacedDigit())
                .frame(width: 64)
            Button(action: increment) { Image(systemName: "plus") }
        }
        .accessibilityLabel(title)
    }

    private func formatSignedMs(_ offsetMs: Int) -> String {
        offsetMs > 0 ? "+\(offsetMs)ms" : "\(offsetMs)ms"
    }
}

struct MainLyricPreviewPanel: View {
    private static let emptyLyricsPreviewVisibleSeconds: TimeInterval = 3

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    // Subscribed (not read directly) so this view re-renders with the display-rate playback clock driving model.nowPositionMs.
    @EnvironmentObject private var playbackClock: PlaybackClock
    var chromeless = false
    var typographyOverride: AppSettings.TypographySettings? = nil
    var showsCulturalAnnotations = false
    var animationsEnabled = true
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var interludeTransition = InterludeTransition()
    @State private var emptyLyricsPreviewKey = ""
    @State private var hiddenEmptyLyricsPreviewKey = ""
    @State private var emptyLyricsPreviewToken = UUID()

    var body: some View {
#if DEBUG && os(iOS)
        let _ = debugProbeCount(.previewBody)
#endif
        let previewItems = AppSettings.normalizePreviewItems(settings.previewItems)
        Group {
            if previewItems != AppSettings.previewItemNone {
                let rows = previewRows(previewItems: previewItems)
                if !rows.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(rows) { row in
                            MainLyricPreviewRowView(
                                row: row,
                                positionMs: model.adjustedPositionMs,
                                continuousPositionMs: model.adjustedContinuousPositionMs,
                                typographyOverride: typographyOverride
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: reservedContentHeight, alignment: .center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(.white)
                    .background(.black.opacity(chromeless ? 0 : 0.22), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(chromeless ? 0 : 0.08)))
                }
            }
        }
        .environment(\.interludeMotionEnabled, smoothInterludeMotion)
        .overlay {
            if let outgoing = interludeTransition.outgoing {
                InterludeExitOverlay(startedAt: outgoing.startedAt) {
                    MainLyricPreviewRowView(row: .interlude(interludeLabel(outgoing.segment.kind)), positionMs: model.adjustedPositionMs, typographyOverride: typographyOverride)
                }
            }
        }
        .task(id: interludeTransition.outgoing) {
            guard let outgoing = interludeTransition.outgoing else { return }
            try? await Task.sleep(for: .seconds(InterludeTransition.exitSeconds))
            guard !Task.isCancelled, interludeTransition.outgoing == outgoing else { return }
            interludeTransition.outgoing = nil
        }
        .onChange(of: previewInterlude, initial: true) { _, next in updateInterlude(next) }
        .onChange(of: model.currentTrackKey) { _, _ in updateInterlude(previewInterlude) }
        .onChange(of: model.lyricsResult.lines) { _, _ in interludeTransition = InterludeTransition(); updateInterlude(previewInterlude) }
        .onChange(of: smoothInterludeMotion) { _, _ in updateInterlude(previewInterlude) }
        .onAppear {
            updateEmptyLyricsPreviewTimer(for: emptyLyricsPreviewCandidateKey)
        }
        .onChange(of: emptyLyricsPreviewCandidateKey) { _, key in
            updateEmptyLyricsPreviewTimer(for: key)
        }
        .onDisappear {
            resetEmptyLyricsPreviewTimer()
            interludeTransition = InterludeTransition()
        }
    }

    private var smoothInterludeMotion: Bool {
        animationsEnabled && settings.syncedLyricsKaraokeAnimationEnabled && !accessibilityReduceMotion
    }

    private var previewInterlude: InterludeTransition.Segment? {
        guard settings.previewItems != AppSettings.previewItemNone,
              LyricsTimelineDisplayBuilder.activeLineIndices(context: model.timelineContext, positionMs: model.adjustedPositionMs).isEmpty,
              let item = LyricsTimelineDisplayBuilder.previewItem(context: model.timelineContext, positionMs: model.adjustedPositionMs,
                  trackDurationMs: model.lyricsDurationMs, autoInstrumentalBreakEnabled: settings.autoInstrumentalBreakEnabled),
              case .interlude(let info) = item else { return nil }
        return .init(id: item.id, startMs: info.startTimeMs, endMs: info.endTimeMs, kind: info.kind, automatic: info.automatic)
    }

    private func updateInterlude(_ next: InterludeTransition.Segment?) {
        interludeTransition.update(next: next, positionMs: model.adjustedPositionMs, now: Date().timeIntervalSinceReferenceDate,
                                  scope: model.currentTrackKey, enabled: smoothInterludeMotion && settings.previewItems != AppSettings.previewItemNone)
    }

    private var reservedContentHeight: CGFloat {
        let typography = typographyOverride ?? settings.typographySettings()
        let primarySize = typography.scaledSize(slotId: AppSettings.typoMainPreviewOriginal, baseSize: 17)
        let pronunciationSize = typography.scaledSize(slotId: AppSettings.typoMainPreviewPronunciation, baseSize: 14.5)
        let translationSize = typography.scaledSize(slotId: AppSettings.typoMainPreviewTranslation, baseSize: 14.5)
        let primaryRow = primarySize * 1.22 + max(7, primarySize * 0.46 * 0.82)
        let secondaryRow = max(pronunciationSize, translationSize) * 1.18
        let culturalRow = showsCulturalAnnotations && settings.culturalAnnotationsEnabled
            ? 4 + CGFloat(AppSettings.clampCulturalFontSize(settings.culturalAnnotationsVinylFontSize)) * 1.4
            : 0
        return primaryRow + 2 * (4 + secondaryRow) + culturalRow
    }

    private func previewRows(previewItems: Int) -> [MainLyricPreviewRow] {
        if model.lyricsResult.lines.isEmpty {
            return emptyPreviewRows()
        }
        let activeIndices = LyricsTimelineDisplayBuilder.activeLineIndices(
            context: model.timelineContext,
            positionMs: model.adjustedPositionMs
        )
        if !activeIndices.isEmpty {
            return activeIndices.flatMap { index in
                previewRows(for: model.lyricsResult.lines[index], lineIndex: index, previewItems: previewItems)
            }
        }
        guard let entry = LyricsTimelineDisplayBuilder.previewItem(
            context: model.timelineContext,
            positionMs: model.adjustedPositionMs,
            trackDurationMs: model.lyricsDurationMs,
            autoInstrumentalBreakEnabled: settings.autoInstrumentalBreakEnabled
        ) else {
            return [MainLyricPreviewRow(text: settings.t("status.lyrics_waiting"), primary: true)]
        }

        switch entry {
        case .interlude(let info):
            var row = MainLyricPreviewRow.interlude(interludeLabel(info.kind))
            row.lineStartTimeMs = info.startTimeMs
            row.lineEndTimeMs = info.endTimeMs
            return [row]
        case .line(let lineIndex, let line, _):
            return previewRows(for: line, lineIndex: lineIndex, previewItems: previewItems)
        }
    }

    private func emptyPreviewRows() -> [MainLyricPreviewRow] {
        let detail = model.lyricsResult.detail.trimmed
        if model.status == .loading || model.showsLyricsLoadingPlaceholder {
            return [.loading(model.lyricsLoadingText)]
        }
        guard settings.lyricsNotFoundNoticeEnabled else { return [] }
        if hiddenEmptyLyricsPreviewKey == buildEmptyLyricsPreviewKey(detail: detail) {
            return []
        }
        return [MainLyricPreviewRow(text: detail.isEmpty ? settings.t("status.lyrics_waiting") : detail, primary: true)]
    }

    private func previewRows(for line: LyricsLine, lineIndex: Int, previewItems: Int) -> [MainLyricPreviewRow] {
        var rows: [MainLyricPreviewRow] = []
        let original = originalPreviewText(line)
        let culturalAnnotations = showsCulturalAnnotations && settings.culturalAnnotationsEnabled
            ? model.culturalAnnotations(
                forLine: lineIndex,
                text: original.text
            )
            : []
        if AppSettings.previewItemEnabled(previewItems, AppSettings.previewItemOriginal) {
            addPreviewRow(&rows, text: original.text, rubyText: original.rubyText, syllables: original.syllables, kind: original.kind, speaker: line.speaker, slotId: AppSettings.typoMainPreviewOriginal)
        }
        if AppSettings.previewItemEnabled(previewItems, AppSettings.previewItemPronunciation) {
            addSupplementPreviewRow(
                &rows,
                text: line.pronunciationText,
                generatingText: model.aiPronunciationLoadingText,
                fallback: original,
                speaker: line.speaker,
                generating: model.lyricsSupplementPronunciationLoading,
                slotId: AppSettings.typoMainPreviewPronunciation
            )
        }
        if AppSettings.previewItemEnabled(previewItems, AppSettings.previewItemTranslation) {
            addSupplementPreviewRow(
                &rows,
                text: line.translationText,
                generatingText: model.aiTranslationLoadingText,
                fallback: original,
                speaker: line.speaker,
                generating: model.lyricsSupplementTranslationLoading,
                slotId: AppSettings.typoMainPreviewTranslation
            )
        }
        if rows.isEmpty {
            addPreviewRow(&rows, text: original.text, rubyText: original.rubyText, syllables: original.syllables, kind: original.kind, speaker: line.speaker, slotId: AppSettings.typoMainPreviewOriginal)
        }
        if !culturalAnnotations.isEmpty,
           let originalIndex = rows.firstIndex(where: { $0.slotId == AppSettings.typoMainPreviewOriginal }) {
            rows[originalIndex].text = CulturalAnnotation.annotateText(
                rows[originalIndex].text,
                annotations: culturalAnnotations
            )
            rows[originalIndex].syllables = CulturalAnnotation.annotateSyllables(
                text: original.text,
                syllables: rows[originalIndex].syllables,
                annotations: culturalAnnotations
            )
            rows[originalIndex].rubyText = ""
        }
        for (index, annotation) in culturalAnnotations.enumerated() {
            rows.append(MainLyricPreviewRow(
                text: "\(index + 1). \(annotation.note)",
                primary: false,
                type: .cultural
            ))
        }
        return rows.map { row in
            var syncedRow = row
            syncedRow.sourceLineIndex = lineIndex
            syncedRow.lineStartTimeMs = line.startTimeMs
            syncedRow.lineEndTimeMs = line.endTimeMs
            return syncedRow
        }
    }

    private func addSupplementPreviewRow(
        _ rows: inout [MainLyricPreviewRow],
        text: String,
        generatingText: String,
        fallback: MainLyricPreviewText,
        speaker: String,
        generating: Bool,
        slotId: String
    ) {
        var value = text.trimmed
        var rubyText = ""
        var syllables: [LyricsLine.Syllable] = []
        var kind = "vocal"
        if value.isEmpty {
            if generating {
                value = generatingText
            } else {
                value = fallback.text
                rubyText = fallback.rubyText
                syllables = fallback.syllables
                kind = fallback.kind
            }
        }
        if samePreviewTextAlreadyShown(rows, value) {
            return
        }
        addPreviewRow(&rows, text: value, rubyText: rubyText, syllables: syllables, kind: kind, speaker: speaker, slotId: slotId)
    }

    private func addPreviewRow(
        _ rows: inout [MainLyricPreviewRow],
        text: String,
        rubyText: String,
        syllables: [LyricsLine.Syllable],
        kind: String,
        speaker: String,
        slotId: String
    ) {
        let value = text.trimmed
        guard !value.isEmpty else { return }
        rows.append(MainLyricPreviewRow(
            text: value,
            rubyText: rubyText,
            primary: rows.isEmpty,
            syllables: syllables,
            kind: kind,
            speaker: speaker,
            slotId: slotId
        ))
    }

    private func samePreviewTextAlreadyShown(_ rows: [MainLyricPreviewRow], _ text: String) -> Bool {
        let value = text.trimmed
        return rows.contains { $0.text == value }
    }

    private func originalPreviewText(_ line: LyricsLine) -> MainLyricPreviewText {
        if !hasMultiplePreviewVocalParts(line), !line.text.trimmed.isEmpty {
            let text = line.text.trimmed
            return MainLyricPreviewText(
                text: text,
                rubyText: previewLineRubyText(line),
                syllables: previewKaraokeSyllables(for: text, syllables: line.syllables),
                kind: line.kind
            )
        }

        var textParts: [String] = []
        var rubyParts: [String] = []
        var syllables: [LyricsLine.Syllable] = []
        var syllablesUsable = true
        for part in line.vocalParts {
            let partText = part.text.trimmed
            guard !partText.isEmpty else { continue }
            if !textParts.isEmpty {
                syllables.append(spaceSyllable(previous: syllables, nextPart: part))
            }
            textParts.append(partText)
            rubyParts.append(previewPartRubyText(part, fallbackText: partText))
            let partSyllables = previewKaraokeSyllables(for: partText, syllables: part.syllables)
            if partSyllables.isEmpty {
                syllablesUsable = false
            }
            syllables.append(contentsOf: partSyllables)
        }
        if textParts.isEmpty {
            return MainLyricPreviewText(text: "♪", rubyText: "", syllables: [], kind: line.kind)
        }
        return MainLyricPreviewText(
            text: textParts.joined(separator: " "),
            rubyText: rubyParts.joined(separator: " "),
            syllables: syllablesUsable ? syllables : [],
            kind: line.kind
        )
    }

    private func previewLineRubyText(_ line: LyricsLine) -> String {
        settings.japaneseFuriganaEnabled ? line.furiganaText.trimmed : ""
    }

    private func previewPartRubyText(_ part: LyricsLine.VocalPart, fallbackText: String) -> String {
        guard settings.japaneseFuriganaEnabled else { return fallbackText }
        let rubyText = part.furiganaText.trimmed
        return rubyText.isEmpty ? fallbackText : rubyText
    }

    private func previewKaraokeSyllables(for text: String, syllables: [LyricsLine.Syllable]) -> [LyricsLine.Syllable] {
        let value = text.trimmed
        guard !value.isEmpty, !syllables.isEmpty else { return [] }
        var usable: [LyricsLine.Syllable] = []
        usable.reserveCapacity(syllables.count)
        var combined = ""
        combined.reserveCapacity(text.utf8.count)
        for syllable in syllables where !syllable.text.isEmpty {
            usable.append(syllable)
            combined.append(contentsOf: syllable.text)
        }
        guard combined.trimmed == value else { return [] }
        return trimPreviewSyllables(usable)
    }

    private func trimPreviewSyllables(_ syllables: [LyricsLine.Syllable]) -> [LyricsLine.Syllable] {
        var start = 0
        var end = syllables.count - 1
        while start <= end, isWhitespaceSyllable(syllables[start]) {
            start += 1
        }
        while end >= start, isWhitespaceSyllable(syllables[end]) {
            end -= 1
        }
        guard start <= end else { return [] }
        return Array(syllables[start...end])
    }

    private func isWhitespaceSyllable(_ syllable: LyricsLine.Syllable) -> Bool {
        syllable.text.isEmpty || syllable.text.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private func spaceSyllable(previous: [LyricsLine.Syllable], nextPart: LyricsLine.VocalPart) -> LyricsLine.Syllable {
        let start = previous.last?.endTimeMs ?? nextPart.startTimeMs
        let end = max(start, nextPart.startTimeMs)
        return LyricsLine.Syllable(text: " ", startTimeMs: start, endTimeMs: end)
    }

    private func hasMultiplePreviewVocalParts(_ line: LyricsLine) -> Bool {
        var count = 0
        for part in line.vocalParts where !part.text.trimmed.isEmpty {
            count += 1
            if count > 1 {
                return true
            }
        }
        return false
    }

    private func interludeLabel(_ kind: String) -> String {
        guard settings.interludeLabelsEnabled else { return "" }
        switch kind {
        case "prelude": return settings.t("interlude.prelude")
        case "postlude": return settings.t("interlude.postlude")
        default: return settings.t("interlude.break")
        }
    }

    private var emptyLyricsPreviewCandidateKey: String {
        let previewItems = AppSettings.normalizePreviewItems(settings.previewItems)
        guard previewItems != AppSettings.previewItemNone,
              model.lyricsResult.lines.isEmpty else {
            return ""
        }
        let detail = model.lyricsResult.detail.trimmed
        guard model.status != .loading, !model.showsLyricsLoadingPlaceholder else {
            return ""
        }
        return buildEmptyLyricsPreviewKey(detail: detail)
    }

    private func buildEmptyLyricsPreviewKey(detail: String) -> String {
        "\(model.currentTrackKey)\n\(detail.trimmed)"
    }

    private func updateEmptyLyricsPreviewTimer(for key: String) {
        guard !key.isEmpty else {
            resetEmptyLyricsPreviewTimer()
            return
        }
        guard key != emptyLyricsPreviewKey else { return }
        emptyLyricsPreviewKey = key
        hiddenEmptyLyricsPreviewKey = ""
        scheduleEmptyLyricsPreviewClear(for: key)
    }

    private func scheduleEmptyLyricsPreviewClear(for key: String) {
        let token = UUID()
        emptyLyricsPreviewToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.emptyLyricsPreviewVisibleSeconds) {
            guard emptyLyricsPreviewToken == token,
                  emptyLyricsPreviewCandidateKey == key else {
                return
            }
            hiddenEmptyLyricsPreviewKey = key
        }
    }

    private func resetEmptyLyricsPreviewTimer() {
        if emptyLyricsPreviewKey.isEmpty,
           hiddenEmptyLyricsPreviewKey.isEmpty {
            return
        }
        emptyLyricsPreviewToken = UUID()
        emptyLyricsPreviewKey = ""
        hiddenEmptyLyricsPreviewKey = ""
    }
}

private struct MainLyricPreviewText {
    var text: String
    var rubyText: String
    var syllables: [LyricsLine.Syllable]
    var kind: String
}

private enum MainLyricPreviewRowType: String {
    case text
    case interlude
    case loading
    case cultural
}

private struct MainLyricPreviewRow: Identifiable {
    var text: String
    var rubyText: String = ""
    var primary: Bool
    var syllables: [LyricsLine.Syllable] = []
    var kind: String = "vocal"
    var speaker: String = ""
    var type: MainLyricPreviewRowType = .text
    var slotId: String = AppSettings.typoMainPreviewOriginal
    var lineStartTimeMs: Int64 = 0
    var lineEndTimeMs: Int64 = 0
    var sourceLineIndex: Int = -1

    var id: String {
        "\(sourceLineIndex)-\(type.rawValue)-\(slotId)-\(primary)-\(text)-\(rubyText)-\(syllables.count)"
    }

    var effectRowSeed: Int {
        var seed: Int32 = 17
        for value in [text, rubyText, kind.trimmed.lowercased()] {
            seed = seed &* 31 &+ javaStringHash(value)
        }
        return seed == Int32.min ? Int(seed) : Int(Swift.abs(seed))
    }

    static func interlude(_ text: String) -> MainLyricPreviewRow {
        MainLyricPreviewRow(text: text, primary: true, type: .interlude)
    }

    static func loading(_ text: String) -> MainLyricPreviewRow {
        MainLyricPreviewRow(text: text, primary: true, type: .loading)
    }
}

private func javaStringHash(_ value: String) -> Int32 {
    value.utf16.reduce(into: Int32(0)) { hash, codeUnit in
        hash = hash &* 31 &+ Int32(codeUnit)
    }
}

private struct MainLyricPreviewContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MainLyricPreviewSlideLayout: Layout {
    private static let startHold: CGFloat = 0.30
    private static let moveDuration: CGFloat = 0.40
    private static let edgeFadeWidth: CGFloat = 28

    var lineProgress: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let contentSize = subview.sizeThatFits(.unspecified)
        let proposedWidth = proposal.width ?? contentSize.width
        let width = proposedWidth.isFinite ? max(0, proposedWidth) : contentSize.width
        return CGSize(width: width, height: contentSize.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        let contentSize = subview.sizeThatFits(.unspecified)
        let x: CGFloat
        if contentSize.width <= bounds.width {
            x = bounds.minX + (bounds.width - contentSize.width) * 0.5
        } else {
            let fadeWidth = min(Self.edgeFadeWidth, bounds.width * 0.28)
            let startX = bounds.minX + fadeWidth
            let endX = bounds.maxX - fadeWidth - contentSize.width
            x = startX + (endX - startX) * slideProgress
        }
        subview.place(
            at: CGPoint(x: x, y: bounds.midY - contentSize.height * 0.5),
            anchor: .topLeading,
            proposal: ProposedViewSize(contentSize)
        )
    }

    private var slideProgress: CGFloat {
        let progress = min(1, max(0, lineProgress))
        if progress <= Self.startHold { return 0 }
        if progress >= Self.startHold + Self.moveDuration { return 1 }
        return (progress - Self.startHold) / Self.moveDuration
    }
}

private struct MainLyricPreviewRowView: View {
    @EnvironmentObject private var settings: AppSettings
    var row: MainLyricPreviewRow
    var positionMs: Int64
    var continuousPositionMs: Double? = nil
    var typographyOverride: AppSettings.TypographySettings? = nil
    @State private var contentWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.interludeMotionEnabled) private var interludeMotionEnabled

    var body: some View {
        switch row.type {
        case .interlude:
            HStack(spacing: 10) {
                MainLyricPreviewInterludeIcon()
                if !row.text.trimmed.isEmpty {
                    Text(row.text)
                        .font(typography.font(slotId: row.slotId, baseSize: 17))
                        .foregroundStyle(.white.opacity(0.88))
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .opacity(InterludeTransition.entryOpacity(positionMs: continuousPositionMs ?? Double(positionMs), startMs: row.lineStartTimeMs,
                                                      enabled: interludeMotionEnabled && !accessibilityReduceMotion))
        case .loading:
            MainLyricPreviewLoadingSkeleton()
            .frame(maxWidth: .infinity, alignment: .center)
        case .cultural:
            Text(row.text)
                .font(vinylCulturalAnnotationFont)
                .foregroundStyle(.white.opacity(Double(settings.culturalAnnotationsVinylOpacity) / 100))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
        case .text:
            MainLyricPreviewSlideLayout(lineProgress: lineProgress) {
                previewTextView
                    .font(typography.font(slotId: row.slotId, baseSize: row.primary ? 17 : 14.5))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: MainLyricPreviewContentWidthKey.self,
                                value: geometry.size.width
                            )
                        }
                    }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .clipped()
            .mask(slideMask)
            .onPreferenceChange(MainLyricPreviewContentWidthKey.self) { width in
                contentWidth = width
            }
        }
    }

    private var typography: AppSettings.TypographySettings {
        _ = settings.typographyRevision
        return typographyOverride ?? settings.typographySettings()
    }

    private var vinylCulturalAnnotationFont: Font {
        let size = CGFloat(AppSettings.clampCulturalFontSize(settings.culturalAnnotationsVinylFontSize))
        let weight: Font.Weight
        switch AppSettings.clampCulturalFontWeight(settings.culturalAnnotationsVinylFontWeight) {
        case 100: weight = .ultraLight
        case 200: weight = .thin
        case 300: weight = .light
        case 400: weight = .regular
        case 500: weight = .medium
        case 600: weight = .semibold
        case 700: weight = .bold
        case 800: weight = .heavy
        default: weight = .black
        }
        switch AppSettings.normalizeCulturalFontFamily(settings.culturalAnnotationsVinylFontFamily) {
        case "system": return .system(size: size, weight: weight)
        case "serif": return .system(size: size, weight: weight, design: .serif)
        case "monospace": return .system(size: size, weight: weight, design: .monospaced)
        default: return .custom("Pretendard", size: size).weight(weight)
        }
    }

    private var lineProgress: CGFloat {
        let duration = row.lineEndTimeMs - row.lineStartTimeMs
        guard duration > 0 else { return 0 }
        return min(1, max(0, CGFloat(positionMs - row.lineStartTimeMs) / CGFloat(duration)))
    }

    private var slideMask: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            if contentWidth > width + 0.5 {
                let fadeStop = min(28, width * 0.28) / width
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white, location: fadeStop),
                        .init(color: .white, location: max(fadeStop, 1 - fadeStop)),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            } else {
                Rectangle().fill(.white)
            }
        }
    }

    @ViewBuilder
    private var previewTextView: some View {
        if shouldRenderTimedKaraoke || shouldRenderRuby {
            SyllableKaraokeText(
                text: row.text,
                rubyText: settings.japaneseFuriganaEnabled ? row.rubyText : "",
                syllables: shouldRenderTimedKaraoke ? row.syllables : [],
                displayGranularity: settings.karaokeDisplayGranularity,
                startTimeMs: row.syllables.first?.startTimeMs ?? 0,
                endTimeMs: row.syllables.last?.endTimeMs ?? 0,
                positionMs: positionMs,
                continuousPositionMs: continuousPositionMs,
                active: true,
                activeColor: LyricSpeakerPalette.activeColor(speaker: row.speaker, settings: speakerColors),
                alignment: .center,
                kind: row.kind,
                speakerColors: speakerColors,
                useCreatorSpeakerColors: settings.useSyncCreatorSpeakerColors,
                bounceEnabled: settings.karaokeBounceEffectEnabled,
                bounceTextSize: typography.scaledSize(slotId: row.slotId, baseSize: row.primary ? 17 : 14.5),
                effectRowSeed: row.effectRowSeed,
                singleLine: true
            )
        } else {
            Text(row.text)
                .foregroundStyle(row.primary ? .white.opacity(0.96) : .white.opacity(0.78))
                .multilineTextAlignment(.center)
        }
    }

    private var shouldRenderTimedKaraoke: Bool {
        !settings.karaokeDataAsLineSynced && row.syllables.contains { $0.endTimeMs > $0.startTimeMs }
    }

    private var shouldRenderRuby: Bool {
        settings.japaneseFuriganaEnabled && row.rubyText.contains("<ruby>")
    }

    private var speakerColors: AppSettings.SpeakerColorSettings {
        _ = settings.speakerColorRevision
        return settings.speakerColorSettings()
    }
}

private struct MainLyricPreviewInterludeIcon: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.interludeMotionEnabled) private var interludeMotionEnabled
    @Environment(\.coveredPageDecorationsPaused) private var coveredPageDecorationsPaused
    @Environment(\.playbackAdvancing) private var playbackAdvancing

    var body: some View {
        // Display rate while playback runs; the previous 1/60 s cadence while it is paused.
        TimelineView(.animation(
            minimumInterval: playbackAdvancing ? nil : 1.0 / 60.0,
            paused: coveredPageDecorationsPaused || accessibilityReduceMotion || !interludeMotionEnabled || !playbackAdvancing
        )) { timeline in
#if DEBUG && os(iOS)
            let _ = debugProbeTimeline(.previewInterludeTick, timeline.date)
#endif
            let nowMs = timeline.date.timeIntervalSinceReferenceDate * 1_000
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.62))
                        .frame(width: 4, height: accessibilityReduceMotion || !interludeMotionEnabled
                            ? 11 : interludeBarHeight(index: index, nowMs: nowMs, minimum: 7, maximum: 19))
                }
            }
        }
        .frame(height: 22, alignment: .center)
    }
}

private struct MainLyricPreviewLoadingSkeleton: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.coveredPageDecorationsPaused) private var coveredPageDecorationsPaused
    @Environment(\.playbackAdvancing) private var playbackAdvancing

    var body: some View {
        // Display rate while playback runs; the previous 1/30 s cadence while it is paused.
        TimelineView(.animation(
            minimumInterval: playbackAdvancing ? nil : 1.0 / 30.0,
            paused: coveredPageDecorationsPaused
        )) { timeline in
#if DEBUG && os(iOS)
            let _ = debugProbeTimeline(.previewSkeletonTick, timeline.date)
#endif
            let nowMs = timeline.date.timeIntervalSinceReferenceDate * 1_000
            VStack(spacing: 6.6) {
                ForEach(Array([0.54, 0.78, 0.42].enumerated()), id: \.offset) { index, widthFactor in
                    KaraokeLoadingRail(
                        widthFactor: widthFactor,
                        height: 4.2,
                        baseOpacity: index == 1 ? 76.0 / 255.0 : 46.0 / 255.0,
                        shimmerOpacity: 0.72,
                        phase: shimmerPhase(nowMs: nowMs, index: index, periodMs: 1_280, staggerMs: 145)
                    )
                }
            }
            .frame(width: 210)
        }
        .frame(height: 26)
        .accessibilityLabel(settings.t("status.lyrics_loading"))
    }
}

private struct LyricsLoadingSkeleton: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.playbackAdvancing) private var playbackAdvancing
    private let widths: [CGFloat] = [0.62, 0.86, 0.74, 0.92, 0.56]

    var body: some View {
        // Display rate while playback runs; the previous 1/30 s cadence while it is paused.
        TimelineView(.animation(minimumInterval: playbackAdvancing ? nil : 1.0 / 30.0)) { timeline in
#if DEBUG && os(iOS)
            let _ = debugProbeTimeline(.lyricsSkeletonTick, timeline.date)
#endif
            let nowMs = timeline.date.timeIntervalSinceReferenceDate * 1_000
            VStack(alignment: .leading, spacing: 20) {
                ForEach(Array(widths.enumerated()), id: \.offset) { index, widthFactor in
                    let active = index == 2
                    KaraokeLoadingRail(
                        widthFactor: widthFactor,
                        height: active ? 25 : 16,
                        baseOpacity: active ? 82.0 / 255.0 : 36.0 / 255.0,
                        shimmerOpacity: active ? 118.0 / 255.0 : 78.0 / 255.0,
                        phase: shimmerPhase(nowMs: nowMs, index: index, periodMs: 1_350, staggerMs: 130),
                        centered: false
                    )
                    .frame(height: active ? 25 : 16)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(settings.t("status.lyrics_loading"))
    }
}

private struct KaraokeLoadingRail: View {
    var widthFactor: CGFloat
    var height: CGFloat
    var baseOpacity: Double
    var shimmerOpacity: Double
    var phase: CGFloat
    var centered = true

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = max(1, geometry.size.width)
            let rowWidth = max(42, availableWidth * widthFactor)
            let shimmerWidth = max(28, rowWidth * 0.36)
            let shimmerX = -shimmerWidth + (rowWidth + shimmerWidth * 2) * phase
            let rowX = centered ? max(0, (availableWidth - rowWidth) * 0.5) : 0
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height * 0.45)
                    .fill(.white.opacity(baseOpacity))
                LinearGradient(
                    colors: [.clear, .white.opacity(shimmerOpacity), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: shimmerWidth)
                .offset(x: shimmerX)
            }
            .frame(width: rowWidth, height: height)
            .clipShape(RoundedRectangle(cornerRadius: height * 0.45))
            .offset(x: rowX)
        }
    }
}

private func shimmerPhase(nowMs: Double, index: Int, periodMs: Double, staggerMs: Double) -> CGFloat {
    CGFloat((nowMs + Double(index) * staggerMs).truncatingRemainder(dividingBy: periodMs) / periodMs)
}

private func interludeBarHeight(index: Int, nowMs: Double, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
    let phase = positiveSine(nowMs + Double(index) * 145, periodMs: 980)
    return minimum + (maximum - minimum) * (0.18 + phase * 0.82)
}

private func positiveSine(_ timeMs: Double, periodMs: Double) -> CGFloat {
    CGFloat((sin(timeMs.truncatingRemainder(dividingBy: periodMs) / periodMs * .pi * 2) + 1) * 0.5)
}

private struct LyricsMetaStrip: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    var inline = false
    var onOpenMenu: () -> Void = {}

    @ViewBuilder
    var body: some View {
        if inline {
            if hasContributors {
                LyricsContributorCredit(contributors: model.lyricsResult.contributors)
                    .contentShape(Rectangle())
                    .onLongPressGesture {
                        onOpenMenu()
                    }
            }
        } else if hasContent {
            VStack(alignment: .leading, spacing: 5) {
                if !sourceStatusText.isEmpty {
                    Text(sourceStatusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.64))
                        .lineLimit(2)
                }
                if hasContributors {
                    LyricsContributorCredit(contributors: model.lyricsResult.contributors)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.05)))
            .contentShape(Rectangle())
            .onLongPressGesture {
                onOpenMenu()
            }
        }
    }

    private var hasContent: Bool {
        !sourceStatusText.isEmpty || hasContributors
    }

    private var sourceStatusText: String {
        let provider = model.lyricsResult.providerLabel.trimmed
        let detail = model.lyricsResult.detail.trimmed
        if provider.isEmpty {
            return model.status == .idle && model.currentTrack == nil && model.lyricsResult.lines.isEmpty ? "" : detail
        }
        return detail.isEmpty ? provider : "\(provider) / \(detail)"
    }

    private var hasContributors: Bool {
        !model.lyricsResult.contributors.isEmpty
    }
}

private struct LyricsContributorCredit: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    var contributors: [LyricsResult.SyncContributor]
    var subdued = false
    var interactive = true

    var body: some View {
        let parts = syncCreditFormatParts
        HStack(spacing: 0) {
            Text(parts.prefix)
                .foregroundStyle(.white.opacity(labelOpacity))
            ForEach(Array(visibleContributors.enumerated()), id: \.offset) { index, contributor in
                if index > 0 {
                    Text(", ")
                        .foregroundStyle(.white.opacity(labelOpacity))
                }
                contributorNameView(contributor)
            }
            if remainingContributorCount > 0 {
                Text(" +\(remainingContributorCount)")
                    .foregroundStyle(.white.opacity(nameOpacity))
            }
            Text(parts.suffix)
                .foregroundStyle(.white.opacity(labelOpacity))
        }
        .font(.caption2)
        .lineLimit(1)
    }

    private var visibleContributors: [LyricsResult.SyncContributor] {
        Array(contributors.prefix(3))
    }

    private var remainingContributorCount: Int {
        max(0, contributors.count - visibleContributors.count)
    }

    private var labelOpacity: Double {
        subdued ? 0.12 : 0.45
    }

    private var nameOpacity: Double {
        subdued ? 0.20 : 0.56
    }

    private var linkedNameOpacity: Double {
        subdued ? 0.20 : 0.76
    }

    private var syncCreditFormatParts: (prefix: String, suffix: String) {
        let format = settings.t("lyrics.credit_sync_by_format")
        guard let range = format.range(of: "%s") else {
            return (format.isEmpty ? "" : format + " ", "")
        }
        return (String(format[..<range.lowerBound]), String(format[range.upperBound...]))
    }

    @ViewBuilder
    private func contributorNameView(_ contributor: LyricsResult.SyncContributor) -> some View {
        HStack(spacing: 4) {
            if interactive,
               !contributor.identityHidden,
               contributor.profileAvailable,
               !contributor.userHash.trimmed.isEmpty {
                Button {
                    Task {
                        await model.openSyncContributorProfile(contributor)
                    }
                } label: {
                    CreatorContributorNameText(
                        name: contributorDisplayName(contributor),
                        presentation: model.creatorSupportPresentation(for: contributor),
                        fallbackOpacity: linkedNameOpacity,
                        supporterOpacity: subdued ? 0.45 : 1
                    )
                }
                .buttonStyle(.plain)
            } else {
                CreatorContributorNameText(
                    name: contributorDisplayName(contributor),
                    presentation: model.creatorSupportPresentation(for: contributor),
                    fallbackOpacity: nameOpacity,
                    supporterOpacity: subdued ? 0.45 : 1
                )
            }
        }
    }

    private func contributorDisplayName(_ contributor: LyricsResult.SyncContributor) -> String {
        contributor.identityHidden ? settings.t("lyrics.credit_anonymous") : contributor.name
    }
}

private struct CreatorContributorNameText: View {
    let name: String
    let presentation: CreatorSupportPresentation?
    let fallbackOpacity: Double
    let supporterOpacity: Double

    @ViewBuilder
    var body: some View {
        if let presentation, presentation.usesGradient {
            let points = gradientPoints(angle: presentation.gradientAngle)
            Text(name)
                .foregroundStyle(LinearGradient(
                    colors: [
                        Color(hex: presentation.gradientStartColor),
                        Color(hex: presentation.gradientEndColor)
                    ],
                    startPoint: points.start,
                    endPoint: points.end
                ))
                .opacity(supporterOpacity)
        } else if let presentation, presentation.hasDecoration {
            Text(name)
                .foregroundStyle(Color(hex: presentation.solidColor))
                .opacity(supporterOpacity)
        } else {
            Text(name)
                .foregroundStyle(.white.opacity(fallbackOpacity))
        }
    }

    private func gradientPoints(angle: Int) -> (start: UnitPoint, end: UnitPoint) {
        let radians = Double(angle) * .pi / 180
        let directionX = sin(radians)
        let directionY = -cos(radians)
        return (
            UnitPoint(x: 0.5 - directionX / 2, y: 0.5 - directionY / 2),
            UnitPoint(x: 0.5 + directionX / 2, y: 0.5 + directionY / 2)
        )
    }
}

private struct EnumeratedRandomAccessCollection<Base: RandomAccessCollection>: RandomAccessCollection {
    typealias Index = Base.Index
    typealias Element = (offset: Int, element: Base.Element)

    private let base: Base

    init(_ base: Base) {
        self.base = base
    }

    var startIndex: Index { base.startIndex }
    var endIndex: Index { base.endIndex }
    var count: Int { base.count }

    subscript(position: Index) -> Element {
        (
            offset: base.distance(from: base.startIndex, to: position),
            element: base[position]
        )
    }

    func index(after index: Index) -> Index {
        base.index(after: index)
    }

    func index(before index: Index) -> Index {
        base.index(before: index)
    }

    func index(_ index: Index, offsetBy distance: Int) -> Index {
        base.index(index, offsetBy: distance)
    }

    func distance(from start: Index, to end: Index) -> Int {
        base.distance(from: start, to: end)
    }
}

struct LyricsTimelineView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    // Subscribed (not read directly) so this view re-renders with the display-rate playback clock driving model.nowPositionMs.
    @EnvironmentObject private var playbackClock: PlaybackClock
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var animatedCenterIndex: Double?
    /// Owned by LyricsTimelineScrollView; nil where the list does not scroll.
    var travelCascade: LyricsTravelCascade? = nil
    var onInterludeFrame: ((String, CGRect) -> Void)? = nil

    var body: some View {
#if DEBUG && os(iOS)
        let _ = debugProbeCount(.timelineBody)
#endif
        let position = model.adjustedPositionMs
        let continuousPosition = model.adjustedContinuousPositionMs
        let frameUptime = model.playbackFrameUptime
        let timelineContext = model.timelineContext
        let displaySnapshot = LyricsTimelineDisplayBuilder.displaySnapshot(
            context: timelineContext,
            positionMs: position,
            trackDurationMs: model.lyricsDurationMs,
            autoInstrumentalBreakEnabled: settings.autoInstrumentalBreakEnabled
        )
        let items = displaySnapshot.items
        let activeItemID = LyricsTimelineDisplayBuilder.previewItem(
            context: timelineContext,
            positionMs: position,
            trackDurationMs: model.lyricsDurationMs,
            autoInstrumentalBreakEnabled: settings.autoInstrumentalBreakEnabled
        )?.id
        let activeDisplayIndex = displaySnapshot.firstIndex(id: activeItemID)
            ?? max(0, displaySnapshot.firstIndex(lineIndex: model.activeLineIndex) ?? 0)
        let anticipatedItemID = settings.syncedLyricsKaraokeAnimationEnabled && !accessibilityReduceMotion
            ? LyricsTimelineDisplayBuilder.previewItem(
                context: timelineContext,
                positionMs: position + 300,
                trackDurationMs: model.lyricsDurationMs,
                autoInstrumentalBreakEnabled: settings.autoInstrumentalBreakEnabled
            )?.id
            : nil
        let anticipatedDisplayIndex = displaySnapshot.firstIndex(id: anticipatedItemID)
        // PC starts moving up to one row 300 ms before the next line. Never
        // skip an intermediate row when several short lines share that window.
        let targetDisplayIndex = anticipatedDisplayIndex.flatMap { index in
            index == activeDisplayIndex + 1 ? index : nil
        } ?? activeDisplayIndex
        let visualCenterIndex = animatedCenterIndex ?? Double(targetDisplayIndex)
        LazyVStack(spacing: 12) {
            if model.lyricsResult.lines.isEmpty {
                if model.status == .loading {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 9) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                            Text(model.lyricsLoadingText)
                                .font(.pretendard(13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.78))
                                .lineLimit(2)
                        }
                        LyricsLoadingSkeleton()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                } else if settings.lyricsNotFoundNoticeEnabled {
                    Text(model.lyricsResult.detail)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white.opacity(0.76))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                }
            } else {
                let _ = settings.typographyRevision
                let _ = settings.speakerColorRevision
                let typography = settings.typographySettings()
                let speakerColors = settings.speakerColorSettings()
                ForEach(EnumeratedRandomAccessCollection(items), id: \.element.id) { displayIndex, item in
                    let itemActive = item.id == activeItemID
                    // Colors stop changing past maximumEffectiveDistance, so farther rows keep
                    // equal inputs and skip re-rendering when the center moves.
                    let displayDistance = min(
                        LyricSpeakerPalette.maximumEffectiveDistance,
                        abs(Double(displayIndex) - visualCenterIndex)
                    )
                    Group {
                        switch item {
                        case .line(let index, let line, _):
                            let visualState = LyricsTimelineDisplayBuilder.playbackVisualState(
                                context: timelineContext,
                                lineIndex: index,
                                positionMs: position,
                                trackDurationMs: model.lyricsDurationMs,
                                autoInstrumentalBreakEnabled: settings.autoInstrumentalBreakEnabled
                            )
                            let lineActive = visualState.highlighted
                                || (activeItemID == nil && index == model.activeLineIndex)
                            let originalText = model.displayText(for: line)
                            LyricsLineView(
                                lineIndex: index,
                                line: line,
                                originalText: originalText,
                                culturalAnnotations: settings.culturalAnnotationsEnabled
                                    ? model.culturalAnnotations(
                                        forLine: index,
                                        text: originalText
                                    )
                                    : [],
                                active: lineActive,
                                animationActive: visualState.animating,
                                completedColorOpacity: visualState.completedColorOpacity,
                                displayDistance: displayDistance,
                                progress: lineActive ? model.progress(for: line) : 0,
                                positionMs: visualState.renderPositionMs,
                                continuousPositionMs: visualState.animating ? continuousPosition : nil,
                                alignment: settings.lyricsTextAlignment,
                                pronunciationLoading: model.lyricsSupplementPronunciationLoading,
                                translationLoading: model.lyricsSupplementTranslationLoading,
                                typography: typography,
                                speakerColors: speakerColors,
                                onSeek: { model.seek(toLyricsTimeMs: $0) }
                            )
                            .equatable()
                        case .interlude(let info):
                            LyricsInterludeView(
                                info: info,
                                active: itemActive,
                                displayDistance: displayDistance,
                                showLabel: settings.interludeLabelsEnabled,
                                alignment: settings.lyricsTextAlignment
                            )
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .named("lyrics-interlude-viewport"))
                            } action: { frame in onInterludeFrame?(item.id, frame) }
                        }
                    }
                    .id(item.id)
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named(LyricsTravelCascade.coordinateSpace))
                    } action: { frame in
                        travelCascade?.rowFrames[item.id] = frame
                    }
                    .offset(y: cascadeOffset(itemID: item.id, displayIndex: displayIndex,
                                             anchorIndex: targetDisplayIndex, at: frameUptime))
                }
            }
        }
        .coordinateSpace(.named(LyricsTravelCascade.coordinateSpace))
        .onAppear {
            animatedCenterIndex = Double(targetDisplayIndex)
        }
        .onChange(of: targetDisplayIndex) { _, nextIndex in
            let next = Double(nextIndex)
            guard let current = animatedCenterIndex, abs(next - current) <= 3.2 else {
                animatedCenterIndex = next
                return
            }
            withAnimation(
                accessibilityReduceMotion
                    ? nil
                    : LyricsMotion.centering(
                        duration: LyricsMotion.centeringDuration(
                            items: items,
                            targetIndex: nextIndex
                        )
                    )
            ) {
                animatedCenterIndex = next
            }
        }
    }

    private func cascadeOffset(itemID: String, displayIndex: Int, anchorIndex: Int, at uptime: TimeInterval) -> CGFloat {
        guard let travelCascade else { return 0 }
        let offset = travelCascade.offset(itemID: itemID, at: uptime)
#if DEBUG && os(iOS)
        if offset != 0 {
            DebugFrameProbe.shared.recordOffset(relativeIndex: displayIndex - anchorIndex, offset: Double(offset))
        }
#endif
        return offset
    }
}

private struct LyricsProviderAttribution: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    var includesSyncContributors = false

    private static let visibleProviderIds: Set<String> = ["lrclib", "paxsenix", "lyricsplus", "unison"]

    @ViewBuilder
    var body: some View {
        if !providerName.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(settings.t("section.lyrics_providers"))
                    .font(.pretendard(9, weight: .bold))
                    .tracking(1.1)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.12))
                Text(providerName)
                    .font(.pretendard(11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.20))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if includesSyncContributors, !model.baseLyricsResult.contributors.isEmpty {
                    Text("•")
                        .font(.pretendard(9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.12))
                    LyricsContributorCredit(
                        contributors: model.baseLyricsResult.contributors,
                        subdued: true,
                        interactive: false
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 26)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
        }
    }

    private var providerName: String {
        guard model.status == .loaded,
              !model.baseLyricsResult.lines.isEmpty else {
            return ""
        }
        let providerId = model.baseLyricsResult.providerId.trimmed.lowercased()
        if Self.visibleProviderIds.contains(providerId) {
            return providerId
        }

        let providerTokens = model.baseLyricsResult.providerLabel
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
        let legacyProviderIds = Set(providerTokens.filter(Self.visibleProviderIds.contains))
        return legacyProviderIds.count == 1 ? legacyProviderIds.first ?? "" : ""
    }
}

/// Geometry is sampled without publishing changes on every scroll/display frame.
private final class InterludeFrameStore {
    var id = ""
    var frame = CGRect.zero
}

private struct InterludeExitOverlay<Content: View>: View {
    let startedAt: TimeInterval
    @ViewBuilder var content: () -> Content

    var body: some View {
        TimelineView(.animation) { timeline in
            let appearance = InterludeTransition.exitAppearance(elapsed: timeline.date.timeIntervalSinceReferenceDate - startedAt)
            content()
                .opacity(appearance.opacity)
                .scaleEffect(appearance.scale)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct LyricsTimelineScrollView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    // Subscribed (not read directly) so this view re-renders with the display-rate playback clock driving model.nowPositionMs.
    @EnvironmentObject private var playbackClock: PlaybackClock
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var autoScrollPaused = false
    @State private var lastScrolledTargetID: String?
    @State private var autoScrollResumeTask: Task<Void, Never>?
    @State private var travelCascade = LyricsTravelCascade()
    @State private var interludeFrameStore = InterludeFrameStore()
    @State private var interludeTransition = InterludeTransition()
    @State private var outgoingInterludeFrame = CGRect.zero

    var topPadding: CGFloat = 0
    var bottomPadding: CGFloat = 0
    var horizontalPadding: CGFloat = 0
    var trailingPadding: CGFloat = 0
    var centerAnchorY: CGFloat = 0.5
    var centerEmptyContent = false

    private static let manualScrollHoldSeconds: TimeInterval = 4.0

    var body: some View {
#if DEBUG && os(iOS)
        let _ = debugProbeCount(.scrollBody)
#endif
        let targetID = activeTargetID
        GeometryReader { geometry in
            if shouldCenterEmptyContent {
                LyricsTimelineView()
                    .padding(.top, topPadding)
                    .padding(.bottom, bottomPadding)
                    .padding(.leading, horizontalPadding)
                    .padding(.trailing, max(horizontalPadding, trailingPadding))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: geometry.size.width)
                    .position(
                        x: geometry.size.width * 0.5,
                        y: geometry.size.height * min(1, max(0, centerAnchorY))
                    )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            if hasScrollableLyrics {
                                Color.clear
                                    .frame(height: topEdgeInset(for: geometry.size.height))
                            }
                            LyricsTimelineView(travelCascade: travelCascade, onInterludeFrame: { id, frame in
                                interludeFrameStore.id = id
                                interludeFrameStore.frame = frame
                            })
                                .padding(.top, topPadding)
                                .padding(.bottom, bottomPadding)
                                .padding(.leading, horizontalPadding)
                                .padding(.trailing, max(horizontalPadding, trailingPadding))
                            if hasScrollableLyrics {
                                Color.clear
                                    .frame(height: bottomEdgeInset(for: geometry.size.height))
                            }
                        }
                    }
                    .mask {
                        if hasScrollableLyrics {
                            LyricsTimelineEdgeFadeMask(height: geometry.size.height)
                        } else {
                            Rectangle().fill(.white)
                        }
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { _ in
                                pauseAutoScroll()
                            }
                            .onEnded { _ in
                                pauseAutoScroll()
                            }
                    )
                    .onAppear {
                        scrollToTarget(targetID, proxy: proxy, animated: false, force: true)
                    }
                    .onChange(of: targetID) { _, nextID in
                        if nextID == nil {
                            lastScrolledTargetID = nil
                        }
                        guard !autoScrollPaused else { return }
                        scrollToTarget(nextID, proxy: proxy, animated: true)
                    }
                    .onChange(of: autoScrollPaused) { _, paused in
                        guard !paused else { return }
                        scrollToTarget(activeTargetID, proxy: proxy, animated: true, force: true)
                    }
                    .onChange(of: model.lyricsFocusRequestRevision) { _, _ in
                        autoScrollResumeTask?.cancel()
                        autoScrollResumeTask = nil
                        autoScrollPaused = false
                        scrollToTarget(activeTargetID, proxy: proxy, animated: true, force: true)
                    }
                    .onChange(of: model.lyricsSupplementLayoutRevision) { _, _ in
                        guard !autoScrollPaused else { return }
                        scrollToTarget(activeTargetID, proxy: proxy, animated: false, force: true)
                    }
                    .onDisappear {
                        autoScrollResumeTask?.cancel()
                        autoScrollResumeTask = nil
                    }
                }
            }
        }
        .coordinateSpace(name: "lyrics-interlude-viewport")
        .overlay(alignment: .topLeading) {
            if let outgoing = interludeTransition.outgoing, !outgoingInterludeFrame.isEmpty {
                InterludeExitOverlay(startedAt: outgoing.startedAt) {
                    LyricsInterludeView(
                        info: .init(startTimeMs: outgoing.segment.startMs, endTimeMs: outgoing.segment.endMs, kind: outgoing.segment.kind, automatic: outgoing.segment.automatic),
                        active: true, displayDistance: 0, showLabel: settings.interludeLabelsEnabled, alignment: settings.lyricsTextAlignment,
                        isExitOverlay: true
                    )
                }
                .frame(width: outgoingInterludeFrame.width, height: outgoingInterludeFrame.height)
                .position(x: outgoingInterludeFrame.midX, y: outgoingInterludeFrame.midY)
            }
        }
        .clipped()
        .task(id: interludeTransition.outgoing) {
            guard let outgoing = interludeTransition.outgoing else { return }
            try? await Task.sleep(for: .seconds(InterludeTransition.exitSeconds))
            guard !Task.isCancelled, interludeTransition.outgoing == outgoing else { return }
            interludeTransition.outgoing = nil
        }
        .onChange(of: activeInterlude, initial: true) { _, next in updateInterlude(next) }
        .onChange(of: model.currentTrackKey) { _, _ in updateInterlude(activeInterlude) }
        .onChange(of: model.lyricsResult.lines) { _, _ in interludeTransition = InterludeTransition(); updateInterlude(activeInterlude) }
        .onChange(of: smoothInterludeMotion) { _, _ in updateInterlude(activeInterlude) }
        .onDisappear { interludeTransition = InterludeTransition() }
    }

    private var smoothInterludeMotion: Bool {
        settings.syncedLyricsKaraokeAnimationEnabled && !accessibilityReduceMotion
    }

    private var activeInterlude: InterludeTransition.Segment? {
        guard let item = LyricsTimelineDisplayBuilder.previewItem(context: model.timelineContext, positionMs: model.adjustedPositionMs,
                  trackDurationMs: model.lyricsDurationMs, autoInstrumentalBreakEnabled: settings.autoInstrumentalBreakEnabled),
              case .interlude(let info) = item else { return nil }
        return .init(id: item.id, startMs: info.startTimeMs, endMs: info.endTimeMs, kind: info.kind, automatic: info.automatic)
    }

    private func updateInterlude(_ next: InterludeTransition.Segment?) {
        let previous = interludeTransition.active
        let frame = interludeFrameStore.frame
        let frameID = interludeFrameStore.id
        interludeTransition.update(next: next, positionMs: model.adjustedPositionMs, now: Date().timeIntervalSinceReferenceDate,
                                  scope: model.currentTrackKey, enabled: smoothInterludeMotion)
        if let outgoing = interludeTransition.outgoing, outgoing.segment == previous {
            outgoingInterludeFrame = frameID == outgoing.segment.id ? frame : .zero
        }
    }

    private var hasScrollableLyrics: Bool {
        !model.lyricsResult.lines.isEmpty
    }

    private var shouldCenterEmptyContent: Bool {
        !hasScrollableLyrics && (centerEmptyContent || model.status == .loading)
    }

    private var activeTargetID: String? {
        let currentTargetID = LyricsTimelineDisplayBuilder.scrollTargetID(
            context: model.timelineContext,
            positionMs: model.adjustedPositionMs,
            trackDurationMs: model.lyricsDurationMs,
            autoInstrumentalBreakEnabled: settings.autoInstrumentalBreakEnabled,
            vocalPartAnchorsEnabled: !settings.karaokeDataAsLineSynced
        )
        guard !accessibilityReduceMotion,
              settings.syncedLyricsKaraokeAnimationEnabled,
              let currentItem = LyricsTimelineDisplayBuilder.previewItem(
                context: model.timelineContext,
                positionMs: model.adjustedPositionMs,
                trackDurationMs: model.lyricsDurationMs,
                autoInstrumentalBreakEnabled: settings.autoInstrumentalBreakEnabled
              ),
              let advancedItem = LyricsTimelineDisplayBuilder.previewItem(
                context: model.timelineContext,
                positionMs: model.adjustedPositionMs + 300,
                trackDurationMs: model.lyricsDurationMs,
                autoInstrumentalBreakEnabled: settings.autoInstrumentalBreakEnabled
              ),
              currentItem.id != advancedItem.id else {
            return currentTargetID
        }
        let displaySnapshot = LyricsTimelineDisplayBuilder.displaySnapshot(
            context: model.timelineContext,
            positionMs: model.adjustedPositionMs,
            trackDurationMs: model.lyricsDurationMs,
            autoInstrumentalBreakEnabled: settings.autoInstrumentalBreakEnabled
        )
        guard let currentIndex = displaySnapshot.firstIndex(id: currentItem.id),
              let advancedIndex = displaySnapshot.firstIndex(id: advancedItem.id),
              advancedIndex == currentIndex + 1 else {
            return currentTargetID
        }
        // Pre-center at most one row so very short lyrics cannot skip an
        // intermediate line inside the look-ahead window.
        return advancedItem.id
    }

    private func topEdgeInset(for height: CGFloat) -> CGFloat {
        max(24, height * min(1, max(0, centerAnchorY)))
    }

    private func bottomEdgeInset(for height: CGFloat) -> CGFloat {
        max(24, height * (1 - min(1, max(0, centerAnchorY))))
    }

    private func pauseAutoScroll() {
        autoScrollPaused = true
        autoScrollResumeTask?.cancel()
        autoScrollResumeTask = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.manualScrollHoldSeconds * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            autoScrollResumeTask = nil
            autoScrollPaused = false
        }
    }

    private func scrollToTarget(_ targetID: String?, proxy: ScrollViewProxy, animated: Bool, force: Bool = false) {
        guard let targetID else { return }
        guard force || lastScrolledTargetID != targetID else { return }
        let previousTargetID = lastScrolledTargetID
        lastScrolledTargetID = targetID
#if DEBUG && os(iOS)
        DebugFrameProbe.shared.recordEvent("travel", ["target": targetID, "animated": animated, "force": force])
#endif
        let anchorY = min(1, max(0, centerAnchorY))
        let action = {
            proxy.scrollTo(
                targetID,
                anchor: UnitPoint(x: 0.5, y: anchorY)
            )
        }
        guard animated && !accessibilityReduceMotion else {
            action()
            return
        }
        let displaySnapshot = LyricsTimelineDisplayBuilder.displaySnapshot(
            context: model.timelineContext,
            positionMs: model.adjustedPositionMs,
            trackDurationMs: model.lyricsDurationMs,
            autoInstrumentalBreakEnabled: settings.autoInstrumentalBreakEnabled
        )
        let targetIndex = displaySnapshot.firstIndex(id: targetID)
        let windowMs = targetIndex.flatMap {
            LyricsTravelMotion.windowMs(items: displaySnapshot.items, targetIndex: $0)
        }
        // A line that is replaced within 80ms moves without travel, like the PC renderer.
        guard !LyricsTravelMotion.skipsMotion(windowMs: windowMs) else {
            action()
            return
        }
        let timing = LyricsTravelMotion.timing(windowMs: windowMs)
        // Only a one-row advance cascades. Seeks, jumps, focus requests and manual-scroll
        // returns (force) move every row together on the scroll alone.
        if !force, let previousTargetID, let targetIndex,
           displaySnapshot.firstIndex(id: previousTargetID) == targetIndex - 1,
           let distance = travelCascade.anchorDistance(from: previousTargetID, to: targetID, anchorY: anchorY),
           distance > 0.5 {
            let startUptime = model.playbackFrameUptime
            travelCascade.begin(
                startUptime: startUptime,
                distance: distance,
                timing: timing,
                rowsBelow: displaySnapshot.items.dropFirst(targetIndex + 1).prefix(32).map(\.id)
            )
            model.keepLyricsFramesUpdating(until: startUptime + timing.totalMs / 1_000)
        }
        // ScrollView honors SwiftUI's built-in springs (not CustomAnimation) for scrollTo.
        // bounce 0 is the same critically damped curve (omega = k / duration); a retargeted
        // scroll keeps its velocity.
        withAnimation(.spring(duration: LyricsTravelMotion.springResponseSeconds(timing), bounce: 0), action)
    }
}

extension LyricsTravelMotion {
    /// Time from this row's travel to the next row's (the same window LyricsMotion uses).
    static func windowMs(items: [LyricsTimelineDisplayItem], targetIndex: Int) -> Double? {
        guard items.indices.contains(targetIndex) else { return nil }
        let targetStart = items[targetIndex].startTimeMs
        guard let nextStart = items.dropFirst(targetIndex + 1)
            .lazy
            .map(\.startTimeMs)
            .first(where: { $0 > targetStart }) else {
            return nil
        }
        return Double(nextStart - targetStart)
    }
}

/// The lyric scroll carries every row on the travel spring. A row below the anchor adds
/// distance * (p(t) - p(t - delay)), so it replays the anchor's travel 'delay' later and ends at
/// exactly zero offset; overlapping travels add up. Plain reference type: rows read it while
/// the playback clock repaints them, so it never invalidates a view by itself.
final class LyricsTravelCascade {
    static let coordinateSpace = "ivlyrics-lyrics-travel"

    private struct Travel {
        var startUptime: TimeInterval
        var distance: Double
        var durationMs: Double
        var endMs: Double
        var delays: [String: Double]
    }

    private var travels: [Travel] = []
    /// Row layout frames in the scroll content; scrolling and cascade offsets do not change them.
    var rowFrames: [String: CGRect] = [:]

    /// Content-offset change of scrollTo(_:anchor:) from one row to the next.
    func anchorDistance(from previousID: String, to targetID: String, anchorY: CGFloat) -> Double? {
        guard let from = rowFrames[previousID], let to = rowFrames[targetID] else { return nil }
        return Double((to.minY + to.height * anchorY) - (from.minY + from.height * anchorY))
    }

    func begin(startUptime: TimeInterval, distance: Double, timing: LyricsTravelMotion.Timing, rowsBelow: [String]) {
        travels.removeAll { (startUptime - $0.startUptime) * 1_000 >= $0.endMs }
        var delays: [String: Double] = [:]
        for (offset, id) in rowsBelow.enumerated() {
            delays[id] = LyricsTravelMotion.delayMs(rowsBelowAnchor: offset + 1, timing: timing)
        }
        travels.append(Travel(startUptime: startUptime, distance: distance, durationMs: timing.durationMs,
                              endMs: timing.totalMs, delays: delays))
    }

    func offset(itemID: String, at uptime: TimeInterval) -> CGFloat {
        guard !travels.isEmpty else { return 0 }
        var total = 0.0
        for travel in travels {
            guard let delay = travel.delays[itemID], delay > 0 else { continue }
            let elapsed = (uptime - travel.startUptime) * 1_000
            guard elapsed > 0, elapsed < travel.durationMs + delay else { continue }
            total += travel.distance * (LyricsTravelMotion.progress(elapsed / travel.durationMs)
                - LyricsTravelMotion.progress((elapsed - delay) / travel.durationMs))
        }
        return CGFloat(total)
    }
}

private enum LyricsMotion {
    static let defaultCenteringDuration = 0.30
    private static let defaultCenteringBudget = 0.412
    private static let minimumCenteringBudget = 0.08
    private static let settleReserveSeconds = 0.024

    // Keep the mobile hand-off on the same symmetric S-curve and adaptive
    // short-line duration as PC.
    static func centering(duration: Double = defaultCenteringDuration) -> Animation {
        .timingCurve(0.42, 0, 0.58, 1, duration: duration)
    }

    static func centeringDuration(
        items: [LyricsTimelineDisplayItem],
        targetIndex: Int
    ) -> Double {
        guard items.indices.contains(targetIndex) else {
            return defaultCenteringDuration
        }
        let targetStart = items[targetIndex].startTimeMs
        guard let nextStart = items.dropFirst(targetIndex + 1)
            .lazy
            .map(\.startTimeMs)
            .first(where: { $0 > targetStart }) else {
            return defaultCenteringDuration
        }
        let available = max(
            minimumCenteringBudget,
            Double(nextStart - targetStart) / 1_000 - settleReserveSeconds
        )
        let timingScale = min(1, available / defaultCenteringBudget)
        return max(0.001, defaultCenteringDuration * timingScale)
    }
}

private struct LyricsTimelineEdgeFadeMask: View {
    var height: CGFloat

    var body: some View {
        let topFadeHeight = min(height * 0.28, 150)
        let bottomFadeHeight = min(34, height * 0.12)
        let centerHeight = max(0, height - topFadeHeight - bottomFadeHeight)
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.clear, .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: max(0, topFadeHeight))

            Rectangle()
                .fill(.black)
                .frame(height: centerHeight)

            LinearGradient(
                colors: [.black, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: max(0, bottomFadeHeight))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum LyricsTimelineDisplayItem: Identifiable {
    case line(index: Int, line: LyricsLine, id: String)
    case interlude(InterludeInfo)

    var id: String {
        switch self {
        case .line(_, _, let id):
            return id
        case .interlude(let info):
            return "interlude-\(info.kind)-\(info.startTimeMs)-\(info.endTimeMs)"
        }
    }

    var startTimeMs: Int64 {
        switch self {
        case .line(_, let line, _):
            return line.startTimeMs
        case .interlude(let info):
            return info.startTimeMs
        }
    }
}

struct InterludeInfo {
    var startTimeMs: Int64
    var endTimeMs: Int64
    var kind: String
    var automatic: Bool
}

/// Item membership and first-occurrence indices share the same interval cache.
/// Duplicate IDs retain firstIndex semantics instead of replacing earlier rows.
final class LyricsTimelineDisplaySnapshot {
    let items: [LyricsTimelineDisplayItem]
    private let indicesByID: [String: Int]
    private let indicesByLine: [Int: Int]

    init(items: [LyricsTimelineDisplayItem]) {
        self.items = items
        var ids: [String: Int] = [:]
        var lines: [Int: Int] = [:]
        ids.reserveCapacity(items.count)
        lines.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let id = item.id
            if ids[id] == nil { ids[id] = index }
            if case .line(let sourceIndex, _, _) = item, lines[sourceIndex] == nil {
                lines[sourceIndex] = index
            }
        }
        indicesByID = ids
        indicesByLine = lines
    }

    func firstIndex(id: String?) -> Int? { id.flatMap { indicesByID[$0] } }
    func firstIndex(lineIndex: Int) -> Int? { indicesByLine[lineIndex] }
}

struct LyricsTimelineContext {
    let lines: [LyricsLine]
    let lineIDs: [String]
    let isMarker: [Bool]
    let markerIndices: [Int]
    let firstUntimedLineIndex: Int?
    let firstRenderableLineIndex: Int?
    let nonMarkerLineCount: Int
    let lastLyricEndTimes: [Int64]?
    let markerInterludeInfos: [InterludeInfo?]
    let baseItems: [LyricsTimelineDisplayItem]
    let baseSnapshot: LyricsTimelineDisplaySnapshot
    let itemQueries: TimelineIntervalCache<LyricsTimelineDisplaySnapshot>
    let previewQueries: TimelineIntervalCache<LyricsTimelineDisplayItem?>
    let activeLineQueries: TimelineIntervalCache<[Int]>
    let precedingLyricEndTimes: [Int64]

    var cachesLyricEndTimes: Bool { lastLyricEndTimes != nil }

    init(lines: [LyricsLine], cacheLyricEndTimes: Bool = true) {
        self.lines = lines
        let lineIDs = lines.enumerated().map {
            LyricsTimelineDisplayBuilder.lineID(index: $0.offset, line: $0.element)
        }
        self.lineIDs = lineIDs
        var isMarker: [Bool] = []
        isMarker.reserveCapacity(lines.count)
        var markerIndices: [Int] = []
        var firstUntimedLineIndex: Int?
        var firstRenderableLineIndex: Int?
        var nonMarkerLineCount = 0
        for index in lines.indices {
            let line = lines[index]
            let marker = LyricsTimelineDisplayBuilder.isInterludeMarkerText(
                LyricsTimelineDisplayBuilder.candidateText(line)
            )
            isMarker.append(marker)
            if marker {
                markerIndices.append(index)
            } else {
                nonMarkerLineCount += 1
                if line.isTimed {
                    if firstRenderableLineIndex == nil {
                        firstRenderableLineIndex = index
                    }
                } else if firstUntimedLineIndex == nil {
                    firstUntimedLineIndex = index
                }
            }
        }
        self.isMarker = isMarker
        self.markerIndices = markerIndices
        self.firstUntimedLineIndex = firstUntimedLineIndex
        self.firstRenderableLineIndex = firstRenderableLineIndex
        self.nonMarkerLineCount = nonMarkerLineCount
        lastLyricEndTimes = cacheLyricEndTimes
            ? lines.map(LyricsTimelineDisplayBuilder.lastLyricEndTime)
            : nil
        var precedingEnd: Int64 = -1
        precedingLyricEndTimes = lines.indices.map { index in
            if !isMarker[index] {
                precedingEnd = max(precedingEnd, LyricsTimelineDisplayBuilder.lastLyricEndTime(lines[index]))
            }
            return precedingEnd
        }
        let markerInterludeInfos = LyricsTimelineDisplayBuilder.markerInterludeInfos(
            lines: lines,
            isMarker: isMarker,
            markerIndices: markerIndices
        )
        self.markerInterludeInfos = markerInterludeInfos
        var baseItems: [LyricsTimelineDisplayItem] = []
        let capacity = nonMarkerLineCount
        baseItems.reserveCapacity(capacity == Int.max ? capacity : capacity + 1)
        for index in lines.indices where !isMarker[index] || markerInterludeInfos[index] == nil {
            baseItems.append(.line(index: index, line: lines[index], id: lineIDs[index]))
        }
        if baseItems.isEmpty, let first = lines.first {
            baseItems.append(.line(index: 0, line: first, id: lineIDs[0]))
        }
        self.baseItems = baseItems
        baseSnapshot = LyricsTimelineDisplaySnapshot(items: baseItems)
        let boundaries = LyricsTimelineDisplayBuilder.queryBoundaries(
            lines: lines, markers: markerInterludeInfos, lyricEndTimes: lastLyricEndTimes
        )
        itemQueries = TimelineIntervalCache(boundaries: boundaries)
        previewQueries = TimelineIntervalCache(boundaries: boundaries)
        activeLineQueries = TimelineIntervalCache(boundaries: boundaries)
    }
}

struct LyricsLinePlaybackVisualState {
    static let inactive = LyricsLinePlaybackVisualState(
        highlighted: false,
        animating: false,
        completedColorOpacity: 0,
        renderPositionMs: 0
    )

    var highlighted: Bool
    var animating: Bool
    var completedColorOpacity: CGFloat
    var renderPositionMs: Int64
}

enum LyricsTimelineDisplayBuilder {
    private static let interludeMinDurationMs: Int64 = 500
    private static let trailingInterludeDelayMs: Int64 = 3_500
    private static let vocalPartCenterThreshold = 4
    private static let displayWhitespace = CharacterSet.whitespacesAndNewlines
    private static let karaokeReleaseWindowMs: Int64 = 820
    private static let karaokeCompletionPositionOffsetMs: Int64 = 900
    private static let completedColorFadeMs: Int64 = 520

    // A scroll anchor is one line; the set of singing rows can contain several.
    // Keep the original source order and individual end times in compact previews.
    static func activeLineIndices(context: LyricsTimelineContext, positionMs: Int64) -> [Int] {
        context.activeLineQueries.value(position: positionMs, duration: 0, automaticInterludes: false) {
            context.lines.indices.filter { index in
                let line = context.lines[index]
                let end = context.lastLyricEndTimes?[index] ?? lastLyricEndTime(line)
                return !context.isMarker[index] && line.isTimed
                    && positionMs >= line.startTimeMs && positionMs < max(line.endTimeMs, end)
            }
        }
    }

    static func lineID(index: Int, line: LyricsLine) -> String {
        "line-\(index)-\(line.id)"
    }

    static func vocalPartTargetID(lineIndex: Int, line: LyricsLine, partIndex: Int) -> String {
        "\(lineID(index: lineIndex, line: line))-part-\(partIndex)"
    }

    static func orderedVocalParts(_ parts: [LyricsLine.VocalPart]) -> [LyricsLine.VocalPart] {
        var sawNonLead = false
        for part in parts {
            if part.role == "lead" {
                if !sawNonLead { continue }

                var result: [LyricsLine.VocalPart] = []
                result.reserveCapacity(parts.count)
                for part in parts where part.role == "lead" {
                    result.append(part)
                }
                for part in parts where part.role != "lead" {
                    result.append(part)
                }
                return result
            }
            sawNonLead = true
        }

        return parts
    }

    static func vocalPartDisplayText(_ part: LyricsLine.VocalPart) -> String {
        for scalar in part.text.unicodeScalars where !displayWhitespace.contains(scalar) {
            return part.text
        }
        var text = ""
        for syllable in part.syllables {
            text.append(syllable.text)
        }
        return text
    }

    static func displayableVocalParts(_ parts: [LyricsLine.VocalPart]) -> [LyricsLine.VocalPart] {
        for part in parts where vocalPartDisplayText(part).trimmed.isEmpty {
            return parts.filter { !vocalPartDisplayText($0).trimmed.isEmpty }
        }
        return parts
    }

    static func shouldUseVocalPartSupplements(_ line: LyricsLine) -> Bool {
        let parts = orderedVocalParts(line.vocalParts)
        return shouldUseVocalPartSupplements(orderedParts: parts)
    }

    static func shouldUseVocalPartSupplements(orderedParts parts: [LyricsLine.VocalPart]) -> Bool {
        return hasVocalPartSupplements(parts) || displayableVocalPartCount(parts) > 1
    }

    static func supplementPlaceholderText(_ line: LyricsLine) -> String {
        let text = line.text.trimmed
        if !text.isEmpty { return text }
        let orderedParts = orderedVocalParts(line.vocalParts)
        if orderedParts.isEmpty { return " " }
        var parts: [String] = []
        parts.reserveCapacity(orderedParts.count)
        for part in orderedParts {
            let value = supplementPlaceholderText(part).trimmed
            if !value.isEmpty { parts.append(value) }
        }
        return parts.isEmpty ? " " : parts.joined(separator: " ")
    }

    static func supplementPlaceholderText(_ part: LyricsLine.VocalPart) -> String {
        let text = vocalPartDisplayText(part).trimmed
        return text.isEmpty ? " " : text
    }

    static func items(
        lines: [LyricsLine],
        positionMs: Int64,
        trackDurationMs: Int64,
        autoInstrumentalBreakEnabled: Bool
    ) -> [LyricsTimelineDisplayItem] {
        items(
            context: LyricsTimelineContext(
                lines: lines,
                cacheLyricEndTimes: autoInstrumentalBreakEnabled
            ),
            positionMs: positionMs,
            trackDurationMs: trackDurationMs,
            autoInstrumentalBreakEnabled: autoInstrumentalBreakEnabled
        )
    }

    static func items(
        context: LyricsTimelineContext,
        positionMs: Int64,
        trackDurationMs: Int64,
        autoInstrumentalBreakEnabled: Bool
    ) -> [LyricsTimelineDisplayItem] {
        displaySnapshot(context: context, positionMs: positionMs, trackDurationMs: trackDurationMs,
                        autoInstrumentalBreakEnabled: autoInstrumentalBreakEnabled).items
    }

    static func displaySnapshot(
        context: LyricsTimelineContext,
        positionMs: Int64,
        trackDurationMs: Int64,
        autoInstrumentalBreakEnabled: Bool
    ) -> LyricsTimelineDisplaySnapshot {
        context.itemQueries.value(position: positionMs, duration: trackDurationMs,
                                  automaticInterludes: autoInstrumentalBreakEnabled) {
            guard !context.lines.isEmpty else { return context.baseSnapshot }
            guard hasActiveInterlude(context: context, positionMs: positionMs, trackDurationMs: trackDurationMs,
                                    autoInstrumentalBreakEnabled: autoInstrumentalBreakEnabled) else {
                return context.baseSnapshot
            }
            return LyricsTimelineDisplaySnapshot(items: uncachedItems(
                context: context, positionMs: positionMs, trackDurationMs: trackDurationMs,
                autoInstrumentalBreakEnabled: autoInstrumentalBreakEnabled))
        }
    }

    fileprivate static func uncachedItems(
        context: LyricsTimelineContext,
        positionMs: Int64,
        trackDurationMs: Int64,
        autoInstrumentalBreakEnabled: Bool
    ) -> [LyricsTimelineDisplayItem] {
        let lines = context.lines
        guard !lines.isEmpty else { return [] }
        guard hasActiveInterlude(
            context: context,
            positionMs: positionMs,
            trackDurationMs: trackDurationMs,
            autoInstrumentalBreakEnabled: autoInstrumentalBreakEnabled
        ) else {
            return context.baseItems
        }
        var result: [LyricsTimelineDisplayItem] = []
        let count = lines.count
        let capacity = context.nonMarkerLineCount
        result.reserveCapacity(capacity == Int.max ? capacity : capacity + 1)
        for index in lines.indices {
            let line = lines[index]
            let marker = markerInterludeInfo(context: context, line: line, index: index, count: count)
            if let marker,
               contains(marker, positionMs),
               !hasOverlap(result, marker) {
                result.append(.interlude(marker))
            } else if marker == nil {
                result.append(.line(index: index, line: line, id: context.lineIDs[index]))
            }

            if let trailing = trailingInterludeInfo(
                context: context,
                line: line,
                index: index,
                count: count,
                positionMs: positionMs,
                trackDurationMs: trackDurationMs,
                autoInstrumentalBreakEnabled: autoInstrumentalBreakEnabled
            ), !hasOverlap(result, trailing) {
                result.append(.interlude(trailing))
            }
        }
        if result.isEmpty, let first = lines.first {
            result.append(.line(index: 0, line: first, id: context.lineIDs[0]))
        }
        return result
    }

    static func previewItem(
        lines: [LyricsLine],
        positionMs: Int64,
        trackDurationMs: Int64,
        autoInstrumentalBreakEnabled: Bool
    ) -> LyricsTimelineDisplayItem? {
        previewItem(
            context: LyricsTimelineContext(
                lines: lines,
                cacheLyricEndTimes: autoInstrumentalBreakEnabled
            ),
            positionMs: positionMs,
            trackDurationMs: trackDurationMs,
            autoInstrumentalBreakEnabled: autoInstrumentalBreakEnabled
        )
    }

    static func previewItem(
        context: LyricsTimelineContext,
        positionMs: Int64,
        trackDurationMs: Int64,
        autoInstrumentalBreakEnabled: Bool
    ) -> LyricsTimelineDisplayItem? {
        context.previewQueries.value(position: positionMs, duration: trackDurationMs,
                                     automaticInterludes: autoInstrumentalBreakEnabled) {
            uncachedPreviewItem(context: context, positionMs: positionMs, trackDurationMs: trackDurationMs,
                                autoInstrumentalBreakEnabled: autoInstrumentalBreakEnabled)
        }
    }

    fileprivate static func uncachedPreviewItem(
        context: LyricsTimelineContext,
        positionMs: Int64,
        trackDurationMs: Int64,
        autoInstrumentalBreakEnabled: Bool
    ) -> LyricsTimelineDisplayItem? {
        let lines = context.lines
        guard !lines.isEmpty else { return nil }
        let count = lines.count
        for index in context.markerIndices {
            let line = lines[index]
            if let marker = markerInterludeInfo(context: context, line: line, index: index, count: count),
               contains(marker, positionMs) {
                return .interlude(marker)
            }
        }

        if let index = context.firstUntimedLineIndex {
            return .line(index: index, line: lines[index], id: context.lineIDs[index])
        }

        var fallbackIndex = -1
        for index in lines.indices {
            let line = lines[index]
            guard line.isTimed, !context.isMarker[index] else { continue }
            if positionMs >= line.startTimeMs {
                // Anchor to the latest start. A previous line can remain
                // highlighted while its timed content finishes, but it must not
                // block the following line from becoming the center row.
                fallbackIndex = index
            }
        }

        if let prelude = previewPreludeInfo(context: context, positionMs: positionMs) {
            return .interlude(prelude)
        }

        if let trailing = previewTrailingInterludeInfo(
            context: context,
            positionMs: positionMs,
            trackDurationMs: trackDurationMs,
            autoInstrumentalBreakEnabled: autoInstrumentalBreakEnabled
        ) {
            return .interlude(trailing)
        }

        guard fallbackIndex >= 0 else { return nil }
        return .line(index: fallbackIndex, line: lines[fallbackIndex], id: context.lineIDs[fallbackIndex])
    }

    static func playbackVisualState(
        context: LyricsTimelineContext,
        lineIndex: Int,
        positionMs: Int64,
        trackDurationMs: Int64,
        autoInstrumentalBreakEnabled: Bool
    ) -> LyricsLinePlaybackVisualState {
        guard context.lines.indices.contains(lineIndex),
              !context.isMarker[lineIndex] else {
            return .inactive
        }
        let line = context.lines[lineIndex]
        guard line.isTimed, positionMs >= line.startTimeMs else {
            return .inactive
        }
        let cachedEnd = context.lastLyricEndTimes?[lineIndex] ?? lastLyricEndTime(line)
        let contentEndTimeMs = max(line.endTimeMs, cachedEnd, line.startTimeMs)
        let nextStartTimeMs = nextRenderableLineStartAfter(context: context, index: lineIndex)
        var holdEndTimeMs = nextStartTimeMs > line.startTimeMs
            ? max(contentEndTimeMs, nextStartTimeMs)
            : contentEndTimeMs
        if let trailing = trailingInterludeInfo(
            context: context,
            line: line,
            index: lineIndex,
            count: context.lines.count,
            positionMs: positionMs,
            trackDurationMs: trackDurationMs,
            autoInstrumentalBreakEnabled: autoInstrumentalBreakEnabled
        ), contains(trailing, positionMs) {
            holdEndTimeMs = min(holdEndTimeMs, trailing.startTimeMs)
        }
        let highlighted = positionMs < holdEndTimeMs
        let animating = positionMs < contentEndTimeMs + karaokeReleaseWindowMs
        let completedColorOpacity: CGFloat
        if highlighted {
            completedColorOpacity = 1
        } else {
            completedColorOpacity = 1 - min(
                1,
                max(0, CGFloat(positionMs - holdEndTimeMs) / CGFloat(completedColorFadeMs))
            )
        }
        let renderPositionMs = animating
            ? positionMs
            : contentEndTimeMs + karaokeCompletionPositionOffsetMs
        return LyricsLinePlaybackVisualState(
            highlighted: highlighted,
            animating: animating,
            completedColorOpacity: completedColorOpacity,
            renderPositionMs: renderPositionMs
        )
    }

    static func scrollTargetID(
        lines: [LyricsLine],
        positionMs: Int64,
        trackDurationMs: Int64,
        autoInstrumentalBreakEnabled: Bool,
        vocalPartAnchorsEnabled: Bool
    ) -> String? {
        scrollTargetID(
            context: LyricsTimelineContext(
                lines: lines,
                cacheLyricEndTimes: autoInstrumentalBreakEnabled
            ),
            positionMs: positionMs,
            trackDurationMs: trackDurationMs,
            autoInstrumentalBreakEnabled: autoInstrumentalBreakEnabled,
            vocalPartAnchorsEnabled: vocalPartAnchorsEnabled
        )
    }

    static func scrollTargetID(
        context: LyricsTimelineContext,
        positionMs: Int64,
        trackDurationMs: Int64,
        autoInstrumentalBreakEnabled: Bool,
        vocalPartAnchorsEnabled: Bool
    ) -> String? {
        guard let item = previewItem(
            context: context,
            positionMs: positionMs,
            trackDurationMs: trackDurationMs,
            autoInstrumentalBreakEnabled: autoInstrumentalBreakEnabled
        ) else {
            return nil
        }

        if case .line(let index, let line, _) = item,
           vocalPartAnchorsEnabled,
           let partTargetID = activeVocalPartTargetID(lineIndex: index, line: line, positionMs: positionMs) {
            return partTargetID
        }
        return item.id
    }

    private static func activeVocalPartTargetID(lineIndex: Int, line: LyricsLine, positionMs: Int64) -> String? {
        let parts = orderedVocalParts(line.vocalParts)
        guard hasTimedKaraokeData(line),
              displayableVocalPartCount(parts) >= vocalPartCenterThreshold else {
            return nil
        }

        var firstActiveIndex = -1
        var lastActiveIndex = -1
        for (index, part) in parts.enumerated() {
            let startTimeMs = part.startTimeMs > 0 ? part.startTimeMs : line.startTimeMs
            let endTimeMs = part.endTimeMs > startTimeMs ? part.endTimeMs : max(startTimeMs, line.endTimeMs)
            if positionMs >= startTimeMs, positionMs <= endTimeMs {
                if firstActiveIndex < 0 {
                    firstActiveIndex = index
                }
                lastActiveIndex = index
            }
        }

        guard firstActiveIndex >= 0, lastActiveIndex >= 0 else { return nil }
        let targetPartIndex = (firstActiveIndex + lastActiveIndex + 1) / 2
        return vocalPartTargetID(lineIndex: lineIndex, line: line, partIndex: targetPartIndex)
    }

    private static func displayableVocalPartCount(_ parts: [LyricsLine.VocalPart]) -> Int {
        parts.reduce(0) { count, part in
            vocalPartDisplayText(part).trimmed.isEmpty ? count : count + 1
        }
    }

    private static func hasVocalPartSupplements(_ parts: [LyricsLine.VocalPart]) -> Bool {
        parts.contains { part in
            !part.pronunciationText.trimmed.isEmpty || !part.translationText.trimmed.isEmpty
        }
    }

    private static func hasTimedKaraokeData(_ line: LyricsLine) -> Bool {
        hasTimedSyllables(line.syllables) || line.vocalParts.contains { hasTimedSyllables($0.syllables) }
    }

    private static func hasTimedSyllables(_ syllables: [LyricsLine.Syllable]) -> Bool {
        syllables.contains { $0.endTimeMs > $0.startTimeMs }
    }

    private static func markerInterludeInfo(context: LyricsTimelineContext, line _: LyricsLine, index: Int, count _: Int) -> InterludeInfo? {
        context.markerInterludeInfos[index]
    }

    fileprivate static func markerInterludeInfos(
        lines: [LyricsLine],
        isMarker: [Bool],
        markerIndices: [Int]
    ) -> [InterludeInfo?] {
        var result = Array<InterludeInfo?>(repeating: nil, count: lines.count)
        let count = lines.count
        for index in markerIndices {
            let line = lines[index]
            guard line.isTimed else { continue }
            var nextStart: Int64 = 0
            if index + 1 < count {
                for nextIndex in (index + 1)..<count {
                    let candidate = lines[nextIndex]
                    guard candidate.isTimed else { continue }
                    if isMarker[nextIndex] { continue }
                    nextStart = candidate.startTimeMs
                    break
                }
            }
            let end = max(line.endTimeMs, nextStart)
            let minimumDurationMs: Int64 = InstrumentalBreakMarker.isMusicNoteMarkerText(candidateText(line))
                ? 0
                : interludeMinDurationMs
            guard end - line.startTimeMs > minimumDurationMs else { continue }
            result[index] = InterludeInfo(
                startTimeMs: line.startTimeMs,
                endTimeMs: end,
                kind: instrumentalKind(index: index, count: count),
                automatic: false
            )
        }
        return result
    }

    private static func hasActiveInterlude(
        context: LyricsTimelineContext,
        positionMs: Int64,
        trackDurationMs: Int64,
        autoInstrumentalBreakEnabled: Bool
    ) -> Bool {
        for index in context.markerIndices {
            if let info = context.markerInterludeInfos[index], contains(info, positionMs) {
                return true
            }
        }
        guard autoInstrumentalBreakEnabled else { return false }
        let lines = context.lines
        let count = lines.count
        for index in lines.indices {
            if trailingInterludeInfo(
                context: context,
                line: lines[index],
                index: index,
                count: count,
                positionMs: positionMs,
                trackDurationMs: trackDurationMs,
                autoInstrumentalBreakEnabled: true
            ) != nil {
                return true
            }
        }
        return false
    }

    private static func trailingInterludeInfo(
        context: LyricsTimelineContext,
        line: LyricsLine,
        index: Int,
        count: Int,
        positionMs: Int64,
        trackDurationMs: Int64,
        autoInstrumentalBreakEnabled: Bool
    ) -> InterludeInfo? {
        guard autoInstrumentalBreakEnabled,
              line.isTimed,
              !context.isMarker[index],
              !hasRenderableInterludeMarkerBeforeNextRenderableLine(context: context, index: index, count: count) else {
            return nil
        }
        let lyricEnd = context.precedingLyricEndTimes[index]
        guard lyricEnd >= 0 else { return nil }
        let start = lyricEnd + trailingInterludeDelayMs
        let nextStart = nextRenderableLineStartAfter(context: context, index: index)
        let end = nextStart > start ? nextStart : (index >= max(0, count - 1) ? trackDurationMs : 0)
        guard end - start > interludeMinDurationMs else { return nil }
        let info = InterludeInfo(startTimeMs: start, endTimeMs: end, kind: nextStart > 0 ? "break" : "postlude", automatic: true)
        return contains(info, positionMs) ? info : nil
    }

    private static func previewPreludeInfo(context: LyricsTimelineContext, positionMs: Int64) -> InterludeInfo? {
        guard let firstIndex = firstRenderableLineIndex(context: context) else { return nil }
        let firstLine = context.lines[firstIndex]
        guard firstLine.isTimed, positionMs < firstLine.startTimeMs else { return nil }
        let info = InterludeInfo(startTimeMs: 0, endTimeMs: firstLine.startTimeMs, kind: "prelude", automatic: false)
        guard info.endTimeMs - info.startTimeMs > interludeMinDurationMs else { return nil }
        return info
    }

    private static func previewTrailingInterludeInfo(
        context: LyricsTimelineContext,
        positionMs: Int64,
        trackDurationMs: Int64,
        autoInstrumentalBreakEnabled: Bool
    ) -> InterludeInfo? {
        guard autoInstrumentalBreakEnabled else { return nil }
        let lines = context.lines
        let count = lines.count
        for index in lines.indices {
            let line = lines[index]
            guard line.isTimed, !context.isMarker[index] else { continue }
            let lyricEnd = context.precedingLyricEndTimes[index]
            guard lyricEnd >= 0 else { continue }
            let start = lyricEnd + trailingInterludeDelayMs
            let nextStart = nextRenderableLineStartAfter(context: context, index: index)
            let end = nextStart > start ? nextStart : (index >= max(0, count - 1) ? trackDurationMs : 0)
            guard end - start > interludeMinDurationMs else { continue }
            let info = InterludeInfo(startTimeMs: start, endTimeMs: end, kind: nextStart > 0 ? "break" : "postlude", automatic: true)
            if contains(info, positionMs) {
                return info
            }
        }
        return nil
    }

    private static func firstRenderableLineIndex(context: LyricsTimelineContext) -> Int? {
        context.firstRenderableLineIndex
    }

    private static func nextRenderableLineStartAfter(context: LyricsTimelineContext, index: Int) -> Int64 {
        for nextIndex in (index + 1)..<context.lines.count {
            let candidate = context.lines[nextIndex]
            guard candidate.isTimed else { continue }
            if context.isMarker[nextIndex] { continue }
            return candidate.startTimeMs
        }
        return 0
    }

    private static func hasRenderableInterludeMarkerBeforeNextRenderableLine(context: LyricsTimelineContext, index: Int, count: Int) -> Bool {
        for nextIndex in (index + 1)..<context.lines.count {
            let candidate = context.lines[nextIndex]
            guard candidate.isTimed else { continue }
            if !context.isMarker[nextIndex] { return false }
            if markerInterludeInfo(context: context, line: candidate, index: nextIndex, count: count) != nil {
                return true
            }
        }
        return false
    }

    fileprivate static func lastLyricEndTime(_ line: LyricsLine) -> Int64 {
        var lastEnd = maxSyllableEnd(line.syllables, fallbackLineEndMs: line.endTimeMs)
        for part in line.vocalParts {
            lastEnd = max(lastEnd, maxSyllableEnd(part.syllables, fallbackLineEndMs: line.endTimeMs))
        }
        if lastEnd >= 0 { return lastEnd }
        return line.endTimeMs > line.startTimeMs ? line.endTimeMs : -1
    }

    fileprivate static func queryBoundaries(
        lines: [LyricsLine], markers: [InterludeInfo?], lyricEndTimes: [Int64]?
    ) -> [Int64] {
        // Structural items change only at starts, marker edges and automatic-break
        // starts. The cache key also splits at the current track duration.
        var boundaries: [Int64] = [0]
        for index in lines.indices {
            boundaries.append(lines[index].startTimeMs)
            if let marker = markers[index] {
                boundaries.append(marker.startTimeMs)
                boundaries.append(marker.endTimeMs)
            }
            let end = lyricEndTimes?[index] ?? lastLyricEndTime(lines[index])
            boundaries.append(max(lines[index].endTimeMs, end))
            let (breakStart, overflow) = end.addingReportingOverflow(trailingInterludeDelayMs)
            if end >= 0, !overflow { boundaries.append(breakStart) }
        }
        return boundaries
    }

    private static func maxSyllableEnd(_ syllables: [LyricsLine.Syllable], fallbackLineEndMs: Int64) -> Int64 {
        var lastEnd: Int64 = -1
        for syllable in syllables {
            let end = syllable.endTimeMs > syllable.startTimeMs ? syllable.endTimeMs : fallbackLineEndMs
            if end >= syllable.startTimeMs {
                lastEnd = max(lastEnd, end)
            }
        }
        return lastEnd
    }

    private static func instrumentalKind(index: Int, count: Int) -> String {
        if index == 0 { return "prelude" }
        if index == max(0, count - 1) { return "postlude" }
        return "break"
    }

    static func candidateText(_ line: LyricsLine) -> String {
        if !line.text.trimmed.isEmpty { return line.text }
        return line.vocalParts.map(\.text).joined()
    }

    static func isInterludeMarkerText(_ text: String) -> Bool {
        InstrumentalBreakMarker.isMarkerText(text)
    }

    private static func contains(_ info: InterludeInfo, _ positionMs: Int64) -> Bool {
        positionMs >= info.startTimeMs && positionMs < info.endTimeMs
    }

    private static func hasOverlap(_ items: [LyricsTimelineDisplayItem], _ info: InterludeInfo) -> Bool {
        items.contains { item in
            guard case .interlude(let existing) = item else { return false }
            return existing.startTimeMs < info.endTimeMs && info.startTimeMs < existing.endTimeMs
        }
    }
}

struct LyricsInterludeView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.playbackAdvancing) private var playbackAdvancing
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    var info: InterludeInfo
    var active: Bool
    var displayDistance: Double
    var showLabel: Bool
    var alignment: String
    var isExitOverlay = false

    var body: some View {
        HStack(spacing: 10) {
            if alignment == "right" { Spacer(minLength: 0) }
            interludeBars
            if showLabel {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(interludeColor)
            }
            if alignment != "right" { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .opacity(InterludeTransition.entryOpacity(positionMs: model.adjustedContinuousPositionMs, startMs: info.startTimeMs,
            enabled: !isExitOverlay && settings.syncedLyricsKaraokeAnimationEnabled && !accessibilityReduceMotion))
        .accessibilityLabel(label)
        .contentShape(Rectangle())
        .onTapGesture {
            seek(to: info.startTimeMs)
        }
    }

    private var interludeBars: some View {
        // Display rate while playback runs; the previous 1/60 s cadence while it is paused.
        TimelineView(.animation(minimumInterval: playbackAdvancing ? nil : 1.0 / 60.0,
                                paused: !active || !playbackAdvancing || accessibilityReduceMotion || !settings.syncedLyricsKaraokeAnimationEnabled)) { timeline in
#if DEBUG && os(iOS)
            let _ = debugProbeTimeline(.interludeBarsTick, timeline.date)
#endif
            let nowMs = timeline.date.timeIntervalSinceReferenceDate * 1_000
            HStack(spacing: 3.8) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2.25)
                        .fill(interludeColor)
                        .frame(
                            width: 3.2,
                            height: active && !accessibilityReduceMotion && settings.syncedLyricsKaraokeAnimationEnabled
                                ? interludeBarHeight(index: index, nowMs: nowMs, minimum: 7, maximum: 23)
                                : 11
                        )
                }
            }
        }
        .frame(height: 23, alignment: .center)
    }

    private var label: String {
        switch info.kind {
        case "prelude": return settings.t("interlude.prelude")
        case "postlude": return settings.t("interlude.postlude")
        default: return settings.t("interlude.break")
        }
    }

    private func seek(to positionMs: Int64) {
        model.seek(toLyricsTimeMs: positionMs)
    }

    private var interludeColor: Color {
        if active {
            return Color(red: 245 / 255, green: 247 / 255, blue: 252 / 255)
        }
        let alpha = max(52.0, (150.0 - min(2.6, max(0, displayDistance)) * 34.0).rounded())
        return Color(red: 212 / 255, green: 218 / 255, blue: 230 / 255).opacity(alpha / 255.0)
    }
}

struct LyricsLineView: View, Equatable {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.originalLyricsVisible) private var originalLyricsVisible
    var lineIndex: Int
    var line: LyricsLine
    var originalText: String
    var culturalAnnotations: [CulturalAnnotation] = []
    var active: Bool
    var animationActive: Bool
    var completedColorOpacity: CGFloat
    var displayDistance: Double
    var progress: Double
    var positionMs: Int64
    /// Set only while the row follows the clock (see SyllableKaraokeText.continuousPositionMs).
    var continuousPositionMs: Double? = nil
    var alignment: String
    var pronunciationLoading: Bool
    var translationLoading: Bool
    var typography: AppSettings.TypographySettings
    var speakerColors: AppSettings.SpeakerColorSettings
    var onSeek: (Int64) -> Void

    static func == (lhs: LyricsLineView, rhs: LyricsLineView) -> Bool {
        // onSeek is intentionally excluded because the parent provides a stable seek contract.
        lhs.lineIndex == rhs.lineIndex
            && lhs.line == rhs.line
            && lhs.originalText == rhs.originalText
            && lhs.culturalAnnotations == rhs.culturalAnnotations
            && lhs.active == rhs.active
            && lhs.animationActive == rhs.animationActive
            && lhs.completedColorOpacity == rhs.completedColorOpacity
            && lhs.displayDistance == rhs.displayDistance
            && lhs.progress == rhs.progress
            && lhs.positionMs == rhs.positionMs
            && lhs.continuousPositionMs == rhs.continuousPositionMs
            && lhs.alignment == rhs.alignment
            && lhs.pronunciationLoading == rhs.pronunciationLoading
            && lhs.translationLoading == rhs.translationLoading
            && lhs.typography == rhs.typography
            && lhs.speakerColors == rhs.speakerColors
    }

    var body: some View {
#if DEBUG && os(iOS)
        let _ = debugProbeCount(.lineBody)
#endif
        let orderedVocalParts = LyricsTimelineDisplayBuilder.orderedVocalParts(line.vocalParts)
        let displayVocalParts = LyricsTimelineDisplayBuilder.displayableVocalParts(orderedVocalParts)
        let linePronunciationText = distinctPronunciation(line.pronunciationText, original: originalText)
        let useVocalPartSupplements = LyricsTimelineDisplayBuilder.shouldUseVocalPartSupplements(
            orderedParts: orderedVocalParts
        )
        VStack(alignment: stackAlignment, spacing: 4) {
            originalLyricsView(
                displayVocalParts: displayVocalParts,
                useVocalPartSupplements: useVocalPartSupplements
            )
                .font(typography.font(slotId: AppSettings.typoLyricsOriginal, baseSize: 25))
            if !useVocalPartSupplements, !linePronunciationText.isEmpty {
                fadingSupplementText(
                    linePronunciationText,
                    slotId: AppSettings.typoLyricsPronunciation,
                    baseSize: 14,
                    activeColor: lineActiveColor.opacity(212.0 / 255.0),
                    inactiveColor: lineSupplementInactiveColor
                )
            } else if !useVocalPartSupplements, pronunciationLoading {
                supplementReserveText(LyricsTimelineDisplayBuilder.supplementPlaceholderText(line), slotId: AppSettings.typoLyricsPronunciation, baseSize: 14)
            }
            if !useVocalPartSupplements, !line.translationText.trimmed.isEmpty {
                fadingSupplementText(
                    line.translationText,
                    slotId: AppSettings.typoLyricsTranslation,
                    baseSize: 14,
                    activeColor: lineActiveColor.opacity(184.0 / 255.0),
                    inactiveColor: lineSupplementInactiveColor
                )
            } else if !useVocalPartSupplements, translationLoading {
                supplementReserveText(LyricsTimelineDisplayBuilder.supplementPlaceholderText(line), slotId: AppSettings.typoLyricsTranslation, baseSize: 14)
            }
            ForEach(Array(culturalAnnotations.enumerated()), id: \.element.id) { index, annotation in
                Text("\(index + 1). \(annotation.note)")
                    .font(culturalAnnotationFont)
                    .foregroundStyle(.white.opacity(Double(settings.culturalAnnotationsOpacity) / 100))
                    .multilineTextAlignment(textAlignment)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            seekToLine()
        }
    }

    private var textAlignment: TextAlignment {
        alignment == "center" ? .center : (alignment == "right" ? .trailing : .leading)
    }

    private var stackAlignment: HorizontalAlignment {
        alignment == "center" ? .center : (alignment == "right" ? .trailing : .leading)
    }

    private var frameAlignment: Alignment {
        alignment == "center" ? .center : (alignment == "right" ? .trailing : .leading)
    }

    private func seekToLine() {
        guard line.isTimed else { return }
        onSeek(line.startTimeMs)
    }

    @ViewBuilder
    private func originalLyricsView(
        displayVocalParts: [LyricsLine.VocalPart],
        useVocalPartSupplements: Bool
    ) -> some View {
        if !displayVocalParts.isEmpty {
            VStack(alignment: stackAlignment, spacing: 0) {
                ForEach(displayVocalParts.indices, id: \.self) { index in
                    let part = displayVocalParts[index]
                    let partActive = active && positionMs >= part.startTimeMs
                    let partAnimating = animationActive
                        && positionMs >= part.startTimeMs
                        && positionMs < max(part.endTimeMs, part.startTimeMs) + 820
                    VStack(alignment: stackAlignment, spacing: 2) {
                        if originalLyricsVisible {
                        SyllableKaraokeText(
                            text: LyricsTimelineDisplayBuilder.vocalPartDisplayText(part),
                            rubyText: settings.japaneseFuriganaEnabled ? part.furiganaText : "",
                            syllables: shouldRenderTimedKaraoke ? part.syllables : [],
                            displayGranularity: settings.karaokeDisplayGranularity,
                            culturalAnnotations: culturalAnnotations,
                            startTimeMs: part.startTimeMs,
                            endTimeMs: part.endTimeMs,
                            positionMs: positionMs,
                            continuousPositionMs: continuousPositionMs,
                            active: partAnimating,
                            completedColorOpacity: completedColorOpacity,
                            activeColor: vocalPartActiveColor(part),
                            alignment: textAlignment,
                            kind: part.kind,
                            speakerColors: speakerColors,
                            useCreatorSpeakerColors: settings.useSyncCreatorSpeakerColors,
                            speakerColorDistance: displayDistance + (partActive ? 0 : 0.45),
                            inactiveColor: vocalPartInactiveColor(part, active: partActive),
                            bounceEnabled: settings.karaokeBounceEffectEnabled,
                            bounceTextSize: typography.scaledSize(slotId: AppSettings.typoLyricsOriginal, baseSize: active ? 25 : 21),
                            effectRowSeed: index
                        )
                        .id(LyricsTimelineDisplayBuilder.vocalPartTargetID(lineIndex: lineIndex, line: line, partIndex: index))
                        }
                        if useVocalPartSupplements {
                            vocalPartSupplements(part, active: partActive)
                        }
                    }
                    .padding(.top, vocalPartTopSpacing(index: index, parts: displayVocalParts))
                }
            }
        } else if originalLyricsVisible, shouldRenderTimedKaraoke {
            SyllableKaraokeText(
                text: originalText.isEmpty ? " " : originalText,
                rubyText: settings.japaneseFuriganaEnabled ? line.furiganaText : "",
                syllables: line.syllables,
                displayGranularity: settings.karaokeDisplayGranularity,
                culturalAnnotations: culturalAnnotations,
                startTimeMs: line.startTimeMs,
                endTimeMs: line.endTimeMs,
                positionMs: positionMs,
                continuousPositionMs: continuousPositionMs,
                active: animationActive,
                completedColorOpacity: completedColorOpacity,
                activeColor: lineActiveColor,
                alignment: textAlignment,
                kind: line.kind,
                speakerColors: speakerColors,
                useCreatorSpeakerColors: settings.useSyncCreatorSpeakerColors,
                speakerColorDistance: displayDistance,
                inactiveColor: inactiveOriginalColor,
                bounceEnabled: settings.karaokeBounceEffectEnabled,
                bounceTextSize: typography.scaledSize(slotId: AppSettings.typoLyricsOriginal, baseSize: active ? 25 : 21)
            )
        } else if originalLyricsVisible, settings.syncedLyricsKaraokeAnimationEnabled {
            SyllableKaraokeText(
                text: originalText.isEmpty ? " " : originalText,
                rubyText: settings.japaneseFuriganaEnabled ? line.furiganaText : "",
                syllables: [],
                displayGranularity: settings.karaokeDisplayGranularity,
                culturalAnnotations: culturalAnnotations,
                startTimeMs: line.startTimeMs,
                endTimeMs: line.endTimeMs,
                positionMs: positionMs,
                continuousPositionMs: continuousPositionMs,
                active: animationActive,
                completedColorOpacity: completedColorOpacity,
                activeColor: lineActiveColor,
                alignment: textAlignment,
                kind: line.kind,
                speakerColors: speakerColors,
                useCreatorSpeakerColors: settings.useSyncCreatorSpeakerColors,
                speakerColorDistance: displayDistance,
                inactiveColor: inactiveOriginalColor,
                bounceEnabled: settings.karaokeBounceEffectEnabled,
                bounceTextSize: typography.scaledSize(slotId: AppSettings.typoLyricsOriginal, baseSize: active ? 25 : 21),
                syntheticTimingEnabled: true
            )
        } else if originalLyricsVisible {
            SyllableKaraokeText(
                text: originalText.isEmpty ? " " : originalText,
                rubyText: settings.japaneseFuriganaEnabled ? line.furiganaText : "",
                syllables: [],
                displayGranularity: settings.karaokeDisplayGranularity,
                culturalAnnotations: culturalAnnotations,
                startTimeMs: line.startTimeMs,
                endTimeMs: line.endTimeMs,
                positionMs: positionMs,
                continuousPositionMs: continuousPositionMs,
                active: animationActive,
                completedColorOpacity: completedColorOpacity,
                activeColor: lineActiveColor,
                alignment: textAlignment,
                kind: line.kind,
                speakerColors: speakerColors,
                useCreatorSpeakerColors: settings.useSyncCreatorSpeakerColors,
                speakerColorDistance: displayDistance,
                inactiveColor: inactiveOriginalColor
            )
        }
    }

    private func vocalPartTopSpacing(index: Int, parts: [LyricsLine.VocalPart]) -> CGFloat {
        guard index > 0, parts.indices.contains(index) else { return 0 }
        if settings.japaneseFuriganaEnabled, parts[index].furiganaText.contains("<ruby>") {
            return 8
        }
        return 4
    }

    @ViewBuilder
    private func vocalPartSupplements(_ part: LyricsLine.VocalPart, active: Bool) -> some View {
        let speakerColor = vocalPartActiveColor(part)
        let inactiveColor = vocalPartSupplementInactiveColor(part, active: active)
        let pronunciationText = distinctPronunciation(
            part.pronunciationText,
            original: LyricsTimelineDisplayBuilder.vocalPartDisplayText(part)
        )
        if !pronunciationText.isEmpty {
            fadingSupplementText(
                pronunciationText,
                slotId: AppSettings.typoLyricsPronunciation,
                baseSize: active ? 14 : 12.5,
                activeColor: speakerColor.opacity(212.0 / 255.0),
                inactiveColor: inactiveColor
            )
        } else if pronunciationLoading {
            supplementReserveText(LyricsTimelineDisplayBuilder.supplementPlaceholderText(part), slotId: AppSettings.typoLyricsPronunciation, baseSize: active ? 14 : 12.5)
        }
        if !part.translationText.trimmed.isEmpty {
            fadingSupplementText(
                part.translationText,
                slotId: AppSettings.typoLyricsTranslation,
                baseSize: active ? 14 : 12.5,
                activeColor: speakerColor.opacity(184.0 / 255.0),
                inactiveColor: inactiveColor
            )
        } else if translationLoading {
            supplementReserveText(LyricsTimelineDisplayBuilder.supplementPlaceholderText(part), slotId: AppSettings.typoLyricsTranslation, baseSize: active ? 14 : 12.5)
        }
    }

    private func distinctPronunciation(_ value: String, original: String) -> String {
        let pronunciation = value.trimmed
        guard !pronunciation.isEmpty,
              !IvLyricsUtilities.lyricsTextsEquivalent(pronunciation, original) else {
            return ""
        }
        return pronunciation
    }

    private func fadingSupplementText(
        _ text: String,
        slotId: String,
        baseSize: CGFloat,
        activeColor: Color,
        inactiveColor: Color
    ) -> some View {
        let font = typography.font(slotId: slotId, baseSize: baseSize)
        return Text(text)
            .font(font)
            .foregroundStyle(inactiveColor)
            .overlay {
                Text(text)
                    .font(font)
                    .foregroundStyle(activeColor)
                    .opacity(completedColorOpacity)
            }
            .multilineTextAlignment(textAlignment)
    }

    private func supplementReserveText(_ text: String, slotId: String, baseSize: CGFloat) -> some View {
        Text(text)
            .font(typography.font(slotId: slotId, baseSize: baseSize))
            .foregroundStyle(.clear)
            .multilineTextAlignment(textAlignment)
            .accessibilityHidden(true)
    }

    private var shouldRenderTimedKaraoke: Bool {
        !settings.karaokeDataAsLineSynced && hasTimedSyllables(line.syllables)
            || !settings.karaokeDataAsLineSynced && line.vocalParts.contains { hasTimedSyllables($0.syllables) }
    }

    private func hasTimedSyllables(_ syllables: [LyricsLine.Syllable]) -> Bool {
        syllables.contains { $0.endTimeMs > $0.startTimeMs }
    }

    private var culturalAnnotationFont: Font {
        let size = CGFloat(AppSettings.clampCulturalFontSize(settings.culturalAnnotationsFontSize))
        let weight = culturalAnnotationFontWeight
        switch AppSettings.normalizeCulturalFontFamily(settings.culturalAnnotationsFontFamily) {
        case "system":
            return .system(size: size, weight: weight)
        case "serif":
            return .system(size: size, weight: weight, design: .serif)
        case "monospace":
            return .system(size: size, weight: weight, design: .monospaced)
        default:
            return .custom("Pretendard-Regular", size: size).weight(weight)
        }
    }

    private var culturalAnnotationFontWeight: Font.Weight {
        switch AppSettings.clampCulturalFontWeight(settings.culturalAnnotationsFontWeight) {
        case ...200: return .ultraLight
        case 300: return .light
        case 400: return .regular
        case 500: return .medium
        case 600: return .semibold
        case 700: return .bold
        case 800: return .heavy
        default: return .black
        }
    }

    private var lineActiveColor: Color {
        LyricSpeakerPalette.activeColor(
            speaker: line.speaker,
            speakerColor: line.speakerColor,
            speakerFallback: line.speakerFallback,
            settings: speakerColors,
            useCreatorColors: settings.useSyncCreatorSpeakerColors
        )
    }

    private func vocalPartActiveColor(_ part: LyricsLine.VocalPart) -> Color {
        LyricSpeakerPalette.activeColor(
            speaker: part.speaker,
            speakerColor: part.speakerColor,
            speakerFallback: part.speakerFallback,
            settings: speakerColors,
            useCreatorColors: settings.useSyncCreatorSpeakerColors
        )
    }

    private func vocalPartInactiveColor(_ part: LyricsLine.VocalPart, active: Bool) -> Color {
        LyricSpeakerPalette.inactiveColor(
            speaker: part.speaker,
            speakerColor: part.speakerColor,
            speakerFallback: part.speakerFallback,
            settings: speakerColors,
            useCreatorColors: settings.useSyncCreatorSpeakerColors,
            distance: displayDistance + (active ? 0 : 0.45)
        )
    }

    private var lineSupplementInactiveColor: Color {
        LyricSpeakerPalette.supplementInactiveColor(
            speaker: line.speaker,
            speakerColor: line.speakerColor,
            speakerFallback: line.speakerFallback,
            settings: speakerColors,
            useCreatorColors: settings.useSyncCreatorSpeakerColors,
            distance: displayDistance
        )
    }

    private func vocalPartSupplementInactiveColor(_ part: LyricsLine.VocalPart, active: Bool) -> Color {
        LyricSpeakerPalette.supplementInactiveColor(
            speaker: part.speaker,
            speakerColor: part.speakerColor,
            speakerFallback: part.speakerFallback,
            settings: speakerColors,
            useCreatorColors: settings.useSyncCreatorSpeakerColors,
            distance: displayDistance + (active ? 0 : 0.45)
        )
    }

    private var inactiveOriginalColor: Color {
        LyricSpeakerPalette.inactiveColor(
            speaker: line.speaker,
            speakerColor: line.speakerColor,
            speakerFallback: line.speakerFallback,
            settings: speakerColors,
            useCreatorColors: settings.useSyncCreatorSpeakerColors,
            distance: displayDistance
        )
    }
}

struct SyllableKaraokeText: View {
    @State private var preparationCache = KaraokeRenderPreparationCache()
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.lyricsSegmentationLocale) private var lyricsSegmentationLocale
    var text: String
    var rubyText: String = ""
    var syllables: [LyricsLine.Syllable]
    var displayGranularity: String = AppSettings.karaokeDisplayCharacter
    var culturalAnnotations: [CulturalAnnotation] = []
    var startTimeMs: Int64
    var endTimeMs: Int64
    var positionMs: Int64
    /// Unrounded position for the frame being painted. Discrete glyph states (pending, active,
    /// done) still come from positionMs; the fill edge and bounce follow this value so they
    /// advance on every display frame. nil (PiP, previews) paints from positionMs.
    var continuousPositionMs: Double? = nil
    var active: Bool
    var completedColorOpacity: CGFloat = 1
    var activeColor: Color
    var alignment: TextAlignment
    var kind: String = "vocal"
    var speakerColors: AppSettings.SpeakerColorSettings = .defaults
    var useCreatorSpeakerColors: Bool = true
    var speakerColorDistance: Double = 0
    var inactiveOpacity: Double = 0.46
    var inactiveColor: Color? = nil
    var bounceEnabled: Bool = false
    var bounceTextSize: CGFloat = 22
    var syntheticTimingEnabled: Bool = false
    var effectRowSeed: Int = 0
    var singleLine: Bool = false
    var sharedPreparationCache: KaraokeRenderPreparationCache? = nil

    var body: some View {
        let displayKind = normalizedKind
        TimelineView(.animation(paused: accessibilityReduceMotion || !requiresContinuousEffect(displayKind))) { timeline in
            karaokeBody(
                nowMs: accessibilityReduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate * 1_000,
                displayKind: displayKind
            )
        }
    }

    @ViewBuilder
    private func karaokeBody(nowMs: Double, displayKind: String) -> some View {
#if DEBUG && os(iOS)
        let _ = debugProbeCount(.karaokeBody)
#endif
        let segments = karaokeSegments
        Group {
            if segments.isEmpty {
                Text(CulturalAnnotation.annotateText(
                    text.isEmpty ? " " : text,
                    annotations: culturalAnnotations
                ))
                    .foregroundStyle(fallbackColor)
                    .multilineTextAlignment(alignment)
                    .modifier(LyricGlyphEffectModifier(kind: displayKind, active: active, nowMs: nowMs, textSize: bounceTextSize, segmentIndex: 0, rowSeed: effectRowSeed, color: activeColor))
                    .modifier(LyricLineMotionModifier(kind: displayKind, active: active, nowMs: nowMs, textSize: bounceTextSize, rowSeed: effectRowSeed))
            } else if LyricsTextShaping.requiresContinuousShaping(text) {
                Text(continuouslyShapedText(segments, activeLayer: false))
                    .overlay {
                        Text(continuouslyShapedText(segments, activeLayer: true))
                            .opacity(completedColorOpacity)
                    }
                    .multilineTextAlignment(alignment)
                    .lineLimit(singleLine ? 1 : nil)
                    .fixedSize(horizontal: singleLine, vertical: false)
                    .modifier(LyricGlyphEffectModifier(kind: displayKind, active: active, nowMs: nowMs, textSize: bounceTextSize, segmentIndex: 0, rowSeed: effectRowSeed, color: activeColor))
                    .modifier(LyricLineMotionModifier(kind: displayKind, active: active, nowMs: nowMs, textSize: bounceTextSize, rowSeed: effectRowSeed))
                    .accessibilityLabel(text)
            } else {
                KaraokeSegmentFlowLayout(alignment: alignment, wraps: !singleLine) {
                    ForEach(segments) { segment in
                        KaraokeSyllableSegmentView(
                            segment: segment,
                            kind: segment.kind,
                            active: active,
                            nowMs: nowMs,
                            textSize: bounceTextSize,
                            rowSeed: effectRowSeed
                        )
                    }
                }
                .modifier(LyricLineMotionModifier(kind: hasInlineEffects ? "vocal" : displayKind, active: active, nowMs: nowMs, textSize: bounceTextSize, rowSeed: effectRowSeed))
                .accessibilityLabel(text)
            }
        }
    }

    private func continuouslyShapedText(
        _ segments: [KaraokeSyllableSegment],
        activeLayer: Bool
    ) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            var run = AttributedString(segment.text)
            run.foregroundColor = activeLayer && segment.fill > 0
                ? segment.activeColor
                : segment.baseColor
            result.append(run)
        }
        return result
    }

    private var karaokeSegments: [KaraokeSyllableSegment] {
        let prepared = preparedKaraoke
        let annotations = prepared.annotations
        let fillTimings = prepared.fillTimings
        let displaySyllables = prepared.display
        var timedSegments: [KaraokeSyllableSegment] = []
        timedSegments.reserveCapacity(displaySyllables.count)
        for (index, syllable) in displaySyllables.enumerated() {
            let fillTiming = fillTimings.indices.contains(index)
                ? fillTimings[index]
                : KaraokeSyllableTimingNormalizer.FillTiming(
                    startTimeMs: syllable.startTimeMs,
                    endTimeMs: syllable.endTimeMs
            )
            guard !syllable.text.isEmpty else { continue }
            let metadata = prepared.displayMetadata[index]
            let bounce = karaokeBounce(profile: prepared.motionProfiles.indices.contains(index)
                ? prepared.motionProfiles[index] : nil)
            timedSegments.append(KaraokeSyllableSegment(
                id: index,
                text: syllable.text,
                rubyText: metadata.rubyText,
                fill: fillFraction(
                    startTimeMs: fillTiming.startTimeMs,
                    endTimeMs: fillTiming.endTimeMs
                ),
                baseColor: segmentBaseColor(for: syllable),
                activeColor: segmentActiveColor(for: syllable),
                kind: segmentKind(for: syllable),
                bounceOffsetY: bounce.offsetY,
                bounceScale: bounce.scale,
                completedColorOpacity: completedColorOpacity,
                isWhitespace: metadata.isWhitespace
            ))
        }
#if DEBUG && os(iOS)
        if DebugFrameProbe.shared.recording, !timedSegments.isEmpty {
            DebugFrameProbe.shared.recordFill(
                singleLine: singleLine, active: active, lineStart: startTimeMs, lineEnd: endTimeMs,
                position: paintPositionMs,
                fill: timedSegments.reduce(0) { $0 + Double($1.fill) },
                bounce: timedSegments.map { Double($0.bounceOffsetY) }.min() ?? 0
            )
        }
#endif
        if !timedSegments.isEmpty {
            return timedSegments
        }
        return addingCulturalMarkers(to: untimedRubySegments(annotations: annotations))
    }

    private func untimedRubySegments(annotations: [FuriganaRepository.RubyAnnotation]) -> [KaraokeSyllableSegment] {
        guard !annotations.isEmpty else { return [] }
        let characters = text.map(String.init)
        guard !characters.isEmpty else { return [] }
        let color = active ? activeColor : baseColor
        var result: [KaraokeSyllableSegment] = []
        var cursor = 0
        var nextID = 0

        func append(_ value: String, ruby: String = "") {
            guard !value.isEmpty else { return }
            result.append(KaraokeSyllableSegment(
                id: nextID,
                text: value,
                rubyText: ruby,
                fill: 0,
                baseColor: color,
                activeColor: activeColor,
                kind: normalizedKind,
                bounceOffsetY: 0,
                bounceScale: 1,
                completedColorOpacity: completedColorOpacity,
                isWhitespace: value.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
            ))
            nextID += 1
        }

        for annotation in annotations.sorted(by: { $0.start < $1.start }) {
            let start = max(cursor, min(characters.count, annotation.start))
            let end = max(start, min(characters.count, annotation.end))
            if cursor < start {
                for character in characters[cursor..<start] {
                    append(character)
                }
            }
            if start < end {
                append(characters[start..<end].joined(), ruby: annotation.reading)
                cursor = end
            }
        }
        if cursor < characters.count {
            for character in characters[cursor...] {
                append(character)
            }
        }
        return result
    }

    private func addingCulturalMarkers(
        to segments: [KaraokeSyllableSegment]
    ) -> [KaraokeSyllableSegment] {
        let markers = CulturalAnnotation.markerInsertions(
            in: text,
            annotations: culturalAnnotations
        )
        guard !markers.isEmpty, !segments.isEmpty else { return segments }
        var markerIndex = 0
        var sourceOffset = 0
        return segments.map { sourceSegment in
            var segment = sourceSegment
            let endOffset = sourceOffset + sourceSegment.text.count
            var localMarkers: [CulturalAnnotation.MarkerInsertion] = []
            while markerIndex < markers.count, markers[markerIndex].offset <= endOffset {
                let marker = markers[markerIndex]
                markerIndex += 1
                if marker.offset > sourceOffset {
                    localMarkers.append(marker)
                }
            }
            for marker in localMarkers.reversed() {
                let index = segment.text.index(
                    segment.text.startIndex,
                    offsetBy: marker.offset - sourceOffset
                )
                segment.text.insert(contentsOf: "[\(marker.number)]", at: index)
            }
            sourceOffset = endOffset
            return segment
        }
    }

    private var rubyAnnotations: [FuriganaRepository.RubyAnnotation] {
        FuriganaRepository.rubyAnnotations(text: text, markup: rubyText)
    }

    private var effectiveSyllables: [LyricsLine.Syllable] {
        if isLineDisplayGranularity {
            guard hasInlineStyles else { return [] }
            return syllables.filter { !$0.text.isEmpty }.map {
                $0.copying(startTimeMs: 0, endTimeMs: 0)
            }
        }
        let timed: [LyricsLine.Syllable]
        if syllables.contains(where: { $0.text.isEmpty }) {
            timed = syllables.filter { !$0.text.isEmpty }
        } else {
            timed = syllables
        }
        if !timed.isEmpty {
            return isWordDisplayGranularity
                ? KaraokeSyllableTimingNormalizer.groupedForWordDisplay(timed, locale: lyricsSegmentationLocale)
                : KaraokeSyllableTimingNormalizer.expandTimedChunks(timed)
        }
        guard syntheticTimingEnabled, endTimeMs > startTimeMs else { return [] }
        let characters = text.map(String.init)
        guard !characters.isEmpty else { return [] }
        let duration = endTimeMs - startTimeMs
        let synthetic = characters.enumerated().map { index, character in
            let start = startTimeMs + Int64((Double(duration) * Double(index) / Double(characters.count)).rounded())
            let end = startTimeMs + Int64((Double(duration) * Double(index + 1) / Double(characters.count)).rounded())
            return LyricsLine.Syllable(text: character, startTimeMs: start, endTimeMs: max(start, end))
        }
        return isWordDisplayGranularity
            ? KaraokeSyllableTimingNormalizer.groupedForWordDisplay(synthetic, locale: lyricsSegmentationLocale)
            : KaraokeSyllableTimingNormalizer.expandTimedChunks(synthetic)
    }

    private var fallbackColor: Color {
        active ? activeColor : baseColor
    }

    private var baseColor: Color {
        inactiveColor ?? activeColor.opacity(inactiveOpacity)
    }

    private var normalizedKind: String {
        let value = kind.trimmed.lowercased()
        return value.isEmpty ? "vocal" : value
    }

    private var hasInlineStyles: Bool {
        syllables.contains { $0.inlineStyle == true }
    }

    private var hasInlineEffects: Bool {
        let effectKinds: Set<String> = [
            "effect", "adlib", "pulse", "bounce", "sway", "float", "pop", "glitch",
            "wave", "sparkle", "echo", "whisper", "glow", "blur", "flicker"
        ]
        return syllables.contains {
            $0.inlineStyle == true
                && effectKinds.contains(($0.styleKind ?? "").trimmed.lowercased())
        }
    }

    private func segmentKind(for syllable: LyricsLine.Syllable) -> String {
        guard syllable.inlineStyle == true else { return normalizedKind }
        let value = (syllable.styleKind ?? "").trimmed.lowercased()
        return value.isEmpty ? normalizedKind : value
    }

    private func segmentActiveColor(for syllable: LyricsLine.Syllable) -> Color {
        guard syllable.inlineStyle == true,
              !(syllable.styleSpeaker ?? "").trimmed.isEmpty else {
            return activeColor
        }
        return LyricSpeakerPalette.activeColor(
            speaker: syllable.styleSpeaker ?? "",
            speakerColor: syllable.styleSpeakerColor ?? "",
            speakerFallback: syllable.styleSpeakerFallback ?? "",
            settings: speakerColors,
            useCreatorColors: useCreatorSpeakerColors
        )
    }

    private func segmentBaseColor(for syllable: LyricsLine.Syllable) -> Color {
        guard syllable.inlineStyle == true,
              !(syllable.styleSpeaker ?? "").trimmed.isEmpty else {
            return baseColor
        }
        return LyricSpeakerPalette.inactiveColor(
            speaker: syllable.styleSpeaker ?? "",
            speakerColor: syllable.styleSpeakerColor ?? "",
            speakerFallback: syllable.styleSpeakerFallback ?? "",
            settings: speakerColors,
            useCreatorColors: useCreatorSpeakerColors,
            distance: speakerColorDistance
        )
    }

    private var normalizedDisplayGranularity: String {
        AppSettings.normalizeKaraokeDisplayGranularity(displayGranularity)
    }

    private var isWordDisplayGranularity: Bool {
        normalizedDisplayGranularity == AppSettings.karaokeDisplayWord
    }

    private var isLineDisplayGranularity: Bool {
        normalizedDisplayGranularity == AppSettings.karaokeDisplayLine
    }

    private func requiresContinuousEffect(_ displayKind: String) -> Bool {
        let continuousKinds: Set<String> = [
            "effect", "adlib", "pulse", "bounce", "sway", "float", "pop", "glitch",
            "wave", "sparkle", "echo", "whisper", "glow", "blur", "flicker"
        ]
        let canRenderInlineEffects = !LyricsTextShaping.requiresContinuousShaping(text)
        return active && (continuousKinds.contains(displayKind) || (canRenderInlineEffects && syllables.contains {
            $0.inlineStyle == true && continuousKinds.contains(($0.styleKind ?? "").trimmed.lowercased())
        }))
    }

    private func fillFraction(startTimeMs: Int64, endTimeMs: Int64) -> CGFloat {
        // Retain the completed paint while the parent line moves and fades away.
        // Previously `active == false` reset every segment to its inactive color
        // in one frame at the line boundary.
        if endTimeMs > startTimeMs, positionMs >= endTimeMs {
            return 1
        }
        if isWordDisplayGranularity {
            return positionMs >= startTimeMs ? 1 : 0
        }
        if positionMs >= endTimeMs {
            return 1
        }
        if positionMs <= startTimeMs || endTimeMs <= startTimeMs {
            return 0
        }
        return min(1, max(0, CGFloat(paintPositionMs - Double(startTimeMs)) / CGFloat(endTimeMs - startTimeMs)))
    }

    private var paintPositionMs: Double {
        continuousPositionMs ?? Double(positionMs)
    }

    private var preparedKaraoke: KaraokeRenderPreparationCache.Value {
        let key = KaraokeRenderPreparationCache.Key(
            text: text, ruby: rubyText, syllables: syllables, granularity: normalizedDisplayGranularity,
            locale: lyricsSegmentationLocale, annotations: culturalAnnotations,
            start: startTimeMs, end: endTimeMs, synthetic: syntheticTimingEnabled
        )
        return (sharedPreparationCache ?? preparationCache).value(for: key) {
            let source = effectiveSyllables
            let timings = isWordDisplayGranularity
                ? source.map { KaraokeSyllableTimingNormalizer.FillTiming(startTimeMs: $0.startTimeMs, endTimeMs: $0.endTimeMs) }
                : KaraokeSyllableTimingNormalizer.latinWordFillTimings(source)
            let sourceUnits = (syllables.isEmpty ? source : syllables).map {
                KaraokeMotionProfile.Unit(text: $0.text, startMs: Double($0.startTimeMs), endMs: Double($0.endTimeMs))
            }
            let displayUnits = source.enumerated().map { index, syllable in
                KaraokeMotionProfile.Unit(text: syllable.text, startMs: Double(timings[index].startTimeMs), endMs: Double(timings[index].endTimeMs))
            }
            return KaraokeRenderPreparationCache.Value(
                source: source,
                display: CulturalAnnotation.annotateSyllables(text: text, syllables: source, annotations: culturalAnnotations),
                fillTimings: timings, annotations: rubyAnnotations,
                motionProfiles: KaraokeMotionProfile.prepare(source: sourceUnits, display: displayUnits)
            )
        }
    }

    private func karaokeBounce(profile: KaraokeMotionProfile?) -> KaraokeBounceMetrics {
        guard bounceEnabled, !accessibilityReduceMotion, let profile else { return .idle }
        let values = profile.values(positionMs: paintPositionMs, textSize: Double(bounceTextSize))
        return KaraokeBounceMetrics(offsetY: CGFloat(values.offsetY), scale: CGFloat(values.scale))
    }

}

/// One preparation per unchanged row. Position, focus, color and font changes do not
/// invalidate timing/text work; those remain render inputs so user settings stay live.
final class KaraokeRenderPreparationCache {
    struct Key: Equatable {
        var text: String
        var ruby: String
        var syllables: [LyricsLine.Syllable]
        var granularity: String
        var locale: String
        var annotations: [CulturalAnnotation]
        var start: Int64
        var end: Int64
        var synthetic: Bool
    }
    struct Value {
        var source: [LyricsLine.Syllable]
        var display: [LyricsLine.Syllable]
        var fillTimings: [KaraokeSyllableTimingNormalizer.FillTiming]
        var annotations: [FuriganaRepository.RubyAnnotation]
        var motionProfiles: [KaraokeMotionProfile?]
        var displayMetadata: [DisplayMetadata]

        init(
            source: [LyricsLine.Syllable],
            display: [LyricsLine.Syllable],
            fillTimings: [KaraokeSyllableTimingNormalizer.FillTiming],
            annotations: [FuriganaRepository.RubyAnnotation],
            motionProfiles: [KaraokeMotionProfile?]
        ) {
            self.source = source
            self.display = display
            self.fillTimings = fillTimings
            self.annotations = annotations
            self.motionProfiles = motionProfiles
            // Ruby overlap and whitespace depend on prepared text, not playback.
            // Preserve source offsets before cultural markers enlarge display text.
            var sourceOffset = 0
            self.displayMetadata = display.enumerated().map { index, syllable in
                let sourceLength = source.indices.contains(index)
                    ? source[index].text.count
                    : syllable.text.count
                defer { sourceOffset += sourceLength }
                return DisplayMetadata(
                    rubyText: syllable.text.isEmpty ? "" : Self.rubyReading(
                        start: sourceOffset, length: sourceLength, annotations: annotations
                    ),
                    isWhitespace: syllable.text.unicodeScalars.allSatisfy {
                        CharacterSet.whitespacesAndNewlines.contains($0)
                    }
                )
            }
        }

        private static func rubyReading(
            start: Int,
            length: Int,
            annotations: [FuriganaRepository.RubyAnnotation]
        ) -> String {
            guard length > 0 else { return "" }
            let end = start + length
            return annotations.compactMap { annotation in
                guard annotation.start < end, annotation.end > start else { return nil }
                let value = annotation.reading(overlapStart: start, overlapEnd: end)
                return value.isEmpty ? nil : value
            }.joined(separator: " ")
        }
    }
    struct DisplayMetadata {
        var rubyText: String
        var isWhitespace: Bool
    }
    private var key: Key?
    private var prepared: Value?

    func value(for next: Key, prepare: () -> Value) -> Value {
        if key == next, let prepared { return prepared }
#if DEBUG && os(iOS)
        MainActor.assumeIsolated { debugProbeCount(.preparationMiss) }
#endif
        let value = prepare()
        key = next
        prepared = value
        return value
    }
}

/// A PiP frame gets a fresh SwiftUI root. Keep expensive text/timing preparation
/// outside that root while retaining independent caches for simultaneous voices.
final class KaraokeRenderPreparationStore {
    private var rows = BoundedLRUCache<String, KaraokeRenderPreparationCache>(capacity: 32)

    func cache(for slot: String) -> KaraokeRenderPreparationCache {
        if let cached = rows.value(forKey: slot) { return cached }
        let cache = KaraokeRenderPreparationCache()
        rows.insert(cache, forKey: slot)
        return cache
    }

    func removeAll() { rows.removeAll() }
}

private struct KaraokeBounceMetrics {
    static let idle = KaraokeBounceMetrics(offsetY: 0, scale: 1)

    var offsetY: CGFloat
    var scale: CGFloat
}

private struct KaraokeSyllableSegment: Identifiable {
    var id: Int
    var text: String
    var rubyText: String = ""
    var fill: CGFloat
    var baseColor: Color
    var activeColor: Color
    var kind: String
    var bounceOffsetY: CGFloat
    var bounceScale: CGFloat
    var completedColorOpacity: CGFloat
    var isWhitespace: Bool
}

private struct KaraokeWhitespaceLayoutKey: LayoutValueKey {
    static let defaultValue = false
}

private struct KaraokeSyllableSegmentView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var segment: KaraokeSyllableSegment
    var kind: String
    var active: Bool
    var nowMs: Double
    var textSize: CGFloat
    var rowSeed: Int

    var body: some View {
#if DEBUG && os(iOS)
        let _ = debugProbeCount(.glyphBody)
#endif
        VStack(spacing: 0) {
            if !segment.rubyText.isEmpty {
                Text(segment.rubyText)
                    .font(.system(size: max(9, textSize * 0.42), weight: .semibold))
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.85 : 1)
                    .foregroundStyle(segment.baseColor.opacity(0.84))
                    .overlay {
                        if segment.fill > 0 {
                            Text(segment.rubyText)
                                .font(.system(size: max(9, textSize * 0.42), weight: .semibold))
                                .foregroundStyle(segment.activeColor.opacity(0.84 * segment.completedColorOpacity))
                        }
                    }
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Text(segment.text)
                .foregroundStyle(segment.baseColor)
                .overlay(alignment: .leading) {
                    if segment.fill > 0 {
                        Text(segment.text)
                            .foregroundStyle(segment.activeColor)
                            .opacity(segment.completedColorOpacity)
                            .mask(KaraokeFillMask(fill: segment.fill))
                            .allowsHitTesting(false)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
            .scaleEffect(segment.bounceScale, anchor: .bottom)
            .offset(y: segment.bounceOffsetY)
            .modifier(LyricGlyphEffectModifier(kind: kind, active: active, nowMs: nowMs, textSize: textSize, segmentIndex: segment.id, rowSeed: rowSeed, color: segment.activeColor))
            .layoutValue(key: KaraokeWhitespaceLayoutKey.self, value: segment.isWhitespace)
    }
}

private struct LyricLineMotionModifier: ViewModifier {
    var kind: String
    var active: Bool
    var nowMs: Double
    var textSize: CGFloat
    var rowSeed: Int = 0

    func body(content: Content) -> some View {
        let motion = motionValues
        content
            .offset(x: motion.x, y: motion.y)
            .rotationEffect(.degrees(motion.rotation))
            .scaleEffect(motion.scale)
    }

    private var motionValues: (x: CGFloat, y: CGFloat, rotation: Double, scale: CGFloat) {
        guard active else { return (0, 0, 0, 1) }
        let effectNowMs = nowMs + Double(rowSeed) * 73
        switch kind {
        case "effect":
            let step = Int(effectNowMs / 45) % 4
            let x: [CGFloat] = [0, -0.5, 0.45, -0.25]
            let y: [CGFloat] = [0, 0.25, -0.25, -0.35]
            return (x[step], y[step], 0, 1)
        case "adlib":
            return (0, CGFloat(KaraokeEffectTiming.adlibOffset(timeMs: effectNowMs)) * textSize, 0, 1)
        case "pulse":
            return (0, 0, 0, 1 + positiveSine(effectNowMs, periodMs: 940) * 0.025)
        case "bounce":
            return (0, CGFloat(KaraokeEffectTiming.bounceOffset(timeMs: effectNowMs)) * textSize, 0, 1)
        case "sway":
            let wave = signedSine(effectNowMs, periodMs: 1_350)
            return (wave * textSize * 0.0245, 0, Double(wave * 0.84), 1)
        case "float":
            return (0, -positiveSine(effectNowMs, periodMs: 1_650) * textSize * 0.09, Double(signedSine(effectNowMs, periodMs: 1_650) * 0.45), 1)
        case "pop":
            return (0, 0, 0, CGFloat(KaraokeEffectTiming.popScale(timeMs: effectNowMs)))
        case "glitch":
            let step = Int(effectNowMs / 35) % 32
            if step == 5 || step == 19 { return (textSize * 0.035, -textSize * 0.01, 0, 1) }
            if step == 6 || step == 20 { return (-textSize * 0.035, textSize * 0.01, 0, 1) }
            return (0, 0, 0, 1)
        default:
            return (0, 0, 0, 1)
        }
    }

    private func signedSine(_ valueMs: Double, periodMs: Double) -> CGFloat {
        CGFloat(sin(valueMs.truncatingRemainder(dividingBy: periodMs) / periodMs * .pi * 2))
    }
}

private struct LyricGlyphEffectModifier: ViewModifier {
    var kind: String
    var active: Bool
    var nowMs: Double
    var textSize: CGFloat
    var segmentIndex: Int
    var rowSeed: Int = 0
    var color: Color

    func body(content: Content) -> some View {
        let effect = effectValues
        content
            .opacity(effect.opacity)
            .shadow(
                color: effect.shadowColor,
                radius: effect.shadowRadius,
                x: effect.shadowX,
                y: effect.shadowY
            )
            .offset(y: effect.waveOffset)
    }

    private var effectValues: (
        opacity: Double,
        shadowColor: Color,
        shadowRadius: CGFloat,
        shadowX: CGFloat,
        shadowY: CGFloat,
        waveOffset: CGFloat
    ) {
        guard active else { return (1, .clear, 0, 0, 0, 0) }
        let waveOffset: CGFloat
        if kind == "wave" {
            let phaseTime = nowMs + Double(rowSeed) * 95 + Double(segmentIndex) * 62
            waveOffset = CGFloat(KaraokeEffectTiming.waveOffset(timeMs: phaseTime)) * textSize
        } else {
            waveOffset = 0
        }

        switch kind {
        case "sparkle":
            let glow = positiveSine(nowMs, periodMs: 1_180)
            return (1, color.opacity(Double(70 + glow * 90) / 255), textSize * (0.07 + glow * 0.18), 0, 0, waveOffset)
        case "echo":
            return (1, color.opacity(78.0 / 255.0), textSize * 0.12, textSize * 0.06, textSize * 0.035, waveOffset)
        case "whisper":
            let amount = positiveSine(nowMs, periodMs: 1_450)
            return (0.76 + Double(1 - amount) * 0.12, .clear, 0, 0, 0, waveOffset)
        case "glow":
            let glow = 0.55 + positiveSine(nowMs, periodMs: 2_800) * 0.30
            return (1, color.opacity(105.0 / 255.0), textSize * (0.14 + glow * 0.14), 0, 0, waveOffset)
        case "blur":
            let blur = 0.30 + positiveSine(nowMs, periodMs: 1_500) * 0.35
            let opacity = 0.90 + Double(1 - blur) * 0.08
            return (opacity, color.opacity(70.0 / 255.0), textSize * blur * 0.055, 0, 0, waveOffset)
        case "flicker":
            let phase = nowMs.truncatingRemainder(dividingBy: 1_220) / 1_220
            let opacity = ((phase > 0.12 && phase < 0.15) || (phase > 0.52 && phase < 0.56)) ? 0.78 : 1
            return (opacity, .clear, 0, 0, 0, waveOffset)
        case "glitch":
            return (1, Color(red: 111 / 255, green: 211 / 255, blue: 1).opacity(78.0 / 255.0), 0, textSize * 0.04, 0, waveOffset)
        default:
            return (1, .clear, 0, 0, 0, waveOffset)
        }
    }
}

private struct KaraokeFillMask: View {
    var fill: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width)
            let height = max(0, geometry.size.height)
            let safeFill = min(1, max(0, fill))
            let fillWidth = width * safeFill
            let softWidth = min(7, max(0, width * 0.30))
            let solidWidth = safeFill >= 0.995 ? width : max(0, fillWidth - softWidth * 0.42)
            let softEnd = safeFill >= 0.995 ? width : min(width, fillWidth + softWidth)
            HStack(spacing: 0) {
                Rectangle()
                    .fill(.white)
                    .frame(width: solidWidth, height: height)
                if safeFill < 0.995, softEnd > solidWidth {
                    LinearGradient(
                        stops: [
                            .init(color: .white, location: 0),
                            .init(color: .white, location: 0.34),
                            .init(color: .white.opacity(0), location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: softEnd - solidWidth, height: height)
                }
            }
            .frame(width: width, height: height, alignment: .leading)
        }
    }
}

private struct KaraokeSegmentFlowLayout: Layout {
    var alignment: TextAlignment
    var rowSpacing: CGFloat = 0
    var wraps: Bool = true

    struct Cache {
        var sizes: [CGSize]
        var whitespace: [Bool]
        var rows: [KaraokeSegmentLayoutRow] = []
        var rowWidth: CGFloat?
        var rowSpacing: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache {
#if DEBUG && os(iOS)
        MainActor.assumeIsolated { debugProbeCount(.flowLayoutMake) }
#endif
        return Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) },
              whitespace: subviews.map { $0[KaraokeWhitespaceLayoutKey.self] })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
#if DEBUG && os(iOS)
        MainActor.assumeIsolated { debugProbeCount(.flowLayoutUpdate) }
#endif
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let whitespace = subviews.map { $0[KaraokeWhitespaceLayoutKey.self] }
        // Fill/motion changes leave intrinsic sizes intact. Fonts, ruby, content and
        // Dynamic Type still invalidate the measured layout when their sizes change.
        if sizes != cache.sizes || whitespace != cache.whitespace {
            cache = Cache(sizes: sizes, whitespace: whitespace)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let maxWidth = wraps
            ? max(1, proposal.width ?? CGFloat.greatestFiniteMagnitude)
            : CGFloat.greatestFiniteMagnitude
        let rows = cachedRows(cache: &cache, maxWidth: maxWidth)
        let contentWidth = rows.map(\.width).max() ?? 0
        let contentHeight = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: wraps ? (proposal.width ?? contentWidth) : contentWidth, height: contentHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let maxWidth = wraps ? max(1, bounds.width) : CGFloat.greatestFiniteMagnitude
        let rows = cachedRows(cache: &cache, maxWidth: maxWidth)
        for row in rows {
            var x = bounds.minX + horizontalOffset(rowWidth: row.width, containerWidth: bounds.width)
            for index in row.indices {
                let size = cache.sizes[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: bounds.minY + row.y + max(0, row.height - size.height)),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width
            }
        }
    }

    private func cachedRows(cache: inout Cache, maxWidth: CGFloat) -> [KaraokeSegmentLayoutRow] {
        if cache.rowWidth == maxWidth, cache.rowSpacing == rowSpacing { return cache.rows }
        var rows: [KaraokeSegmentLayoutRow] = []
        var currentIndices: [Int] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0
        var y: CGFloat = 0

        func flushRow() {
            guard !currentIndices.isEmpty else { return }
            rows.append(KaraokeSegmentLayoutRow(indices: currentIndices, width: currentWidth, height: currentHeight, y: y))
            y += currentHeight + rowSpacing
            currentIndices = []
            currentWidth = 0
            currentHeight = 0
        }

        let units = makeWrapUnits(whitespace: cache.whitespace)
        for unit in units {
            let sizes = unit.map { cache.sizes[$0] }
            let separatorCount = unit.prefix { cache.whitespace[$0] }.count
            let phraseIndices = Array(unit.dropFirst(separatorCount))
            let separatorWidth = sizes.prefix(separatorCount).reduce(0) { $0 + $1.width }
            let phraseWidth = sizes.dropFirst(separatorCount).reduce(0) { $0 + $1.width }
            if phraseWidth <= maxWidth {
                let spacingWidth = currentIndices.isEmpty ? 0 : separatorWidth
                if !currentIndices.isEmpty, currentWidth + spacingWidth + phraseWidth > maxWidth {
                    flushRow()
                }
                if !currentIndices.isEmpty {
                    currentIndices.append(contentsOf: unit.prefix(separatorCount))
                    currentWidth += separatorWidth
                }
                currentIndices.append(contentsOf: phraseIndices)
                currentWidth += phraseWidth
                currentHeight = max(currentHeight, sizes.map(\.height).max() ?? 0)
                continue
            }
            // Only an oversized single phrase falls back to its constituent glyph/syllable segments.
            for index in phraseIndices {
                let size = cache.sizes[index]
                if !currentIndices.isEmpty, currentWidth + size.width > maxWidth {
                    flushRow()
                }
                currentIndices.append(index)
                currentWidth += size.width
                currentHeight = max(currentHeight, size.height)
            }
        }
        flushRow()
        cache.rows = rows
        cache.rowWidth = maxWidth
        cache.rowSpacing = rowSpacing
        return rows
    }

    private func makeWrapUnits(whitespace: [Bool]) -> [[Int]] {
        var units: [[Int]] = []
        var current: [Int] = []
        for index in whitespace.indices {
            if whitespace[index] {
                if current.contains(where: { !whitespace[$0] }) {
                    units.append(current)
                    current = []
                }
                current.append(index)
            } else {
                current.append(index)
            }
        }
        if current.contains(where: { !whitespace[$0] }) {
            units.append(current)
        }
        return units
    }

    private func horizontalOffset(rowWidth: CGFloat, containerWidth: CGFloat) -> CGFloat {
        switch alignment {
        case .center:
            return max(0, (containerWidth - rowWidth) * 0.5)
        case .trailing:
            return max(0, containerWidth - rowWidth)
        default:
            return 0
        }
    }
}

private struct KaraokeSegmentLayoutRow {
    var indices: [Int]
    var width: CGFloat
    var height: CGFloat
    var y: CGFloat
}

#if DEBUG
private struct MainLyricPreviewSlideDebugPreview: View {
    private let durationMs: Int64 = 10_000

    var body: some View {
        let positionMs = debugPositionMs
        VStack(spacing: 28) {
            Text("Main preview \(positionMs / 100) %")
                .font(.pretendard(15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
            VStack(spacing: 4) {
                ForEach(rows) { row in
                    MainLyricPreviewRowView(row: row, positionMs: positionMs)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.035, green: 0.04, blue: 0.06))
        .ignoresSafeArea()
    }

    private var debugPositionMs: Int64 {
        let rawValue = ProcessInfo.processInfo.environment["IVLYRICS_DEBUG_MAIN_PREVIEW_POSITION_MS"] ?? "5000"
        return min(durationMs, max(0, Int64(rawValue) ?? 5_000))
    }

    private var rows: [MainLyricPreviewRow] {
        let original = "This deliberately long main lyric preview stays on one line and moves with its synchronized duration"
        return [
            MainLyricPreviewRow(
                text: original,
                primary: true,
                syllables: debugSyllables(original),
                slotId: AppSettings.typoMainPreviewOriginal,
                lineStartTimeMs: 0,
                lineEndTimeMs: durationMs
            ),
            MainLyricPreviewRow(
                text: "번역 가사 역시 줄바꿈 없이 같은 싱크 진행률에 맞춰 부드럽게 가로로 이동합니다",
                primary: false,
                slotId: AppSettings.typoMainPreviewTranslation,
                lineStartTimeMs: 0,
                lineEndTimeMs: durationMs
            ),
            MainLyricPreviewRow(
                text: "Short centered lyric",
                primary: false,
                slotId: AppSettings.typoMainPreviewPronunciation,
                lineStartTimeMs: 0,
                lineEndTimeMs: durationMs
            )
        ]
    }

    private func debugSyllables(_ text: String) -> [LyricsLine.Syllable] {
        let parts = text.split(separator: " ", omittingEmptySubsequences: false)
        return parts.enumerated().map { index, part in
            let value = index + 1 < parts.count ? String(part) + " " : String(part)
            let start = durationMs * Int64(index) / Int64(parts.count)
            let end = durationMs * Int64(index + 1) / Int64(parts.count)
            return LyricsLine.Syllable(text: value, startTimeMs: start, endTimeMs: end)
        }
    }
}

private struct PictureInPictureLayoutDebugPreview: View {
    let controller: LyricsPictureInPictureController

    var body: some View {
        let environment = ProcessInfo.processInfo.environment
        let orientation = AppSettings.normalizePipOrientation(
            environment["IVLYRICS_DEBUG_PIP_ORIENTATION"] ?? AppSettings.pipOrientationLandscape
        )
        let showArtwork = environment["IVLYRICS_DEBUG_PIP_ARTWORK"] != "0"
        let backgroundMode = AppSettings.normalizePipBackgroundMode(
            environment["IVLYRICS_DEBUG_PIP_BACKGROUND"] ?? AppSettings.pipBackgroundCover
        )
        let image = controller.debugFrameImage(orientation: orientation, showArtwork: showArtwork, backgroundMode: backgroundMode)
        Image(uiImage: image)
            .resizable()
            .interpolation(.none)
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .ignoresSafeArea()
    }
}

private struct KaraokeEffectsDebugPreview: View {
    private let kinds = [
        "effect", "adlib", "pulse",
        "bounce", "sway", "float",
        "pop", "glitch", "wave",
        "sparkle", "echo", "whisper",
        "glow", "blur", "flicker"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Android lyric effects")
                .font(.pretendard(16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.64))
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                spacing: 12
            ) {
                ForEach(Array(kinds.enumerated()), id: \.offset) { index, kind in
                    SyllableKaraokeText(
                        text: kind,
                        syllables: [],
                        startTimeMs: 0,
                        endTimeMs: 10_000,
                        positionMs: 5_000,
                        active: true,
                        activeColor: effectColor(index),
                        alignment: .center,
                        kind: kind,
                        bounceTextSize: 18,
                        effectRowSeed: index
                    )
                    .font(.pretendard(18, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { index in
                    SyllableKaraokeText(
                        text: "V\(index + 1)",
                        syllables: [],
                        startTimeMs: 0,
                        endTimeMs: 10_000,
                        positionMs: 5_000,
                        active: true,
                        activeColor: effectColor(index),
                        alignment: .center,
                        kind: "wave",
                        bounceTextSize: 18,
                        effectRowSeed: index
                    )
                    .font(.pretendard(18, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Color(red: 0.035, green: 0.04, blue: 0.06))
        .ignoresSafeArea()
    }

    private func effectColor(_ index: Int) -> Color {
        let colors: [Color] = [
            .white,
            Color(red: 0.58, green: 0.86, blue: 1),
            Color(red: 1, green: 0.62, blue: 0.78)
        ]
        return colors[index % colors.count]
    }
}

private struct LyricsMotionDebugPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 38) {
            Text("Interlude motion")
                .font(.pretendard(15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
            LyricsInterludeView(
                info: InterludeInfo(startTimeMs: 0, endTimeMs: 12_000, kind: "break", automatic: true),
                active: true,
                displayDistance: 0,
                showLabel: true,
                alignment: "left"
            )
            Text("Stable lyric below")
                .font(.pretendard(28, weight: .bold))
                .foregroundStyle(.white)

            Text("Main preview loading")
                .font(.pretendard(15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
            MainLyricPreviewLoadingSkeleton()
                .frame(maxWidth: .infinity)

            Text("Full lyrics loading")
                .font(.pretendard(15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
            LyricsLoadingSkeleton()
                .frame(maxWidth: .infinity)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Color(red: 0.04, green: 0.045, blue: 0.065))
        .ignoresSafeArea()
    }
}

private struct KaraokeDebugPreview: View {
    @EnvironmentObject private var settings: AppSettings
    private var arabicPreviewEnabled: Bool {
        ProcessInfo.processInfo.environment["IVLYRICS_DEBUG_KARAOKE_ARABIC"] == "1"
    }
    private var longText: String {
        arabicPreviewEnabled ? "تايهة و توهتك في القصة ويايا" : "Someone to die for you and more"
    }
    private var rangeStyledLine: LyricsLine {
        let baseLine = LyricsLine(startTimeMs: 0, endTimeMs: 6_000, text: "ABCDEF")
        return SyncDataApplier.applyWithDiagnostics(
            baseLyrics: [baseLine],
            syncBody: [
                "version": 5,
                "lines": [[
                    "start": 0,
                    "end": 5,
                    "chars": [0.0, 1.0, 2.0, 3.0, 4.0, 5.0],
                    "granularity": "character",
                    "kind": "vocal",
                    "styleRanges": [[
                        "start": 2,
                        "end": 3,
                        "kind": "wave",
                        "speaker": "FEMALE 1"
                    ]]
                ]]
            ],
            track: nil
        ).lines.first ?? baseLine
    }

    var body: some View {
        let _ = settings.typographyRevision
        let _ = settings.speakerColorRevision
        let typography = settings.typographySettings()
        let speakerColors = settings.speakerColorSettings()
        VStack(alignment: .leading, spacing: 44) {
            Text("Synthetic line sync at 50%")
                .font(.pretendard(15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
            SyllableKaraokeText(
                text: longText,
                syllables: [],
                startTimeMs: 0,
                endTimeMs: 10_000,
                positionMs: 5_000,
                active: true,
                activeColor: .white,
                alignment: arabicPreviewEnabled ? .trailing : .leading,
                bounceEnabled: false,
                bounceTextSize: 38,
                syntheticTimingEnabled: true
            )
            .font(.pretendard(38, weight: .bold))
            .frame(width: 320, alignment: arabicPreviewEnabled ? .trailing : .leading)

            Text("C–D use range wave and speaker color")
                .font(.pretendard(15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
            SyllableKaraokeText(
                text: "ABCDEF",
                syllables: rangeStyledLine.syllables,
                startTimeMs: 0,
                endTimeMs: 6_000,
                positionMs: 2_100,
                active: true,
                activeColor: Color(red: 0.48, green: 0.80, blue: 0.78),
                alignment: .leading,
                speakerColors: speakerColors,
                useCreatorSpeakerColors: settings.useSyncCreatorSpeakerColors,
                bounceEnabled: true,
                bounceTextSize: 52
            )
            .font(.pretendard(52, weight: .bold))

            Text("Lead and creator-colored background keep separate timing/colors")
                .font(.pretendard(15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
            LyricsLineView(
                lineIndex: 0,
                line: multiVocalLine,
                originalText: multiVocalLine.text,
                active: true,
                animationActive: true,
                completedColorOpacity: 1,
                displayDistance: 0,
                progress: 0.52,
                positionMs: 2_100,
                alignment: "left",
                pronunciationLoading: false,
                translationLoading: false,
                typography: typography,
                speakerColors: speakerColors,
                onSeek: { _ in }
            )
            .equatable()
            .frame(width: 330)

            Text("System PiP keeps the same vocal stack")
                .font(.pretendard(15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
            PictureInPictureKaraokeContent(
                line: multiVocalLine,
                positionMs: 2_100,
                alignment: .leading,
                frameAlignment: .leading,
                fontSize: 32,
                speakerColors: speakerColors,
                useCreatorSpeakerColors: settings.useSyncCreatorSpeakerColors,
                karaokeDisplayGranularity: AppSettings.karaokeDisplayCharacter,
                syncedLyricsKaraokeAnimationEnabled: true,
                bounceEnabled: true
            )
            .frame(width: 330, height: 100, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(36)
        .background(Color(red: 0.04, green: 0.045, blue: 0.065))
        .ignoresSafeArea()
    }

    private var multiVocalLine: LyricsLine {
        let baseLine = LyricsLine(
            startTimeMs: 0,
            endTimeMs: 3_600,
            text: "LEADDUET"
        )
        let syncBody: [String: Any] = [
            "version": 2,
            "lines": [[
                "start": 0,
                "end": 7,
                "chars": [0.0, 0.4, 0.8, 1.2, 1.6, 2.0, 2.4, 2.8],
                "speaker": "MALE 1",
                "kind": "vocal",
                "parallel": [
                    "parts": [
                        [
                            "id": "lead",
                            "role": "lead",
                            "speaker": "MALE 1",
                            "kind": "vocal",
                            "ranges": [["start": 0, "end": 3]],
                            "chars": [0.0, 0.4, 0.8, 1.2]
                        ],
                        [
                            "id": "background",
                            "role": "background",
                            "speaker": "FEMALE CUSTOM",
                            "speaker-color": "#ff4fa3",
                            "speaker-fallback": "female-1",
                            "kind": "vocal",
                            "ranges": [["start": 4, "end": 7]],
                            "chars": [1.2, 1.8, 2.4, 3.0]
                        ]
                    ]
                ]
            ]]
        ]
        if let parsed = SyncDataApplier.applyWithDiagnostics(
            baseLyrics: [baseLine],
            syncBody: syncBody,
            track: nil
        ).lines.first,
           parsed.vocalParts.count == 2 {
            return parsed
        }

        let lead = LyricsLine.VocalPart(
            id: "lead",
            role: "lead",
            speaker: "MALE 1",
            kind: "vocal",
            text: "LEAD",
            syllables: timedSyllables("LEAD", startTimeMs: 0, stepMs: 800)
        )
        let background = LyricsLine.VocalPart(
            id: "background",
            role: "background",
            speaker: "FEMALE CUSTOM",
            speakerColor: "#ff4fa3",
            speakerFallback: "female-1",
            kind: "vocal",
            text: "DUET",
            syllables: timedSyllables("DUET", startTimeMs: 1_200, stepMs: 600)
        )
        return LyricsLine(
            startTimeMs: 0,
            endTimeMs: 3_600,
            text: "LEADDUET",
            speaker: "MALE 1",
            vocalParts: [background, lead]
        )
    }

    private func timedSyllables(_ text: String, startTimeMs: Int64, stepMs: Int64) -> [LyricsLine.Syllable] {
        text.enumerated().map { index, character in
            let start = startTimeMs + Int64(index) * stepMs
            return LyricsLine.Syllable(text: String(character), startTimeMs: start, endTimeMs: start + stepMs)
        }
    }
}
#endif

enum LyricSpeakerPalette {
    /// Every distance-based lyric color is constant beyond this distance: inactive text clamps
    /// at 2.6 (also after a vocal part's +0.45), supplements at 2.8, interlude bars at 2.6.
    static let maximumEffectiveDistance = 2.8

    private struct ResolutionCacheKey: Hashable {
        var speaker: String
        var speakerColor: String
        var speakerFallback: String
        var settings: AppSettings.SpeakerColorSettings
        var useCreatorColors: Bool
    }

    private struct SpeakerResolution {
        var resolvedColor: Color?
        var activeColor: Color
        var inactiveAlpha: Double
    }

    private final class ResolutionCache: @unchecked Sendable {
        private static let limit = 128
        private let lock = NSLock()
        private var values: [ResolutionCacheKey: SpeakerResolution] = [:]

        func value(
            for key: ResolutionCacheKey,
            create: () -> SpeakerResolution
        ) -> SpeakerResolution {
            lock.lock()
            if let value = values[key] {
                lock.unlock()
                return value
            }
            lock.unlock()

            let value = create()
            lock.lock()
            defer { lock.unlock() }
            if let existing = values[key] {
                return existing
            }
            if values.count >= Self.limit {
                values.removeAll(keepingCapacity: true)
            }
            values[key] = value
            return value
        }
    }

    private static let resolutionCache = ResolutionCache()

    static func activeColor(speaker: String, settings: AppSettings.SpeakerColorSettings) -> Color {
        activeColor(
            speaker: speaker,
            speakerColor: "",
            speakerFallback: "",
            settings: settings,
            useCreatorColors: true
        )
    }

    static func activeColor(
        speaker: String,
        speakerColor: String,
        speakerFallback: String,
        settings: AppSettings.SpeakerColorSettings,
        useCreatorColors: Bool
    ) -> Color {
        speakerResolution(
            speaker: speaker,
            speakerColor: speakerColor,
            speakerFallback: speakerFallback,
            settings: settings,
            useCreatorColors: useCreatorColors
        ).activeColor
    }

    static func inactiveColor(
        speaker: String,
        speakerColor: String,
        speakerFallback: String,
        settings: AppSettings.SpeakerColorSettings,
        useCreatorColors: Bool,
        distance: Double
    ) -> Color {
        let resolution = speakerResolution(
            speaker: speaker,
            speakerColor: speakerColor,
            speakerFallback: speakerFallback,
            settings: settings,
            useCreatorColors: useCreatorColors
        )
        let baseAlpha = max(54.0, min(190.0, 185.0 - min(2.6, max(0, distance)) * 46.0))
        guard let color = resolution.resolvedColor else {
            return Color(red: 174 / 255, green: 181 / 255, blue: 195 / 255).opacity(baseAlpha / 255.0)
        }
        let distanceFactor = baseAlpha / 185.0
        let alpha = max(40.0, min(150.0, (255.0 * resolution.inactiveAlpha * distanceFactor).rounded()))
        return color.opacity(alpha / 255.0)
    }

    static func supplementInactiveColor(
        speaker: String,
        speakerColor: String,
        speakerFallback: String,
        settings: AppSettings.SpeakerColorSettings,
        useCreatorColors: Bool,
        distance: Double
    ) -> Color {
        let alpha = max(34.0, (105.0 - min(2.8, max(0, distance)) * 24.0).rounded()) / 255.0
        guard let color = speakerResolution(
            speaker: speaker,
            speakerColor: speakerColor,
            speakerFallback: speakerFallback,
            settings: settings,
            useCreatorColors: useCreatorColors
        ).resolvedColor else {
            return Color(red: 210 / 255, green: 216 / 255, blue: 226 / 255).opacity(alpha)
        }
        return color.opacity(alpha)
    }

    private static func speakerResolution(
        speaker: String,
        speakerColor: String,
        speakerFallback: String,
        settings: AppSettings.SpeakerColorSettings,
        useCreatorColors: Bool
    ) -> SpeakerResolution {
        let cacheKey = ResolutionCacheKey(
            speaker: speaker,
            speakerColor: speakerColor,
            speakerFallback: speakerFallback,
            settings: settings,
            useCreatorColors: useCreatorColors
        )
        return resolutionCache.value(for: cacheKey) {
            let key = normalizeSpeakerKey(speaker)
            let fallbackKey = fallbackCustomSpeakerKey(key, speakerFallback: speakerFallback)
            let resolvedColor: Color?
            if isCustomSpeakerKey(key), useCreatorColors, AppSettings.isHexColor(speakerColor) {
                resolvedColor = Color(hex: AppSettings.normalizeHexColor(speakerColor, fallback: "#ffffff"))
            } else {
                resolvedColor = speakerActiveColor(key: fallbackKey, settings: settings)
            }
            return SpeakerResolution(
                resolvedColor: resolvedColor,
                activeColor: resolvedColor ?? Color(hex: settings.hex(AppSettings.speakerColorNormal)),
                inactiveAlpha: speakerInactiveAlpha(fallbackKey)
            )
        }
    }

    private static func speakerActiveColor(key: String, settings: AppSettings.SpeakerColorSettings) -> Color? {
        switch key {
        case "speaker-b", "b":
            return Color(red: 139 / 255.0, green: 211 / 255.0, blue: 255 / 255.0)
        case "speaker-c", "c":
            return Color(red: 255 / 255.0, green: 209 / 255.0, blue: 102 / 255.0)
        case "speaker-d", "d":
            return Color(red: 196 / 255.0, green: 167 / 255.0, blue: 255 / 255.0)
        case "speaker-sfx", "sfx":
            return Color(red: 244 / 255.0, green: 166 / 255.0, blue: 200 / 255.0)
        default:
            if let color = numberedColor(key: key, prefix: "male", settings: settings) { return color }
            if let color = numberedColor(key: key, prefix: "female", settings: settings) { return color }
            if let color = numberedColor(key: key, prefix: "duet", settings: settings) { return color }
            return nil
        }
    }

    private static func isCustomSpeakerKey(_ key: String) -> Bool {
        switch key {
        case "custom", "speaker-custom", "male-custom", "speaker-male-custom",
             "female-custom", "speaker-female-custom", "duet-custom", "speaker-duet-custom":
            return true
        default:
            return false
        }
    }

    private static func fallbackCustomSpeakerKey(_ key: String, speakerFallback: String) -> String {
        switch key {
        case "custom", "speaker-custom":
            let fallback = normalizeSpeakerKey(speakerFallback)
            return ["male-1", "female-1", "duet-1"].contains(fallback) ? fallback : "male-1"
        case "male-custom", "speaker-male-custom":
            return "male-1"
        case "female-custom", "speaker-female-custom":
            return "female-1"
        case "duet-custom", "speaker-duet-custom":
            return "duet-1"
        default:
            return key
        }
    }

    private static func speakerInactiveAlpha(_ key: String) -> Double {
        switch key {
        case "speaker-b", "b", "speaker-sfx", "sfx":
            return 0.46
        case "speaker-c", "c", "speaker-d", "d":
            return 0.48
        default:
            for prefix in ["male", "female", "duet"] {
                if let index = speakerIndex(key: key, prefix: prefix) {
                    return index == 0 ? 0.52 : 0.50
                }
            }
            return 0.50
        }
    }

    private static func numberedColor(key: String, prefix: String, settings: AppSettings.SpeakerColorSettings) -> Color? {
        guard let index = speakerIndex(key: key, prefix: prefix), (0..<5).contains(index) else {
            return nil
        }
        return Color(hex: settings.hex("\(prefix)\(index + 1)"))
    }

    private static func speakerIndex(key: String, prefix: String) -> Int? {
        if key == prefix || key == "speaker-\(prefix)" {
            return 0
        }
        let candidates = [
            key.replacingOccurrences(of: "speaker-\(prefix)-", with: ""),
            key.replacingOccurrences(of: "speaker-\(prefix)", with: ""),
            key.replacingOccurrences(of: "\(prefix)-", with: ""),
            key.replacingOccurrences(of: prefix, with: "")
        ]
        for candidate in candidates where candidate != key {
            if candidate.isEmpty { return 0 }
            if let number = Int(candidate), number > 0 { return number - 1 }
        }
        return nil
    }

    private static func normalizeSpeakerKey(_ speaker: String) -> String {
        speaker
            .trimmed
            .lowercased()
            .replacingOccurrences(of: #"[_\s]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

struct LogsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    // Subscribed (not read directly) so this view re-renders with the display-rate playback clock driving model.nowPositionMs.
    @EnvironmentObject private var playbackClock: PlaybackClock
    @Binding var visible: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(settings.t("debug.title"))
                    .font(.pretendard(24, weight: .bold))
                Spacer(minLength: 12)
                Button(settings.t("button.close")) {
                    withAnimation(.easeOut(duration: 0.16)) {
                        visible = false
                    }
                }
                .font(.pretendard(13, weight: .semibold))
                .frame(width: 92, height: 42)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .buttonStyle(.plain)
            }

            Text(debugSourceText)
                .font(.pretendard(13, weight: .semibold))
                .foregroundStyle(Color(red: 142.0 / 255.0, green: 236.0 / 255.0, blue: 198.0 / 255.0))
                .padding(.top, 18)

            Text(debugStatusText)
                .font(.pretendard(12))
                .foregroundStyle(.white.opacity(0.81))
                .lineSpacing(2)
                .padding(.top, 8)

            Text("\(debugTime(model.nowPositionMs)) / \(debugTime(model.durationMs))")
                .font(.pretendard(13, weight: .semibold))
                .monospacedDigit()
                .padding(.top, 12)

            if !model.spotifyAppRemoteConnected && !model.spotifyLivePolling {
                Button(settings.t("debug.permission")) {
                    model.connectSpotifyUserAndStartPolling()
                }
                .androidDebugButton()
                .padding(.top, 14)
            }

            HStack(spacing: 8) {
                Button(settings.t("debug.previous")) {
                    model.skipToPreviousTrack()
                }
                .androidDebugButton()

                Button(settings.t("debug.play_pause")) {
                    model.togglePlayback()
                }
                .androidDebugButton()
                .frame(maxWidth: .infinity)

                Button(settings.t("debug.next")) {
                    model.skipToNextTrack()
                }
                .androidDebugButton()
            }
            .padding(.top, 10)

            Button(settings.t("debug.refresh")) {
                if model.spotifyAppRemoteConnected || model.spotifyLivePolling {
                    Task { await model.refreshSpotifyPlayback(loadLyricsIfNeeded: true) }
                } else {
                    model.reloadLyrics(bypassCache: true)
                }
            }
            .androidDebugButton()
            .padding(.top, 10)

            Text(settings.t("debug.log"))
                .font(.pretendard(14, weight: .semibold))
                .padding(.top, 18)

            ScrollView {
                Text(debugLogText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.83))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.black.opacity(118.0 / 255.0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.top, 8)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.top, 52)
        .padding(.bottom, 22)
        .background(Color(red: 15.0 / 255.0, green: 18.0 / 255.0, blue: 31.0 / 255.0).opacity(238.0 / 255.0))
        .ignoresSafeArea()
    }

    private var debugSourceText: String {
        if model.spotifyAppRemoteConnected {
            return "Spotify App Remote"
        }
        if model.spotifyLivePolling {
            return "Spotify Web API"
        }
        if model.currentTrack != nil {
            return "Track metadata"
        }
        return settings.t("status.waiting_current_track")
    }

    private var debugLogText: String {
        model.logs.isEmpty ? settings.t("debug.log_waiting") : model.logs.joined(separator: "\n")
    }

    private var debugStatusText: String {
        let detail = model.lyricsResult.detail.trimmed
        return detail.isEmpty ? model.status.text(settings: settings) : detail
    }

    private func debugTime(_ milliseconds: Int64) -> String {
        androidPlayerTime(milliseconds)
    }
}

private extension View {
    func androidDebugButton() -> some View {
        self
            .font(.pretendard(13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .buttonStyle(.plain)
    }
}

struct SettingsView: View {
    enum Menu: String, CaseIterable, Identifiable, Hashable {
        case currentTrack = "current_track"
        case general
        case providers
        case ai
        case appearance
        case lyrics
        case player
        case system

        var id: String { rawValue }
        var titleKey: String { "tab.\(rawValue)" }

        var symbol: String {
            switch self {
            case .currentTrack: return "music.note"
            case .general: return "slider.horizontal.3"
            case .providers: return "music.note.list"
            case .ai: return "sparkles"
            case .appearance: return "paintpalette"
            case .lyrics: return "music.mic"
            case .player: return "play.rectangle"
            case .system: return "gearshape.2"
            }
        }
    }

    private enum MenuGroup: String, CaseIterable, Identifiable {
        case general
        case sources
        case display
        case manage

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .general: return "tab.general"
            case .sources: return "settings.group.sources"
            case .display: return "settings.group.display"
            case .manage: return "settings.group.manage"
            }
        }

        var menus: [Menu] {
            switch self {
            case .general: return [.currentTrack, .general]
            case .sources: return [.providers, .ai]
            case .display: return [.appearance, .lyrics, .player]
            case .manage: return [.system]
            }
        }
    }

    private enum PreviewKind {
        case lyrics
        case main
        case annotation
        case pip
        case vinyl
    }

    private enum SettingsSheet: String, Identifiable {
        case uiLanguage
        case outputLanguage
        case ruleSource
        case aiModel

        var id: String { rawValue }
    }

    private enum SearchPreparation: Equatable {
        case none
        case typography(String)
        case cultural(String)
        case connection(String)
        case reveal
    }

    private struct SearchEntry: Identifiable {
        let id: String
        let menu: Menu
        let label: String
        var description = ""
        var section = ""
        var context = ""
        var options: [String] = []
        var value = ""
        var preparation: SearchPreparation = .none
    }

    private struct SearchBlock: Identifiable {
        let id: Int
        let menu: Menu
        var entries: [SearchEntry]
    }

    private struct RevealRequest: Equatable {
        let menu: Menu
        let rowID: String
        let token = UUID()
    }

    private static let pageSpace = "settings.page"

#if DEBUG
    /// Metadata-only probe: never evaluates a view or reads an uninstalled environment object.
    static var debugMenuContentSize: Int {
        func size<Content: View>(of build: (Menu) -> Content) -> Int { MemoryLayout<Content>.size }
        return size(of: SettingsView().menuSections)
    }
#endif

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    @State private var path: [Menu] = []
    @State private var currentTrackTab: LyricsMetaMenuTab = .language
    @State private var settingsSearch = ""
    @State private var settingsSearchFocused = false
    @State private var reveal: RevealRequest?
    @State private var flashRowID: String?
    @State private var revealedRowID: String?
    @State private var scrollMemory = SettingsScrollMemory()
    @State private var previewExpanded: [Menu: Bool] = [:]
    @State private var previewSectionID = ""
    /// Height of the settings screen, used to decide whether the live preview can stay pinned and how tall it may be.
    /// Measured on the navigation stack so a collapsing large title does not change it.
    @State private var settingsHeight: CGFloat = 0
    @State private var typographyGroup = "main"
    @State private var culturalColumn = "normal"
    @State private var selectedSpeakerColor = AppSettings.speakerColorNormal
    @State private var expandedAIProvider: String?
    @State private var activeSheet: SettingsSheet?
    @State private var settingsLogsPresented = false
    @State private var aiModels: [AIProviderModels.Model] = []
    @State private var aiModelsConfiguration: AIProviderModels.Configuration?
    @State private var aiModelsLoading = false
    @State private var aiModelsError = ""
    @State private var aiModelsBuiltIn = false
    @State private var aiModelsRequestId = UUID()
    @State private var cloudApplyConfirmationPresented = false
    @State private var cloudDeleteConfirmationPresented = false
    @State private var clearAllConfirmationPresented = false
    @State private var aiCacheConfirmationPresented = false

    var body: some View {
        NavigationStack(path: $path) {
            homePage
                .navigationDestination(for: Menu.self) { menu in
                    menuPage(menu)
                }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            if abs(height - settingsHeight) > 0.5 { settingsHeight = height }
        }
        .tint(palette.accentText)
        .toggleStyle(SettingsSwitchStyle())
        .environment(\.settingsPalette, palette)
        .preferredColorScheme(palette.colorScheme)
        .overlay(alignment: .bottom) { settingsToast }
        .onChange(of: model.toastMessage) { _, message in
            let text = message.trimmed
            if !text.isEmpty { UIAccessibility.post(notification: .announcement, argument: text) }
        }
        .onChange(of: path) { _, newPath in
            settingsSearchFocused = false
            previewSectionID = ""
            if newPath.last != reveal?.menu {
                reveal = nil
                revealedRowID = nil
                flashRowID = nil
            }
        }
        .onAppear {
#if DEBUG
            if path.isEmpty,
               let rawTab = ProcessInfo.processInfo.environment["IVLYRICS_DEBUG_SETTINGS_TAB"],
               let menu = Menu(rawValue: rawTab) {
                path = [menu]
            }
#endif
#if DEBUG
            if !DebugSettingsUIHarness.enabled { model.prepareCreatorPrivacySettings() }
#else
            model.prepareCreatorPrivacySettings()
#endif
        }
        .sheet(item: $activeSheet) { sheet in
            sheetContent(sheet)
                .environment(\.settingsPalette, palette)
                .environmentObject(settings)
                .environmentObject(model)
        }
        .fullScreenCover(isPresented: $settingsLogsPresented) {
            LogsView(visible: $settingsLogsPresented)
                .environmentObject(model)
                .environmentObject(model.playbackClock)
        }
        .alert(settings.t("cloud_sync.apply"), isPresented: $cloudApplyConfirmationPresented) {
            Button(settings.t("button.cancel"), role: .cancel) {}
            Button(settings.t("cloud_sync.apply")) { model.applyCloudSettings() }
        } message: {
            Text(settings.t("cloud_sync.confirm_apply"))
        }
        .alert(settings.t("cloud_sync.delete"), isPresented: $cloudDeleteConfirmationPresented) {
            Button(settings.t("button.cancel"), role: .cancel) {}
            Button(settings.t("cloud_sync.delete"), role: .destructive) { model.deleteCloudSettings() }
        } message: {
            Text(settings.t("cloud_sync.confirm_delete"))
        }
        .alert(
            settings.t("cloud_sync.section"),
            isPresented: Binding(
                get: { model.cloudMonthlyRequiredAlertPresented },
                set: { presented in
                    if !presented { model.dismissCloudMonthlyRequiredAlert() }
                }
            )
        ) {
            Button(settings.t("button.close")) { model.dismissCloudMonthlyRequiredAlert() }
        } message: {
            Text(settings.t("cloud_sync.monthly_required"))
        }
        .alert(settings.t("button.clear_all"), isPresented: $clearAllConfirmationPresented) {
            Button(settings.t("button.cancel"), role: .cancel) {}
            Button(settings.t("button.clear_all"), role: .destructive) { model.clearAllCaches() }
        } message: {
            Text(settings.t("settings.confirm.irreversible"))
        }
        .alert(settings.t("button.ai_cache_clear"), isPresented: $aiCacheConfirmationPresented) {
            Button(settings.t("button.cancel"), role: .cancel) {}
            Button(settings.t("button.ai_cache_clear"), role: .destructive) { model.clearAiCaches() }
        } message: {
            Text(settings.t("settings.confirm.irreversible"))
        }
    }

    private var palette: SettingsPalette {
        SettingsTheme.palette(settings.settingsTheme)
    }

    /// Toasts are drawn by the player screen, which this full-screen cover hides; show them here too.
    @ViewBuilder
    private var settingsToast: some View {
        let message = model.toastMessage.trimmed
        if !message.isEmpty {
            Text(message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.inkText)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(palette.ink, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 18)
                .padding(.bottom, 20)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
        }
    }

    // MARK: Home

    private var homePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsHomeWordmark()
                    .padding(.top, 8)
                    .padding(.bottom, 22)
                searchBox
                    .padding(.bottom, 18)
                if settingsSearch.trimmed.isEmpty {
                    ForEach(MenuGroup.allCases) { group in
                        homeGroup(group)
                    }
                } else {
                    settingsSearchResults
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 40)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("settings.home")
        .background(palette.background.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { themeSwitch }
            ToolbarItem(placement: .topBarTrailing) { closeButton }
        }
        .toolbarBackground(palette.background, for: .navigationBar)
    }

    private var searchBox: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(palette.text3)
                .accessibilityHidden(true)
            SettingsSearchField(prompt: settings.t("settings.search"), text: $settingsSearch,
                                isFocused: $settingsSearchFocused)
                .frame(maxWidth: .infinity, minHeight: 48)
                .layoutPriority(1)
            if !settingsSearch.isEmpty {
                Button { settingsSearch = ""; settingsSearchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill")
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                        .foregroundStyle(palette.text3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(settings.t("button.clear_search"))
                .accessibilityIdentifier("settings.search.clear")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, settingsSearch.isEmpty ? 12 : 2)
        .background(palette.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(settingsSearchFocused ? palette.accentLine : palette.line2))
    }

    private func homeGroup(_ group: MenuGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(settings.t(group.titleKey))
                .font(.footnote.weight(.medium))
                .foregroundStyle(palette.text3)
                .padding(.horizontal, 6)
                .accessibilityAddTraits(.isHeader)
            SettingsGroup {
                ForEach(group.menus) { menu in
                    homeRow(menu)
                }
            }
        }
        .padding(.bottom, 20)
    }

    private func homeRow(_ menu: Menu) -> some View {
        Button {
            settingsSearchFocused = false
            path = [menu]
        } label: {
            HStack(spacing: 12) {
                menuIcon(menu)
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.t(menu.titleKey))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(palette.text)
                    Text(menuSummary(menu))
                        .font(.footnote)
                        .foregroundStyle(palette.text3)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.text4)
                    .accessibilityHidden(true)
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowButtonStyle())
        .settingsRowSeparator()
        .accessibilityIdentifier("settings.menu.\(menu.rawValue)")
        .accessibilityHint(menuSummary(menu))
    }

    private func menuIcon(_ menu: Menu) -> some View {
        Image(systemName: menu.symbol)
            .font(.subheadline)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(palette.text2)
            .frame(width: 30, height: 30)
            .background(palette.surface3, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
    }

    private func menuSummary(_ menu: Menu) -> String {
        menuSectionTitleKeys(menu).map { settings.t($0) }.joined(separator: " · ")
    }

    private func menuSectionTitleKeys(_ menu: Menu) -> [String] {
        switch menu {
        case .currentTrack:
            return ["lyrics.tab.language", "lyrics.tab.sync", "lyrics.tab.video", "lyrics.tab.background", "section.lyrics_providers"]
        case .general:
            return ["section.language", "settings.section.lyrics_display"]
        case .providers:
            return ["settings.section.lookup", "section.lyrics_providers"]
        case .ai:
            return ["section.ai_lyrics", "section.language_rules", "section.provider", "settings.section.connections", "setting.cultural_annotations"]
        case .appearance:
            return ["section.layout", "section.typography", "section.speaker_colors", "section.background", "section.track_background"]
        case .lyrics:
            return ["settings.section.interlude", "settings.section.karaoke"]
        case .player:
            return ["section.player", "settings.section.landscape", "section.pip", "vinyl.mode", "vinyl.settings.tonearm_title"]
        case .system:
            return ["section.account", "section.spotify_api", "lyrics.tab.sync", "section.update", "section.tools"]
        }
    }

    private var themeSwitch: some View {
        HStack(spacing: 0) {
            themeOption(SettingsTheme.light, symbol: "sun.max", key: "settings.theme.light")
            themeOption(SettingsTheme.dark, symbol: "moon", key: "settings.theme.dark")
        }
        .background {
            // The visible track is inset; each option keeps a full 44pt hit area.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.surface2)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.line2))
                .padding(.vertical, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(settings.t("settings.theme"))
    }

    private func themeOption(_ theme: String, symbol: String, key: String) -> some View {
        let isOn = SettingsTheme.normalized(settings.settingsTheme) == theme
        return Button {
            settings.settingsTheme = theme
        } label: {
            Image(systemName: symbol)
                .font(.subheadline.weight(.medium))
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .foregroundStyle(isOn ? palette.text : palette.text3)
                .frame(width: 44, height: 44)
                .background {
                    if isOn {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(palette.raise)
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(palette.line2))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 6)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(settings.t(key))
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
        .accessibilityIdentifier("settings.theme.\(theme)")
    }

    private var closeButton: some View {
        Button {
            settingsSearchFocused = false
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .foregroundStyle(palette.text2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(settings.t("button.close"))
        .accessibilityIdentifier("settings.close")
    }

    // MARK: Search

    private var settingsSearchResults: some View {
        let results = searchResults(settingsSearch)
        return VStack(alignment: .leading, spacing: 14) {
            if results.isEmpty {
                Text(settings.t("settings.no_results"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(palette.text2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            } else {
                Text(settings.tf("settings.search.results_format", results.count))
                    .font(.footnote)
                    .foregroundStyle(palette.text3)
                    .padding(.horizontal, 6)
                ForEach(searchBlocks(results)) { block in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(settings.t(block.menu.titleKey))
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(palette.text3)
                            .padding(.horizontal, 6)
                            .accessibilityAddTraits(.isHeader)
                        SettingsGroup {
                            ForEach(block.entries) { entry in
                                searchResultRow(entry)
                            }
                        }
                    }
                }
            }
        }
    }

    private func searchBlocks(_ results: [SearchEntry]) -> [SearchBlock] {
        var blocks: [SearchBlock] = []
        for entry in results {
            if let last = blocks.indices.last, blocks[last].menu == entry.menu {
                blocks[last].entries.append(entry)
            } else {
                blocks.append(SearchBlock(id: blocks.count, menu: entry.menu, entries: [entry]))
            }
        }
        return blocks
    }

    private func searchResultRow(_ entry: SearchEntry) -> some View {
        Button { openSearchResult(entry) } label: {
            HStack(spacing: 12) {
                menuIcon(entry.menu)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.label)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(palette.text)
                    Text(([settings.t(entry.menu.titleKey), entry.section, entry.context].filter { !$0.isEmpty }).joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(palette.text3)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                if !entry.value.isEmpty {
                    Text(entry.value)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(palette.text3)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowButtonStyle())
        .settingsRowSeparator()
        .accessibilityIdentifier("settings.result.\(entry.id)")
    }

    private func searchResults(_ query: String) -> [SearchEntry] {
        let needle = SettingsSearchText.normalized(query)
        guard !needle.isEmpty else { return [] }
        let initialsOnly = SettingsSearchText.isInitialConsonantQuery(needle)
        var scored: [(entry: SearchEntry, score: Int)] = []
        for entry in searchCatalog {
            let label = SettingsSearchText.normalized(entry.label)
            var score = 0
            if label == needle {
                score = 100
            } else if label.hasPrefix(needle) {
                score = 80
            } else if label.contains(needle) {
                score = 60
            } else if initialsOnly && SettingsSearchText.initialConsonants(entry.label.filter { !$0.isWhitespace }).contains(needle) {
                score = 50
            } else if entry.options.contains(where: { SettingsSearchText.normalized($0).contains(needle) }) {
                score = 35
            } else if SettingsSearchText.normalized(entry.description).contains(needle) {
                score = 30
            } else if SettingsSearchText.normalized(settings.t(entry.menu.titleKey) + entry.section + entry.context).contains(needle) {
                score = 18
            }
            if score > 0 { scored.append((entry, score)) }
        }
        return scored
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.score != rhs.element.score { return lhs.element.score > rhs.element.score }
                if lhs.element.entry.label.count != rhs.element.entry.label.count {
                    return lhs.element.entry.label.count < rhs.element.entry.label.count
                }
                return lhs.offset < rhs.offset
            }
            .prefix(60)
            .map { $0.element.entry }
    }

    private func openSearchResult(_ entry: SearchEntry) {
        settingsSearchFocused = false
        switch entry.preparation {
        case .none:
            break
        case let .typography(group):
            typographyGroup = group
        case let .cultural(column):
            culturalColumn = column
        case let .connection(providerId):
            if providerId == LocalAI.providerId {
                expandedAIProvider = providerId
            } else {
                settings.setProvider(providerId)
                expandedAIProvider = settings.providerId
            }
        case .reveal:
            revealedRowID = entry.id
        }
        reveal = RevealRequest(menu: entry.menu, rowID: entry.id)
        if path != [entry.menu] { path = [entry.menu] }
    }

    @MainActor
    private func performReveal(menu: Menu, proxy: ScrollViewProxy) async {
        guard let request = reveal, request.menu == menu else { return }
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled, reveal == request else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            proxy.scrollTo(request.rowID, anchor: .center)
        }
        flashRowID = request.rowID
        try? await Task.sleep(for: .milliseconds(1600))
        if flashRowID == request.rowID {
            withAnimation(.easeOut(duration: 0.35)) { flashRowID = nil }
        }
    }

    private func onOff(_ value: Bool) -> String {
        settings.t(value ? "label.on" : "label.off")
    }

    private func entry(_ id: String, _ menu: Menu, section: String, description: String? = nil, label: String? = nil,
                       options: [String] = [], value: String = "", context: String = "",
                       preparation: SearchPreparation = .none) -> SearchEntry {
        SearchEntry(
            id: id,
            menu: menu,
            label: label ?? settings.t(id),
            description: description.map { settings.t($0) } ?? "",
            section: settings.t(section),
            context: context,
            options: options,
            value: value,
            preparation: preparation
        )
    }

    /// Every row that search can find, with the row identifier that the pages scroll to.
    private var searchCatalog: [SearchEntry] {
        var entries: [SearchEntry] = [
            entry("tab.current_track", .currentTrack, section: "tab.current_track",
                  options: menuSectionTitleKeys(.currentTrack).map { settings.t($0) })
        ]
        let language = "section.language"
        let display = "settings.section.lyrics_display"
        entries += [
            entry("setting.ui_language", .general, section: language, description: "setting.ui_language_desc",
                  options: AppSettings.languages.map(\.nativeName), value: languageLabel(settings.uiLang)),
            entry("setting.pronunciation_language", .general, section: language, description: "setting.pronunciation_language_desc",
                  value: outputLanguageLabel),
            entry("setting.pronunciation_notation", .general, section: language, description: "setting.pronunciation_notation_desc",
                  options: pronunciationNotationChoices.map(\.title)),
            entry("setting.main_preview", .general, section: display, description: "setting.main_preview_desc",
                  options: [settings.t("setting.preview_hidden"), settings.t("setting.main_preview_original"),
                            settings.t("setting.main_preview_pronunciation"), settings.t("setting.main_preview_translation")]),
            entry("setting.metadata_translation", .general, section: display, description: "setting.metadata_translation_desc",
                  value: onOff(settings.metadataTranslationEnabled)),
            entry("setting.simplify_title", .general, section: display, description: "setting.simplify_title_desc",
                  value: onOff(settings.simplifyTitleEnabled)),
            entry("setting.japanese_furigana", .general, section: display, description: "setting.japanese_furigana_desc",
                  value: onOff(settings.japaneseFuriganaEnabled))
        ]
        let lookup = "settings.section.lookup"
        entries += [
            entry("setting.lyrics_type_priority", .providers, section: lookup, description: "setting.lyrics_type_priority_desc",
                  value: onOff(settings.preferLyricsTypeOverProviderOrder)),
            entry("setting.sync_data_provider_priority", .providers, section: lookup, description: "setting.sync_data_provider_priority_desc",
                  value: onOff(settings.preferSyncDataProvider))
        ]
        entries += AppSettings.lyricsProviders.map { provider in
            entry("lyricsProvider.\(provider.id)", .providers, section: "section.lyrics_providers", label: provider.name,
                  options: [settings.t("lyrics.provider.type_karaoke"), settings.t("lyrics.provider.type_synced"), settings.t("lyrics.provider.type_plain")],
                  value: onOff(settings.lyricsProviderEnabled[provider.id] ?? true))
        }
        entries.append(entry("lyrics.lrclib_endpoint.title", .providers, section: "section.lyrics_providers",
                             description: "lyrics.lrclib_endpoint.description", value: settings.lrclibCustomEndpoint))
        entries += [
            entry("ai.translation", .ai, section: "section.ai_lyrics", label: settings.t("lyrics.translation"),
                  value: onOff(settings.translationEnabled)),
            entry("ai.pronunciation", .ai, section: "section.ai_lyrics", label: settings.t("lyrics.pronunciation"),
                  value: onOff(settings.pronunciationEnabled)),
            entry("field.source", .ai, section: "section.language_rules", value: ruleSourceLabel),
            entry("field.track_language", .ai, section: "section.language_rules", value: selectedRuleSourceLabel),
            entry("field.save_target", .ai, section: "section.language_rules", value: selectedRuleTargetLabel),
            entry("lyrics.rule.reset", .ai, section: "section.language_rules")
        ]
        entries += settings.aiProviderOrder.compactMap(AppSettings.aiProviderById).map { provider in
            entry("aiProvider.\(provider.id)", .ai, section: "section.provider", description: nil, label: provider.label,
                  value: onOff(settings.aiProviderEnabled[provider.id] ?? false))
        }
        entries += connectionProviders.map { provider in
            entry("connection.\(provider.id)", .ai, section: "settings.section.connections", label: provider.label,
                  preparation: .connection(provider.id))
        }
        let selected = selectedProvider
        let connectionSection = "settings.section.connections"
        var fields = ["field.api_key"]
        if !selected.translationOnly {
            fields = ["field.base_url", "field.model", "field.max_tokens", "field.temperature"] + fields
        }
        if selected.id == "chatgpt" { fields.append("openai.connections") }
        if selected.id == "pollinations" { fields.append("pollinations.access_token") }
        entries += fields.map { key in
            entry("connection.field.\(key)", .ai, section: connectionSection, label: settings.t(key),
                  context: selected.label, preparation: .connection(selected.id))
        }
        let cultural = "setting.cultural_annotations"
        entries.append(entry("setting.cultural_annotations", .ai, section: cultural, description: "setting.cultural_annotations_desc",
                             value: onOff(settings.culturalAnnotationsEnabled)))
        for (key, value) in [("setting.cultural_font_family", ""), ("setting.cultural_font_size", "\(settings.culturalAnnotationsFontSize)px"),
                             ("setting.cultural_font_weight", "\(settings.culturalAnnotationsFontWeight)"),
                             ("setting.cultural_opacity", "\(settings.culturalAnnotationsOpacity)%")] {
            entries.append(entry("cultural.normal.\(key)", .ai, section: cultural, label: settings.t(key),
                                 value: value, context: settings.t("settings.cultural.normal"), preparation: .cultural("normal")))
        }
        for (key, value) in [("setting.cultural_font_family", ""), ("setting.cultural_font_size", "\(settings.culturalAnnotationsVinylFontSize)px"),
                             ("setting.cultural_font_weight", "\(settings.culturalAnnotationsVinylFontWeight)"),
                             ("setting.cultural_opacity", "\(settings.culturalAnnotationsVinylOpacity)%")] {
            entries.append(entry("cultural.vinyl.\(key)", .ai, section: cultural,
                                 label: "\(settings.t("vinyl.mode")) · \(settings.t(key))",
                                 value: value, context: settings.t("vinyl.mode"), preparation: .cultural("vinyl")))
        }
        entries.append(entry("setting.lyrics_alignment", .appearance, section: "section.layout", description: "setting.lyrics_alignment_desc"))
        let _ = settings.typographyRevision
        for slot in AppSettings.typographySlots {
            let style = typographyStyle(slot)
            let group = slot.id.hasPrefix("main_") ? "main" : "lyrics"
            entries.append(entry("typography.\(slot.id)", .appearance, section: "section.typography",
                                 description: "typography.slot.\(slot.id)_desc", label: settings.t("typography.slot.\(slot.id)"),
                                 value: "\(style.sizePercent)% · \(settings.t("typography.weight.\(style.weight)"))",
                                 context: settings.t(group == "main" ? "settings.typography.main" : "settings.typography.lyrics"),
                                 preparation: .typography(group)))
        }
        entries += [
            entry("setting.creator_speaker_colors", .appearance, section: "section.speaker_colors",
                  description: "setting.creator_speaker_colors_desc", value: onOff(settings.useSyncCreatorSpeakerColors)),
            entry("speakers.palette", .appearance, section: "section.speaker_colors", label: settings.t("section.speaker_colors"),
                  options: ["normal", "duet", "male", "female"].map { settings.t("speaker_color.\($0)") })
        ]
        let background = "section.background"
        entries += [
            entry("setting.background_mode", .appearance, section: background, description: "setting.background_mode_desc",
                  options: backgroundModeChoices.map(\.title), value: backgroundModeLabel(settings.backgroundMode)),
            entry("setting.video_fallback", .appearance, section: background, preparation: .reveal),
            entry("setting.video_aspect", .appearance, section: background, preparation: .reveal),
            entry("setting.video_edge_to_edge", .appearance, section: background, description: "setting.video_edge_to_edge_desc", preparation: .reveal),
            entry("setting.video_scale", .appearance, section: background, value: "\(settings.backgroundVideoScale)%", preparation: .reveal),
            entry("field.solid_color", .appearance, section: background, value: settings.backgroundSolidColor.uppercased(), preparation: .reveal),
            entry("setting.brightness", .appearance, section: background, value: "\(settings.backgroundBrightness)%"),
            entry("setting.blur", .appearance, section: background, value: "\(settings.backgroundBlur)%"),
            entry("setting.noise", .appearance, section: background, value: onOff(settings.backgroundNoiseEnabled)),
            entry("setting.reduce_motion", .appearance, section: background, value: onOff(settings.backgroundReduceMotionEnabled)),
            entry("lyrics.background.override", .appearance, section: "section.track_background")
        ]
        let interlude = "settings.section.interlude"
        let karaoke = "settings.section.karaoke"
        entries += [
            entry("setting.auto_interlude", .lyrics, section: interlude, description: "setting.auto_interlude_desc",
                  value: onOff(settings.autoInstrumentalBreakEnabled)),
            entry("setting.interlude_labels", .lyrics, section: interlude, description: "setting.interlude_labels_desc",
                  value: onOff(settings.interludeLabelsEnabled)),
            entry("setting.synced_karaoke_animation", .lyrics, section: karaoke, description: "setting.synced_karaoke_animation_desc",
                  value: onOff(settings.syncedLyricsKaraokeAnimationEnabled)),
            entry("setting.karaoke_bounce_effect", .lyrics, section: karaoke, description: "setting.karaoke_bounce_effect_desc",
                  value: onOff(settings.karaokeBounceEffectEnabled)),
            entry("setting.karaoke_display_granularity", .lyrics, section: karaoke, description: "setting.karaoke_display_granularity_desc",
                  options: karaokeGranularityOptions.map { $0.title })
        ]
        let player = "section.player"
        let landscape = "settings.section.landscape"
        let pip = "section.pip"
        let vinyl = "vinyl.mode"
        let tonearm = "vinyl.settings.tonearm_title"
        entries += [
            entry("setting.title_tap_action", .player, section: player, options: titleTapChoices.map(\.title)),
            entry("setting.lyrics_not_found_notice", .player, section: player, value: onOff(settings.lyricsNotFoundNoticeEnabled)),
            entry("setting.keep_screen_on", .player, section: player, description: "setting.keep_screen_on_desc", value: onOff(settings.keepScreenOn)),
            entry("setting.landscape_original_lyrics", .player, section: landscape, description: "setting.landscape_original_lyrics_desc",
                  value: onOff(settings.landscapeOriginalLyricsEnabled)),
            entry("setting.landscape_artwork", .player, section: landscape, value: onOff(settings.landscapeArtworkEnabled)),
            entry("setting.landscape_auto_hide", .player, section: landscape, description: "setting.landscape_auto_hide_desc",
                  value: onOff(settings.landscapeAutoHideControls)),
            entry("setting.landscape_center_no_lyrics", .player, section: landscape, description: "setting.landscape_center_no_lyrics_desc",
                  value: onOff(settings.landscapeCenterNoLyrics)),
            entry("setting.pip_show_artwork", .player, section: pip, description: "setting.pip_show_artwork_desc", value: onOff(settings.pipShowArtwork)),
            entry("setting.pip_background", .player, section: pip, description: "setting.pip_background_desc", options: pipBackgroundChoices.map(\.title)),
            entry("setting.pip_orientation", .player, section: pip, description: "setting.pip_orientation_desc"),
            entry("setting.pip_lyrics_alignment", .player, section: pip, description: "setting.pip_lyrics_alignment_desc"),
            entry("setting.pip_lyrics_size", .player, section: pip, description: "setting.pip_lyrics_size_desc",
                  value: "\(AppSettings.clampPipLyricsSizePercent(settings.pipLyricsSizePercent))%"),
            entry("setting.pip_translation_size", .player, section: pip, description: "setting.pip_translation_size_desc",
                  value: "\(AppSettings.clampPipTranslationSizePercent(settings.pipTranslationSizePercent))%"),
            entry("vinyl.settings.album_size", .player, section: vinyl, description: "vinyl.settings.album_size_desc",
                  value: "\(AppSettings.clampVinylSizePercent(settings.vinylAlbumSizePercent))%"),
            entry("vinyl.settings.record_size", .player, section: vinyl, description: "vinyl.settings.record_size_desc",
                  value: "\(AppSettings.clampVinylSizePercent(settings.vinylRecordSizePercent))%"),
            entry("vinyl.settings.animations", .player, section: vinyl, description: "vinyl.settings.animations_desc", value: onOff(settings.vinylAnimationsEnabled)),
            entry("vinyl.settings.track_change_animations", .player, section: vinyl, description: "vinyl.settings.track_change_animations_desc",
                  value: onOff(settings.vinylTrackChangeAnimationsEnabled)),
            entry("vinyl.settings.rotation_speed", .player, section: vinyl, description: "vinyl.settings.rotation_speed_desc",
                  value: "\(settings.vinylRotationSpeedPercent)%"),
            entry("vinyl.settings.center_rotation", .player, section: vinyl, description: "vinyl.settings.center_rotation_desc",
                  value: onOff(settings.vinylCenterRotationEnabled)),
            entry("vinyl.settings.lyrics", .player, section: vinyl, description: "vinyl.settings.lyrics_desc", value: onOff(settings.vinylLyricsEnabled)),
            entry("vinyl.settings.tonearm_style", .player, section: tonearm, description: "vinyl.settings.tonearm_style_desc",
                  options: tonearmStyleChoices.map(\.title)),
            entry("vinyl.settings.tonearm_finish", .player, section: tonearm, description: "vinyl.settings.tonearm_finish_desc"),
            entry("vinyl.settings.tonearm_size", .player, section: tonearm, description: "vinyl.settings.tonearm_size_desc",
                  value: "\(AppSettings.clampVinylTonearmSizePercent(settings.vinylTonearmSizePercent))%")
        ]
        for slot in AppSettings.vinylTypographySlots {
            let style = typographyStyle(slot)
            entries.append(entry("typography.\(slot.id)", .player, section: "section.typography",
                                 description: "typography.slot.\(slot.id)_desc", label: settings.t("typography.slot.\(slot.id)"),
                                 value: "\(style.sizePercent)% · \(settings.t("typography.weight.\(style.weight)"))"))
        }
        let account = "section.account"
        let spotify = "section.spotify_api"
        let sync = "lyrics.tab.sync"
        let tools = "section.tools"
        entries += [
            entry("account.discord", .system, section: account, description: "creator_privacy.section_desc", label: "Discord"),
            entry("creator_privacy.private_title", .system, section: account, description: "creator_privacy.private_desc"),
            entry("cloud_sync.section", .system, section: account, description: "cloud_sync.section_desc"),
            entry("cloud_sync.refresh", .system, section: account, context: settings.t("cloud_sync.section")),
            entry("cloud_sync.upload", .system, section: account, context: settings.t("cloud_sync.section")),
            entry("cloud_sync.apply", .system, section: account, context: settings.t("cloud_sync.section")),
            entry("cloud_sync.delete", .system, section: account, context: settings.t("cloud_sync.section")),
            entry("spotify.setup.instructions", .system, section: spotify),
            entry("field.spotify_client_id", .system, section: spotify),
            entry("field.spotify_client_secret", .system, section: spotify, description: "field.spotify_client_secret_role"),
            entry("field.redirect_uri", .system, section: spotify, value: SpotifyRedirectConfiguration.uri),
            entry("setting.spotify_web_api", .system, section: spotify, description: "setting.spotify_web_api_desc",
                  value: onOff(settings.spotifyWebAPIEnabled)),
            entry("button.spotify_save", .system, section: spotify),
            entry("field.live_source", .system, section: spotify, value: liveSourceText),
            entry("lyrics.global_sync.title", .system, section: sync, description: "lyrics.global_sync.help", value: formatSignedMs(model.globalOffsetMs)),
            entry("lyrics.sync.title", .system, section: sync, description: "lyrics.sync.help", value: formatSignedMs(model.trackOffsetMs)),
            entry("lyrics.bluetooth_sync.title", .system, section: sync, description: "lyrics.bluetooth_sync.help", value: formatSignedMs(model.bluetoothOffsetMs)),
            entry("lyrics.video_sync.title", .system, section: sync, description: "lyrics.video_sync.help", value: formatSignedMs(model.videoOffsetMs)),
            entry("update.check", .system, section: "section.update"),
            entry("button.open_release", .system, section: "section.update"),
            entry("button.reload_current", .system, section: tools),
            entry("button.debug_log", .system, section: tools),
            entry("button.ai_cache_clear", .system, section: tools),
            entry("button.clear_current", .system, section: tools),
            entry("button.clear_all", .system, section: tools)
        ]
        if model.spotifyWebAPIAuthorizationStored {
            entries.append(entry("spotify.disconnect_oauth", .system, section: spotify, description: "spotify.disconnect_oauth_desc"))
        }
        return entries
    }

    // MARK: Menu pages

    private func menuPage(_ menu: Menu) -> some View {
        let hasPreview = [Menu.ai, .appearance, .player].contains(menu)
        // Short pages scroll the preview away with the content instead of covering most of the screen.
        let tallEnough = settingsHeight == 0 || settingsHeight >= Self.pinnedPreviewMinScreenHeight
        let pinned = hasPreview && tallEnough && verticalSizeClass != .compact && !dynamicTypeSize.isAccessibilitySize
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if hasPreview && !pinned {
                        previewPanel(menu, pinned: false)
                            .padding(.top, 6)
                    }
                    menuSections(menu)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 48)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
                .background(SettingsScrollKeeper(key: menu.rawValue, memory: scrollMemory, restores: reveal?.menu != menu))
            }
            // Identify the scroll view itself; set after the inset it would also rename the pinned preview toggle.
            .accessibilityIdentifier("settings.scroll")
            .coordinateSpace(.named(Self.pageSpace))
            .safeAreaInset(edge: .top, spacing: 0) {
                if pinned { previewPanel(menu, pinned: true) }
            }
            .onPreferenceChange(SettingsSectionOffsetKey.self) { offsets in
                updatePreviewSection(offsets)
            }
            .scrollDismissesKeyboard(.interactively)
            .task(id: reveal?.token) {
                await performReveal(menu: menu, proxy: proxy)
            }
        }
        .background(palette.background.ignoresSafeArea())
        .navigationTitle(settings.t(menu.titleKey))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { closeButton }
        }
        .toolbarBackground(palette.background, for: .navigationBar)
    }

    // Bound the navigation payload independently of the largest settings page. A ViewBuilder
    // switch combines every page into nested _ConditionalContent values (31KB before boxing).
    // Release builds copy/allocate those values along the entire destination builder chain;
    // Debug's implicit opaque type erasure can conceal the device-side stack pressure.
    // Erase a deferred page before it enters that chain, not the already-built switch.
    // The small wrapper also prevents the optimizer from reserving every page's temporary
    // construction storage in this function before it knows which category was selected.
    private func menuSections(_ menu: Menu) -> AnyView {
        switch menu {
        case .currentTrack:
            return AnyView(SettingsPageContent {
                LyricsMetaMenuOverlay(
                    visible: .constant(true),
                    selectedTab: $currentTrackTab,
                    screenHeight: settingsHeight,
                    isSettingsPage: true
                )
                .id(model.currentTrackKey)
                .settingsRow("tab.current_track", flashing: flashRowID)
            })
        case .general: return AnyView(SettingsPageContent { generalSettingsPage })
        case .providers: return AnyView(SettingsPageContent { lyricsProvidersSettingsPage })
        case .ai: return AnyView(SettingsPageContent { aiSettingsPage })
        case .appearance: return AnyView(SettingsPageContent { appearanceSettingsPage })
        case .lyrics: return AnyView(SettingsPageContent { lyricsSettingsPage })
        case .player: return AnyView(SettingsPageContent { playerSettingsPage })
        case .system: return AnyView(SettingsPageContent { systemSettingsPage })
        }
    }

    /// Section header plus content; sections with a live preview report where they are.
    private func section<Content: View>(
        _ id: String,
        title: String,
        subtitle: String = "",
        tracksPreview: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: title, subtitle: subtitle)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
        }
        // Sections keep their natural height, so a parent stack can never squeeze their rows or cards.
        .fixedSize(horizontal: false, vertical: true)
        .id(id)
        .background {
            if tracksPreview {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: SettingsSectionOffsetKey.self,
                        value: [id: geometry.frame(in: .named(Self.pageSpace)).minY]
                    )
                }
            }
        }
    }

    private func updatePreviewSection(_ offsets: [String: CGFloat]) {
        guard !offsets.isEmpty else { return }
        let line: CGFloat = 320
        let passed = offsets.filter { $0.value <= line }
        let active = passed.max { $0.value < $1.value }?.key ?? offsets.min { $0.value < $1.value }?.key ?? ""
        if active != previewSectionID { previewSectionID = active }
    }

    private func previewKind(_ menu: Menu) -> PreviewKind {
        switch menu {
        case .ai:
            return .annotation
        case .player:
            return ["player.vinyl", "player.tonearm", "player.vinylTypography"].contains(previewSectionID) ? .vinyl : .pip
        default:
            return previewSectionID == "appearance.typography" && typographyGroup == "main" ? .main : .lyrics
        }
    }

    private static let pinnedPreviewMinScreenHeight: CGFloat = 700

    /// A pinned preview keeps its natural height but never takes much more than a third of the screen.
    private var pinnedPreviewMaxHeight: CGFloat {
        settingsHeight > 0 ? max(180, settingsHeight * 0.36) : .infinity
    }

    private func previewPanel(_ menu: Menu, pinned: Bool) -> some View {
        let expanded = previewExpanded[menu] ?? (menu == .appearance)
        return VStack(spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    previewExpanded[menu] = !expanded
                }
            } label: {
                HStack(spacing: 8) {
                    Text(settings.t("settings.preview"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(palette.text3)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.line2))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(settings.t(expanded ? "label.on" : "label.off"))
            .accessibilityIdentifier("settings.preview.toggle")
            if expanded {
                // The previews draw full-bleed backgrounds; without a fixed vertical size they would grow to fill
                // whatever height the pinned inset is offered.
                SettingsNaturalHeightLayout(maxHeight: pinned ? pinnedPreviewMaxHeight : .infinity) {
                    previewContent(previewKind(menu))
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .transition(.opacity)
            }
        }
        .padding(.horizontal, pinned ? 16 : 0)
        .padding(.top, pinned ? 6 : 0)
        .padding(.bottom, 8)
        .frame(maxWidth: pinned ? 712 : .infinity)
        .frame(maxWidth: .infinity)
        .background(pinned ? palette.background : Color.clear)
    }

    @ViewBuilder
    private func previewContent(_ kind: PreviewKind) -> some View {
        switch kind {
        case .lyrics: SettingsLyricsPreview()
        case .annotation: SettingsLyricsPreview(annotation: true)
        case .main: SettingsMainScreenPreview()
        case .pip: SettingsPipPreview()
        case .vinyl: SettingsVinylPreview()
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: SettingsSheet) -> some View {
        switch sheet {
        case .uiLanguage:
            SettingsOptionSheet(
                title: settings.t("setting.ui_language"),
                options: AppSettings.languages.map { SettingsChoice(value: $0.code, title: "\($0.nativeName) · \($0.name)") },
                selection: settings.uiLang,
                searchPrompt: settings.t("button.search"),
                closeLabel: settings.t("button.close"),
                emptyText: settings.t("settings.no_results"),
                onSelect: { uiLanguageBinding.wrappedValue = $0 }
            )
        case .outputLanguage:
            SettingsOptionSheet(
                title: settings.t("setting.pronunciation_language"),
                options: [SettingsChoice(value: AppSettings.outputLangSameUI, title: settings.t("language.same_as_ui"))]
                    + AppSettings.languages.map { SettingsChoice(value: $0.code, title: "\($0.nativeName) · \($0.name)") },
                selection: settings.outputLang,
                searchPrompt: settings.t("button.search"),
                closeLabel: settings.t("button.close"),
                emptyText: settings.t("settings.no_results"),
                onSelect: { outputLanguageBinding.wrappedValue = $0 }
            )
        case .ruleSource:
            SettingsOptionSheet(
                title: settings.t("field.source"),
                options: [SettingsChoice(value: "auto", title: settings.t("language.auto_default"))]
                    + AppSettings.languages.map { SettingsChoice(value: $0.code, title: "\($0.nativeName) · \($0.name)") },
                selection: model.selectedRuleSourceLang,
                searchPrompt: settings.t("button.search"),
                closeLabel: settings.t("button.close"),
                emptyText: settings.t("settings.no_results"),
                onSelect: { selectedRuleSourceBinding.wrappedValue = $0 }
            )
        case .aiModel:
            SettingsOptionSheet(
                title: settings.t("field.model"),
                options: aiModelChoices,
                selection: settings.model,
                searchPrompt: settings.t("button.search"),
                closeLabel: settings.t("button.close"),
                emptyText: settings.t("settings.no_results"),
                onSelect: { settings.model = $0 }
            )
        }
    }

    // MARK: Shared row builders

    private func toggleRow(_ key: String, descriptionKey: String? = nil, isOn: Binding<Bool>,
                           identifier: String? = nil, rowID: String? = nil, indent: Bool = false) -> some View {
        SettingsToggleRow(
            title: settings.t(key),
            description: descriptionKey.map { settings.t($0) } ?? "",
            isOn: isOn,
            identifier: identifier ?? "settings.toggle.\(key)",
            indent: indent
        )
        .settingsRow(rowID ?? key, flashing: flashRowID)
    }

    private func sliderRow(_ key: String, descriptionKey: String? = nil, rowID: String? = nil, value: Binding<Double>,
                           range: ClosedRange<Double>, step: Double = 1, unit: String = "%", decimals: Int = 0,
                           onEditingChanged: @escaping (Bool) -> Void = { _ in }) -> some View {
        SettingsStackRow(title: settings.t(key), description: descriptionKey.map { settings.t($0) } ?? "") {
            SettingsValueSlider(label: settings.t(key), value: value, range: range, step: step, unit: unit,
                                decimals: decimals, onEditingChanged: onEditingChanged)
        }
        .settingsRow(rowID ?? key, flashing: flashRowID)
    }

    private func segmentedRow(_ key: String, descriptionKey: String? = nil, rowID: String? = nil, selection: Binding<String>,
                              options: [(value: String, title: String)], icons: [String: String] = [:],
                              swatches: [String: Color] = [:]) -> some View {
        SettingsStackRow(title: settings.t(key), description: descriptionKey.map { settings.t($0) } ?? "") {
            SettingsSegmentedPicker(title: settings.t(key), selection: selection, options: options, icons: icons, swatches: swatches)
        }
        .settingsRow(rowID ?? key, flashing: flashRowID)
    }

    private func cardsRow(_ key: String, descriptionKey: String? = nil, selection: Binding<String>,
                          options: [SettingsChoice], columns: Int = 2) -> some View {
        SettingsStackRow(title: settings.t(key), description: descriptionKey.map { settings.t($0) } ?? "") {
            SettingsOptionCards(title: settings.t(key), options: options, selection: selection, columns: columns)
        }
        .settingsRow(key, flashing: flashRowID)
    }

    /// Shown under a row that search revealed although its condition currently hides it.
    private func conditionNote(_ controllerKey: String) -> some View {
        SettingsNoteRow(text: settings.tf("settings.conditional_format", settings.t(controllerKey)),
                        systemImage: "info.circle", color: palette.accentText)
    }

    private func languageLabel(_ code: String) -> String {
        let language = AppSettings.languageInfo(code)
        return "\(language.nativeName) · \(language.name)"
    }

    private var outputLanguageLabel: String {
        settings.outputLang == AppSettings.outputLangSameUI ? settings.t("language.same_as_ui") : languageLabel(settings.outputLang)
    }

    private func formatSignedMs(_ offsetMs: Int) -> String {
        offsetMs > 0 ? "+\(offsetMs)ms" : "\(offsetMs)ms"
    }

    private func rankBadge(_ rank: Int) -> some View {
        Text("\(rank)")
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(palette.text3)
            .multilineTextAlignment(.center)
            .debugSettingsBadgeTextBounds("rank.\(rank)")
            .frame(minWidth: 22, minHeight: 22, alignment: .center)
            .background(palette.surface3, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .debugSettingsBadgeBounds("rank.\(rank)")
    }

    private func providerMoveButtons(index: Int, count: Int, name: String, move: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 2) {
            SettingsIconButton(systemImage: "chevron.up", label: "\(name), \(settings.t("accessibility.move_up"))") { move(-1) }
                .disabled(index == 0)
            SettingsIconButton(systemImage: "chevron.down", label: "\(name), \(settings.t("accessibility.move_down"))") { move(1) }
                .disabled(index == count - 1)
        }
    }

    private func cardBackground<Content: View>(_ content: Content) -> some View {
        content
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.line))
    }

    // MARK: General

    private var pronunciationNotationChoices: [SettingsChoice] {
        [
            SettingsChoice(value: AppSettings.pronunciationNotationTranslation, title: settings.t("pronunciation.notation.translation")),
            SettingsChoice(value: AppSettings.pronunciationNotationLatin, title: settings.t("pronunciation.notation.latin")),
            SettingsChoice(value: AppSettings.pronunciationNotationIPA, title: settings.t("pronunciation.notation.ipa"))
        ]
    }

    private var generalSettingsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            section("general.language", title: settings.t("section.language"), subtitle: settings.t("section.language_desc")) {
                SettingsGroup {
                    SettingsStackRow(title: settings.t("setting.ui_language"), description: settings.t("setting.ui_language_desc")) {
                        SettingsPickerButton(title: settings.t("setting.ui_language"), value: languageLabel(settings.uiLang)) {
                            activeSheet = .uiLanguage
                        }
                    }
                    .settingsRow("setting.ui_language", flashing: flashRowID)
                    SettingsStackRow(title: settings.t("setting.pronunciation_language"), description: settings.t("setting.pronunciation_language_desc")) {
                        SettingsPickerButton(title: settings.t("setting.pronunciation_language"), value: outputLanguageLabel) {
                            activeSheet = .outputLanguage
                        }
                    }
                    .settingsRow("setting.pronunciation_language", flashing: flashRowID)
                    cardsRow("setting.pronunciation_notation", descriptionKey: "setting.pronunciation_notation_desc",
                             selection: pronunciationNotationBinding, options: pronunciationNotationChoices)
                }
            }
            section("general.display", title: settings.t("settings.section.lyrics_display")) {
                SettingsGroup {
                    SettingsStackRow(title: settings.t("setting.main_preview"), description: settings.t("setting.main_preview_desc")) {
                        SettingsFlowLayout(spacing: 8, lineSpacing: 8) {
                            Toggle(settings.t("setting.preview_hidden"), isOn: previewHiddenBinding)
                                .toggleStyle(SettingsLayerChipStyle(color: nil))
                            Toggle(settings.t("setting.main_preview_original"), isOn: previewItemBinding(AppSettings.previewItemOriginal))
                                .toggleStyle(SettingsLayerChipStyle(color: palette.layerOriginal))
                            Toggle(settings.t("setting.main_preview_pronunciation"), isOn: previewItemBinding(AppSettings.previewItemPronunciation))
                                .toggleStyle(SettingsLayerChipStyle(color: palette.layerPhonetic))
                            Toggle(settings.t("setting.main_preview_translation"), isOn: previewItemBinding(AppSettings.previewItemTranslation))
                                .toggleStyle(SettingsLayerChipStyle(color: palette.layerTranslation))
                        }
                    }
                    .settingsRow("setting.main_preview", flashing: flashRowID)
                    toggleRow("setting.metadata_translation", descriptionKey: "setting.metadata_translation_desc",
                              isOn: metadataTranslationBinding, identifier: "settings.toggle.metadata")
                    toggleRow("setting.simplify_title", descriptionKey: "setting.simplify_title_desc",
                              isOn: settingsSavedBinding(\.simplifyTitleEnabled))
                    toggleRow("setting.japanese_furigana", descriptionKey: "setting.japanese_furigana_desc",
                              isOn: japaneseFuriganaBinding)
                }
            }
        }
    }

    // MARK: Lyrics providers

    private var lyricsProvidersSettingsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            section("providers.lookup", title: settings.t("settings.section.lookup"), subtitle: settings.t("settings.section.lookup_desc")) {
                SettingsGroup {
                    toggleRow("setting.lyrics_type_priority", descriptionKey: "setting.lyrics_type_priority_desc",
                              isOn: lyricsTypePriorityBinding)
                    toggleRow("setting.sync_data_provider_priority", descriptionKey: "setting.sync_data_provider_priority_desc",
                              isOn: syncDataProviderPriorityBinding)
                    lookupChain
                }
            }
            section("providers.list", title: settings.t("section.lyrics_providers"), subtitle: settings.t("section.lyrics_providers_desc")) {
                ForEach(Array(settings.lyricsProviderOrder.enumerated()), id: \.element) { index, providerId in
                    if let provider = AppSettings.lyricsProviderById(providerId) {
                        lyricsProviderSettingsCard(provider, index: index)
                    }
                }
            }
        }
    }

    /// The order in which lyrics are tried, drawn from the two switches above and the provider list.
    private var lookupChain: some View {
        var steps: [(title: String, accent: Bool)] = []
        if settings.preferSyncDataProvider { steps.append((title: "ivLyrics Sync", accent: true)) }
        if settings.preferLyricsTypeOverProviderOrder {
            steps += ["lyrics.provider.type_karaoke", "lyrics.provider.type_synced", "lyrics.provider.type_plain"].map { (title: settings.t($0), accent: false) }
        } else {
            steps += settings.lyricsProviderOrder
                .filter { settings.lyricsProviderEnabled[$0] ?? true }
                .compactMap { AppSettings.lyricsProviderById($0)?.name }
                .map { (title: $0, accent: false) }
        }
        return SettingsFlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 6) {
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(palette.text4)
                    }
                    Text(step.title)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(step.accent ? palette.accentText : palette.text)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 28)
                        .background(step.accent ? palette.accentSoft : palette.surface2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(step.accent ? palette.accentLine : palette.line2))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsRowSeparator()
        .accessibilityElement(children: .combine)
    }

    private func lyricsProviderSettingsCard(_ provider: AppSettings.LyricsProvider, index: Int) -> some View {
        let enabled = settings.lyricsProviderEnabled[provider.id] ?? true
        let header = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 10))
        return VStack(alignment: .leading, spacing: 10) {
            header {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    rankBadge(index + 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.name)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(palette.text)
                        Text(settings.t("lyrics.provider.author_default"))
                            .font(.footnote)
                            .foregroundStyle(palette.text3)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .opacity(enabled ? 1 : 0.5)
                HStack(spacing: 8) {
                    providerMoveButtons(index: index, count: settings.lyricsProviderOrder.count, name: provider.name) { offset in
                        settings.moveLyricsProvider(provider.id, offset: offset)
                        model.reloadLyrics(bypassCache: true)
                    }
                    Toggle(provider.name, isOn: lyricsProviderEnabledBinding(provider.id))
                        .labelsHidden()
                        .toggleStyle(SettingsSwitchStyle())
                        .fixedSize()
                        .accessibilityLabel("\(provider.name), \(settings.t("lyrics.provider.enabled"))")
                        .accessibilityIdentifier("settings.lyrics.toggle.\(provider.id)")
                        .debugSettingsHitArea("settings.lyrics.toggle.\(provider.id)")
                }
            }
            SettingsFlowLayout(spacing: 8, lineSpacing: 0) {
                Toggle(settings.t("lyrics.provider.type_karaoke"), isOn: lyricsProviderTypeBinding(provider.id, type: AppSettings.lyricsTypeKaraoke))
                    .toggleStyle(SettingsChipToggleStyle(systemImage: "music.mic"))
                    .accessibilityLabel(provider.supportsNativeKaraoke ? settings.t("lyrics.provider.type_karaoke") : settings.t("lyrics.provider.type_karaoke_sync_data"))
                if provider.supportsSynced {
                    Toggle(settings.t("lyrics.provider.type_synced"), isOn: lyricsProviderTypeBinding(provider.id, type: AppSettings.lyricsTypeSynced))
                        .toggleStyle(SettingsChipToggleStyle(systemImage: "clock"))
                }
                if provider.supportsPlain {
                    Toggle(settings.t("lyrics.provider.type_plain"), isOn: lyricsProviderTypeBinding(provider.id, type: AppSettings.lyricsTypePlain))
                        .toggleStyle(SettingsChipToggleStyle(systemImage: "text.alignleft"))
                }
            }
            .opacity(enabled ? 1 : 0.5)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(settings.t("lyrics.provider.allowed_types"))
            if provider.id == "lrclib" {
                LrclibEndpointSettingsView()
                    .settingsRow("lyrics.lrclib_endpoint.title", flashing: flashRowID)
            }
            if let projectURL = provider.projectURL, let url = URL(string: projectURL) {
                Button { openURL(url) } label: {
                    SettingsButtonLabel(title: settings.t("lyrics.provider.open_project"), systemImage: "arrow.up.right.square")
                }
                .buttonStyle(SettingsButtonStyle())
                .accessibilityLabel("\(provider.name), \(settings.t("lyrics.provider.open_project"))")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.line))
        .settingsRow("lyricsProvider.\(provider.id)", flashing: flashRowID)
    }

    // MARK: AI

    private var aiSettingsPage: some View {
        let owners = aiTaskOwners
        return VStack(alignment: .leading, spacing: 0) {
            section("ai.layers", title: settings.t("section.ai_lyrics"), subtitle: settings.t("section.ai_lyrics_desc")) {
                let tiles = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: 8))
                    : AnyLayout(HStackLayout(spacing: 8))
                tiles {
                    SettingsToggleTile(title: settings.t("lyrics.translation"), systemImage: "translate", color: palette.layerTranslation,
                                       onText: settings.t("label.on"), offText: settings.t("label.off"),
                                       isOn: $settings.translationEnabled, identifier: "settings.toggle.translation")
                        .settingsRow("ai.translation", flashing: flashRowID)
                    SettingsToggleTile(title: settings.t("lyrics.pronunciation"), systemImage: "speaker.wave.2", color: palette.layerPhonetic,
                                       onText: settings.t("label.on"), offText: settings.t("label.off"),
                                       isOn: $settings.pronunciationEnabled, identifier: "settings.toggle.pronunciation")
                        .settingsRow("ai.pronunciation", flashing: flashRowID)
                }
                aiLayerSample
            }
            section("ai.rules", title: settings.t("section.language_rules")) {
                languageRulesGroup
            }
            section("ai.providers", title: settings.t("section.provider"), subtitle: settings.t("setting.ai_provider_order_desc")) {
                SettingsFlowLayout(spacing: 6, lineSpacing: 6) {
                    ownerPill(settings.t("lyrics.translation"), color: palette.layerTranslation, owner: owners.translation)
                    ownerPill(settings.t("lyrics.pronunciation"), color: palette.layerPhonetic, owner: owners.pronunciation)
                }
                ForEach(Array(settings.aiProviderOrder.enumerated()), id: \.element) { index, providerId in
                    if let provider = AppSettings.aiProviderById(providerId) {
                        aiProviderSettingsCard(provider, index: index, owners: owners)
                    }
                }
            }
            section("ai.connections", title: settings.t("settings.section.connections"), subtitle: settings.t("settings.section.connections_desc")) {
                ForEach(connectionProviders) { provider in
                    aiConnectionCard(provider)
                }
            }
            section("ai.cultural", title: settings.t("setting.cultural_annotations"), tracksPreview: true) {
                culturalAnnotationsGroup
            }
        }
    }

    private var aiLayerSample: some View {
        let line = SettingsPreviewSamples.sky
        return VStack(alignment: .leading, spacing: 3) {
            Text(line.original)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.text)
            // Lines of a layer that is off turn neutral grey instead of fading out, so they stay readable on both themes.
            Text(line.pronunciation)
                .font(.system(size: 13))
                .foregroundStyle(settings.pronunciationEnabled ? palette.layerPhonetic : palette.text3)
                .opacity(settings.pronunciationEnabled ? 1 : 0.8)
            Text(settings.t(line.translationKey))
                .font(.system(size: 14))
                .foregroundStyle(settings.translationEnabled ? palette.layerTranslation : palette.text3)
                .opacity(settings.translationEnabled ? 1 : 0.8)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.line))
        .accessibilityHidden(true)
    }

    private func ownerPill(_ task: String, color: Color, owner: String?) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(task)
                .foregroundStyle(palette.text3)
            Text(owner ?? settings.t("settings.provider.none"))
                .fontWeight(owner == nil ? .regular : .medium)
                .foregroundStyle(owner == nil ? palette.text3 : palette.text)
        }
        .font(.footnote)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 30)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(palette.line2))
        .accessibilityElement(children: .combine)
    }

    /// Which provider is tried first for each task: the first enabled one that can actually run.
    private var aiTaskOwners: (translation: String?, pronunciation: String?) {
        let snapshot = settings.snapshot
        var translation: String?
        for providerId in snapshot.enabledAIProviderOrder {
            guard let provider = AppSettings.aiProviderById(providerId) else { continue }
            if provider.isKeyless {
                translation = provider.label
            } else if provider.isLocal {
                let tier = LocalAI.Tier.stored(settings.localAITier)
                guard LocalAIController.shared.state.downloadedTiers.contains(tier) else { continue }
                translation = provider.label
            } else if let selected = snapshot.selectingAIProvider(providerId), selected.hasApiKey,
                      provider.translationOnly || selected.hasModel {
                translation = provider.label
            }
            if translation != nil { break }
        }
        let pronunciation = snapshot.readyAIProviderSnapshots.first?.provider.label
        return (translation, pronunciation)
    }

    private var languageRulesGroup: some View {
        let infoLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 6))
            : AnyLayout(HStackLayout(spacing: 6))
        return SettingsGroup {
            infoLayout {
                ruleInfo(settings.t("field.track_language"), value: selectedRuleSourceLabel)
                ruleInfo(settings.t("field.save_target"), value: selectedRuleTargetLabel)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .settingsRow("field.track_language", flashing: flashRowID)
            .overlay(alignment: .bottom) { Color.clear.frame(height: 1).id("field.save_target") }
            SettingsStackRow(title: settings.t("field.source")) {
                SettingsPickerButton(title: settings.t("field.source"), value: ruleSourceLabel) {
                    activeSheet = .ruleSource
                }
            }
            .settingsRow("field.source", flashing: flashRowID)
            rulesTable
        }
    }

    private func ruleInfo(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption)
                .foregroundStyle(palette.text3)
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(palette.line))
        .accessibilityElement(children: .combine)
    }

    /// Default rule and the rule of the current song language, each with translation / pronunciation.
    private var rulesTable: some View {
        let source = effectiveRuleSourceLang
        let hasSourceRow = source != AppSettings.defaultSourceLang
        let inherited = hasSourceRow && settings.snapshot.languageRules[AppSettings.normalizeSourceLanguageKey(source)] == nil
        let stacked = dynamicTypeSize.isAccessibilitySize
        return VStack(alignment: .leading, spacing: 0) {
            if !stacked {
                HStack(spacing: 12) {
                    Text(settings.t("field.source"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ruleColumn(translation: true) {
                        ruleColumnTitle(settings.t("lyrics.translation"), color: palette.layerTranslation)
                    }
                    ruleColumn(translation: false) {
                        ruleColumnTitle(settings.t("lyrics.pronunciation"), color: palette.layerPhonetic)
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(palette.text3)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)
                .settingsRowSeparator()
                .accessibilityHidden(true)
            }
            ruleRow(title: settings.t("settings.rules.default"), badge: nil, source: AppSettings.defaultSourceLang,
                    inherited: false, stacked: stacked)
                .background(palette.surface2)
            if hasSourceRow {
                ruleRow(title: languageLabel(source), badge: settings.t("field.track_language"), source: source,
                        inherited: inherited, stacked: stacked)
                    .overlay(alignment: .leading) { palette.accent.frame(width: 2).accessibilityHidden(true) }
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        settings.resetLanguageRule(sourceLang: effectiveRuleSourceLang)
                        model.saveLanguageRuleAndRegenerate()
                    } label: {
                        SettingsButtonLabel(title: settings.t("lyrics.rule.reset"), systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(effectiveRuleSourceLang == AppSettings.defaultSourceLang)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .settingsRow("lyrics.rule.reset", flashing: flashRowID)
            }
        }
    }

    private func ruleColumnTitle(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 7, height: 7)
            Text(title).fixedSize()
        }
        .font(.caption.weight(.medium))
    }

    /// A table column as wide as its caption (at least a switch), so header and rows stay aligned
    /// in every language without breaking the caption mid-word.
    private func ruleColumn<Content: View>(translation: Bool, @ViewBuilder content: () -> Content) -> some View {
        ZStack {
            ruleColumnTitle(settings.t(translation ? "lyrics.translation" : "lyrics.pronunciation"),
                            color: translation ? palette.layerTranslation : palette.layerPhonetic)
                .hidden()
            Color.clear.frame(width: 56, height: 1)
            content()
        }
    }

    private func ruleRow(title: String, badge: String?, source: String, inherited: Bool, stacked: Bool) -> some View {
        let name = VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
            if let badge { SettingsPill(text: badge, tone: .accent) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        return Group {
            if stacked {
                VStack(alignment: .leading, spacing: 2) {
                    name
                    Toggle(isOn: ruleBinding(source: source, translation: true)) {
                        ruleColumnTitle(settings.t("lyrics.translation"), color: palette.layerTranslation)
                    }
                    .toggleStyle(SettingsSwitchStyle())
                    .opacity(inherited ? 0.6 : 1)
                    Toggle(isOn: ruleBinding(source: source, translation: false)) {
                        ruleColumnTitle(settings.t("lyrics.pronunciation"), color: palette.layerPhonetic)
                    }
                    .toggleStyle(SettingsSwitchStyle())
                    .opacity(inherited ? 0.6 : 1)
                }
            } else {
                HStack(spacing: 12) {
                    name
                    ruleColumn(translation: true) {
                        Toggle("\(title) · \(settings.t("lyrics.translation"))", isOn: ruleBinding(source: source, translation: true))
                            .labelsHidden()
                            .toggleStyle(SettingsSwitchStyle())
                            .fixedSize()
                            .opacity(inherited ? 0.6 : 1)
                    }
                    ruleColumn(translation: false) {
                        Toggle("\(title) · \(settings.t("lyrics.pronunciation"))", isOn: ruleBinding(source: source, translation: false))
                            .labelsHidden()
                            .toggleStyle(SettingsSwitchStyle())
                            .fixedSize()
                            .opacity(inherited ? 0.6 : 1)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .settingsRowSeparator()
    }

    /// The same path as the former rule switches: the rule is saved and the current lyrics regenerate.
    private func ruleBinding(source: String, translation: Bool) -> Binding<Bool> {
        Binding(
            get: {
                _ = settings.languageRulesRevision
                let rule = settings.languageRule(for: source)
                return translation ? rule.translationEnabled : rule.pronunciationEnabled
            },
            set: { enabled in
                let rule = settings.languageRule(for: source)
                settings.setLanguageRule(
                    sourceLang: source,
                    translationEnabled: translation ? enabled : rule.translationEnabled,
                    pronunciationEnabled: translation ? rule.pronunciationEnabled : enabled,
                    targetLang: settings.outputLang
                )
                model.saveLanguageRuleAndRegenerate()
            }
        )
    }

    private var ruleSourceLabel: String {
        model.selectedRuleSourceLang == "auto" ? settings.t("language.auto_default") : languageLabel(model.selectedRuleSourceLang)
    }

    private func aiProviderSettingsCard(_ provider: AppSettings.Provider, index: Int,
                                        owners: (translation: String?, pronunciation: String?)) -> some View {
        let enabled = settings.aiProviderEnabled[provider.id] ?? false
        let header = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        return VStack(alignment: .leading, spacing: 10) {
            header {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    rankBadge(index + 1)
                    Text(provider.label)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .opacity(enabled ? 1 : 0.5)
                HStack(spacing: 8) {
                    providerMoveButtons(index: index, count: settings.aiProviderOrder.count, name: provider.label) { offset in
                        settings.moveAIProvider(provider.id, offset: offset)
                        model.translationProviderSettingsChanged()
                    }
                    .draggable(provider.id)
                    .accessibilityHint(settings.tf("setting.ai_provider_drag_format", provider.label))
                    Toggle("", isOn: aiProviderEnabledBinding(provider.id))
                        .labelsHidden()
                        .toggleStyle(SettingsSwitchStyle())
                        .fixedSize()
                        .accessibilityLabel(settings.tf("setting.ai_provider_toggle_format", provider.label))
                        .accessibilityIdentifier("settings.ai.toggle.\(provider.id)")
                        .debugSettingsHitArea("settings.ai.toggle.\(provider.id)")
                }
            }
            // Descriptions use the full card width under the name instead of a column beside the controls.
            VStack(alignment: .leading, spacing: 2) {
                Text(aiProviderDescription(provider))
                    .font(.footnote)
                    .foregroundStyle(palette.text3)
                if provider.isLocal {
                    // Translation runs on the phone itself, so the card says up front that it needs a high-end device.
                    Text(settings.t("local_ai.performance_note"))
                        .font(.footnote)
                        .foregroundStyle(palette.warn)
                        .padding(.top, 2)
                }
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 32)
            .opacity(enabled ? 1 : 0.5)
            HStack(spacing: 8) {
                capabilityChip(settings.t("lyrics.translation"), systemImage: "translate", isOwner: owners.translation == provider.label && enabled)
                if !provider.translationOnly {
                    capabilityChip(settings.t("lyrics.pronunciation"), systemImage: "speaker.wave.2", isOwner: owners.pronunciation == provider.label && enabled)
                }
            }
            .padding(.leading, 32)
            .opacity(enabled ? 1 : 0.5)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.line))
        .settingsRow("aiProvider.\(provider.id)", flashing: flashRowID)
        .dropDestination(for: String.self) { providerIds, location in
            guard let sourceId = providerIds.first else { return false }
            settings.moveAIProvider(sourceId, relativeTo: provider.id, after: location.y > 36)
            model.translationProviderSettingsChanged()
            return true
        }
        .accessibilityAction(named: Text(settings.t("accessibility.move_up"))) {
            guard index > 0 else { return }
            settings.moveAIProvider(provider.id, offset: -1)
            model.translationProviderSettingsChanged()
        }
        .accessibilityAction(named: Text(settings.t("accessibility.move_down"))) {
            guard index < settings.aiProviderOrder.count - 1 else { return }
            settings.moveAIProvider(provider.id, offset: 1)
            model.translationProviderSettingsChanged()
        }
    }

    private func aiProviderDescription(_ provider: AppSettings.Provider) -> String {
        switch provider.id {
        case "deepl":
            return provider.description
        case KeylessTranslationProviders.bingId:
            return settings.t("setting.bing_translate_provider_desc")
        case KeylessTranslationProviders.googleId:
            return settings.t("setting.google_translate_provider_desc")
        case LocalAI.providerId:
            return settings.t("local_ai.description")
        default:
            return settings.t("provider.desc.\(provider.id)")
        }
    }

    private func capabilityChip(_ title: String, systemImage: String, isOwner: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .accessibilityHidden(true)
            Text(title)
                .font(.footnote.weight(.medium))
        }
        .foregroundStyle(isOwner ? Color.white : palette.text2)
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .background(isOwner ? palette.accent : palette.surface2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(isOwner ? Color.clear : palette.line2))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOwner ? [.isSelected] : [])
    }

    private var connectionProviders: [AppSettings.Provider] {
        settings.aiProviderOrder.compactMap(AppSettings.aiProviderById).filter { !$0.isKeyless }
    }

    private func providerInitials(_ label: String) -> String {
        let words = label
            .replacingOccurrences(of: #"[^A-Za-z0-9가-힣 ]"#, with: " ", options: .regularExpression)
            .split(separator: " ")
        if words.count > 1, let first = words[0].first, let second = words[1].first {
            return "\(first)\(second)".uppercased()
        }
        return String(label.prefix(2)).uppercased()
    }

    private func aiConnectionCard(_ provider: AppSettings.Provider) -> some View {
        let selected = !provider.isKeyless && !provider.isLocal && settings.providerId == provider.id
        // Local AI has its own panel and does not change the provider whose keys are edited.
        let expanded = expandedAIProvider == provider.id && (selected || provider.isLocal)
        let enabled = settings.aiProviderEnabled[provider.id] ?? false
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if expanded {
                    expandedAIProvider = nil
                } else if provider.isLocal {
                    expandedAIProvider = provider.id
                } else {
                    settings.setProvider(provider.id)
                    expandedAIProvider = provider.id
                    model.showSavedToast(settings.t("toast.provider_saved"))
                }
            } label: {
                HStack(spacing: 12) {
                    Text(providerInitials(provider.label))
                        .font(.caption.weight(.semibold))
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .foregroundStyle(palette.text2)
                        .multilineTextAlignment(.center)
                        .debugSettingsBadgeTextBounds("connection.\(provider.id)")
                        .frame(width: 30, height: 30, alignment: .center)
                        .background(palette.surface3, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(palette.line))
                        .debugSettingsBadgeBounds("connection.\(provider.id)")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.label)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(palette.text)
                        Text(aiProviderDescription(provider))
                            .font(.footnote)
                            .foregroundStyle(palette.text3)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        if selected {
                            SettingsPill(text: settings.t("setting.ai_provider_selected"), tone: .accent)
                                .padding(.top, 4)
                        }
                    }
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    SettingsPill(text: settings.t(enabled ? "label.on" : "label.off"), tone: enabled ? .ok : .neutral)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(palette.text3)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
            }
            .buttonStyle(SettingsRowButtonStyle())
            .accessibilityValue(selected ? settings.t("setting.ai_provider_selected") : "")
            .accessibilityIdentifier("settings.ai.expand.\(provider.id)")
            if expanded {
                Group {
                    if provider.isLocal {
                        LocalAISettingsPanel()
                    } else {
                        aiProviderConfiguration
                    }
                }
                .settingsRowSeparator()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(expanded ? palette.line2 : palette.line))
        .settingsRow("connection.\(provider.id)", flashing: flashRowID)
    }

    private var aiProviderConfiguration: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let url = URL(string: selectedProvider.apiKeyURL), !selectedProvider.apiKeyURL.trimmed.isEmpty {
                HStack {
                    Button { openURL(url) } label: {
                        SettingsButtonLabel(title: settings.t("button.get_key"), systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(SettingsButtonStyle())
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            if !selectedProvider.translationOnly {
                SettingsStackRow(title: settings.t("field.base_url")) {
                    settingsTextField(settings.t("field.base_url"), text: $settings.baseUrl)
                }
                .settingsRow("connection.field.field.base_url", flashing: flashRowID)
                SettingsStackRow(
                    title: settings.t("field.model"),
                    description: settings.providerId == "paxsenix" && settings.model.trimmed.isEmpty
                        ? settings.t("field.model_required")
                        : ""
                ) {
                    aiModelSelector
                }
                .settingsRow("connection.field.field.model", flashing: flashRowID)
                .task(id: aiModelConfiguration) {
                    aiModels = []
                    aiModelsError = ""
                    aiModelsBuiltIn = false
                    do {
                        try await Task.sleep(for: .milliseconds(350))
                        await refreshAIModels()
                    } catch { }
                }
            }
            if settings.providerId == "chatgpt" {
                SettingsStackRow(title: settings.t("openai.connections"), description: settings.t("openai.connections_desc")) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(settings.openAIConnections.enumerated()), id: \.element.id) { index, connection in
                            OpenAIConnectionEditor(connection: Binding(
                                get: { settings.openAIConnections.first(where: { $0.id == connection.id }) ?? connection },
                                set: { value in settings.openAIConnections = settings.openAIConnections.map { $0.id == value.id ? value : $0 } }
                            ), position: index, count: settings.openAIConnections.count,
                            onMove: { delta in
                                var connections = settings.openAIConnections
                                guard let current = connections.firstIndex(where: { $0.id == connection.id }),
                                      connections.indices.contains(current + delta) else { return }
                                connections.swapAt(current, current + delta)
                                settings.openAIConnections = connections
                            }, onRemove: {
                                settings.openAIConnections.removeAll { $0.id == connection.id }
                            })
                        }
                        Button {
                            settings.openAIConnections.append(OpenAIConnection())
                        } label: {
                            SettingsButtonLabel(title: settings.t("openai.add_connection"), systemImage: "plus")
                        }
                        .buttonStyle(SettingsButtonStyle())
                    }
                }
                .settingsRow("connection.field.openai.connections", flashing: flashRowID)
            }
            if !selectedProvider.translationOnly {
                SettingsStackRow(title: settings.t("field.max_tokens")) {
                    SettingsStepperField(label: settings.t("field.max_tokens"), value: maxTokensBinding, range: 256...65_536, step: 256,
                                         decrementLabel: "\(settings.t("field.max_tokens")) −256",
                                         incrementLabel: "\(settings.t("field.max_tokens")) +256")
                }
                .settingsRow("connection.field.field.max_tokens", flashing: flashRowID)
                SettingsStackRow(title: settings.t("field.temperature")) {
                    SettingsValueSlider(label: settings.t("field.temperature"), value: temperatureBinding, range: 0...2, step: 0.05,
                                        unit: "", decimals: 2)
                }
                .settingsRow("connection.field.field.temperature", flashing: flashRowID)
            }
            SettingsStackRow(title: settings.t("field.api_key"), description: settings.t("field.api_key_desc")) {
                TextEditor(text: $settings.apiKeys)
                    .font(.body)
                    .foregroundStyle(palette.text)
                    .scrollContentBackground(.hidden)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: 86)
                    .padding(8)
                    .background(palette.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.line2))
                    .accessibilityLabel(settings.t("field.api_key"))
            }
            .settingsRow("connection.field.field.api_key", flashing: flashRowID)
            if settings.providerId == "pollinations" {
                SettingsStackRow(title: settings.t("pollinations.access_token")) {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsSecureField(title: settings.t("pollinations.access_token"), text: $settings.pollinationsAccessToken,
                                            showLabel: settings.t("settings.secret.show"), hideLabel: settings.t("settings.secret.hide"))
                        SettingsStatusLine(text: model.pollinationsAuthStatusText, dot: model.pollinationsConnected ? palette.ok : nil,
                                           busy: model.pollinationsAuthInFlight)
                        SettingsFlowLayout(spacing: 8, lineSpacing: 8) {
                            Button {
                                model.startPollinationsLogin()
                            } label: {
                                SettingsButtonLabel(title: model.pollinationsConnected ? settings.t("pollinations.reconnect") : settings.t("pollinations.connect"))
                            }
                            .buttonStyle(SettingsButtonStyle())
                            .disabled(model.pollinationsAuthInFlight)
                            Button {
                                model.openPollinationsLoginPage()
                            } label: {
                                SettingsButtonLabel(title: settings.t("pollinations.open_login"), systemImage: "arrow.up.right.square")
                            }
                            .buttonStyle(SettingsButtonStyle())
                            .disabled(!model.pollinationsCanOpenLoginPage)
                            Button {
                                model.testPollinationsToken()
                            } label: {
                                SettingsButtonLabel(title: settings.t("pollinations.test"))
                            }
                            .buttonStyle(SettingsButtonStyle())
                            .disabled(!model.pollinationsCanTestToken)
                            Button(role: .destructive) {
                                model.disconnectPollinationsLogin()
                            } label: {
                                SettingsButtonLabel(title: settings.t("pollinations.disconnect"))
                            }
                            .buttonStyle(SettingsButtonStyle(tone: .danger))
                            .disabled(!model.pollinationsConnected || model.pollinationsAuthInFlight)
                        }
                    }
                }
                .settingsRow("connection.field.pollinations.access_token", flashing: flashRowID)
            }
            SettingsNoteRow(text: settings.t("settings.ai_autosave"))
            SettingsFlowLayout(spacing: 8, lineSpacing: 8) {
                Button {
                    model.testAIConnection()
                } label: {
                    SettingsButtonLabel(title: settings.t(model.aiConnectionTesting ? "pollinations.status_testing" : "pollinations.test"),
                                        busy: model.aiConnectionTesting)
                }
                .buttonStyle(SettingsButtonStyle())
                .disabled(model.aiConnectionTesting)
                Button {
                    model.saveAiSettingsAndRegenerate()
                } label: {
                    SettingsButtonLabel(title: settings.t("button.save_regenerate"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(SettingsButtonStyle(tone: .primary))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsRowSeparator()
        }
    }

    private var culturalFontOptions: [(value: String, title: String)] {
        [
            ("pretendard", settings.t("font.pretendard")),
            ("system", settings.t("font.system")),
            ("serif", settings.t("font.serif")),
            ("monospace", settings.t("font.monospace"))
        ]
    }

    private var culturalAnnotationsGroup: some View {
        let vinyl = culturalColumn == "vinyl"
        let prefix = vinyl ? "cultural.vinyl." : "cultural.normal."
        return SettingsGroup {
            toggleRow("setting.cultural_annotations", descriptionKey: "setting.cultural_annotations_desc",
                      isOn: culturalAnnotationsEnabledBinding, identifier: "settings.toggle.cultural")
            VStack(alignment: .leading, spacing: 0) {
                SettingsSegmentedPicker(
                    title: settings.t("setting.cultural_annotations"),
                    selection: $culturalColumn,
                    options: [("normal", settings.t("settings.cultural.normal")), ("vinyl", settings.t("vinyl.mode"))]
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .settingsRowSeparator()
                segmentedRow("setting.cultural_font_family", rowID: prefix + "setting.cultural_font_family",
                             selection: vinyl ? $settings.culturalAnnotationsVinylFontFamily : $settings.culturalAnnotationsFontFamily,
                             options: culturalFontOptions)
                sliderRow("setting.cultural_font_size", rowID: prefix + "setting.cultural_font_size",
                          value: vinyl ? culturalAnnotationVinylFontSizeBinding : culturalAnnotationFontSizeBinding,
                          range: 10...28, unit: "px")
                sliderRow("setting.cultural_font_weight", rowID: prefix + "setting.cultural_font_weight",
                          value: vinyl ? culturalAnnotationVinylFontWeightBinding : culturalAnnotationFontWeightBinding,
                          range: 100...900, step: 100, unit: "")
                sliderRow("setting.cultural_opacity", rowID: prefix + "setting.cultural_opacity",
                          value: vinyl ? culturalAnnotationVinylOpacityBinding : culturalAnnotationOpacityBinding,
                          range: 20...100, step: 5, unit: "%")
            }
            .disabled(!settings.culturalAnnotationsEnabled)
            .opacity(settings.culturalAnnotationsEnabled ? 1 : 0.42)
        }
    }

    private var effectiveRuleSourceLang: String {
        model.effectiveSelectedRuleSourceLang
    }

    private var selectedProvider: AppSettings.Provider {
        AppSettings.providerById(settings.providerId)
    }

    private var aiModelConfiguration: AIProviderModels.Configuration {
        AIProviderModels.Configuration(provider: settings.providerId,
                                       baseURL: settings.baseUrl.trimmed.isEmpty ? selectedProvider.defaultBaseUrl : settings.baseUrl,
                                       apiKeys: settings.apiKeys, pollinationsAccessToken: settings.pollinationsAccessToken)
    }

    private var availableAIModels: [AIProviderModels.Model] {
        aiModelsConfiguration == aiModelConfiguration ? aiModels : []
    }

    private var aiModelChoices: [SettingsChoice] {
        var choices = [SettingsChoice(value: "", title: settings.t("field.model_required"))]
        if !settings.model.trimmed.isEmpty, !availableAIModels.contains(where: { $0.id == settings.model }) {
            choices.append(SettingsChoice(value: settings.model, title: settings.model))
        }
        choices += availableAIModels.map { SettingsChoice(value: $0.id, title: $0.displayName) }
        return choices
    }

    private var aiModelLabel: String {
        if settings.model.trimmed.isEmpty { return settings.t("field.model_required") }
        return availableAIModels.first(where: { $0.id == settings.model })?.displayName ?? settings.model
    }

    private var aiModelSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SettingsPickerButton(title: settings.t("field.model"), value: aiModelLabel) {
                    activeSheet = .aiModel
                }
                .disabled(aiModelsLoading || availableAIModels.isEmpty)
                if aiModelsLoading {
                    ProgressView().frame(width: 44, height: 44)
                } else {
                    SettingsIconButton(systemImage: "arrow.clockwise", label: settings.t("button.refresh_models")) {
                        Task { await refreshAIModels() }
                    }
                }
            }
            if aiModelsLoading {
                Text(settings.t("status.models_loading"))
                    .font(.caption).foregroundStyle(palette.text3)
            } else if !aiModelsError.isEmpty {
                Text(settings.t("status.models_unavailable"))
                    .font(.caption).foregroundStyle(palette.warn)
            } else if aiModelsBuiltIn {
                Text(settings.t("status.models_builtin_sonar"))
                    .font(.caption).foregroundStyle(palette.text3)
            }
            settingsTextField(settings.t("field.model_id"), text: $settings.model)
        }
    }

    @MainActor
    private func refreshAIModels() async {
#if DEBUG
        if DebugSettingsUIHarness.enabled { return }
#endif
        let configuration = aiModelConfiguration
        let requestId = UUID()
        aiModelsRequestId = requestId
        aiModelsLoading = true
        aiModelsError = ""
        defer { if aiModelsRequestId == requestId { aiModelsLoading = false } }
        do {
            let catalog = try await AIProviderModels.fetch(configuration)
            try Task.checkCancellation()
            guard requestId == aiModelsRequestId, configuration == aiModelConfiguration else { return }
            aiModels = catalog.models
            aiModelsConfiguration = configuration
            aiModelsBuiltIn = catalog.builtIn
            if aiModels.isEmpty { aiModelsError = "empty" }
        } catch {
            guard !Task.isCancelled, requestId == aiModelsRequestId, configuration == aiModelConfiguration else { return }
            aiModels = []
            aiModelsError = error.localizedDescription
        }
    }

    private func settingsTextField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .settingsFieldChrome()
    }

    // MARK: Appearance

    private static let alignmentIcons = ["left": "text.alignleft", "center": "text.aligncenter", "right": "text.alignright"]

    private var alignmentOptions: [(value: String, title: String)] {
        [
            (value: "left", title: settings.t("alignment.left")),
            (value: "center", title: settings.t("alignment.center")),
            (value: "right", title: settings.t("alignment.right"))
        ]
    }

    private var typographyWeightOptions: [(value: String, title: String)] {
        [AppSettings.typoWeightRegular, AppSettings.typoWeightSemibold, AppSettings.typoWeightBold].map {
            (value: $0, title: settings.t("typography.weight.\($0)"))
        }
    }

    private var backgroundModeChoices: [SettingsChoice] {
        [
            SettingsChoice(value: AppSettings.backgroundGradient, title: settings.t("background.mode.gradient")),
            SettingsChoice(value: AppSettings.backgroundBlurGradient, title: settings.t("background.mode.blur_gradient")),
            SettingsChoice(value: AppSettings.backgroundVideo, title: settings.t("background.mode.video")),
            SettingsChoice(value: AppSettings.backgroundSolid, title: settings.t("background.mode.solid"))
        ]
    }

    private func backgroundModeLabel(_ mode: String) -> String {
        backgroundModeChoices.first { $0.value == mode }?.title ?? mode
    }

    private var appearanceSettingsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            section("appearance.layout", title: settings.t("section.layout"), tracksPreview: true) {
                SettingsGroup {
                    segmentedRow("setting.lyrics_alignment", descriptionKey: "setting.lyrics_alignment_desc",
                                 selection: lyricsAlignmentBinding, options: alignmentOptions, icons: Self.alignmentIcons)
                }
            }
            section("appearance.typography", title: settings.t("section.typography"), subtitle: settings.t("section.typography_desc"),
                    tracksPreview: true) {
                SettingsSegmentedPicker(
                    title: settings.t("section.typography"),
                    selection: $typographyGroup,
                    options: [(value: "main", title: settings.t("settings.typography.main")),
                              (value: "lyrics", title: settings.t("settings.typography.lyrics"))]
                )
                SettingsGroup {
                    ForEach(AppSettings.typographySlots.filter { $0.id.hasPrefix(typographyGroup == "main" ? "main_" : "lyrics_") }) { slot in
                        typographySettingsRow(slot)
                    }
                }
            }
            section("appearance.speakers", title: settings.t("section.speaker_colors"), subtitle: settings.t("section.speaker_colors_desc"),
                    tracksPreview: true) {
                speakerColorsGroup
            }
            backgroundSettingsSection
            trackBackgroundSettingsSection
        }
    }

    private func typographyRoleColor(_ slotId: String) -> Color {
        if slotId.contains("original") { return palette.layerOriginal }
        if slotId.contains("pronunciation") { return palette.layerPhonetic }
        if slotId.contains("translation") { return palette.layerTranslation }
        if slotId.contains("artist") { return palette.text4 }
        return palette.text3
    }

    private func typographySettingsRow(_ slot: AppSettings.TypographySlot) -> some View {
        let style = typographyStyle(slot)
        let title = settings.t("typography.slot.\(slot.id)")
        let heading = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return VStack(alignment: .leading, spacing: 10) {
            heading {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(typographyRoleColor(slot.id))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(style.sizePercent)% · \(settings.t("typography.weight.\(style.weight)"))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(palette.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsValueSlider(label: title, value: typographySizeBinding(slot), range: 70...160, step: 1, unit: "%") { editing in
                if !editing { model.showSavedToast(settings.t("toast.typography_saved")) }
            }
            .accessibilityHint(settings.t("typography.slot.\(slot.id)_desc"))
            SettingsSegmentedPicker(title: title, selection: typographyWeightBinding(slot), options: typographyWeightOptions)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsRowSeparator()
        .settingsRow("typography.\(slot.id)", flashing: flashRowID)
    }

    private var speakerColorsGroup: some View {
        SettingsGroup {
            toggleRow("setting.creator_speaker_colors", descriptionKey: "setting.creator_speaker_colors_desc",
                      isOn: settingsSavedBinding(\.useSyncCreatorSpeakerColors))
            VStack(alignment: .leading, spacing: 14) {
                ForEach(["normal", "duet", "male", "female"], id: \.self) { group in
                    speakerSwatchGroup(group)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsRowSeparator()
            .settingsRow("speakers.palette", flashing: flashRowID)
            if let slot = AppSettings.speakerColorSlots.first(where: { $0.id == selectedSpeakerColor }) {
                SpeakerColorRow(slot: slot)
                    .id(slot.id)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .settingsRowSeparator()
            }
            HStack {
                Spacer(minLength: 0)
                Button {
                    settings.resetSpeakerColors()
                    model.showSavedToast(settings.t("toast.speaker_colors_reset"))
                } label: {
                    SettingsButtonLabel(title: settings.t("button.reset"), systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(SettingsButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .settingsRowSeparator()
        }
    }

    private func speakerSwatchGroup(_ group: String) -> some View {
        let slots = AppSettings.speakerColorSlots.filter { $0.id.hasPrefix(group) }
        let colors = settings.speakerColorSettings()
        let columnCount = dynamicTypeSize.isAccessibilitySize ? 2 : (dynamicTypeSize >= .xLarge ? 4 : 5)
        return VStack(alignment: .leading, spacing: 8) {
            Text(settings.t("speaker_color.\(group)"))
                .font(.footnote.weight(.medium))
                .foregroundStyle(palette.text2)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columnCount), alignment: .leading, spacing: 8) {
                ForEach(slots) { slot in
                    let hex = colors.hex(slot.id)
                    let isOn = selectedSpeakerColor == slot.id
                    Button { selectedSpeakerColor = slot.id } label: {
                        VStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color(hex: hex))
                                .frame(height: 30)
                                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.gray.opacity(0.25)))
                            Text(hex.replacingOccurrences(of: "#", with: "").uppercased())
                                .font(.caption.monospaced())
                                .foregroundStyle(palette.text3)
                                .lineLimit(1)
                        }
                        .padding(5)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(palette.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isOn ? palette.accent : palette.line, lineWidth: isOn ? 2 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(slot.id == AppSettings.speakerColorNormal
                                        ? settings.t("speaker_color.normal")
                                        : "\(settings.t("speaker_color.\(group)")) \(slot.id.last.map(String.init) ?? "")")
                    .accessibilityValue(hex)
                    .accessibilityAddTraits(isOn ? [.isSelected] : [])
                }
            }
        }
    }

    private var backgroundSettingsSection: some View {
        let video = settings.backgroundMode == AppSettings.backgroundVideo
        let solidUsed = settings.backgroundMode == AppSettings.backgroundSolid
            || (video && settings.backgroundVideoFallback == AppSettings.backgroundSolid)
            || AppSettings.normalizePipBackgroundMode(settings.pipBackgroundMode) == AppSettings.pipBackgroundSolid
        let videoRows = ["setting.video_fallback", "setting.video_aspect", "setting.video_edge_to_edge", "setting.video_scale"]
        let showVideo = video || videoRows.contains(revealedRowID ?? "")
        let showSolid = solidUsed || revealedRowID == "field.solid_color"
        return section("appearance.background", title: settings.t("section.background"), subtitle: settings.t("section.background_desc"),
                       tracksPreview: true) {
            SettingsGroup {
                SettingsStackRow(title: settings.t("setting.background_mode"), description: settings.t("setting.background_mode_desc")) {
                    SettingsOptionCards(title: settings.t("setting.background_mode"), options: backgroundModeChoices,
                                        selection: backgroundModeBinding) { option in
                        BackgroundModeSwatch(mode: option.value, solidColor: settings.backgroundSolidColor)
                    }
                }
                .settingsRow("setting.background_mode", flashing: flashRowID)
            }
            if showVideo || showSolid {
                SettingsGroup {
                    if showVideo {
                        if !video { conditionNote("setting.background_mode") }
                        videoAppearanceRows(fallback: $settings.backgroundVideoFallback, aspect: $settings.backgroundVideoAspect,
                                            edgeToEdge: $settings.backgroundVideoEdgeToEdge, scale: globalVideoScaleBinding,
                                            scaleEditingChanged: backgroundSliderEditingChanged, rowPrefix: "")
                    }
                    if showSolid {
                        if !solidUsed { conditionNote("setting.background_mode") }
                        HexColorEditorRow(
                            title: settings.t("field.solid_color"),
                            hexColor: $settings.backgroundSolidColor,
                            fallback: "#1e3a8a",
                            onSave: { model.showSavedToast(settings.t("toast.background_saved")) }
                        )
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .settingsRowSeparator()
                        .settingsRow("field.solid_color", flashing: flashRowID)
                    }
                }
            }
            SettingsGroup {
                sliderRow("setting.brightness", value: Binding(get: { Double(settings.backgroundBrightness) },
                                                               set: { settings.backgroundBrightness = Int($0.rounded()) }),
                          range: 0...100, onEditingChanged: backgroundSliderEditingChanged)
                sliderRow("setting.blur", value: Binding(get: { Double(settings.backgroundBlur) },
                                                         set: { settings.backgroundBlur = Int($0.rounded()) }),
                          range: 0...100, onEditingChanged: backgroundSliderEditingChanged)
                toggleRow("setting.noise", isOn: backgroundNoiseBinding)
                toggleRow("setting.reduce_motion", isOn: backgroundReduceMotionBinding)
            }
        }
    }

    @ViewBuilder
    private func videoAppearanceRows(fallback: Binding<String>, aspect: Binding<String>, edgeToEdge: Binding<Bool>,
                                     scale: Binding<Double>, scaleEditingChanged: @escaping (Bool) -> Void,
                                     rowPrefix: String) -> some View {
        segmentedRow("setting.video_fallback", rowID: rowPrefix + "setting.video_fallback", selection: fallback, options: [
            (value: AppSettings.backgroundGradient, title: settings.t("background.mode.gradient")),
            (value: AppSettings.backgroundBlurGradient, title: settings.t("background.mode.blur_gradient")),
            (value: AppSettings.backgroundSolid, title: settings.t("background.mode.solid"))
        ])
        segmentedRow("setting.video_aspect", rowID: rowPrefix + "setting.video_aspect", selection: aspect, options: [
            (value: "fit", title: settings.t("video_aspect.fit")),
            (value: "fill", title: settings.t("video_aspect.fill")),
            (value: "stretch", title: settings.t("video_aspect.stretch"))
        ])
        toggleRow("setting.video_edge_to_edge", descriptionKey: "setting.video_edge_to_edge_desc", isOn: edgeToEdge,
                  identifier: "settings.toggle.\(rowPrefix)setting.video_edge_to_edge", rowID: rowPrefix + "setting.video_edge_to_edge")
        sliderRow("setting.video_scale", rowID: rowPrefix + "setting.video_scale", value: scale, range: 100...180,
                  onEditingChanged: scaleEditingChanged)
    }

    private var trackBackgroundSettingsSection: some View {
        let hasTrack = !model.currentTrackKey.isEmpty
        let track = editableTrackBackground
        let trackVideo = track.mode == AppSettings.backgroundVideo
        let trackSolid = track.mode == AppSettings.backgroundSolid || (trackVideo && track.videoFallback == AppSettings.backgroundSolid)
        return section("appearance.trackBackground", title: settings.t("section.track_background"), tracksPreview: true) {
            SettingsGroup {
                trackBackgroundHeader(hasTrack: hasTrack)
                    .settingsRow("lyrics.background.override", flashing: flashRowID)
                if !hasTrack {
                    SettingsNoteRow(text: settings.t("label.no_current_track"))
                } else if currentTrackHasBackgroundOverride {
                    SettingsStackRow(title: settings.t("setting.background_mode")) {
                        SettingsOptionCards(title: settings.t("setting.background_mode"), options: backgroundModeChoices,
                                            selection: trackBackgroundModeBinding) { option in
                            BackgroundModeSwatch(mode: option.value, solidColor: track.solidColor, height: 40)
                        }
                    }
                    if trackVideo {
                        videoAppearanceRows(
                            fallback: Binding(get: { editableTrackBackground.videoFallback },
                                              set: { value in updateTrackBackground { $0.videoFallback = AppSettings.normalizeVideoFallback(value) } }),
                            aspect: Binding(get: { editableTrackBackground.videoAspect },
                                            set: { value in updateTrackBackground { $0.videoAspect = AppearancePolicy.videoAspect(value) } }),
                            edgeToEdge: Binding(get: { editableTrackBackground.videoEdgeToEdge },
                                                set: { value in updateTrackBackground { $0.videoEdgeToEdge = value } }),
                            scale: trackBackgroundVideoScaleBinding,
                            scaleEditingChanged: trackBackgroundSliderEditingChanged,
                            rowPrefix: "track."
                        )
                    }
                    sliderRow("setting.brightness", rowID: "track.setting.brightness", value: trackBackgroundBrightnessBinding,
                              range: 0...100, onEditingChanged: trackBackgroundSliderEditingChanged)
                    sliderRow("setting.blur", rowID: "track.setting.blur", value: trackBackgroundBlurBinding,
                              range: 0...100, onEditingChanged: trackBackgroundSliderEditingChanged)
                    toggleRow("setting.noise", isOn: trackBackgroundNoiseBinding, identifier: "settings.toggle.track.noise",
                              rowID: "track.setting.noise")
                    toggleRow("setting.reduce_motion", isOn: trackBackgroundReduceMotionBinding,
                              identifier: "settings.toggle.track.reduce_motion", rowID: "track.setting.reduce_motion")
                    if trackSolid {
                        HexColorEditorRow(
                            title: settings.t("field.solid_color"),
                            hexColor: trackBackgroundSolidColorBinding,
                            fallback: "#1e3a8a",
                            onSave: { model.showSavedToast(settings.t("toast.track_background_saved")) }
                        )
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .settingsRowSeparator()
                    }
                }
            }
        }
    }

    private func trackBackgroundHeader(hasTrack: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                SettingsArtGradient()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hasTrack ? model.titleText : settings.t("label.no_current_track"))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(palette.text)
                    if hasTrack && !model.artistText.isEmpty {
                        Text(model.artistText)
                            .font(.footnote)
                            .foregroundStyle(palette.text3)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .accessibilityElement(children: .combine)
            Toggle(isOn: trackBackgroundOverrideBinding) {
                SettingsTextBlock(title: settings.t("lyrics.background.override"))
            }
            .toggleStyle(SettingsSwitchStyle())
            .disabled(!hasTrack)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .settingsRowSeparator()
            .accessibilityIdentifier("settings.toggle.track_background")
            .debugSettingsHitArea("settings.toggle.track_background")
        }
        .settingsRowSeparator()
    }

    // MARK: Behavior

    private var karaokeGranularityOptions: [(value: String, title: String)] {
        [
            (value: AppSettings.karaokeDisplayCharacter, title: settings.t("karaoke.display.character")),
            (value: AppSettings.karaokeDisplayWord, title: settings.t("karaoke.display.word")),
            (value: AppSettings.karaokeDisplayLine, title: settings.t("karaoke.display.line"))
        ]
    }

    private var lyricsSettingsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            section("lyrics.interlude", title: settings.t("settings.section.interlude")) {
                SettingsGroup {
                    toggleRow("setting.auto_interlude", descriptionKey: "setting.auto_interlude_desc", isOn: autoInterludeBinding)
                    // Labels also apply to interludes marked in the lyrics, so this stays visible when auto detection is off.
                    toggleRow("setting.interlude_labels", descriptionKey: "setting.interlude_labels_desc",
                              isOn: settingsSavedBinding(\.interludeLabelsEnabled), indent: true)
                }
            }
            section("lyrics.karaoke", title: settings.t("settings.section.karaoke")) {
                SettingsGroup {
                    toggleRow("setting.synced_karaoke_animation", descriptionKey: "setting.synced_karaoke_animation_desc",
                              isOn: settingsSavedBinding(\.syncedLyricsKaraokeAnimationEnabled))
                    toggleRow("setting.karaoke_bounce_effect", descriptionKey: "setting.karaoke_bounce_effect_desc",
                              isOn: settingsSavedBinding(\.karaokeBounceEffectEnabled))
                    segmentedRow("setting.karaoke_display_granularity", descriptionKey: "setting.karaoke_display_granularity_desc",
                                 selection: karaokeGranularityBinding, options: karaokeGranularityOptions)
                }
            }
        }
    }

    private var karaokeGranularityBinding: Binding<String> {
        Binding(
            get: { AppSettings.normalizeKaraokeDisplayGranularity(settings.karaokeDisplayGranularity) },
            set: { value in
                settings.karaokeDisplayGranularity = value
                model.showSavedToast(settings.t("toast.settings_saved"))
            }
        )
    }

    // MARK: Player

    private var titleTapChoices: [SettingsChoice] {
        [
            SettingsChoice(value: "disabled", title: settings.t("title_action.disabled")),
            SettingsChoice(value: "track", title: settings.t("title_action.track")),
            SettingsChoice(value: "album", title: settings.t("title_action.album")),
            SettingsChoice(value: "context", title: settings.t("title_action.context"))
        ]
    }

    private var pipBackgroundChoices: [SettingsChoice] {
        [
            SettingsChoice(value: AppSettings.pipBackgroundCover, title: settings.t("pip.background.cover")),
            SettingsChoice(value: AppSettings.pipBackgroundBlur, title: settings.t("pip.background.blur")),
            SettingsChoice(value: AppSettings.pipBackgroundGradient, title: settings.t("pip.background.gradient")),
            SettingsChoice(value: AppSettings.pipBackgroundSolid, title: settings.t("background.mode.solid"))
        ]
    }

    private var tonearmStyleChoices: [SettingsChoice] {
        [
            SettingsChoice(value: AppSettings.vinylTonearmStyleS, title: settings.t("vinyl.settings.tonearm_style_s")),
            SettingsChoice(value: AppSettings.vinylTonearmStyleStraight, title: settings.t("vinyl.settings.tonearm_style_straight")),
            SettingsChoice(value: AppSettings.vinylTonearmStyleJ, title: settings.t("vinyl.settings.tonearm_style_j")),
            SettingsChoice(value: AppSettings.vinylTonearmStyleLinear, title: settings.t("vinyl.settings.tonearm_style_linear"))
        ]
    }

    private var playerSettingsPage: some View {
        let pipSolid = AppSettings.normalizePipBackgroundMode(settings.pipBackgroundMode) == AppSettings.pipBackgroundSolid
        return VStack(alignment: .leading, spacing: 0) {
            section("player.player", title: settings.t("section.player")) {
                SettingsGroup {
                    cardsRow("setting.title_tap_action", selection: $settings.titleTapAction, options: titleTapChoices)
                    toggleRow("setting.lyrics_not_found_notice", isOn: settingsSavedBinding(\.lyricsNotFoundNoticeEnabled))
                    toggleRow("setting.keep_screen_on", descriptionKey: "setting.keep_screen_on_desc", isOn: keepScreenOnBinding)
                }
            }
            section("player.landscape", title: settings.t("settings.section.landscape")) {
                SettingsGroup {
                    toggleRow("setting.landscape_original_lyrics", descriptionKey: "setting.landscape_original_lyrics_desc",
                              isOn: settingsSavedBinding(\.landscapeOriginalLyricsEnabled))
                    toggleRow("setting.landscape_artwork", isOn: settingsSavedBinding(\.landscapeArtworkEnabled))
                    toggleRow("setting.landscape_auto_hide", descriptionKey: "setting.landscape_auto_hide_desc", isOn: landscapeAutoHideBinding)
                    toggleRow("setting.landscape_center_no_lyrics", descriptionKey: "setting.landscape_center_no_lyrics_desc",
                              isOn: landscapeCenterNoLyricsBinding)
                }
            }
            section("player.pip", title: settings.t("section.pip"), subtitle: settings.t("section.pip_desc"), tracksPreview: true) {
                SettingsGroup {
                    toggleRow("setting.pip_show_artwork", descriptionKey: "setting.pip_show_artwork_desc", isOn: pipShowArtworkBinding)
                    cardsRow("setting.pip_background", descriptionKey: "setting.pip_background_desc", selection: pipBackgroundBinding,
                             options: pipBackgroundChoices)
                    if pipSolid {
                        // PiP's solid background uses the same colour as the lyrics background.
                        HexColorEditorRow(
                            title: settings.t("field.solid_color"),
                            hexColor: $settings.backgroundSolidColor,
                            fallback: "#1e3a8a",
                            onSave: { model.showSavedToast(settings.t("toast.background_saved")) }
                        )
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .settingsRowSeparator()
                    }
                    segmentedRow("setting.pip_orientation", descriptionKey: "setting.pip_orientation_desc", selection: pipOrientationBinding,
                                 options: [
                                    (value: AppSettings.pipOrientationLandscape, title: settings.t("pip.orientation.landscape")),
                                    (value: AppSettings.pipOrientationPortrait, title: settings.t("pip.orientation.portrait")),
                                    (value: AppSettings.pipOrientationSquare, title: settings.t("pip.orientation.square"))
                                 ],
                                 icons: [AppSettings.pipOrientationLandscape: "rectangle",
                                         AppSettings.pipOrientationPortrait: "rectangle.portrait",
                                         AppSettings.pipOrientationSquare: "square"])
                    segmentedRow("setting.pip_lyrics_alignment", descriptionKey: "setting.pip_lyrics_alignment_desc",
                                 selection: pipAlignmentBinding, options: alignmentOptions, icons: Self.alignmentIcons)
                    sliderRow("setting.pip_lyrics_size", descriptionKey: "setting.pip_lyrics_size_desc", value: pipLyricsSizeBinding,
                              range: 50...180, onEditingChanged: pipSliderEditingChanged)
                    sliderRow("setting.pip_translation_size", descriptionKey: "setting.pip_translation_size_desc",
                              value: pipTranslationSizeBinding, range: 50...250, onEditingChanged: pipSliderEditingChanged)
                }
            }
            section("player.vinyl", title: settings.t("vinyl.mode"), subtitle: settings.t("vinyl.settings.subtitle"), tracksPreview: true) {
                SettingsGroup {
                    sliderRow("vinyl.settings.album_size", descriptionKey: "vinyl.settings.album_size_desc", value: vinylAlbumSizeBinding,
                              range: 70...140, step: 5, onEditingChanged: settingsSavedSliderEditingChanged)
                    sliderRow("vinyl.settings.record_size", descriptionKey: "vinyl.settings.record_size_desc", value: vinylRecordSizeBinding,
                              range: 70...140, step: 5, onEditingChanged: settingsSavedSliderEditingChanged)
                    toggleRow("vinyl.settings.animations", descriptionKey: "vinyl.settings.animations_desc",
                              isOn: settingsSavedBinding(\.vinylAnimationsEnabled))
                    toggleRow("vinyl.settings.track_change_animations", descriptionKey: "vinyl.settings.track_change_animations_desc",
                              isOn: settingsSavedBinding(\.vinylTrackChangeAnimationsEnabled))
                    sliderRow("vinyl.settings.rotation_speed", descriptionKey: "vinyl.settings.rotation_speed_desc",
                              value: vinylRotationSpeedBinding, range: 25...300, step: 5, onEditingChanged: settingsSavedSliderEditingChanged)
                    toggleRow("vinyl.settings.center_rotation", descriptionKey: "vinyl.settings.center_rotation_desc",
                              isOn: settingsSavedBinding(\.vinylCenterRotationEnabled))
                    toggleRow("vinyl.settings.lyrics", descriptionKey: "vinyl.settings.lyrics_desc",
                              isOn: settingsSavedBinding(\.vinylLyricsEnabled))
                }
            }
            section("player.tonearm", title: settings.t("vinyl.settings.tonearm_title"), subtitle: settings.t("vinyl.settings.tonearm_subtitle"),
                    tracksPreview: true) {
                SettingsGroup {
                    SettingsStackRow(title: settings.t("vinyl.settings.tonearm_style"), description: settings.t("vinyl.settings.tonearm_style_desc")) {
                        SettingsOptionCards(title: settings.t("vinyl.settings.tonearm_style"), options: tonearmStyleChoices,
                                            selection: tonearmStyleBinding) { option in
                            TonearmGlyph(style: option.value)
                                .stroke(palette.text2, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                                .frame(width: 32, height: 32)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(palette.surface2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .accessibilityHidden(true)
                        }
                    }
                    .settingsRow("vinyl.settings.tonearm_style", flashing: flashRowID)
                    segmentedRow("vinyl.settings.tonearm_finish", descriptionKey: "vinyl.settings.tonearm_finish_desc",
                                 selection: tonearmFinishBinding, options: [
                                    (value: AppSettings.vinylTonearmFinishWhite, title: settings.t("vinyl.settings.tonearm_finish_white")),
                                    (value: AppSettings.vinylTonearmFinishSilver, title: settings.t("vinyl.settings.tonearm_finish_silver")),
                                    (value: AppSettings.vinylTonearmFinishBlack, title: settings.t("vinyl.settings.tonearm_finish_black"))
                                 ],
                                 swatches: [AppSettings.vinylTonearmFinishWhite: Color(hex: "#F2F2F2"),
                                            AppSettings.vinylTonearmFinishSilver: Color(hex: "#B9BEC7"),
                                            AppSettings.vinylTonearmFinishBlack: Color(hex: "#1D1F24")])
                    sliderRow("vinyl.settings.tonearm_size", descriptionKey: "vinyl.settings.tonearm_size_desc", value: tonearmSizeBinding,
                              range: 80...120, step: 5, onEditingChanged: settingsSavedSliderEditingChanged)
                }
            }
            section("player.vinylTypography", title: settings.t("section.typography"), subtitle: settings.t("vinyl.settings.typography_desc"),
                    tracksPreview: true) {
                SettingsGroup {
                    ForEach(AppSettings.vinylTypographySlots) { slot in
                        typographySettingsRow(slot)
                    }
                }
            }
        }
    }

    // MARK: Advanced

    private var systemSettingsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            section("system.account", title: settings.t("section.account")) {
                SettingsGroup {
                    discordCard
                        .settingsRow("account.discord", flashing: flashRowID)
                    if model.creatorAccountConnected {
                        SettingsActionRow(title: settings.t("creator_privacy.refresh"), busy: model.creatorPrivacyRequestInFlight) {
                            model.refreshCreatorPrivacy()
                        }
                        .disabled(model.creatorPrivacyRequestInFlight)
                    } else {
                        SettingsActionRow(title: settings.t("creator_privacy.login"), busy: model.creatorPrivacyLoginInProgress) {
                            model.startCreatorAccountLogin()
                        }
                        .disabled(model.creatorPrivacyRequestInFlight || model.creatorPrivacyLoginInProgress)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: creatorPrivacyBinding) {
                            SettingsTextBlock(title: settings.t("creator_privacy.private_title"), description: settings.t("creator_privacy.private_desc"))
                        }
                        .toggleStyle(SettingsSwitchStyle())
                        .disabled(!model.creatorPrivacyCanEdit)
                        .accessibilityValue(model.creatorPrivacyStatusText)
                        .accessibilityIdentifier("settings.toggle.creator_privacy")
                        SettingsStatusLine(text: model.creatorPrivacyStatusText, dot: creatorPrivacyStatusColor,
                                           busy: model.creatorPrivacyRequestInFlight)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .settingsRowSeparator()
                    .settingsRow("creator_privacy.private_title", flashing: flashRowID)
                }
                if model.creatorAccountConnected {
                    SettingsGroup {
                        SettingsActionRow(title: settings.t("creator_privacy.disconnect"), role: .danger) {
                            model.disconnectCreatorAccount()
                        }
                        .disabled(model.creatorPrivacyRequestInFlight)
                    }
                }
                SettingsGroup {
                    SettingsSubhead(title: settings.t("cloud_sync.section"),
                                    description: settings.t("cloud_sync.monthly_required") + "\n" + settings.t("cloud_sync.section_desc"))
                        .settingsRow("cloud_sync.section", flashing: flashRowID)
                    cloudStatusRow
                    SettingsActionRow(title: settings.t("cloud_sync.refresh")) { model.refreshCloudSettings() }
                        .disabled(!model.cloudSettingsActionsEnabled)
                        .settingsRow("cloud_sync.refresh", flashing: flashRowID)
                    SettingsActionRow(title: settings.t("cloud_sync.upload")) { model.uploadCloudSettings() }
                        .disabled(!model.cloudSettingsActionsEnabled)
                        .settingsRow("cloud_sync.upload", flashing: flashRowID)
                    SettingsActionRow(title: settings.t("cloud_sync.apply")) { cloudApplyConfirmationPresented = true }
                        .disabled(!model.cloudSettingsCanApply)
                        .settingsRow("cloud_sync.apply", flashing: flashRowID)
                }
                SettingsGroup {
                    SettingsActionRow(title: settings.t("cloud_sync.delete"), role: .danger) { cloudDeleteConfirmationPresented = true }
                        .disabled(!model.cloudSettingsActionsEnabled)
                }
                .settingsRow("cloud_sync.delete", flashing: flashRowID)
            }
            section("system.spotify", title: settings.t("section.spotify_api"), subtitle: settings.t("section.spotify_api_option_desc")) {
                SpotifySetupInstructionsPanel()
                    .settingsRow("spotify.setup.instructions", flashing: flashRowID)
                SettingsGroup {
                    SettingsStackRow(title: settings.t("field.spotify_client_id")) {
                        settingsTextField(settings.t("field.spotify_client_id"), text: $settings.spotifyClientId)
                    }
                    .settingsRow("field.spotify_client_id", flashing: flashRowID)
                    SettingsStackRow(title: settings.t("field.spotify_client_secret"), description: settings.t("field.spotify_client_secret_role")) {
                        SettingsSecureField(title: settings.t("field.spotify_client_secret"), text: $settings.spotifyClientSecret,
                                            showLabel: settings.t("settings.secret.show"), hideLabel: settings.t("settings.secret.hide"))
                    }
                    .settingsRow("field.spotify_client_secret", flashing: flashRowID)
                    SettingsStackRow(title: settings.t("field.redirect_uri")) {
                        // The URI stays on one line next to Copy when it fits; otherwise Copy moves below it.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                redirectURIChip
                                    .fixedSize()
                                Spacer(minLength: 0)
                                redirectURICopyButton
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                redirectURIChip
                                    .fixedSize(horizontal: false, vertical: true)
                                redirectURICopyButton
                            }
                        }
                    }
                    .settingsRow("field.redirect_uri", flashing: flashRowID)
                    spotifyWebAPIOptInRow
                        .settingsRow("setting.spotify_web_api", flashing: flashRowID)
                    if !model.spotifyValidationStatus.trimmed.isEmpty {
                        SettingsNoteRow(text: model.spotifyValidationStatus, systemImage: nil)
                    }
                    SettingsActionRow(
                        title: model.spotifyCredentialsValidationInFlight ? settings.t("spotify.validate_checking") : settings.t("button.spotify_save"),
                        busy: model.spotifyCredentialsValidationInFlight
                    ) {
                        model.validateSpotifyApiCredentials(reloadOnChange: true)
                    }
                    .disabled(model.spotifyCredentialsValidationInFlight)
                    .settingsRow("button.spotify_save", flashing: flashRowID)
                }
                SettingsGroup {
                    SettingsSubhead(title: settings.t("field.live_source"))
                    SettingsStatusLine(text: liveSourceText,
                                       dot: model.spotifyAppRemoteConnected || model.spotifyLivePolling ? palette.ok : nil)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    SettingsActionRow(title: model.spotifyLivePolling ? settings.t("spotify.live.stop") : settings.t("spotify.live.connect")) {
                        model.spotifyLivePolling ? model.stopSpotifyLivePolling() : model.connectSpotifyUserAndStartPolling()
                    }
                }
                .settingsRow("field.live_source", flashing: flashRowID)
                if model.spotifyWebAPIAuthorizationStored {
                    SettingsGroup {
                        SettingsActionRow(title: settings.t("spotify.disconnect_oauth"), subtitle: settings.t("spotify.disconnect_oauth_desc"),
                                          role: .danger) {
                            model.disconnectSpotifyUser()
                        }
                    }
                    .settingsRow("spotify.disconnect_oauth", flashing: flashRowID)
                }
            }
            section("system.sync", title: settings.t("lyrics.tab.sync"), subtitle: settings.t("lyrics.global_sync.help")) {
                offsetSumPanel
                SettingsGroup {
                    offsetRow(id: "lyrics.global_sync.title", title: settings.t("lyrics.global_sync.title"), help: "",
                              value: model.globalOffsetMs, resetTitle: settings.t("lyrics.global_sync.reset"),
                              adjust: { model.adjustGlobalOffsetMs($0) }, reset: { model.setGlobalOffsetMs(0, notify: true) })
                    offsetRow(id: "lyrics.sync.title", title: settings.t("lyrics.sync.title"), context: trackContext,
                              help: settings.t("lyrics.sync.help"), value: model.trackOffsetMs, resetTitle: settings.t("lyrics.sync.reset"),
                              adjust: { model.adjustTrackOffsetMs($0) }, reset: { model.setTrackOffsetMs(0, notify: true) })
                    offsetRow(id: "lyrics.bluetooth_sync.title", title: settings.t("lyrics.bluetooth_sync.title"),
                              context: model.hasBluetoothAudioDevice ? model.bluetoothAudioDeviceName : nil, contextIcon: "headphones",
                              subtitle: bluetoothScopeText, help: settings.t("lyrics.bluetooth_sync.help"), value: model.bluetoothOffsetMs,
                              resetTitle: settings.t("lyrics.bluetooth_sync.reset"), dimmed: !model.hasBluetoothAudioDevice,
                              adjust: { model.adjustBluetoothOffsetMs($0) }, reset: { model.setBluetoothOffsetMs(0, notify: true) })
                    offsetRow(id: "lyrics.video_sync.title", title: settings.t("lyrics.video_sync.title"), context: trackContext,
                              help: settings.t("lyrics.video_sync.help"), value: model.videoOffsetMs,
                              resetTitle: settings.t("lyrics.video_sync.reset"),
                              adjust: { model.adjustVideoOffsetMs($0) }, reset: { model.setVideoOffsetMs(0, notify: true) })
                }
            }
            section("system.update", title: settings.t("section.update")) {
                SettingsGroup {
                    SettingsStatusLine(text: model.updateStatus)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    SettingsActionRow(title: model.updateCheckInFlight ? settings.t("update.checking") : settings.t("update.check"),
                                      busy: model.updateCheckInFlight) {
                        model.checkForUpdates(manual: true)
                    }
                    .disabled(model.updateCheckInFlight)
                    .settingsRow("update.check", flashing: flashRowID)
                    SettingsActionRow(title: settings.t("button.open_release"), systemImage: "arrow.up.right") {
                        model.openUpdateReleasePage()
                    }
                    .settingsRow("button.open_release", flashing: flashRowID)
                }
            }
            section("system.tools", title: settings.t("section.tools"), subtitle: settings.t("section.tools_desc")) {
                SettingsGroup {
                    SettingsActionRow(title: settings.t("button.reload_current")) { model.reloadLyrics(bypassCache: true) }
                        .settingsRow("button.reload_current", flashing: flashRowID)
                    SettingsActionRow(title: settings.t("button.debug_log")) { settingsLogsPresented = true }
                        .settingsRow("button.debug_log", flashing: flashRowID)
                    SettingsActionRow(title: settings.t("button.ai_cache_clear")) { aiCacheConfirmationPresented = true }
                        .settingsRow("button.ai_cache_clear", flashing: flashRowID)
                }
                // Data-deleting actions sit in their own block, away from everyday tools.
                SettingsGroup {
                    SettingsActionRow(title: settings.t("button.clear_current"), role: .danger) { model.clearCachesForCurrentTrack() }
                        .settingsRow("button.clear_current", flashing: flashRowID)
                    SettingsActionRow(title: settings.t("button.clear_all"), role: .danger) { clearAllConfirmationPresented = true }
                        .settingsRow("button.clear_all", flashing: flashRowID)
                }
            }
        }
    }

    private var discordCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.2.fill")
                .font(.subheadline.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .foregroundStyle(Color.white)
                .frame(width: 40, height: 40)
                .background(Color(hex: "#5865F2"), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Discord")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(palette.text)
                Text(settings.t("creator_privacy.section_desc"))
                    .font(.footnote)
                    .foregroundStyle(palette.text3)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .settingsRowSeparator()
        .accessibilityElement(children: .combine)
    }

    private var cloudStatusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if model.cloudSettingsRequestInFlight {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: model.cloudSettingsSupportBlocked
                          ? "exclamationmark.triangle.fill"
                          : (model.cloudSettingsExists ? "checkmark.icloud" : "icloud"))
                        .foregroundStyle(model.cloudSettingsSupportBlocked
                                         ? palette.warn
                                         : (model.cloudSettingsExists ? palette.ok : palette.text3))
                }
            }
            .accessibilityHidden(true)
            Text(model.cloudSettingsStatusText)
                .font(.footnote)
                .foregroundStyle(palette.text2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(model.cloudSettingsStatusText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .settingsRowSeparator()
    }

    private var redirectURIChip: some View {
        Text(SpotifyRedirectConfiguration.uri)
            .font(.footnote.monospaced())
            .foregroundStyle(palette.text)
            .textSelection(.enabled)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(palette.surface3, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var redirectURICopyButton: some View {
        Button {
            UIPasteboard.general.string = SpotifyRedirectConfiguration.uri
            model.showSavedToast(settings.tf("toast.copied_format", SpotifyRedirectConfiguration.uri))
        } label: {
            SettingsButtonLabel(title: settings.t("button.copy"), systemImage: "doc.on.doc")
        }
        .buttonStyle(SettingsButtonStyle())
    }

    private var spotifyWebAPIOptInRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: spotifyWebAPIEnabledBinding) {
                SettingsTextBlock(title: settings.t("setting.spotify_web_api"), description: settings.t("setting.spotify_web_api_desc"))
            }
            .toggleStyle(SettingsSwitchStyle())
            .accessibilityIdentifier("settings.toggle.spotify_web_api")
            SettingsStatusLine(text: spotifyWebAPIStatusText, dot: spotifyWebAPIStatusColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .settingsRowSeparator()
    }

    private var liveSourceText: String {
        model.spotifyAppRemoteConnected
            ? settings.t("spotify.source.app_remote")
            : (model.spotifyLivePolling ? settings.t("spotify.source.web_api") : settings.t("spotify.source.off"))
    }

    private var trackContext: String? {
        model.currentTrackKey.isEmpty ? nil : model.titleText
    }

    private var bluetoothScopeText: String {
        model.hasBluetoothAudioDevice
            ? settings.tf("lyrics.bluetooth_sync.device_scope", model.bluetoothAudioDeviceName)
            : settings.t("lyrics.bluetooth_sync.no_device")
    }

    /// Global + current song + Bluetooth = what the lyrics use (video has its own offset on top).
    private var offsetSumPanel: some View {
        let parts: [(title: String, value: Int)] = [
            (title: settings.t("lyrics.global_sync.title"), value: model.globalOffsetMs),
            (title: settings.t("lyrics.sync.title"), value: model.trackOffsetMs),
            (title: settings.t("lyrics.bluetooth_sync.title"), value: model.bluetoothOffsetMs)
        ]
        let total = parts.reduce(0) { $0 + $1.value }
        return SettingsFlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                HStack(spacing: 6) {
                    if index > 0 {
                        Text("+").font(.subheadline.weight(.medium)).foregroundStyle(palette.text3)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(part.title)
                            .font(.caption)
                            .foregroundStyle(palette.text3)
                        Text(formatSignedMs(part.value))
                            .font(.subheadline.weight(.medium).monospacedDigit())
                            .foregroundStyle(palette.text)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(part.value != 0 ? palette.accentSoft : palette.surface2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(part.value != 0 ? palette.accentLine : palette.line))
                }
            }
            HStack(spacing: 6) {
                Text("=").font(.subheadline.weight(.medium)).foregroundStyle(palette.text3)
                Text(formatSignedMs(total))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(palette.text)
            }
            .frame(minHeight: 44)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.line))
        .accessibilityElement(children: .combine)
    }

    private func offsetRow(id: String, title: String, context: String? = nil, contextIcon: String = "music.note",
                           subtitle: String = "", help: String, value: Int, resetTitle: String, dimmed: Bool = false,
                           adjust: @escaping (Int) -> Void, reset: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsFlowLayout(spacing: 8, lineSpacing: 6) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(palette.text)
                if let context, !context.isEmpty {
                    SettingsPill(text: context, systemImage: contextIcon)
                }
            }
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !help.isEmpty {
                Text(help)
                    .font(.footnote)
                    .foregroundStyle(palette.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(formatSignedMs(value))
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(value == 0 ? palette.text3 : palette.text)
                .accessibilityLabel("\(title), \(formatSignedMs(value))")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: dynamicTypeSize.isAccessibilitySize ? 2 : 3),
                      spacing: 8) {
                ForEach([-100, -50, -10, 10, 50, 100], id: \.self) { delta in
                    Button { adjust(delta) } label: {
                        Text(formatSignedMs(delta))
                            .font(.subheadline.weight(.medium).monospacedDigit())
                    }
                    .buttonStyle(SettingsButtonStyle(fullWidth: true))
                    .accessibilityLabel("\(title) \(formatSignedMs(delta))")
                }
            }
            Button { reset() } label: {
                SettingsButtonLabel(title: resetTitle, systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(SettingsButtonStyle(fullWidth: true))
        }
        .opacity(dimmed ? 0.45 : 1)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsRowSeparator()
        .settingsRow(id, flashing: flashRowID)
    }

    // MARK: Bindings (same keys, saving paths, toasts and regenerations as before)

    private var spotifyWebAPIEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.spotifyWebAPIEnabled },
            set: { value in
                model.setSpotifyWebAPIEnabled(value)
                model.showSavedToast(settings.t("toast.settings_saved"))
            }
        )
    }

    private var spotifyWebAPIStatusText: String {
        guard settings.spotifyWebAPIEnabled else {
            return settings.t("setting.spotify_web_api_status_off")
        }
        return model.spotifyWebAPIConnected
            ? settings.t("setting.spotify_web_api_status_connected")
            : settings.t("setting.spotify_web_api_status_pending")
    }

    private var spotifyWebAPIStatusColor: Color {
        guard settings.spotifyWebAPIEnabled else { return palette.text4 }
        return model.spotifyWebAPIConnected ? palette.ok : palette.warn
    }

    private var creatorPrivacyBinding: Binding<Bool> {
        Binding(
            get: { model.creatorPrivacyIsPrivate },
            set: { model.setCreatorPrivacy($0) }
        )
    }

    private var creatorPrivacyStatusColor: Color {
        switch model.creatorPrivacyState {
        case .privateProfile:
            return palette.accent
        case .publicProfile:
            return palette.ok
        case .loading, .notLoaded:
            return palette.text3
        case .signedOut:
            return palette.text4
        }
    }

    private func aiProviderEnabledBinding(_ providerId: String) -> Binding<Bool> {
        Binding(
            get: { settings.aiProviderEnabled[providerId] ?? false },
            set: { enabled in
                settings.setAIProviderEnabled(providerId, enabled: enabled)
                model.translationProviderSettingsChanged()
            }
        )
    }

    private var uiLanguageBinding: Binding<String> {
        Binding(
            get: { settings.uiLang },
            set: { value in
                settings.uiLang = value
                model.uiLanguageChanged()
            }
        )
    }

    private var outputLanguageBinding: Binding<String> {
        Binding(
            get: { settings.outputLang },
            set: { value in
                let normalized = AppSettings.normalizeOutputLanguage(value)
                guard settings.outputLang != normalized else { return }
                settings.outputLang = normalized
                model.outputLanguageChanged()
            }
        )
    }

    private var pronunciationNotationBinding: Binding<String> {
        Binding(
            get: { settings.pronunciationNotation },
            set: { value in
                let normalized = AppSettings.normalizePronunciationNotation(value)
                guard settings.pronunciationNotation != normalized else { return }
                settings.pronunciationNotation = normalized
                model.pronunciationNotationChanged()
            }
        )
    }

    private var culturalAnnotationsEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.culturalAnnotationsEnabled },
            set: { enabled in
                settings.culturalAnnotationsEnabled = enabled
                model.culturalAnnotationsSettingChanged(enabled: enabled)
            }
        )
    }

    private var culturalAnnotationFontSizeBinding: Binding<Double> {
        Binding(
            get: { Double(settings.culturalAnnotationsFontSize) },
            set: { settings.culturalAnnotationsFontSize = AppSettings.clampCulturalFontSize(Int($0.rounded())) }
        )
    }

    private var culturalAnnotationFontWeightBinding: Binding<Double> {
        Binding(
            get: { Double(settings.culturalAnnotationsFontWeight) },
            set: { settings.culturalAnnotationsFontWeight = AppSettings.clampCulturalFontWeight(Int($0.rounded())) }
        )
    }

    private var culturalAnnotationOpacityBinding: Binding<Double> {
        Binding(
            get: { Double(settings.culturalAnnotationsOpacity) },
            set: { settings.culturalAnnotationsOpacity = AppSettings.clampCulturalOpacity(Int($0.rounded())) }
        )
    }

    private var culturalAnnotationVinylFontSizeBinding: Binding<Double> {
        Binding(
            get: { Double(settings.culturalAnnotationsVinylFontSize) },
            set: { settings.culturalAnnotationsVinylFontSize = AppSettings.clampCulturalFontSize(Int($0.rounded())) }
        )
    }

    private var culturalAnnotationVinylFontWeightBinding: Binding<Double> {
        Binding(
            get: { Double(settings.culturalAnnotationsVinylFontWeight) },
            set: { settings.culturalAnnotationsVinylFontWeight = AppSettings.clampCulturalFontWeight(Int($0.rounded())) }
        )
    }

    private var culturalAnnotationVinylOpacityBinding: Binding<Double> {
        Binding(
            get: { Double(settings.culturalAnnotationsVinylOpacity) },
            set: { settings.culturalAnnotationsVinylOpacity = AppSettings.clampCulturalOpacity(Int($0.rounded())) }
        )
    }

    private var metadataTranslationBinding: Binding<Bool> {
        Binding(
            get: { settings.metadataTranslationEnabled },
            set: { enabled in
                settings.metadataTranslationEnabled = enabled
                model.metadataTranslationSettingChanged(enabled: enabled)
                model.showSavedToast(settings.t(enabled ? "toast.metadata_translation_on" : "toast.metadata_translation_off"))
            }
        )
    }

    private var japaneseFuriganaBinding: Binding<Bool> {
        Binding(
            get: { settings.japaneseFuriganaEnabled },
            set: { enabled in
                settings.japaneseFuriganaEnabled = enabled
                model.japaneseFuriganaSettingChanged(enabled: enabled)
                model.showSavedToast(settings.t(enabled ? "toast.furigana_on" : "toast.furigana_off"))
            }
        )
    }

    private var autoInterludeBinding: Binding<Bool> {
        boolSettingBinding(
            \.autoInstrumentalBreakEnabled,
            onToastKey: "toast.auto_interlude_on",
            offToastKey: "toast.auto_interlude_off"
        )
    }

    private var lyricsTypePriorityBinding: Binding<Bool> {
        Binding(
            get: { settings.preferLyricsTypeOverProviderOrder },
            set: { value in
                settings.preferLyricsTypeOverProviderOrder = value
                model.reloadLyrics(bypassCache: true)
            }
        )
    }

    private var syncDataProviderPriorityBinding: Binding<Bool> {
        Binding(
            get: { settings.preferSyncDataProvider },
            set: { value in
                settings.preferSyncDataProvider = value
                model.reloadLyrics(bypassCache: true)
            }
        )
    }

    private func lyricsProviderEnabledBinding(_ providerId: String) -> Binding<Bool> {
        Binding(
            get: { settings.lyricsProviderEnabled[providerId] ?? true },
            set: { value in
                settings.setLyricsProviderEnabled(providerId, enabled: value)
                model.reloadLyrics(bypassCache: true)
            }
        )
    }

    private func lyricsProviderTypeBinding(_ providerId: String, type: String) -> Binding<Bool> {
        Binding(
            get: { settings.lyricsProviderTypes[providerId]?[type] ?? true },
            set: { value in
                settings.setLyricsProviderTypeEnabled(providerId, type: type, enabled: value)
                model.reloadLyrics(bypassCache: true)
            }
        )
    }

    private var lyricsAlignmentBinding: Binding<String> {
        Binding(
            get: { AppSettings.normalizeLyricsAlignment(settings.lyricsTextAlignment) },
            set: { value in
                settings.lyricsTextAlignment = AppSettings.normalizeLyricsAlignment(value)
                model.showSavedToast(settings.t("toast.lyrics_alignment_saved"))
            }
        )
    }

    private var backgroundModeBinding: Binding<String> {
        Binding(
            get: { settings.backgroundMode },
            set: { value in
                settings.backgroundMode = value
                model.refreshBackgroundForCurrentTrack()
                model.showSavedToast(settings.t("toast.background_saved"))
            }
        )
    }

    private var globalVideoScaleBinding: Binding<Double> {
        Binding(
            get: { Double(settings.backgroundVideoScale) },
            set: { settings.backgroundVideoScale = AppSettings.clampBackgroundVideoScale(Int($0.rounded())) }
        )
    }

    private var keepScreenOnBinding: Binding<Bool> {
        boolSettingBinding(\.keepScreenOn, onToastKey: "toast.keep_screen_on_on", offToastKey: "toast.keep_screen_on_off")
    }

    private var landscapeAutoHideBinding: Binding<Bool> {
        boolSettingBinding(\.landscapeAutoHideControls, onToastKey: "toast.landscape_auto_hide_on", offToastKey: "toast.landscape_auto_hide_off")
    }

    private var landscapeCenterNoLyricsBinding: Binding<Bool> {
        boolSettingBinding(\.landscapeCenterNoLyrics, onToastKey: "toast.landscape_center_no_lyrics_on", offToastKey: "toast.landscape_center_no_lyrics_off")
    }

    private var pipShowArtworkBinding: Binding<Bool> {
        boolSettingBinding(\.pipShowArtwork, toastKey: "toast.pip_settings_saved")
    }

    private var pipBackgroundBinding: Binding<String> {
        Binding(
            get: { AppSettings.normalizePipBackgroundMode(settings.pipBackgroundMode) },
            set: { value in
                settings.pipBackgroundMode = value
                model.showSavedToast(settings.t("toast.pip_settings_saved"))
            }
        )
    }

    private var pipOrientationBinding: Binding<String> {
        Binding(
            get: { AppSettings.normalizePipOrientation(settings.pipOrientation) },
            set: { value in
                settings.pipOrientation = value
                model.showSavedToast(settings.t("toast.pip_settings_saved"))
            }
        )
    }

    private var pipAlignmentBinding: Binding<String> {
        Binding(
            get: { AppSettings.normalizeLyricsAlignment(settings.pipLyricsTextAlignment) },
            set: { value in
                settings.pipLyricsTextAlignment = value
                model.showSavedToast(settings.t("toast.pip_settings_saved"))
            }
        )
    }

    private var pipLyricsSizeBinding: Binding<Double> {
        Binding(
            get: { Double(AppSettings.clampPipLyricsSizePercent(settings.pipLyricsSizePercent)) },
            set: { value in
                settings.pipLyricsSizePercent = AppSettings.clampPipLyricsSizePercent(Int(value.rounded()))
            }
        )
    }

    private var pipTranslationSizeBinding: Binding<Double> {
        Binding(
            get: { Double(AppSettings.clampPipTranslationSizePercent(settings.pipTranslationSizePercent)) },
            set: { value in
                settings.pipTranslationSizePercent = AppSettings.clampPipTranslationSizePercent(Int(value.rounded()))
            }
        )
    }

    private func pipSliderEditingChanged(_ editing: Bool) {
        if !editing { model.showSavedToast(settings.t("toast.pip_settings_saved")) }
    }

    private func settingsSavedSliderEditingChanged(_ editing: Bool) {
        if !editing { model.showSavedToast(settings.t("toast.settings_saved")) }
    }

    private var vinylAlbumSizeBinding: Binding<Double> {
        Binding(
            get: { Double(AppSettings.clampVinylSizePercent(settings.vinylAlbumSizePercent)) },
            set: { value in
                settings.vinylAlbumSizePercent = AppSettings.clampVinylSizePercent(Int(value.rounded()))
            }
        )
    }

    private var vinylRecordSizeBinding: Binding<Double> {
        Binding(
            get: { Double(AppSettings.clampVinylSizePercent(settings.vinylRecordSizePercent)) },
            set: { value in
                settings.vinylRecordSizePercent = AppSettings.clampVinylSizePercent(Int(value.rounded()))
            }
        )
    }

    private var vinylRotationSpeedBinding: Binding<Double> {
        Binding(
            get: { Double(settings.vinylRotationSpeedPercent) },
            set: { settings.vinylRotationSpeedPercent = VinylMotionPolicy.speedPercent(Int($0.rounded())) }
        )
    }

    private var tonearmStyleBinding: Binding<String> {
        Binding(
            get: { AppSettings.normalizeVinylTonearmStyle(settings.vinylTonearmStyle) },
            set: { value in
                settings.vinylTonearmStyle = AppSettings.normalizeVinylTonearmStyle(value)
                model.showSavedToast(settings.t("toast.settings_saved"))
            }
        )
    }

    private var tonearmFinishBinding: Binding<String> {
        Binding(
            get: { AppSettings.normalizeVinylTonearmFinish(settings.vinylTonearmFinish) },
            set: { value in
                settings.vinylTonearmFinish = AppSettings.normalizeVinylTonearmFinish(value)
                model.showSavedToast(settings.t("toast.settings_saved"))
            }
        )
    }

    private var tonearmSizeBinding: Binding<Double> {
        Binding(
            get: { Double(AppSettings.clampVinylTonearmSizePercent(settings.vinylTonearmSizePercent)) },
            set: { value in
                settings.vinylTonearmSizePercent = AppSettings.clampVinylTonearmSizePercent(Int(value.rounded()))
            }
        )
    }

    private var backgroundNoiseBinding: Binding<Bool> {
        boolSettingBinding(\.backgroundNoiseEnabled, onToastKey: "toast.background_noise_on", offToastKey: "toast.background_noise_off")
    }

    private var backgroundReduceMotionBinding: Binding<Bool> {
        boolSettingBinding(\.backgroundReduceMotionEnabled, onToastKey: "toast.reduce_motion_on", offToastKey: "toast.reduce_motion_off")
    }

    private func settingsSavedBinding(_ keyPath: ReferenceWritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        boolSettingBinding(keyPath, toastKey: "toast.settings_saved")
    }

    private func boolSettingBinding(_ keyPath: ReferenceWritableKeyPath<AppSettings, Bool>, toastKey: String) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                settings[keyPath: keyPath] = value
                model.showSavedToast(settings.t(toastKey))
            }
        )
    }

    private func boolSettingBinding(
        _ keyPath: ReferenceWritableKeyPath<AppSettings, Bool>,
        onToastKey: String,
        offToastKey: String
    ) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                settings[keyPath: keyPath] = value
                model.showSavedToast(settings.t(value ? onToastKey : offToastKey))
            }
        )
    }

    private func backgroundSliderEditingChanged(_ editing: Bool) {
        if !editing {
            model.showSavedToast(settings.t("toast.background_saved"))
        }
    }

    private func trackBackgroundSliderEditingChanged(_ editing: Bool) {
        if !editing {
            model.showSavedToast(settings.t("toast.track_background_saved"))
        }
    }

    private var maxTokensBinding: Binding<Int> {
        Binding(
            get: { settings.maxTokens },
            set: { value in
                settings.maxTokens = max(256, min(65_536, value))
            }
        )
    }

    private var temperatureBinding: Binding<Double> {
        Binding(
            get: { settings.temperature },
            set: { value in
                settings.temperature = min(2, max(0, value))
            }
        )
    }

    private var selectedRuleSourceBinding: Binding<String> {
        Binding(
            get: { model.selectedRuleSourceLang },
            set: { model.setSelectedRuleSourceLang($0) }
        )
    }

    private var selectedRuleSourceLabel: String {
        if model.selectedRuleSourceLang == "auto" {
            return settings.autoSourceLanguageLabel(model.effectiveDetectedLyricsSourceLang)
        }
        let language = AppSettings.languageInfo(effectiveRuleSourceLang)
        return "\(language.nativeName) · \(language.name)"
    }

    private var selectedRuleTargetLabel: String {
        let target = settings.snapshot.resolveTargetLanguage(sourceLang: effectiveRuleSourceLang)
        let language = AppSettings.languageInfo(target)
        return "\(language.nativeName) · \(language.name)"
    }

    private var previewHiddenBinding: Binding<Bool> {
        Binding(
            get: { AppSettings.normalizePreviewItems(settings.previewItems) == AppSettings.previewItemNone },
            set: { hidden in
                settings.setPreviewItems(hidden ? AppSettings.previewItemNone : AppSettings.previewItemOriginal)
                model.showSavedToast(settings.t("toast.preview_saved"))
            }
        )
    }

    private func previewItemBinding(_ item: Int) -> Binding<Bool> {
        Binding(
            get: {
                AppSettings.previewItemEnabled(settings.previewItems, item)
            },
            set: { enabled in
                var next = AppSettings.normalizePreviewItems(settings.previewItems)
                if enabled {
                    next |= item
                } else {
                    next &= ~item
                }
                settings.setPreviewItems(next)
                model.showSavedToast(settings.t("toast.preview_saved"))
            }
        )
    }

    private func typographyStyle(_ slot: AppSettings.TypographySlot) -> AppSettings.TypographyStyle {
        _ = settings.typographyRevision
        return settings.typographySettings().style(slot.id)
    }

    private func typographySizeBinding(_ slot: AppSettings.TypographySlot) -> Binding<Double> {
        Binding(
            get: { Double(typographyStyle(slot).sizePercent) },
            set: { value in
                let current = typographyStyle(slot)
                settings.setTypographyStyle(slotId: slot.id, sizePercent: Int(value.rounded()), weight: current.weight)
            }
        )
    }

    private func typographyWeightBinding(_ slot: AppSettings.TypographySlot) -> Binding<String> {
        Binding(
            get: { typographyStyle(slot).weight },
            set: { value in
                let current = typographyStyle(slot)
                settings.setTypographyStyle(slotId: slot.id, sizePercent: current.sizePercent, weight: value)
                model.showSavedToast(settings.t("toast.typography_saved"))
            }
        )
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
        guard !model.currentTrackKey.isEmpty, currentTrackHasBackgroundOverride else { return }
        var next = editableTrackBackground
        update(&next)
        settings.setTrackBackgroundSettings(model.currentTrackKey, next)
    }
}

private struct SettingsSectionOffsetKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

struct UpdateSheetView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.52)
                    .ignoresSafeArea()
                    .onTapGesture { dismissDialog() }

                VStack(alignment: .leading, spacing: 0) {
                    Text(settings.t("update.dialog_title"))
                        .font(.pretendard(20, weight: .bold))

                    if let info = model.pendingUpdateInfo {
                        ScrollView {
                            Text(updateMessage(info))
                                .font(.pretendard(13))
                                .foregroundStyle(.white.opacity(0.82))
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: min(updateMessageHeight(info), geometry.size.height * 0.52))
                        .padding(.top, 18)
                    } else {
                        Text(model.updateStatus.trimmed.isEmpty ? settings.t("update.status_idle") : model.updateStatus)
                            .font(.pretendard(13))
                            .foregroundStyle(.white.opacity(0.72))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 18)
                    }

                    HStack(spacing: 8) {
                        if let info = model.pendingUpdateInfo {
                            Button(settings.t("update.open_release")) {
                                dismissDialog()
                                model.openUpdateReleasePage(info)
                            }
                            .androidDialogButton()
                        }

                        Button(settings.t("update.later")) {
                            dismissDialog()
                        }
                        .androidDialogButton()
                    }
                    .padding(.top, 20)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .foregroundStyle(.white)
                .frame(maxWidth: min(430, max(300, geometry.size.width - 32)))
                .background(
                    Color(red: 31.0 / 255.0, green: 32.0 / 255.0, blue: 39.0 / 255.0),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
                .padding(.horizontal, 16)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func dismissDialog() {
        withAnimation(.easeOut(duration: 0.16)) {
            model.updateDialogPresented = false
        }
    }

    private func updateMessage(_ info: AppUpdateInfo) -> String {
        settings.tf(
            "update.dialog_message_format",
            info.currentVersionName,
            info.currentVersionCode,
            info.latestDisplayVersion,
            info.latestVersionCode,
            compactReleaseNotes(info.releaseNotes)
        )
    }

    private func updateMessageHeight(_ info: AppUpdateInfo) -> CGFloat {
        let estimatedLines = updateMessage(info)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { count, line in
                count + max(1, Int(ceil(Double(line.count) / 30.0)))
            }
        return min(390, max(96, CGFloat(estimatedLines) * 22))
    }

    private func compactReleaseNotes(_ notes: String) -> String {
        let value = notes.trimmed
        if value.isEmpty {
            return settings.t("update.no_release_notes")
        }
        return value.count <= 700 ? value : String(value.prefix(700)).trimmed + "\n..."
    }
}

private extension View {
    func androidDialogButton() -> some View {
        self
            .font(.pretendard(12, weight: .bold))
            .foregroundStyle(Color(red: 142.0 / 255.0, green: 206.0 / 255.0, blue: 255.0 / 255.0))
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
    }
}

struct PlayerTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.callout)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.08)))
    }
}

extension AppSettings.TypographySettings {
    func font(slotId: String, baseSize: CGFloat) -> Font {
        let style = style(slotId)
        return .pretendard(scaledSize(baseSize: baseSize, style: style), weight: style.fontWeight)
    }

    func font(slotId: String, baseSize: CGFloat, multiplier: Double) -> Font {
        let style = style(slotId)
        return .pretendard(scaledSize(baseSize: baseSize, style: style, multiplier: multiplier), weight: style.fontWeight)
    }

    func scaledSize(slotId: String, baseSize: CGFloat, multiplier: Double = 1) -> CGFloat {
        scaledSize(baseSize: baseSize, style: style(slotId), multiplier: multiplier)
    }

    private func scaledSize(baseSize: CGFloat, style: AppSettings.TypographyStyle, multiplier: Double = 1) -> CGFloat {
        let safeMultiplier = min(1.8, max(0.5, multiplier))
        return CGFloat(max(8, Double(baseSize) * style.scale * safeMultiplier))
    }
}

extension AppSettings.TypographyStyle {
    var fontWeight: Font.Weight {
        switch weight {
        case AppSettings.typoWeightBold:
            return .bold
        case AppSettings.typoWeightRegular:
            return .regular
        default:
            return .semibold
        }
    }
}

extension Color {
    init(hex: String) {
        let value = hex.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var number: UInt64 = 0
        Scanner(string: value).scanHexInt64(&number)
        let red = Double((number >> 16) & 0xff) / 255.0
        let green = Double((number >> 8) & 0xff) / 255.0
        let blue = Double(number & 0xff) / 255.0
        self.init(red: red, green: green, blue: blue)
    }

    var hexRGB: String? {
        #if os(iOS)
        let uiColor = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        return String(
            format: "#%02x%02x%02x",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
        #else
        return nil
        #endif
    }
}
