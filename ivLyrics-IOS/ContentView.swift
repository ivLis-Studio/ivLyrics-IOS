import Combine
import SwiftUI
import WebKit

#if os(iOS)
import UIKit
#endif

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

    @State private var animationStart = Date()

    var body: some View {
        let font = measuredFont
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let lineHeight = ceil(font.lineHeight)

        GeometryReader { proxy in
            let availableWidth = max(0, proxy.size.width)
            let overflowing = textWidth > availableWidth + 0.5

            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !overflowing)) { timeline in
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
    @StateObject private var settings = AppSettings.shared
    @StateObject private var viewModel = AppViewModel(settings: .shared)

    init() {
        IvLyricsFontLoader.registerPretendard()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(viewModel)
                .environmentObject(viewModel.playbackClock)
                .onOpenURL { url in
                    viewModel.handleOpenURL(url)
                }
        }
    }
}

struct ContentView: View {
    private static let lyricsMetaTipShownKey = "lyrics_meta_menu_tip_shown"

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.scenePhase) private var scenePhase
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

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            rootContent(
                isLandscape: isLandscape,
                size: geometry.size,
                safeAreaInsets: geometry.safeAreaInsets
            )
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
            PlayerBackgroundView()
            primaryContent(
                isLandscape: isLandscape,
                size: size,
                safeAreaInsets: safeAreaInsets
            )
            .opacity(vinylModeVisible ? 0 : 1)
            .scaleEffect(vinylModeVisible ? 0.985 : 1)
            .allowsHitTesting(!vinylModeVisible)
            .accessibilityHidden(vinylModeVisible)
            .animation(.timingCurve(0.22, 0.74, 0.28, 1, duration: 0.36), value: vinylModeVisible)
            if vinylModeVisible {
                VinylPlayerModeView(isPresented: $vinylModeVisible)
                    .transition(.opacity.combined(with: .scale(scale: 0.975)))
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
            let artworkSize = max(180, min(width - 32, fullHeight * 0.45))
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
                    model.openSpotifyForCurrentTrack()
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
            .frame(width: max(0, width - 48), height: max(0, height))
            .padding(.horizontal, 24)
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
            if controlsShown {
                LandscapeCommandBar(
                    showingSettings: $showingSettings
                )
                .padding(.top, 16)
                .padding(.trailing, 22)
                .transition(.opacity)
            }
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
        withAnimation(.timingCurve(0.18, 0.80, 0.22, 1, duration: 0.42)) {
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
    // Subscribed (not read directly) so this view re-renders with the 30 Hz playback clock driving model.nowPositionMs.
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
            if background.mode == AppSettings.backgroundGradient, let url = model.currentTrack?.artworkURL {
                MovingArtworkBlurLayer(
                    url: url,
                    blur: background.blur,
                    opacity: 1,
                    scale: background.blur >= 55 ? 2.55 : 2.2,
                    date: date,
                    reduceMotion: background.reduceMotion
                )
                .ignoresSafeArea()
                AndroidArtworkDimmingGradient(brightness: background.brightness)
                    .ignoresSafeArea()
            } else {
                backgroundBase(background: background, date: date)
            }
            if background.mode == AppSettings.backgroundVideo, let info = model.youtubeInfo {
                YouTubeBackdropSection(info: info, background: background)
            }
            if background.mode != AppSettings.backgroundGradient {
                Color.black.opacity(0.24).ignoresSafeArea()
            }
            if background.noise {
                NoiseOverlay()
                    .opacity(0.18)
                    .ignoresSafeArea()
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
    // Subscribed (not read directly) so this view re-renders with the 30 Hz playback clock driving model.nowPositionMs.
    @EnvironmentObject private var playbackClock: PlaybackClock
    var info: YouTubeVideoInfo
    var background: AppSettings.BackgroundSettings

    var body: some View {
        Group {
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
                videoScale: background.videoScale
            )
            .blur(radius: youtubeBackgroundBlurRadius(background.blur))
            .ignoresSafeArea()
            Color.black.opacity(youtubeBackgroundDimOpacity(background.brightness))
                .ignoresSafeArea()
        }
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
        let radius = max(size.width, size.height) * Self.radii[index]
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
            .blur(radius: max(8, CGFloat(blur) * 0.72))
            .opacity(opacity)
            .clipped()
        }
    }

    private func artworkTransform(size: CGSize) -> (scale: CGFloat, offset: CGSize) {
        let effectiveScale: CGFloat = reduceMotion ? max(1.16, scale * 0.92) : scale
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

private func youtubeBackgroundDimOpacity(_ brightness: Int) -> Double {
    let alpha = max(42, min(220, Int((214.0 - Double(brightness) * 1.28).rounded())))
    return Double(alpha) / 255.0
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
                Text(model.status.text(settings: settings))
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

                LyricsTimelineScrollView(
                    topPadding: 16,
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
                    model.openSpotifyForCurrentTrack()
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
                LandscapeArtworkView(size: artworkSize, onTap: onOpenVinyl)
                    .scaleEffect(controlsVisible ? 1 : 1.08)
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
                    image.resizable().scaledToFill()
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
    @EnvironmentObject private var model: AppViewModel
    // Subscribed (not read directly) so this view re-renders with the 30 Hz playback clock driving model.nowPositionMs.
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
                Button { model.togglePlayback() } label: {
                    Color.clear
                }
                .buttonStyle(AndroidTransportButtonStyle(
                    kind: .playPause,
                    primary: true,
                    playing: model.currentTrack?.playing == true,
                    size: 62
                ))
                Button { model.skipToNextTrack() } label: {
                    Color.clear
                }
                .buttonStyle(AndroidTransportButtonStyle(kind: .next, size: 54))
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
    @EnvironmentObject private var settings: AppSettings
    @Binding var showingSettings: Bool

    var body: some View {
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
    }
}

private struct LandscapeLyricsPane: View {
    var body: some View {
        LyricsTimelineScrollView(
            topPadding: 6,
            bottomPadding: 6,
            trailingPadding: 8,
            centerEmptyContent: true
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            LyricsProviderAttribution(includesSyncContributors: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
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
                    image.resizable().scaledToFill()
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

private struct TmiSheetView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel

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

                    ScrollView {
                        content
                            .frame(maxWidth: .infinity, alignment: .topLeading)
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
                        image.resizable().scaledToFill()
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
        if model.tmiLoading {
            HStack(spacing: 12) {
                ProgressView()
                    .tint(.white)
                Text(settings.t("tmi.loading"))
                    .font(.pretendard(13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(28.0 / 255.0), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        } else if let info = model.tmiInfo, info.hasContent {
            tmiInfoContent(info)
        } else {
            Text(settings.t("tmi.no_data"))
                .font(.pretendard(13))
                .foregroundStyle(.white.opacity(0.68))
                .frame(maxWidth: .infinity, minHeight: 140)
        }
    }

    private func tmiInfoContent(_ info: AiLyricsRepository.TmiInfo) -> some View {
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
    // Subscribed (not read directly) so this view re-renders with the 30 Hz playback clock driving model.nowPositionMs.
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

struct BluetoothSyncOffsetControls: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        DetailedOffsetControls(
            title: settings.t("lyrics.bluetooth_sync.title"),
            subtitle: scopeText,
            help: settings.t("lyrics.bluetooth_sync.help"),
            value: model.bluetoothOffsetMs,
            resetTitle: settings.t("lyrics.bluetooth_sync.reset"),
            contentOpacity: model.hasBluetoothAudioDevice ? 1 : 0.45,
            adjust: { model.adjustBluetoothOffsetMs($0) },
            reset: { model.setBluetoothOffsetMs(0, notify: true) }
        )
    }

    private var scopeText: String {
        model.hasBluetoothAudioDevice
            ? settings.tf("lyrics.bluetooth_sync.device_scope", model.bluetoothAudioDeviceName)
            : settings.t("lyrics.bluetooth_sync.no_device")
    }
}

struct DetailedOffsetControls: View {
    var title: String
    var subtitle: String? = nil
    var help: String
    var value: Int
    var resetTitle: String
    var contentOpacity: Double = 1
    var adjust: (Int) -> Void
    var reset: () -> Void

    private let negativeSteps = [-100, -50, -10]
    private let positiveSteps = [10, 50, 100]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(help)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(formatSignedMs(value))
                .font(.title3.monospacedDigit().weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            offsetButtonRow(negativeSteps)
            offsetButtonRow(positiveSteps)
            Button(resetTitle) {
                reset()
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
        }
        .opacity(contentOpacity)
    }

    private func offsetButtonRow(_ steps: [Int]) -> some View {
        HStack(spacing: 8) {
            ForEach(steps, id: \.self) { delta in
                Button(formatSignedMs(delta)) {
                    adjust(delta)
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func formatSignedMs(_ offsetMs: Int) -> String {
        offsetMs > 0 ? "+\(offsetMs)ms" : "\(offsetMs)ms"
    }
}

struct MainLyricPreviewPanel: View {
    private static let emptyLyricsPreviewVisibleSeconds: TimeInterval = 3

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    // Subscribed (not read directly) so this view re-renders with the 30 Hz playback clock driving model.nowPositionMs.
    @EnvironmentObject private var playbackClock: PlaybackClock
    var chromeless = false
    @State private var emptyLyricsPreviewKey = ""
    @State private var hiddenEmptyLyricsPreviewKey = ""
    @State private var emptyLyricsPreviewToken = UUID()

    var body: some View {
        let previewItems = AppSettings.normalizePreviewItems(settings.previewItems)
        Group {
            if previewItems != AppSettings.previewItemNone {
                let rows = previewRows(previewItems: previewItems)
                if !rows.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(rows) { row in
                            MainLyricPreviewRowView(row: row, positionMs: model.adjustedPositionMs)
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
        .onAppear {
            updateEmptyLyricsPreviewTimer(for: emptyLyricsPreviewCandidateKey)
        }
        .onChange(of: emptyLyricsPreviewCandidateKey) { _, key in
            updateEmptyLyricsPreviewTimer(for: key)
        }
        .onDisappear {
            resetEmptyLyricsPreviewTimer()
        }
    }

    private var reservedContentHeight: CGFloat {
        let typography = settings.typographySettings()
        let primarySize = typography.scaledSize(slotId: AppSettings.typoMainPreviewOriginal, baseSize: 17)
        let pronunciationSize = typography.scaledSize(slotId: AppSettings.typoMainPreviewPronunciation, baseSize: 14.5)
        let translationSize = typography.scaledSize(slotId: AppSettings.typoMainPreviewTranslation, baseSize: 14.5)
        let primaryRow = primarySize * 1.22 + max(7, primarySize * 0.46 * 0.82)
        let secondaryRow = max(pronunciationSize, translationSize) * 1.18
        return primaryRow + 2 * (4 + secondaryRow)
    }

    private func previewRows(previewItems: Int) -> [MainLyricPreviewRow] {
        if model.lyricsResult.lines.isEmpty {
            return emptyPreviewRows()
        }
        guard let entry = LyricsTimelineDisplayBuilder.previewItem(
            context: model.timelineContext,
            positionMs: model.adjustedPositionMs,
            trackDurationMs: model.durationMs,
            autoInstrumentalBreakEnabled: settings.autoInstrumentalBreakEnabled
        ) else {
            return [MainLyricPreviewRow(text: settings.t("status.lyrics_waiting"), primary: true)]
        }

        switch entry {
        case .interlude(let info):
            return [MainLyricPreviewRow.interlude(interludeLabel(info.kind))]
        case .line(_, let line, _):
            return previewRows(for: line, previewItems: previewItems)
        }
    }

    private func emptyPreviewRows() -> [MainLyricPreviewRow] {
        let detail = model.lyricsResult.detail.trimmed
        if model.status == .loading || isLoadingLyricsPreview(detail) {
            return [.loading(settings.t("status.lyrics_loading"))]
        }
        if hiddenEmptyLyricsPreviewKey == buildEmptyLyricsPreviewKey(detail: detail) {
            return []
        }
        return [MainLyricPreviewRow(text: detail.isEmpty ? settings.t("status.lyrics_waiting") : detail, primary: true)]
    }

    private func previewRows(for line: LyricsLine, previewItems: Int) -> [MainLyricPreviewRow] {
        var rows: [MainLyricPreviewRow] = []
        let original = originalPreviewText(line)
        if AppSettings.previewItemEnabled(previewItems, AppSettings.previewItemOriginal) {
            addPreviewRow(&rows, text: original.text, rubyText: original.rubyText, syllables: original.syllables, kind: original.kind, speaker: line.speaker, slotId: AppSettings.typoMainPreviewOriginal)
        }
        if AppSettings.previewItemEnabled(previewItems, AppSettings.previewItemPronunciation) {
            addSupplementPreviewRow(
                &rows,
                text: line.pronunciationText,
                generatingText: settings.t("loading.pronunciation"),
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
                generatingText: settings.t("loading.translation"),
                fallback: original,
                speaker: line.speaker,
                generating: model.lyricsSupplementTranslationLoading,
                slotId: AppSettings.typoMainPreviewTranslation
            )
        }
        if rows.isEmpty {
            addPreviewRow(&rows, text: original.text, rubyText: original.rubyText, syllables: original.syllables, kind: original.kind, speaker: line.speaker, slotId: AppSettings.typoMainPreviewOriginal)
        }
        return rows.map { row in
            var syncedRow = row
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

    private func isLoadingLyricsPreview(_ detail: String) -> Bool {
        let value = detail.lowercased()
        return value.contains("loading") || value.contains("불러")
    }

    private var emptyLyricsPreviewCandidateKey: String {
        let previewItems = AppSettings.normalizePreviewItems(settings.previewItems)
        guard previewItems != AppSettings.previewItemNone,
              model.lyricsResult.lines.isEmpty else {
            return ""
        }
        let detail = model.lyricsResult.detail.trimmed
        guard model.status != .loading, !isLoadingLyricsPreview(detail) else {
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

    var id: String {
        "\(type.rawValue)-\(slotId)-\(primary)-\(text)-\(rubyText)-\(syllables.count)"
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
    @State private var contentWidth: CGFloat = 0

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
        case .loading:
            MainLyricPreviewLoadingSkeleton()
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
        return settings.typographySettings()
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
                startTimeMs: row.syllables.first?.startTimeMs ?? 0,
                endTimeMs: row.syllables.last?.endTimeMs ?? 0,
                positionMs: positionMs,
                active: true,
                activeColor: LyricSpeakerPalette.activeColor(speaker: row.speaker, settings: speakerColors),
                alignment: .center,
                kind: row.kind,
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
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let nowMs = timeline.date.timeIntervalSinceReferenceDate * 1_000
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.62))
                        .frame(width: 4, height: interludeBarHeight(index: index, nowMs: nowMs, minimum: 7, maximum: 19))
                }
            }
        }
        .frame(height: 22, alignment: .center)
    }
}

private struct MainLyricPreviewLoadingSkeleton: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
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
        .accessibilityLabel("Loading lyrics")
    }
}

private struct LyricsLoadingSkeleton: View {
    private let widths: [CGFloat] = [0.62, 0.86, 0.74, 0.92, 0.56]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
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
        .accessibilityLabel("Loading lyrics")
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
        if interactive,
           !contributor.identityHidden,
           contributor.profileAvailable,
           !contributor.userHash.trimmed.isEmpty {
            Button {
                Task {
                    await model.openSyncContributorProfile(contributor)
                }
            } label: {
                Text(contributorDisplayName(contributor))
                    .foregroundStyle(.white.opacity(linkedNameOpacity))
            }
            .buttonStyle(.plain)
        } else {
            Text(contributorDisplayName(contributor))
                .foregroundStyle(.white.opacity(nameOpacity))
        }
    }

    private func contributorDisplayName(_ contributor: LyricsResult.SyncContributor) -> String {
        contributor.identityHidden ? settings.t("lyrics.credit_anonymous") : contributor.name
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
    // Subscribed (not read directly) so this view re-renders with the 30 Hz playback clock driving model.nowPositionMs.
    @EnvironmentObject private var playbackClock: PlaybackClock
    @State private var animatedCenterIndex: Double?

    var body: some View {
        let position = model.adjustedPositionMs
        let timelineContext = model.timelineContext
        let items = LyricsTimelineDisplayBuilder.items(
            context: timelineContext,
            positionMs: position,
            trackDurationMs: model.durationMs,
            autoInstrumentalBreakEnabled: settings.autoInstrumentalBreakEnabled
        )
        let activeItemID = LyricsTimelineDisplayBuilder.previewItem(
            context: timelineContext,
            positionMs: position,
            trackDurationMs: model.durationMs,
            autoInstrumentalBreakEnabled: settings.autoInstrumentalBreakEnabled
        )?.id
        let activeDisplayIndex = activeItemID.flatMap { id in
            items.firstIndex { $0.id == id }
        } ?? max(0, items.firstIndex { item in
            if case .line(let index, _, _) = item {
                return index == model.activeLineIndex
            }
            return false
        } ?? 0)
        let visualCenterIndex = animatedCenterIndex ?? Double(activeDisplayIndex)
        LazyVStack(spacing: 12) {
            if model.lyricsResult.lines.isEmpty {
                if model.status == .loading {
                    LyricsLoadingSkeleton()
                        .padding(.horizontal, 14)
                } else {
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
                    let displayDistance = abs(Double(displayIndex) - visualCenterIndex)
                    Group {
                        switch item {
                        case .line(let index, let line, _):
                            let lineActive = itemActive || (activeItemID == nil && index == model.activeLineIndex)
                            LyricsLineView(
                                lineIndex: index,
                                line: line,
                                originalText: model.displayText(for: line),
                                active: lineActive,
                                displayDistance: displayDistance,
                                progress: lineActive ? model.progress(for: line) : 0,
                                positionMs: lineActive ? position : 0,
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
                        }
                    }
                    .id(item.id)
                }
            }
        }
        .onAppear {
            animatedCenterIndex = Double(activeDisplayIndex)
        }
        .onChange(of: activeDisplayIndex) { _, nextIndex in
            let next = Double(nextIndex)
            guard let current = animatedCenterIndex, abs(next - current) <= 3.2 else {
                animatedCenterIndex = next
                return
            }
            withAnimation(LyricsMotion.centering) {
                animatedCenterIndex = next
            }
        }
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

private struct LyricsTimelineScrollView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    // Subscribed (not read directly) so this view re-renders with the 30 Hz playback clock driving model.nowPositionMs.
    @EnvironmentObject private var playbackClock: PlaybackClock
    @State private var autoScrollPaused = false
    @State private var lastScrolledTargetID: String?
    @State private var autoScrollResumeTask: Task<Void, Never>?

    var topPadding: CGFloat = 0
    var bottomPadding: CGFloat = 0
    var horizontalPadding: CGFloat = 0
    var trailingPadding: CGFloat = 0
    var centerAnchorY: CGFloat = 0.5
    var centerEmptyContent = false

    private static let manualScrollHoldSeconds: TimeInterval = 4.0

    var body: some View {
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
                            LyricsTimelineView()
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
                    .onDisappear {
                        autoScrollResumeTask?.cancel()
                        autoScrollResumeTask = nil
                    }
                }
            }
        }
    }

    private var hasScrollableLyrics: Bool {
        !model.lyricsResult.lines.isEmpty
    }

    private var shouldCenterEmptyContent: Bool {
        !hasScrollableLyrics && (centerEmptyContent || model.status == .loading)
    }

    private var activeTargetID: String? {
        LyricsTimelineDisplayBuilder.scrollTargetID(
            context: model.timelineContext,
            positionMs: model.adjustedPositionMs,
            trackDurationMs: model.durationMs,
            autoInstrumentalBreakEnabled: settings.autoInstrumentalBreakEnabled,
            vocalPartAnchorsEnabled: !settings.karaokeDataAsLineSynced
        )
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
        lastScrolledTargetID = targetID
        let action = {
            proxy.scrollTo(
                targetID,
                anchor: UnitPoint(x: 0.5, y: min(1, max(0, centerAnchorY)))
            )
        }
        if animated {
            withAnimation(LyricsMotion.centering, action)
        } else {
            action()
        }
    }
}

private enum LyricsMotion {
    // Android approaches the target with a 230 ms exponential time constant.
    static let centering = Animation.timingCurve(0.20, 0.70, 0.42, 0.96, duration: 0.82)
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
}

struct InterludeInfo {
    var startTimeMs: Int64
    var endTimeMs: Int64
    var kind: String
    var automatic: Bool
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
    }
}

enum LyricsTimelineDisplayBuilder {
    private static let interludeMinDurationMs: Int64 = 500
    private static let trailingInterludeDelayMs: Int64 = 3_500
    private static let vocalPartCenterThreshold = 4
    private static let displayWhitespace = CharacterSet.whitespacesAndNewlines

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
            if positionMs >= line.startTimeMs, positionMs < line.endTimeMs {
                return .line(index: index, line: line, id: context.lineIDs[index])
            }
            if positionMs >= line.startTimeMs {
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
            guard end - line.startTimeMs > interludeMinDurationMs else { continue }
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
        let lyricEnd = context.lastLyricEndTimes?[index] ?? lastLyricEndTime(line)
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
            let lyricEnd = context.lastLyricEndTimes?[index] ?? lastLyricEndTime(line)
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
        let normalized = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&NBSP;", with: " ")
            .trimmed
        if normalized.isEmpty { return true }
        return normalized.unicodeScalars.allSatisfy { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar)
                || scalar.value == 0x00A0
                || (scalar.value >= 0x200B && scalar.value <= 0x200D)
                || scalar.value == 0xFEFF
                || (scalar.value >= 0x2669 && scalar.value <= 0x266C)
        }
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
    var info: InterludeInfo
    var active: Bool
    var displayDistance: Double
    var showLabel: Bool
    var alignment: String

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
        .accessibilityLabel(label)
        .contentShape(Rectangle())
        .onTapGesture {
            seek(to: info.startTimeMs)
        }
    }

    private var interludeBars: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { timeline in
            let nowMs = timeline.date.timeIntervalSinceReferenceDate * 1_000
            HStack(spacing: 3.8) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2.25)
                        .fill(interludeColor)
                        .frame(
                            width: 3.2,
                            height: active
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
    var lineIndex: Int
    var line: LyricsLine
    var originalText: String
    var active: Bool
    var displayDistance: Double
    var progress: Double
    var positionMs: Int64
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
            && lhs.active == rhs.active
            && lhs.displayDistance == rhs.displayDistance
            && lhs.progress == rhs.progress
            && lhs.positionMs == rhs.positionMs
            && lhs.alignment == rhs.alignment
            && lhs.pronunciationLoading == rhs.pronunciationLoading
            && lhs.translationLoading == rhs.translationLoading
            && lhs.typography == rhs.typography
            && lhs.speakerColors == rhs.speakerColors
    }

    var body: some View {
        let orderedVocalParts = LyricsTimelineDisplayBuilder.orderedVocalParts(line.vocalParts)
        let displayVocalParts = LyricsTimelineDisplayBuilder.displayableVocalParts(orderedVocalParts)
        let useVocalPartSupplements = LyricsTimelineDisplayBuilder.shouldUseVocalPartSupplements(
            orderedParts: orderedVocalParts
        )
        VStack(alignment: stackAlignment, spacing: 4) {
            originalLyricsView(
                displayVocalParts: displayVocalParts,
                useVocalPartSupplements: useVocalPartSupplements
            )
                .font(typography.font(slotId: AppSettings.typoLyricsOriginal, baseSize: 25))
            if !useVocalPartSupplements, !line.pronunciationText.trimmed.isEmpty {
                Text(line.pronunciationText)
                    .font(typography.font(slotId: AppSettings.typoLyricsPronunciation, baseSize: 14))
                    .foregroundStyle(active ? lineActiveColor.opacity(212.0 / 255.0) : lineSupplementInactiveColor)
                    .multilineTextAlignment(textAlignment)
            } else if !useVocalPartSupplements, pronunciationLoading {
                supplementReserveText(LyricsTimelineDisplayBuilder.supplementPlaceholderText(line), slotId: AppSettings.typoLyricsPronunciation, baseSize: 14)
            }
            if !useVocalPartSupplements, !line.translationText.trimmed.isEmpty {
                Text(line.translationText)
                    .font(typography.font(slotId: AppSettings.typoLyricsTranslation, baseSize: 14))
                    .foregroundStyle(active ? lineActiveColor.opacity(184.0 / 255.0) : lineSupplementInactiveColor)
                    .multilineTextAlignment(textAlignment)
            } else if !useVocalPartSupplements, translationLoading {
                supplementReserveText(LyricsTimelineDisplayBuilder.supplementPlaceholderText(line), slotId: AppSettings.typoLyricsTranslation, baseSize: 14)
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
                    VStack(alignment: stackAlignment, spacing: 2) {
                        SyllableKaraokeText(
                            text: LyricsTimelineDisplayBuilder.vocalPartDisplayText(part),
                            rubyText: settings.japaneseFuriganaEnabled ? part.furiganaText : "",
                            syllables: shouldRenderTimedKaraoke ? part.syllables : [],
                            startTimeMs: part.startTimeMs,
                            endTimeMs: part.endTimeMs,
                            positionMs: positionMs,
                            active: partActive,
                            activeColor: vocalPartActiveColor(part),
                            alignment: textAlignment,
                            kind: part.kind,
                            inactiveColor: vocalPartInactiveColor(part, active: partActive),
                            bounceEnabled: settings.karaokeBounceEffectEnabled,
                            bounceTextSize: typography.scaledSize(slotId: AppSettings.typoLyricsOriginal, baseSize: active ? 25 : 21),
                            effectRowSeed: index
                        )
                        .id(LyricsTimelineDisplayBuilder.vocalPartTargetID(lineIndex: lineIndex, line: line, partIndex: index))
                        if useVocalPartSupplements {
                            vocalPartSupplements(part, active: partActive)
                        }
                    }
                    .padding(.top, vocalPartTopSpacing(index: index, parts: displayVocalParts))
                }
            }
        } else if shouldRenderTimedKaraoke {
            SyllableKaraokeText(
                text: originalText.isEmpty ? " " : originalText,
                rubyText: settings.japaneseFuriganaEnabled ? line.furiganaText : "",
                syllables: line.syllables,
                startTimeMs: line.startTimeMs,
                endTimeMs: line.endTimeMs,
                positionMs: positionMs,
                active: active,
                activeColor: lineActiveColor,
                alignment: textAlignment,
                kind: line.kind,
                inactiveColor: inactiveOriginalColor,
                bounceEnabled: settings.karaokeBounceEffectEnabled,
                bounceTextSize: typography.scaledSize(slotId: AppSettings.typoLyricsOriginal, baseSize: active ? 25 : 21)
            )
        } else if settings.syncedLyricsKaraokeAnimationEnabled {
            SyllableKaraokeText(
                text: originalText.isEmpty ? " " : originalText,
                rubyText: settings.japaneseFuriganaEnabled ? line.furiganaText : "",
                syllables: [],
                startTimeMs: line.startTimeMs,
                endTimeMs: line.endTimeMs,
                positionMs: positionMs,
                active: active,
                activeColor: lineActiveColor,
                alignment: textAlignment,
                kind: line.kind,
                inactiveColor: inactiveOriginalColor,
                bounceEnabled: settings.karaokeBounceEffectEnabled,
                bounceTextSize: typography.scaledSize(slotId: AppSettings.typoLyricsOriginal, baseSize: active ? 25 : 21),
                syntheticTimingEnabled: true
            )
        } else {
            SyllableKaraokeText(
                text: originalText.isEmpty ? " " : originalText,
                rubyText: settings.japaneseFuriganaEnabled ? line.furiganaText : "",
                syllables: [],
                startTimeMs: line.startTimeMs,
                endTimeMs: line.endTimeMs,
                positionMs: positionMs,
                active: active,
                activeColor: lineActiveColor,
                alignment: textAlignment,
                kind: line.kind,
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
        if !part.pronunciationText.trimmed.isEmpty {
            Text(part.pronunciationText)
                .font(typography.font(slotId: AppSettings.typoLyricsPronunciation, baseSize: active ? 14 : 12.5))
                .foregroundStyle(active ? speakerColor.opacity(212.0 / 255.0) : inactiveColor)
                .multilineTextAlignment(textAlignment)
        } else if pronunciationLoading {
            supplementReserveText(LyricsTimelineDisplayBuilder.supplementPlaceholderText(part), slotId: AppSettings.typoLyricsPronunciation, baseSize: active ? 14 : 12.5)
        }
        if !part.translationText.trimmed.isEmpty {
            Text(part.translationText)
                .font(typography.font(slotId: AppSettings.typoLyricsTranslation, baseSize: active ? 14 : 12.5))
                .foregroundStyle(active ? speakerColor.opacity(184.0 / 255.0) : inactiveColor)
                .multilineTextAlignment(textAlignment)
        } else if translationLoading {
            supplementReserveText(LyricsTimelineDisplayBuilder.supplementPlaceholderText(part), slotId: AppSettings.typoLyricsTranslation, baseSize: active ? 14 : 12.5)
        }
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
    var text: String
    var rubyText: String = ""
    var syllables: [LyricsLine.Syllable]
    var startTimeMs: Int64
    var endTimeMs: Int64
    var positionMs: Int64
    var active: Bool
    var activeColor: Color
    var alignment: TextAlignment
    var kind: String = "vocal"
    var inactiveOpacity: Double = 0.46
    var inactiveColor: Color? = nil
    var bounceEnabled: Bool = false
    var bounceTextSize: CGFloat = 22
    var syntheticTimingEnabled: Bool = false
    var effectRowSeed: Int = 0
    var singleLine: Bool = false

    var body: some View {
        let displayKind = normalizedKind
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !requiresContinuousEffect(displayKind))) { timeline in
            karaokeBody(
                nowMs: timeline.date.timeIntervalSinceReferenceDate * 1_000,
                displayKind: displayKind
            )
        }
    }

    @ViewBuilder
    private func karaokeBody(nowMs: Double, displayKind: String) -> some View {
        let segments = karaokeSegments
        Group {
            if segments.isEmpty {
                Text(text.isEmpty ? " " : text)
                    .foregroundStyle(fallbackColor)
                    .multilineTextAlignment(alignment)
                    .modifier(LyricGlyphEffectModifier(kind: displayKind, active: active, nowMs: nowMs, textSize: bounceTextSize, segmentIndex: 0, rowSeed: effectRowSeed, color: activeColor))
                    .modifier(LyricLineMotionModifier(kind: displayKind, active: active, nowMs: nowMs, textSize: bounceTextSize, rowSeed: effectRowSeed))
            } else {
                KaraokeSegmentFlowLayout(alignment: alignment, wraps: !singleLine) {
                    ForEach(segments) { segment in
                        KaraokeSyllableSegmentView(
                            segment: segment,
                            kind: displayKind,
                            active: active,
                            nowMs: nowMs,
                            textSize: bounceTextSize,
                            rowSeed: effectRowSeed
                        )
                    }
                }
                .modifier(LyricLineMotionModifier(kind: displayKind, active: active, nowMs: nowMs, textSize: bounceTextSize, rowSeed: effectRowSeed))
                .accessibilityLabel(text)
            }
        }
    }

    private var karaokeSegments: [KaraokeSyllableSegment] {
        let annotations = rubyAnnotations
        let displaySyllables = effectiveSyllables
        let bounceActiveIndex = bounceEnabled && active && !displaySyllables.isEmpty
            ? activeSegmentIndex(in: displaySyllables)
            : nil
        var timedSegments: [KaraokeSyllableSegment] = []
        timedSegments.reserveCapacity(displaySyllables.count)
        var sourceOffset = 0
        for (index, syllable) in displaySyllables.enumerated() {
            let sourceLength = syllable.text.count
            defer { sourceOffset += sourceLength }
            guard !syllable.text.isEmpty else { continue }
            let bounce = karaokeBounce(for: syllable, index: index, activeIndex: bounceActiveIndex)
            timedSegments.append(KaraokeSyllableSegment(
                id: index,
                text: syllable.text,
                rubyText: rubyReading(start: sourceOffset, length: sourceLength, annotations: annotations),
                fill: fillFraction(for: syllable),
                baseColor: baseColor,
                activeColor: activeColor,
                bounceOffsetY: bounce.offsetY,
                bounceScale: bounce.scale,
                isWhitespace: syllable.text.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
            ))
        }
        if !timedSegments.isEmpty {
            return timedSegments
        }
        return untimedRubySegments(annotations: annotations)
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
                bounceOffsetY: 0,
                bounceScale: 1,
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

    private var rubyAnnotations: [FuriganaRepository.RubyAnnotation] {
        FuriganaRepository.rubyAnnotations(text: text, markup: rubyText)
    }

    private func rubyReading(
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

    private var effectiveSyllables: [LyricsLine.Syllable] {
        let timed: [LyricsLine.Syllable]
        if syllables.contains(where: { $0.text.isEmpty }) {
            timed = syllables.filter { !$0.text.isEmpty }
        } else {
            timed = syllables
        }
        if !timed.isEmpty {
            return KaraokeSyllableTimingNormalizer.expandTimedChunks(timed)
        }
        guard syntheticTimingEnabled, endTimeMs > startTimeMs else { return [] }
        let characters = text.map(String.init)
        guard !characters.isEmpty else { return [] }
        let duration = endTimeMs - startTimeMs
        return characters.enumerated().map { index, character in
            let start = startTimeMs + Int64((Double(duration) * Double(index) / Double(characters.count)).rounded())
            let end = startTimeMs + Int64((Double(duration) * Double(index + 1) / Double(characters.count)).rounded())
            return LyricsLine.Syllable(text: character, startTimeMs: start, endTimeMs: max(start, end))
        }
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

    private func requiresContinuousEffect(_ displayKind: String) -> Bool {
        active && [
            "effect", "adlib", "pulse", "bounce", "sway", "float", "pop", "glitch",
            "wave", "sparkle", "echo", "whisper", "glow", "blur", "flicker"
        ].contains(displayKind)
    }

    private func fillFraction(for syllable: LyricsLine.Syllable) -> CGFloat {
        guard active else { return 0 }
        if positionMs >= syllable.endTimeMs {
            return 1
        }
        if positionMs <= syllable.startTimeMs || syllable.endTimeMs <= syllable.startTimeMs {
            return 0
        }
        return min(1, max(0, CGFloat(positionMs - syllable.startTimeMs) / CGFloat(syllable.endTimeMs - syllable.startTimeMs)))
    }

    private func karaokeBounce(
        for syllable: LyricsLine.Syllable,
        index: Int,
        activeIndex: Int?
    ) -> KaraokeBounceMetrics {
        guard bounceEnabled,
              active,
              syllable.endTimeMs > syllable.startTimeMs,
              let activeIndex else {
            return .idle
        }
        let distance = abs(CGFloat(index - activeIndex))
        guard distance <= 3, let rawStrength = bounceStrength(startTimeMs: syllable.startTimeMs) else {
            return .idle
        }
        let attenuation = max(0.22, 1 - distance * 0.23)
        let strength = rawStrength * attenuation
        guard strength >= 0.025 else {
            return .idle
        }
        let offsetY = ((-bounceTextSize * 0.23 * strength) * 2).rounded() / 2
        let scale = ((1 + 0.055 * strength) * 100).rounded() / 100
        return KaraokeBounceMetrics(offsetY: offsetY, scale: scale)
    }

    private func activeSegmentIndex(in syllables: [LyricsLine.Syllable]) -> Int? {
        var fallbackIndex: Int?
        var fallbackEnd = Int64.min
        var nextIndex: Int?
        var nextStart = Int64.max
        for (index, syllable) in syllables.enumerated() {
            guard !syllable.text.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) else {
                continue
            }
            if positionMs >= syllable.startTimeMs, positionMs < syllable.endTimeMs {
                return index
            }
            if positionMs >= syllable.endTimeMs, syllable.endTimeMs >= fallbackEnd {
                fallbackEnd = syllable.endTimeMs
                fallbackIndex = index
            }
            if positionMs < syllable.startTimeMs, syllable.startTimeMs < nextStart {
                nextStart = syllable.startTimeMs
                nextIndex = index
            }
        }
        if let fallbackIndex, positionMs - fallbackEnd < 2_000 {
            return nextIndex ?? fallbackIndex
        }
        return nextIndex ?? fallbackIndex
    }

    private func bounceStrength(startTimeMs: Int64) -> CGFloat? {
        let prelead: CGFloat = 70
        let rise: CGFloat = 220
        let release: CGFloat = 640
        let elapsed = CGFloat(positionMs - startTimeMs)
        if elapsed < -prelead || elapsed > rise + release {
            return nil
        }
        if elapsed < 0 {
            let progress = (elapsed + prelead) / prelead
            return easeOutCubic(progress) * 0.22
        }
        if elapsed <= rise {
            return 0.22 + easeOutCubic(elapsed / rise) * 0.78
        }
        let progress = min(1, (elapsed - rise) / release)
        return pow(1 - progress, 1.38)
    }

    private func easeOutCubic(_ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, value))
        return 1 - pow(1 - t, 3)
    }
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
    var bounceOffsetY: CGFloat
    var bounceScale: CGFloat
    var isWhitespace: Bool
}

private struct KaraokeWhitespaceLayoutKey: LayoutValueKey {
    static let defaultValue = false
}

private struct KaraokeSyllableSegmentView: View {
    var segment: KaraokeSyllableSegment
    var kind: String
    var active: Bool
    var nowMs: Double
    var textSize: CGFloat
    var rowSeed: Int

    var body: some View {
        VStack(spacing: 0) {
            if !segment.rubyText.isEmpty {
                Text(segment.rubyText)
                    .font(.system(size: max(9, textSize * 0.42), weight: .semibold))
                    .foregroundStyle((segment.fill > 0 ? segment.activeColor : segment.baseColor).opacity(0.84))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Text(segment.text)
                .foregroundStyle(segment.baseColor)
                .overlay(alignment: .leading) {
                    if segment.fill > 0 {
                        Text(segment.text)
                            .foregroundStyle(segment.activeColor)
                            .mask(KaraokeFillMask(fill: segment.fill))
                            .allowsHitTesting(false)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
            .scaleEffect(segment.bounceScale, anchor: .center)
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
            return (0, -1.5 * signedSine(effectNowMs, periodMs: 1_050), 0, 1)
        case "pulse":
            return (0, 0, 0, 1 + positiveSine(effectNowMs, periodMs: 940) * 0.025)
        case "bounce":
            return (0, -positiveSine(effectNowMs, periodMs: 780) * textSize * 0.12, 0, 1)
        case "sway":
            let wave = signedSine(effectNowMs, periodMs: 1_350)
            return (wave * textSize * 0.0245, 0, Double(wave * 0.84), 1)
        case "float":
            return (0, -positiveSine(effectNowMs, periodMs: 1_650) * textSize * 0.09, Double(signedSine(effectNowMs, periodMs: 1_650) * 0.45), 1)
        case "pop":
            let phase = effectNowMs.truncatingRemainder(dividingBy: 1_080) / 1_080
            return (0, 0, 0, phase < 0.18 ? 1.035 : (phase < 0.34 ? 0.996 : 1))
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
            let wave = CGFloat(sin(phaseTime.truncatingRemainder(dividingBy: 980) / 980 * .pi * 2))
            let lift = positiveSine(nowMs + Double(segmentIndex) * 42, periodMs: 760) * textSize * 0.018
            waveOffset = wave * textSize * 0.145 - lift
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

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = wraps
            ? max(1, proposal.width ?? CGFloat.greatestFiniteMagnitude)
            : CGFloat.greatestFiniteMagnitude
        let rows = makeRows(subviews: subviews, maxWidth: maxWidth)
        let contentWidth = rows.map(\.width).max() ?? 0
        let contentHeight = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: wraps ? (proposal.width ?? contentWidth) : contentWidth, height: contentHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = wraps ? max(1, bounds.width) : CGFloat.greatestFiniteMagnitude
        let rows = makeRows(subviews: subviews, maxWidth: maxWidth)
        for row in rows {
            var x = bounds.minX + horizontalOffset(rowWidth: row.width, containerWidth: bounds.width)
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: bounds.minY + row.y + max(0, row.height - size.height)),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width
            }
        }
    }

    private func makeRows(subviews: Subviews, maxWidth: CGFloat) -> [KaraokeSegmentLayoutRow] {
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

        let units = makeWrapUnits(subviews: subviews)
        for unit in units {
            let sizes = unit.map { subviews[$0].sizeThatFits(.unspecified) }
            let unitWidth = sizes.reduce(0) { $0 + $1.width }
            if unitWidth <= maxWidth {
                if !currentIndices.isEmpty, currentWidth + unitWidth > maxWidth {
                    flushRow()
                }
                currentIndices.append(contentsOf: unit)
                currentWidth += unitWidth
                currentHeight = max(currentHeight, sizes.map(\.height).max() ?? 0)
                continue
            }
            for (offset, index) in unit.enumerated() {
                let size = sizes[offset]
                if !currentIndices.isEmpty, currentWidth + size.width > maxWidth {
                    flushRow()
                }
                currentIndices.append(index)
                currentWidth += size.width
                currentHeight = max(currentHeight, size.height)
            }
        }
        flushRow()
        return rows
    }

    private func makeWrapUnits(subviews: Subviews) -> [[Int]] {
        var units: [[Int]] = []
        var current: [Int] = []
        for index in subviews.indices {
            current.append(index)
            if subviews[index][KaraokeWhitespaceLayoutKey.self] {
                units.append(current)
                current = []
            }
        }
        if !current.isEmpty {
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
    private let longText = "Someone to die for you and more"
    private let bounceSyllables = Array("ABCDEF").enumerated().map { index, character in
        LyricsLine.Syllable(
            text: String(character),
            startTimeMs: Int64(index * 1_000),
            endTimeMs: Int64((index + 1) * 1_000)
        )
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
                alignment: .leading,
                bounceEnabled: false,
                bounceTextSize: 38,
                syntheticTimingEnabled: true
            )
            .font(.pretendard(38, weight: .bold))
            .frame(width: 320, alignment: .leading)

            Text("Only C should bounce")
                .font(.pretendard(15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
            SyllableKaraokeText(
                text: "ABCDEF",
                syllables: bounceSyllables,
                startTimeMs: 0,
                endTimeMs: 6_000,
                positionMs: 2_100,
                active: true,
                activeColor: Color(red: 0.48, green: 0.80, blue: 0.78),
                alignment: .leading,
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
                karaokeDataAsLineSynced: false,
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
    // Subscribed (not read directly) so this view re-renders with the 30 Hz playback clock driving model.nowPositionMs.
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

struct InitialSetupView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    @State private var welcomeMessageIndex = 0

    private let welcomeMessages = [
        "ivLyrics에 오신 것을 환영합니다",
        "Welcome to ivLyrics",
        "ivLyricsへようこそ",
        "欢迎使用 ivLyrics",
        "Bienvenue dans ivLyrics",
        "Bienvenido a ivLyrics"
    ]
    private let welcomeTimer = Timer.publish(every: 1.85, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 33.0 / 255.0, green: 35.0 / 255.0, blue: 52.0 / 255.0),
                    Color(red: 13.0 / 255.0, green: 14.0 / 255.0, blue: 20.0 / 255.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    Image("IvLyricsLogo")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 86, height: 86)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    Text("ivLyrics")
                        .font(.pretendard(15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.67))
                        .padding(.top, 12)

                    ZStack {
                        Text(welcomeMessages[welcomeMessageIndex])
                            .id(welcomeMessageIndex)
                            .font(.pretendard(30, weight: .bold))
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.72)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .bottom)),
                                removal: .opacity.combined(with: .move(edge: .top))
                            ))
                    }
                    .frame(maxWidth: .infinity, minHeight: 78, maxHeight: 78)
                    .padding(.top, 18)

                    Text(settings.t("onboarding.subtitle_ios"))
                        .font(.pretendard(13))
                        .foregroundStyle(.white.opacity(0.70))
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .padding(.top, 10)

                    Text(settings.tf("onboarding.step_format", model.onboardingStep + 1, 3))
                        .font(.pretendard(11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.57))
                        .padding(.top, 30)

                    stepBody
                        .padding(.top, 14)

                    HStack(spacing: 10) {
                        Button {
                            model.retreatOnboarding()
                        } label: {
                            Text(settings.t("button.previous"))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(model.onboardingStep == 0)
                        .opacity(model.onboardingStep == 0 ? 0.45 : 1)

                        Button {
                            handleNext()
                        } label: {
                            Text(nextButtonTitle)
                                .foregroundStyle(Color(red: 0.07, green: 0.07, blue: 0.08))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(model.onboardingStep == 2 && (!model.initialSetupComplete || model.spotifyCredentialsValidationInFlight))
                        .opacity(model.onboardingStep == 2 && (!model.initialSetupComplete || model.spotifyCredentialsValidationInFlight) ? 0.42 : 1)
                    }
                    .font(.pretendard(15, weight: .semibold))
                    .padding(.top, 18)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 34)
                .padding(.bottom, 34)
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(!model.initialSetupComplete)
        .onReceive(welcomeTimer) { _ in
            withAnimation(.easeInOut(duration: 0.24)) {
                welcomeMessageIndex = (welcomeMessageIndex + 1) % welcomeMessages.count
            }
        }
    }

    @ViewBuilder
    private var stepBody: some View {
        switch model.onboardingStep {
        case 0:
            welcomeStep
        case 1:
            spotifyLiveStep
        default:
            spotifyApiStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(settings.t("onboarding.app_language_en"))
                        .font(.pretendard(12, weight: .semibold))
                    Text(settings.t("onboarding.app_language_native"))
                        .font(.pretendard(11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Picker("", selection: $settings.uiLang) {
                    ForEach(AppI18n.uiLanguages) { language in
                        Text(language.nativeName).tag(language.code)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.white)
                .frame(width: 172)
                .frame(minHeight: 42)
                .background(.white.opacity(0.17), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 12) {
                Text(settings.t("onboarding.preview.line1"))
                    .font(.pretendard(22, weight: .bold))
                Text(settings.t("onboarding.preview.line2"))
                    .font(.pretendard(19, weight: .bold))
                    .foregroundStyle(.white.opacity(0.52))
                Text(settings.t("onboarding.preview.line3"))
                    .font(.pretendard(15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.36))
                Text(settings.t("onboarding.preview.line4"))
                    .font(.pretendard(13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var spotifyLiveStep: some View {
        VStack(spacing: 14) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.green)
            Text(settings.t("spotify.live.title"))
                .font(.pretendard(21, weight: .bold))
            Text(settings.t("spotify.live.desc_ios"))
                .font(.pretendard(14))
                .foregroundStyle(.white.opacity(0.74))
                .multilineTextAlignment(.center)
            Button(model.spotifyLivePolling ? settings.t("spotify.live.connected") : settings.t("spotify.live.connect")) {
                model.spotifyLivePolling ? model.stopSpotifyLivePolling() : model.connectSpotifyUserAndStartPolling()
            }
            .buttonStyle(.borderedProminent)
            .disabled(settings.spotifyClientId.trimmed.isEmpty)
            if settings.spotifyClientId.trimmed.isEmpty {
                Text(settings.t("spotify.live.connect_after_client"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
            }
        }
        .padding(16)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var spotifyApiStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(settings.t("spotify.api.title"))
                .font(.pretendard(21, weight: .bold))
            Text(settings.t("spotify.api.desc_ios"))
                .font(.pretendard(14))
                .foregroundStyle(.white.opacity(0.74))
            TextField(settings.t("field.spotify_client_id"), text: $settings.spotifyClientId)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(PlayerTextFieldStyle())
            SecureField(settings.t("field.spotify_client_secret"), text: $settings.spotifyClientSecret)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(PlayerTextFieldStyle())
            LabeledContent(settings.t("field.redirect_uri")) {
                Text(SpotifyRedirectConfiguration.uri)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            Button(model.spotifyCredentialsValidationInFlight ? settings.t("spotify.validate_checking") : settings.t("button.spotify_save")) {
                model.validateSpotifyApiCredentials(reloadOnChange: true)
            }
            .buttonStyle(.bordered)
            .disabled(model.spotifyCredentialsValidationInFlight)
            Text(model.initialSetupComplete ? settings.t("spotify.status_credentials_saved") : settings.t("spotify.status_credentials_required"))
                .font(.caption)
                .foregroundStyle(model.initialSetupComplete ? .green : .white.opacity(0.58))
            if !model.spotifyValidationStatus.trimmed.isEmpty {
                Text(model.spotifyValidationStatus)
                    .font(.caption)
                    .foregroundStyle(model.spotifyCredentialsValidationInFlight ? .white.opacity(0.72) : .white.opacity(0.58))
            }
        }
        .padding(16)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var nextButtonTitle: String {
        if model.onboardingStep >= 2 && model.spotifyCredentialsValidationInFlight {
            return settings.t("spotify.status_checking")
        }
        return model.onboardingStep >= 2 ? settings.t("button.save_start") : settings.t("button.next")
    }

    private func handleNext() {
        if model.onboardingStep >= 2 {
            model.finishInitialSetup()
        } else {
            model.advanceOnboarding()
        }
    }
}

private struct SpotifySetupInstructionsPanel: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var step = 0
    @State private var copiedMessage = ""

    private let stepCount = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(settings.t("spotify.setup.instructions"))
                    .font(.headline)
                Spacer()
                Text(settings.tf("onboarding.step_format", step + 1, stepCount))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(stepTitle)
                .font(.subheadline.weight(.semibold))
            Text(stepDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let item = copyItem {
                copyRow(title: item.title, value: item.value)
            }

            if step == 0, let url = URL(string: "https://developer.spotify.com/dashboard") {
                Link(settings.t("button.open_browser"), destination: url)
                    .font(.caption.weight(.semibold))
            }

            if !copiedMessage.trimmed.isEmpty {
                Text(copiedMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(settings.t("button.previous")) {
                    step = max(0, step - 1)
                }
                .disabled(step == 0)

                Button(step == stepCount - 1 ? settings.t("button.restart") : settings.t("button.next")) {
                    step = step == stepCount - 1 ? 0 : step + 1
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 6)
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
            return (settings.t("spotify.copy.dashboard_url"), "https://developer.spotify.com/dashboard")
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
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            Spacer()
            Button(settings.t("button.copy")) {
                #if os(iOS)
                UIPasteboard.general.string = value
                #endif
                copiedMessage = settings.tf("toast.copied_format", value)
            }
            .buttonStyle(.bordered)
        }
    }
}

struct SettingsView: View {
    private enum SettingsTab: String, CaseIterable, Identifiable {
        case lyrics
        case display
        case ai
        case tools

        var id: String { rawValue }
        var titleKey: String { "tab.\(rawValue)" }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    @State private var settingsLogsPresented = false
    @State private var selectedTab: SettingsTab = .lyrics
    @State private var paxsenixModels: [PaxsenixAIProvider.Model] = []
    @State private var paxsenixModelsLoading = false
    @State private var paxsenixModelsError = ""

    var body: some View {
        ZStack {
            Color(red: 12.0 / 255.0, green: 13.0 / 255.0, blue: 17.0 / 255.0)
                .ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    settingsHeader

                    Text(settings.t(aiStatusKey))
                        .font(.pretendard(14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.82))
                        .padding(.top, 22)

                    settingsTabs
                        .padding(.top, 20)

                    selectedSettingsPage
                        .padding(.top, 22)
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 34)
            }
        }
        .preferredColorScheme(.dark)
        .tint(Color(red: 0.48, green: 0.80, blue: 0.78))
        .onAppear {
#if DEBUG
            if let rawTab = ProcessInfo.processInfo.environment["IVLYRICS_DEBUG_SETTINGS_TAB"],
               let tab = SettingsTab(rawValue: rawTab) {
                selectedTab = tab
            }
#endif
            if settings.providerId == "paxsenix" {
                Task { await refreshPaxsenixModels() }
            }
            model.prepareCreatorPrivacySettings()
        }
        .onChange(of: settings.providerId) { _, providerId in
            guard providerId == "paxsenix" else { return }
            Task { await refreshPaxsenixModels() }
        }
        .fullScreenCover(isPresented: $settingsLogsPresented) {
            LogsView(visible: $settingsLogsPresented)
                .environmentObject(model)
                .environmentObject(model.playbackClock)
        }
    }

    private var settingsHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(settings.t("settings.title"))
                    .font(.pretendard(26, weight: .bold))
                    .foregroundStyle(.white)
                Text(settings.t("settings.subtitle"))
                    .font(.pretendard(14))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button {
                dismiss()
            } label: {
                Text(settings.t("button.close"))
                    .font(.pretendard(16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 88, height: 48)
                    .background(Color(red: 0.23, green: 0.23, blue: 0.25), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var settingsTabs: some View {
        HStack(spacing: 10) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        selectedTab = tab
                    }
                } label: {
                    Text(settings.t(tab.titleKey))
                        .font(.pretendard(15, weight: .bold))
                        .foregroundStyle(selectedTab == tab ? Color(red: 0.08, green: 0.08, blue: 0.09) : .white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            selectedTab == tab
                                ? Color(red: 0.94, green: 0.94, blue: 0.95)
                                : Color(red: 0.17, green: 0.17, blue: 0.19),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var selectedSettingsPage: some View {
        switch selectedTab {
        case .lyrics:
            lyricsSettingsPage
        case .display:
            displaySettingsPage
        case .ai:
            aiSettingsPage
        case .tools:
            toolsSettingsPage
        }
    }

    private var lyricsSettingsPage: some View {
        VStack(alignment: .leading, spacing: 26) {
            settingsSection(
                settings.t("section.lyrics_providers"),
                description: settings.t("section.lyrics_providers_desc")
            ) {
                settingsToggleCard(
                    settings.t("setting.lyrics_type_priority"),
                    description: settings.t("setting.lyrics_type_priority_desc"),
                    binding: lyricsTypePriorityBinding
                )
                settingsToggleCard(
                    settings.t("setting.sync_data_provider_priority"),
                    description: settings.t("setting.sync_data_provider_priority_desc"),
                    binding: syncDataProviderPriorityBinding
                )
                ForEach(Array(settings.lyricsProviderOrder.enumerated()), id: \.element) { index, providerId in
                    if let provider = AppSettings.lyricsProviderById(providerId) {
                        lyricsProviderSettingsCard(provider, index: index)
                    }
                }
            }

            settingsSection(settings.t("section.language"), description: settings.t("section.language_desc")) {
                settingsCard(settings.t("setting.ui_language"), description: settings.t("setting.ui_language_desc")) {
                    Picker("", selection: uiLanguageBinding) {
                        ForEach(AppSettings.languages) { language in
                            Text("\(language.nativeName) · \(language.name)").tag(language.code)
                        }
                    }
                    .labelsHidden()
                    .settingsMenuSurface()
                }

                settingsCard(settings.t("setting.pronunciation_language"), description: settings.t("setting.pronunciation_language_desc")) {
                    Picker("", selection: outputLanguageBinding) {
                        Text(settings.t("language.same_as_ui")).tag(AppSettings.outputLangSameUI)
                        ForEach(AppSettings.languages) { language in
                            Text("\(language.nativeName) · \(language.name)").tag(language.code)
                        }
                    }
                    .labelsHidden()
                    .settingsMenuSurface()
                }

                settingsToggleCard(
                    settings.t("setting.metadata_translation"),
                    description: settings.t("setting.metadata_translation_desc"),
                    binding: metadataTranslationBinding
                )
                settingsToggleCard(
                    settings.t("setting.japanese_furigana"),
                    description: settings.t("setting.japanese_furigana_desc"),
                    binding: japaneseFuriganaBinding
                )
                settingsCard(settings.t("setting.main_preview"), description: settings.t("setting.main_preview_desc")) {
                    VStack(spacing: 4) {
                        Toggle(settings.t("setting.preview_hidden"), isOn: previewHiddenBinding)
                        Toggle(settings.t("setting.main_preview_original"), isOn: previewItemBinding(AppSettings.previewItemOriginal))
                        Toggle(settings.t("setting.main_preview_pronunciation"), isOn: previewItemBinding(AppSettings.previewItemPronunciation))
                        Toggle(settings.t("setting.main_preview_translation"), isOn: previewItemBinding(AppSettings.previewItemTranslation))
                    }
                }
            }

            settingsSection(settings.t("tab.lyrics")) {
                settingsToggleCard(settings.t("setting.auto_interlude"), description: settings.t("setting.auto_interlude_desc"), binding: autoInterludeBinding)
                settingsToggleCard(settings.t("setting.interlude_labels"), description: settings.t("setting.interlude_labels_desc"), binding: settingsSavedBinding(\.interludeLabelsEnabled))
                settingsToggleCard(settings.t("setting.synced_karaoke_animation"), description: settings.t("setting.synced_karaoke_animation_desc"), binding: settingsSavedBinding(\.syncedLyricsKaraokeAnimationEnabled))
                settingsToggleCard(settings.t("setting.karaoke_bounce_effect"), description: settings.t("setting.karaoke_bounce_effect_desc"), binding: settingsSavedBinding(\.karaokeBounceEffectEnabled))
                settingsToggleCard(settings.t("setting.karaoke_data_as_line_synced"), description: settings.t("setting.karaoke_data_as_line_synced_desc"), binding: settingsSavedBinding(\.karaokeDataAsLineSynced))
            }
        }
    }

    @ViewBuilder
    private func lyricsProviderSettingsCard(_ provider: AppSettings.LyricsProvider, index: Int) -> some View {
        settingsCard(
            provider.name,
            description: settings.t("lyrics.provider.author_default")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Toggle(
                        settings.t("lyrics.provider.enabled"),
                        isOn: lyricsProviderEnabledBinding(provider.id)
                    )
                    .font(.pretendard(14, weight: .semibold))

                    Spacer(minLength: 8)

                    Button {
                        settings.moveLyricsProvider(provider.id, offset: -1)
                        model.reloadLyrics(bypassCache: true)
                    } label: {
                        Image(systemName: "chevron.up")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.bordered)
                    .disabled(index == 0)

                    Button {
                        settings.moveLyricsProvider(provider.id, offset: 1)
                        model.reloadLyrics(bypassCache: true)
                    } label: {
                        Image(systemName: "chevron.down")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.bordered)
                    .disabled(index == settings.lyricsProviderOrder.count - 1)
                }

                Divider().overlay(.white.opacity(0.12))

                VStack(alignment: .leading, spacing: 9) {
                    Text(settings.t("lyrics.provider.allowed_types"))
                        .font(.pretendard(13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.64))
                    Toggle(
                        provider.supportsNativeKaraoke
                            ? settings.t("lyrics.provider.type_karaoke")
                            : settings.t("lyrics.provider.type_karaoke_sync_data"),
                        isOn: lyricsProviderTypeBinding(provider.id, type: AppSettings.lyricsTypeKaraoke)
                    )
                    if provider.supportsSynced {
                        Toggle(
                            settings.t("lyrics.provider.type_synced"),
                            isOn: lyricsProviderTypeBinding(provider.id, type: AppSettings.lyricsTypeSynced)
                        )
                    }
                    if provider.supportsPlain {
                        Toggle(
                            settings.t("lyrics.provider.type_plain"),
                            isOn: lyricsProviderTypeBinding(provider.id, type: AppSettings.lyricsTypePlain)
                        )
                    }
                }
                .font(.pretendard(14))

                if let projectURL = provider.projectURL,
                   let url = URL(string: projectURL) {
                    Link(destination: url) {
                        Label(settings.t("lyrics.provider.open_project"), systemImage: "arrow.up.right.square")
                            .font(.pretendard(13, weight: .semibold))
                    }
                }
            }
        }
    }

    private var displaySettingsPage: some View {
        VStack(alignment: .leading, spacing: 26) {
            settingsSection(settings.t("section.player"), description: settings.t("section.player_desc")) {
                settingsToggleCard(settings.t("setting.keep_screen_on"), description: settings.t("setting.keep_screen_on_desc"), binding: keepScreenOnBinding)
                settingsToggleCard(settings.t("setting.landscape_auto_hide"), description: settings.t("setting.landscape_auto_hide_desc"), binding: landscapeAutoHideBinding)
                settingsToggleCard(settings.t("setting.landscape_center_no_lyrics"), description: settings.t("setting.landscape_center_no_lyrics_desc"), binding: landscapeCenterNoLyricsBinding)
                settingsCard(settings.t("setting.lyrics_alignment"), description: settings.t("setting.lyrics_alignment_desc")) {
                    Picker("", selection: lyricsAlignmentBinding) {
                        Text(settings.t("alignment.left")).tag("left")
                        Text(settings.t("alignment.center")).tag("center")
                        Text(settings.t("alignment.right")).tag("right")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }

            settingsSection(settings.t("section.pip"), description: settings.t("section.pip_desc")) {
                settingsToggleCard(settings.t("setting.pip_show_artwork"), description: settings.t("setting.pip_show_artwork_desc"), binding: pipShowArtworkBinding)
                settingsCard(settings.t("setting.pip_background"), description: settings.t("setting.pip_background_desc")) {
                    Picker("", selection: Binding(get: {
                        AppSettings.normalizePipBackgroundMode(settings.pipBackgroundMode)
                    }, set: { value in
                        settings.pipBackgroundMode = value
                        model.showSavedToast(settings.t("toast.pip_settings_saved"))
                    })) {
                        Text(settings.t("pip.background.cover")).tag(AppSettings.pipBackgroundCover)
                        Text(settings.t("pip.background.blur")).tag(AppSettings.pipBackgroundBlur)
                        Text(settings.t("pip.background.gradient")).tag(AppSettings.pipBackgroundGradient)
                        Text(settings.t("background.mode.solid")).tag(AppSettings.pipBackgroundSolid)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                settingsCard(settings.t("setting.pip_orientation"), description: settings.t("setting.pip_orientation_desc")) {
                    Picker("", selection: Binding(get: {
                        AppSettings.normalizePipOrientation(settings.pipOrientation)
                    }, set: { value in
                        settings.pipOrientation = value
                        model.showSavedToast(settings.t("toast.pip_settings_saved"))
                    })) {
                        Text(settings.t("pip.orientation.landscape")).tag(AppSettings.pipOrientationLandscape)
                        Text(settings.t("pip.orientation.portrait")).tag(AppSettings.pipOrientationPortrait)
                        Text(settings.t("pip.orientation.square")).tag(AppSettings.pipOrientationSquare)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                settingsCard(settings.t("setting.pip_lyrics_alignment"), description: settings.t("setting.pip_lyrics_alignment_desc")) {
                    Picker("", selection: Binding(get: {
                        AppSettings.normalizeLyricsAlignment(settings.pipLyricsTextAlignment)
                    }, set: { value in
                        settings.pipLyricsTextAlignment = value
                        model.showSavedToast(settings.t("toast.pip_settings_saved"))
                    })) {
                        Text(settings.t("alignment.left")).tag("left")
                        Text(settings.t("alignment.center")).tag("center")
                        Text(settings.t("alignment.right")).tag("right")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                settingsCard(settings.t("setting.pip_lyrics_size"), description: settings.t("setting.pip_lyrics_size_desc")) {
                    HStack {
                        Slider(value: Binding(get: {
                            Double(AppSettings.clampPipLyricsSizePercent(settings.pipLyricsSizePercent))
                        }, set: { value in
                            settings.pipLyricsSizePercent = AppSettings.clampPipLyricsSizePercent(Int(value.rounded()))
                        }), in: 50...180, step: 1, onEditingChanged: { editing in
                            if !editing { model.showSavedToast(settings.t("toast.pip_settings_saved")) }
                        })
                        Text("\(AppSettings.clampPipLyricsSizePercent(settings.pipLyricsSizePercent))%")
                            .font(.pretendard(13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.68))
                    }
                }
                settingsCard(settings.t("setting.pip_translation_size"), description: settings.t("setting.pip_translation_size_desc")) {
                    HStack {
                        Slider(value: Binding(get: {
                            Double(AppSettings.clampPipTranslationSizePercent(settings.pipTranslationSizePercent))
                        }, set: { value in
                            settings.pipTranslationSizePercent = AppSettings.clampPipTranslationSizePercent(Int(value.rounded()))
                        }), in: 50...250, step: 1, onEditingChanged: { editing in
                            if !editing { model.showSavedToast(settings.t("toast.pip_settings_saved")) }
                        })
                        Text("\(AppSettings.clampPipTranslationSizePercent(settings.pipTranslationSizePercent))%")
                            .font(.pretendard(13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.68))
                    }
                }
            }

            settingsSection(settings.t("section.typography"), description: settings.t("section.typography_desc")) {
                ForEach(AppSettings.typographySlots) { slot in
                    settingsCard(slot.label) {
                        VStack(spacing: 10) {
                            HStack {
                                Slider(value: typographySizeBinding(slot), in: 70...160, step: 1, onEditingChanged: { editing in
                                    if !editing { model.showSavedToast(settings.t("toast.typography_saved")) }
                                })
                                Text("\(typographyStyle(slot).sizePercent)%")
                                    .foregroundStyle(.white.opacity(0.68))
                            }
                            Picker(settings.t("field.weight"), selection: typographyWeightBinding(slot)) {
                                Text(settings.t("typography.weight.regular")).tag(AppSettings.typoWeightRegular)
                                Text(settings.t("typography.weight.semibold")).tag(AppSettings.typoWeightSemibold)
                                Text(settings.t("typography.weight.bold")).tag(AppSettings.typoWeightBold)
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                }
            }

            settingsSection(settings.t("section.speaker_colors"), description: settings.t("section.speaker_colors_desc")) {
                settingsToggleCard(
                    settings.t("setting.creator_speaker_colors"),
                    description: settings.t("setting.creator_speaker_colors_desc"),
                    binding: settingsSavedBinding(\.useSyncCreatorSpeakerColors)
                )
                settingsCard(settings.t("section.speaker_colors")) {
                    VStack(spacing: 12) {
                        ForEach(AppSettings.speakerColorSlots) { slot in
                            SpeakerColorRow(slot: slot)
                                .environmentObject(settings)
                        }
                        settingsActionButton(settings.t("button.reset"), role: .destructive) {
                            settings.resetSpeakerColors()
                            model.showSavedToast(settings.t("toast.speaker_colors_reset"))
                        }
                    }
                }
            }

            backgroundSettingsSection
            trackBackgroundSettingsSection
        }
    }

    private var aiSettingsPage: some View {
        VStack(alignment: .leading, spacing: 26) {
            settingsSection(settings.t("section.ai_lyrics"), description: settings.t("section.ai_lyrics_desc")) {
                settingsToggleCard(settings.t("lyrics.translation"), binding: $settings.translationEnabled)
                settingsToggleCard(settings.t("lyrics.pronunciation"), binding: $settings.pronunciationEnabled)
                settingsCard(settings.t("section.provider")) {
                    Picker("", selection: providerBinding) {
                        ForEach(AppSettings.providers) { provider in
                            Text(provider.label).tag(provider.id)
                        }
                    }
                    .labelsHidden()
                    .settingsMenuSurface()
                }
                if let url = URL(string: selectedProvider.apiKeyURL), !selectedProvider.apiKeyURL.trimmed.isEmpty {
                    Link(settings.t("button.get_key"), destination: url)
                        .font(.pretendard(15, weight: .semibold))
                }
                settingsCard(settings.t("field.base_url")) {
                    settingsTextField(settings.t("field.base_url"), text: $settings.baseUrl)
                }
                settingsCard(
                    settings.t("field.model"),
                    description: settings.providerId == "paxsenix" && settings.model.trimmed.isEmpty
                        ? settings.t("field.model_required")
                        : ""
                ) {
                    if settings.providerId == "paxsenix" {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Picker("", selection: $settings.model) {
                                    Text(settings.t("field.model_required")).tag("")
                                    if !settings.model.trimmed.isEmpty,
                                       !paxsenixModels.contains(where: { $0.id == settings.model }) {
                                        Text(settings.model).tag(settings.model)
                                    }
                                    ForEach(paxsenixModels) { model in
                                        Text(model.displayName).tag(model.id)
                                    }
                                }
                                .labelsHidden()
                                .settingsMenuSurface()
                                .disabled(paxsenixModelsLoading || paxsenixModels.isEmpty)

                                Button {
                                    Task { await refreshPaxsenixModels() }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .frame(width: 34, height: 34)
                                }
                                .buttonStyle(.bordered)
                                .disabled(paxsenixModelsLoading)
                                .accessibilityLabel(settings.t("button.refresh_models"))
                            }
                            if paxsenixModelsLoading {
                                Text(settings.t("status.models_loading"))
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.62))
                            } else if !paxsenixModelsError.isEmpty {
                                Text(settings.t("status.models_unavailable"))
                                    .font(.caption)
                                    .foregroundStyle(Color.orange.opacity(0.88))
                            }
                            settingsTextField(settings.t("field.model_id"), text: $settings.model)
                        }
                    } else {
                        settingsTextField(settings.t("field.model"), text: $settings.model)
                    }
                }
                settingsCard(settings.t("field.max_tokens")) {
                    Stepper(value: maxTokensBinding, in: 256...65_536, step: 256) {
                        Text("\(settings.maxTokens)")
                    }
                }
                settingsCard(settings.t("field.temperature")) {
                    HStack {
                        Slider(value: temperatureBinding, in: 0...2, step: 0.05)
                        Text(String(format: "%.2f", settings.temperature))
                            .foregroundStyle(.white.opacity(0.68))
                    }
                }
                settingsCard(settings.t("field.api_key"), description: settings.t("field.api_key_desc")) {
                    TextEditor(text: $settings.apiKeys)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 86)
                        .padding(10)
                        .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                }
                if settings.providerId == "pollinations" {
                    settingsCard(settings.t("pollinations.access_token")) {
                        SecureField(settings.t("pollinations.access_token"), text: $settings.pollinationsAccessToken)
                            .textFieldStyle(PlayerTextFieldStyle())
                        Text(model.pollinationsAuthStatusText)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.62))
                        settingsActionButton(model.pollinationsConnected ? settings.t("pollinations.reconnect") : settings.t("pollinations.connect")) {
                            model.startPollinationsLogin()
                        }
                        .disabled(model.pollinationsAuthInFlight)
                        settingsActionButton(settings.t("pollinations.open_login")) { model.openPollinationsLoginPage() }
                            .disabled(!model.pollinationsCanOpenLoginPage)
                        settingsActionButton(settings.t("pollinations.test")) { model.testPollinationsToken() }
                            .disabled(!model.pollinationsCanTestToken)
                        settingsActionButton(settings.t("pollinations.disconnect"), role: .destructive) { model.disconnectPollinationsLogin() }
                            .disabled(!model.pollinationsConnected || model.pollinationsAuthInFlight)
                    }
                }
                settingsActionButton(settings.t("button.save_regenerate")) {
                    model.saveAiSettingsAndRegenerate()
                }
            }

            settingsSection(settings.t("section.language_rules")) {
                settingsCard(settings.t("field.source")) {
                    Picker("", selection: selectedRuleSourceBinding) {
                        Text(settings.t("language.auto_default")).tag("auto")
                        ForEach(AppSettings.languages) { language in
                            Text("\(language.nativeName) · \(language.name)").tag(language.code)
                        }
                    }
                    .labelsHidden()
                    .settingsMenuSurface()
                }
                settingsToggleCard(settings.t("lyrics.translation"), binding: selectedRuleTranslationBinding)
                settingsToggleCard(settings.t("lyrics.pronunciation"), binding: selectedRulePronunciationBinding)
                settingsCard(settings.t("field.track_language")) {
                    Text(selectedRuleSourceLabel).foregroundStyle(.white.opacity(0.70))
                }
                settingsCard(settings.t("field.save_target")) {
                    Text(selectedRuleTargetLabel).foregroundStyle(.white.opacity(0.70))
                }
                settingsActionButton(settings.t("lyrics.rule.reset"), role: .destructive) {
                    settings.resetLanguageRule(sourceLang: effectiveRuleSourceLang)
                    model.saveLanguageRuleAndRegenerate()
                }
                .disabled(effectiveRuleSourceLang == AppSettings.defaultSourceLang)
            }
        }
    }

    private var toolsSettingsPage: some View {
        VStack(alignment: .leading, spacing: 26) {
            settingsSection(
                settings.t("creator_privacy.section"),
                description: settings.t("creator_privacy.section_desc")
            ) {
                settingsCard(
                    settings.t("creator_privacy.private_title"),
                    description: settings.t("creator_privacy.private_desc")
                ) {
                    HStack(alignment: .center, spacing: 12) {
                        Group {
                            if model.creatorPrivacyRequestInFlight {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Circle()
                                    .fill(creatorPrivacyStatusColor)
                                    .frame(width: 8, height: 8)
                            }
                        }
                        .frame(width: 18, height: 18)

                        Text(model.creatorPrivacyStatusText)
                            .font(.pretendard(13))
                            .foregroundStyle(.white.opacity(0.68))
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 10)

                        Toggle("", isOn: creatorPrivacyBinding)
                            .labelsHidden()
                            .fixedSize()
                            .disabled(!model.creatorPrivacyCanEdit)
                            .accessibilityLabel(settings.t("creator_privacy.private_title"))
                            .accessibilityValue(model.creatorPrivacyStatusText)
                    }

                    HStack(spacing: 10) {
                        if model.creatorAccountConnected {
                            settingsActionButton(settings.t("creator_privacy.refresh")) {
                                model.refreshCreatorPrivacy()
                            }
                            .disabled(model.creatorPrivacyRequestInFlight)

                            settingsActionButton(settings.t("creator_privacy.disconnect"), role: .destructive) {
                                model.disconnectCreatorAccount()
                            }
                            .disabled(model.creatorPrivacyRequestInFlight)
                        } else {
                            settingsActionButton(settings.t("creator_privacy.login")) {
                                model.startCreatorAccountLogin()
                            }
                            .disabled(model.creatorPrivacyRequestInFlight || model.creatorPrivacyLoginInProgress)
                        }
                    }
                }
            }

            settingsSection(settings.t("section.spotify_api")) {
                settingsCard(settings.t("section.spotify_api")) {
                    SpotifySetupInstructionsPanel()
                }
                settingsCard(settings.t("field.spotify_client_id")) {
                    settingsTextField(settings.t("field.spotify_client_id"), text: $settings.spotifyClientId)
                }
                settingsCard(settings.t("field.spotify_client_secret")) {
                    SecureField(settings.t("field.spotify_client_secret"), text: $settings.spotifyClientSecret)
                        .textFieldStyle(PlayerTextFieldStyle())
                }
                settingsCard(settings.t("field.redirect_uri")) {
                    Text(SpotifyRedirectConfiguration.uri)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.white.opacity(0.72))
                }
                settingsCard(settings.t("field.live_source")) {
                    Text(model.spotifyAppRemoteConnected ? settings.t("spotify.source.app_remote") : (model.spotifyLivePolling ? settings.t("spotify.source.web_api") : settings.t("spotify.source.off")))
                        .foregroundStyle(.white.opacity(0.72))
                    settingsActionButton(model.spotifyLivePolling ? settings.t("spotify.live.stop") : settings.t("spotify.live.connect")) {
                        model.spotifyLivePolling ? model.stopSpotifyLivePolling() : model.connectSpotifyUserAndStartPolling()
                    }
                }
                if !model.spotifyValidationStatus.trimmed.isEmpty {
                    Text(model.spotifyValidationStatus)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.62))
                }
                settingsActionButton(model.spotifyCredentialsValidationInFlight ? settings.t("spotify.validate_checking") : settings.t("button.spotify_save")) {
                    model.validateSpotifyApiCredentials(reloadOnChange: true)
                }
                .disabled(model.spotifyCredentialsValidationInFlight)
                settingsActionButton(settings.t("spotify.disconnect_oauth"), role: .destructive) {
                    model.disconnectSpotifyUser()
                }
                .disabled(!model.spotifyUserConnected)
            }

            settingsSection(settings.t("lyrics.sync.title"), description: settings.t("lyrics.sync.help")) {
                settingsCard(settings.t("lyrics.sync.title")) {
                    DetailedOffsetControls(
                        title: settings.t("lyrics.sync.title"),
                        help: settings.t("lyrics.sync.help"),
                        value: model.trackOffsetMs,
                        resetTitle: settings.t("lyrics.sync.reset"),
                        adjust: { model.adjustTrackOffsetMs($0) },
                        reset: { model.setTrackOffsetMs(0, notify: true) }
                    )
                    BluetoothSyncOffsetControls()
                    DetailedOffsetControls(
                        title: settings.t("lyrics.video_sync.title"),
                        help: settings.t("lyrics.video_sync.help"),
                        value: model.videoOffsetMs,
                        resetTitle: settings.t("lyrics.video_sync.reset"),
                        adjust: { model.adjustVideoOffsetMs($0) },
                        reset: { model.setVideoOffsetMs(0, notify: true) }
                    )
                }
            }

            settingsSection(settings.t("section.update")) {
                settingsCard(settings.t("section.update")) {
                    Text(model.updateStatus)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.62))
                    settingsActionButton(model.updateCheckInFlight ? settings.t("update.checking") : settings.t("update.check")) {
                        model.checkForUpdates(manual: true)
                    }
                    .disabled(model.updateCheckInFlight)
                    settingsActionButton(settings.t("button.open_release")) { model.openUpdateReleasePage() }
                }
            }

            settingsSection(settings.t("section.tools"), description: settings.t("section.tools_desc")) {
                settingsActionButton(settings.t("button.reload_current")) { model.reloadLyrics(bypassCache: true) }
                settingsActionButton(settings.t("button.clear_current")) { model.clearCachesForCurrentTrack() }
                settingsActionButton(settings.t("button.clear_all"), role: .destructive) { model.clearAllCaches() }
                settingsActionButton(settings.t("button.ai_cache_clear")) { model.clearAiCaches() }
                settingsActionButton(settings.t("button.debug_log")) { settingsLogsPresented = true }
            }
        }
    }

    private var backgroundSettingsSection: some View {
        settingsSection(settings.t("section.background"), description: settings.t("section.background_desc")) {
            settingsCard(settings.t("setting.background_mode"), description: settings.t("setting.background_mode_desc")) {
                Picker("", selection: Binding(get: { settings.backgroundMode }, set: { value in
                    settings.backgroundMode = value
                    model.refreshBackgroundForCurrentTrack()
                    model.showSavedToast(settings.t("toast.background_saved"))
                })) {
                    Text(settings.t("background.mode.gradient")).tag(AppSettings.backgroundGradient)
                    Text(settings.t("background.mode.blur_gradient")).tag(AppSettings.backgroundBlurGradient)
                    Text(settings.t("background.mode.video")).tag(AppSettings.backgroundVideo)
                    Text(settings.t("background.mode.solid")).tag(AppSettings.backgroundSolid)
                }
                .labelsHidden()
                .settingsMenuSurface()
            }
            settingsCard(settings.t("setting.brightness")) {
                Slider(value: Binding(get: { Double(settings.backgroundBrightness) }, set: { settings.backgroundBrightness = Int($0.rounded()) }), in: 0...100, step: 1, onEditingChanged: backgroundSliderEditingChanged)
            }
            settingsCard(settings.t("setting.blur")) {
                Slider(value: Binding(get: { Double(settings.backgroundBlur) }, set: { settings.backgroundBlur = Int($0.rounded()) }), in: 0...100, step: 1, onEditingChanged: backgroundSliderEditingChanged)
            }
            settingsCard(settings.t("setting.video_scale")) {
                Slider(value: Binding(get: { Double(settings.backgroundVideoScale) }, set: { settings.backgroundVideoScale = AppSettings.clampBackgroundVideoScale(Int($0.rounded())) }), in: 100...180, step: 1, onEditingChanged: backgroundSliderEditingChanged)
            }
            settingsToggleCard(settings.t("setting.noise"), binding: backgroundNoiseBinding)
            settingsToggleCard(settings.t("setting.reduce_motion"), binding: backgroundReduceMotionBinding)
            settingsCard(settings.t("field.solid_color")) {
                HexColorEditorRow(
                    title: settings.t("field.solid_color"),
                    hexColor: $settings.backgroundSolidColor,
                    fallback: "#1e3a8a",
                    onSave: { model.showSavedToast(settings.t("toast.background_saved")) }
                )
            }
        }
    }

    private var trackBackgroundSettingsSection: some View {
        settingsSection(settings.t("section.track_background")) {
            settingsToggleCard(settings.t("lyrics.background.override"), binding: trackBackgroundOverrideBinding)
                .disabled(model.currentTrackKey.isEmpty)
            if model.currentTrackKey.isEmpty {
                Text(settings.t("label.no_current_track"))
                    .font(.pretendard(13))
                    .foregroundStyle(.white.opacity(0.58))
            } else if currentTrackHasBackgroundOverride {
                settingsCard(settings.t("setting.background_mode")) {
                    Picker("", selection: trackBackgroundModeBinding) {
                        Text(settings.t("background.mode.gradient")).tag(AppSettings.backgroundGradient)
                        Text(settings.t("background.mode.blur_gradient")).tag(AppSettings.backgroundBlurGradient)
                        Text(settings.t("background.mode.video")).tag(AppSettings.backgroundVideo)
                        Text(settings.t("background.mode.solid")).tag(AppSettings.backgroundSolid)
                    }
                    .labelsHidden()
                    .settingsMenuSurface()
                }
                settingsCard(settings.t("setting.brightness")) {
                    Slider(value: trackBackgroundBrightnessBinding, in: 0...100, step: 1, onEditingChanged: trackBackgroundSliderEditingChanged)
                }
                settingsCard(settings.t("setting.blur")) {
                    Slider(value: trackBackgroundBlurBinding, in: 0...100, step: 1, onEditingChanged: trackBackgroundSliderEditingChanged)
                }
                settingsCard(settings.t("setting.video_scale")) {
                    Slider(value: trackBackgroundVideoScaleBinding, in: 100...180, step: 1, onEditingChanged: trackBackgroundSliderEditingChanged)
                }
                settingsToggleCard(settings.t("setting.noise"), binding: trackBackgroundNoiseBinding)
                settingsToggleCard(settings.t("setting.reduce_motion"), binding: trackBackgroundReduceMotionBinding)
                settingsCard(settings.t("field.solid_color")) {
                    HexColorEditorRow(
                        title: settings.t("field.solid_color"),
                        hexColor: trackBackgroundSolidColorBinding,
                        fallback: "#1e3a8a",
                        onSave: { model.showSavedToast(settings.t("toast.track_background_saved")) }
                    )
                }
            }
        }
    }

    private var aiStatusKey: String {
        if settings.translationEnabled || settings.pronunciationEnabled {
            return "status.ai_lyrics_active"
        }
        return "status.ai_disabled"
    }

    private func settingsSection<Content: View>(
        _ title: String,
        description: String = "",
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.pretendard(23, weight: .bold))
                .foregroundStyle(.white)
            if !description.trimmed.isEmpty {
                Text(description)
                    .font(.pretendard(14))
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsCard<Content: View>(
        _ title: String,
        description: String = "",
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.trimmed.isEmpty {
                Text(title)
                    .font(.pretendard(16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            if !description.trimmed.isEmpty {
                Text(description)
                    .font(.pretendard(13))
                    .foregroundStyle(.white.opacity(0.60))
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(red: 0.16, green: 0.16, blue: 0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func settingsToggleCard(_ title: String, description: String = "", binding: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.pretendard(16, weight: .semibold))
                    .foregroundStyle(.white)
                if !description.trimmed.isEmpty {
                    Text(description)
                        .font(.pretendard(13))
                        .foregroundStyle(.white.opacity(0.60))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: binding)
                .labelsHidden()
                .fixedSize()
        }
        .padding(16)
        .background(Color(red: 0.16, green: 0.16, blue: 0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func settingsActionButton(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.pretendard(15, weight: .semibold))
                .foregroundStyle(role == .destructive ? Color(red: 1.0, green: 0.45, blue: 0.48) : .white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .background(Color.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func settingsTextField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textFieldStyle(PlayerTextFieldStyle())
    }

    private var effectiveRuleSourceLang: String {
        model.effectiveSelectedRuleSourceLang
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
            return Color(red: 0.67, green: 0.55, blue: 1.0)
        case .publicProfile:
            return Color(red: 0.21, green: 0.87, blue: 0.52)
        case .loading, .notLoaded:
            return Color.white.opacity(0.40)
        case .signedOut:
            return Color.white.opacity(0.24)
        }
    }

    private var selectedProvider: AppSettings.Provider {
        AppSettings.providerById(settings.providerId)
    }

    @MainActor
    private func refreshPaxsenixModels() async {
        guard settings.providerId == "paxsenix", !paxsenixModelsLoading else { return }
        paxsenixModelsLoading = true
        paxsenixModelsError = ""
        defer { paxsenixModelsLoading = false }
        do {
            paxsenixModels = try await PaxsenixAIProvider.fetchModels(apiKeys: settings.apiKeys)
            if paxsenixModels.isEmpty {
                paxsenixModelsError = "empty"
            }
        } catch is CancellationError {
            return
        } catch {
            paxsenixModelsError = error.localizedDescription
        }
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

    private var providerBinding: Binding<String> {
        Binding(
            get: { settings.providerId },
            set: { value in
                settings.setProvider(value)
                model.showSavedToast(settings.t("toast.provider_saved"))
            }
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
                model.saveLanguageRuleAndRegenerate()
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
                model.saveLanguageRuleAndRegenerate()
            }
        )
    }

    private var selectedRuleSourceLabel: String {
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

private extension View {
    func settingsMenuSurface() -> some View {
        self
            .pickerStyle(.menu)
            .tint(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
            .background(Color.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
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

struct HexColorEditorRow: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    let title: String
    @Binding var hexColor: String
    let fallback: String
    var onSave: (() -> Void)? = nil
    @State private var draft = ""
    @State private var invalidDraft = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: normalizedColor))
                .frame(width: 22, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.35)))
            Text(title)
            Spacer()
            ColorPicker("", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 32)
            TextField(fallback, text: $draft)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.caption.monospaced())
                .foregroundStyle(invalidDraft ? .red : .primary)
                .frame(maxWidth: 110)
                .focused($focused)
                .onChange(of: draft) { _, value in
                    invalidDraft = !value.trimmed.isEmpty && !AppSettings.isHexColor(value)
                }
                .onSubmit(saveDraft)
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
