import AVFoundation
import AVKit
import Combine
import CoreImage
import CoreMedia
import CoreVideo
import SwiftUI
import UIKit

private final class PictureInPicturePlaybackInfo: @unchecked Sendable {
    private let lock = NSLock()
    private var durationMs: Int64 = 1
    private var isPaused = true

    func update(durationMs: Int64, isPaused: Bool) {
        lock.lock()
        self.durationMs = durationMs
        self.isPaused = isPaused
        lock.unlock()
    }

    func read() -> (durationMs: Int64, isPaused: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (durationMs, isPaused)
    }
}

@MainActor
final class LyricsPictureInPictureController: NSObject, ObservableObject {
    private struct PlaybackState: Equatable {
        let durationMs: Int64
        let isPaused: Bool
    }

    private enum StartReason: Equatable {
        case explicit
        case automaticTransition
    }

    @Published private(set) var active = false

    var isEngaged: Bool { active || startReason != nil }
    var needsStateUpdates: Bool { active || startReason != nil || automaticPreparationEnabled }

    var onSetPlaying: ((Bool) -> Void)?
    var onSkip: ((Int64) -> Void)?
    var onLog: ((String) -> Void)?
    var onStartFailure: (() -> Void)?
    var onEngagementEnded: (() -> Void)?

    private let displayLayer = AVSampleBufferDisplayLayer()
    private var pictureInPictureController: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private weak var hostView: UIView?
    private var state = RenderState.empty
    private var artwork: UIImage?
    private var blurredArtwork: UIImage?
    private var artworkURL: URL?
    private var artworkTask: Task<Void, Never>?
    private var blurredArtworkTask: Task<Void, Never>?
    private var startRetryTask: Task<Void, Never>?
    private var startReason: StartReason?
    private var hasPreparedTrack = false
    private var automaticPreparationEnabled = false
    private var hasPrimedFrame = false
    private var lastRenderUptime: TimeInterval = 0
    private var lastRenderedPositionMs: Int64?
    private var lastRenderIdentityValue: String?
    private var audioSessionActive = false
    private nonisolated let playbackInfo = PictureInPicturePlaybackInfo()
    private var lastPublishedPlaybackState: PlaybackState?
    private var pixelBufferPool: CVPixelBufferPool?
    private var pixelBufferPoolSize = CGSize.zero
    private var videoFormatDescription: CMVideoFormatDescription?

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .moviePlayback,
                options: [.mixWithOthers]
            )
        } catch {
            onLog?("lyrics pip audio session category failed: \(error.localizedDescription)")
        }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.requiresLinearPlayback = false
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            Task { @MainActor [weak self] in
                guard let self, self.startReason != nil, controller.isPictureInPicturePossible else { return }
                self.startIfPossible()
            }
        }
        pictureInPictureController = controller
    }

    deinit {
        artworkTask?.cancel()
        blurredArtworkTask?.cancel()
        startRetryTask?.cancel()
        possibleObservation?.invalidate()
    }

    func attach(to view: UIView) {
        guard hostView !== view else { return }
        displayLayer.removeFromSuperlayer()
        hostView = view
        view.backgroundColor = .black
        view.layer.addSublayer(displayLayer)
        displayLayer.frame = view.bounds
    }

    func layoutHost() {
        guard let hostView else { return }
        displayLayer.frame = hostView.bounds
    }

    func update(
        track: TrackSnapshot?,
        lyrics: LyricsResult,
        positionMs: Int64,
        title: String,
        artist: String,
        statusText: String,
        settings: AppSettings.Snapshot
    ) {
        let nextState = RenderState(
            track: track,
            lines: lyrics.lines,
            positionMs: positionMs,
            title: title,
            artist: artist,
            statusText: statusText,
            showArtwork: settings.pipShowArtwork,
            orientation: settings.pipOrientation,
            backgroundMode: settings.pipBackgroundMode,
            alignment: settings.pipLyricsTextAlignment,
            lyricsSizePercent: settings.pipLyricsSizePercent,
            translationSizePercent: settings.pipTranslationSizePercent,
            solidColor: settings.backgroundSolidColor,
            syncedLyricsKaraokeAnimationEnabled: settings.syncedLyricsKaraokeAnimationEnabled,
            karaokeBounceEffectEnabled: settings.karaokeBounceEffectEnabled,
            karaokeDataAsLineSynced: settings.karaokeDataAsLineSynced,
            useSyncCreatorSpeakerColors: settings.useSyncCreatorSpeakerColors,
            typography: settings.typography,
            speakerColors: settings.speakerColors
        )
        let nextRenderIdentity = nextState.renderIdentity
        let forceRender = nextRenderIdentity != lastRenderIdentityValue
        state = nextState
        lastRenderIdentityValue = nextRenderIdentity
        publishPlaybackState(
            durationMs: max(1, track?.durationMs ?? 0),
            isPaused: !(track?.playing ?? false)
        )
        loadArtworkIfNeeded(track?.artworkURL)
        updateBlurredArtworkIfNeeded()
        hasPreparedTrack = track != nil
        let shouldPrepareAutomatically = hasPreparedTrack && pictureInPictureController != nil
        automaticPreparationEnabled = shouldPrepareAutomatically
        if shouldPrepareAutomatically {
            _ = activateAudioSession()
        } else if !active && startReason == nil {
            deactivateAudioSession()
        }
        guard active || startReason != nil || automaticPreparationEnabled else {
            if !hasPrimedFrame {
                renderFrame()
                hasPrimedFrame = lastRenderUptime > 0
            }
            return
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        if active || startReason != nil {
            if forceRender || state.positionMs != lastRenderedPositionMs || uptime - lastRenderUptime >= 1.0 {
                renderFrame()
            }
        } else if forceRender || !hasPrimedFrame || uptime - lastRenderUptime >= 1.0 {
            renderFrame()
            hasPrimedFrame = lastRenderUptime > 0
        }
    }

    func prepareForAutomaticTransition() {
        guard hasPreparedTrack else {
            onLog?("lyrics pip: automatic transition skipped (no prepared track)")
            return
        }
        guard let controller = pictureInPictureController else {
            onLog?("lyrics pip: automatic transition skipped (controller unavailable)")
            return
        }
        guard !active, !controller.isPictureInPictureActive else {
            onLog?("lyrics pip: automatic transition skipped (already active)")
            return
        }
        guard startReason == nil else {
            onLog?("lyrics pip: automatic transition skipped (start in flight)")
            return
        }
        _ = activateAudioSession()
        renderFrame()
        publishPlaybackState(
            durationMs: max(1, state.track?.durationMs ?? 0),
            isPaused: !(state.track?.playing ?? false),
            force: true
        )
        let playbackState = playbackInfo.read()
        onLog?(
            "lyrics pip: lifecycle transition possible=\(controller.isPictureInPicturePossible) " +
            "paused=\(playbackState.isPaused) durationMs=\(playbackState.durationMs)"
        )

        // Give AVKit's automatic inline-to-PiP transition the first opportunity.
        // A single short fallback preserves the previous lifecycle request without
        // depending on retries after the process has already been suspended.
        startRetryTask?.cancel()
        startRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self,
                  !Task.isCancelled,
                  !self.active,
                  controller.isPictureInPictureActive == false,
                  UIApplication.shared.applicationState != .active else { return }
            _ = self.requestStart(reason: .automaticTransition, schedulesRetries: false)
        }
    }

    @discardableResult
    func start() -> Bool {
        requestStart(reason: .explicit)
    }

    @discardableResult
    private func requestStart(reason: StartReason, schedulesRetries: Bool = true) -> Bool {
        guard AVPictureInPictureController.isPictureInPictureSupported(), pictureInPictureController != nil else {
            onLog?("lyrics pip: system Picture in Picture is not supported")
            return false
        }
        guard !active, pictureInPictureController?.isPictureInPictureActive != true else { return true }
        if startReason != nil {
            // A foreground button press upgrades an in-flight lifecycle request so
            // its eventual failure keeps the existing user-facing error behavior.
            if reason == .explicit {
                startReason = .explicit
            }
            return true
        }
        guard activateAudioSession() else {
            if reason == .automaticTransition {
                onLog?("lyrics pip: automatic transition failed (audio session unavailable)")
            }
            return false
        }
        startReason = reason
        renderFrame()
        publishPlaybackState(
            durationMs: max(1, state.track?.durationMs ?? 0),
            isPaused: !(state.track?.playing ?? false),
            force: true
        )
        if reason == .automaticTransition {
            let playbackState = playbackInfo.read()
            onLog?(
                "lyrics pip: automatic fallback requested possible=\(pictureInPictureController?.isPictureInPicturePossible == true) " +
                "paused=\(playbackState.isPaused) durationMs=\(playbackState.durationMs)"
            )
        }
        startIfPossible()
        guard !active else { return true }
        if schedulesRetries {
            scheduleStartRetries()
        } else if pictureInPictureController?.isPictureInPicturePossible != true {
            startReason = nil
            onEngagementEnded?()
            onLog?("lyrics pip: automatic fallback unavailable")
        }
        return true
    }

    private func publishPlaybackState(durationMs: Int64, isPaused: Bool, force: Bool = false) {
        let playbackState = PlaybackState(durationMs: max(1, durationMs), isPaused: isPaused)
        playbackInfo.update(durationMs: playbackState.durationMs, isPaused: playbackState.isPaused)
        guard force || playbackState != lastPublishedPlaybackState else { return }
        lastPublishedPlaybackState = playbackState
        pictureInPictureController?.invalidatePlaybackState()
    }

    private func scheduleStartRetries() {
        startRetryTask?.cancel()
        startRetryTask = Task { @MainActor [weak self] in
            for delay in [100_000_000, 300_000_000, 700_000_000, 1_500_000_000, 2_500_000_000] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay)
                guard let self, !Task.isCancelled, self.startReason != nil, !self.active else { return }
                self.renderFrame()
                self.startIfPossible()
            }
            guard let self, let reason = self.startReason, !self.active else { return }
            self.startReason = nil
            self.onEngagementEnded?()
            if !self.automaticPreparationEnabled {
                self.deactivateAudioSession()
            }
            switch reason {
            case .automaticTransition:
                self.onLog?("lyrics pip: automatic transition failed because Picture in Picture is not currently available")
            case .explicit:
                self.onLog?("lyrics pip: Picture in Picture is not currently available")
                self.onStartFailure?()
            }
        }
    }

    func stop() {
        startReason = nil
        startRetryTask?.cancel()
        if pictureInPictureController?.isPictureInPictureActive == true {
            pictureInPictureController?.stopPictureInPicture()
        } else {
            deactivateAudioSession()
        }
    }

    private func startIfPossible() {
        guard startReason != nil,
              let controller = pictureInPictureController,
              controller.isPictureInPicturePossible,
              !controller.isPictureInPictureActive else { return }
        controller.startPictureInPicture()
    }

    private func activateAudioSession() -> Bool {
        guard !audioSessionActive else { return true }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
            audioSessionActive = true
            return true
        } catch {
            onLog?("lyrics pip audio session failed: \(error.localizedDescription)")
            return false
        }
    }

    private func deactivateAudioSession() {
        guard audioSessionActive else { return }
        audioSessionActive = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            onLog?("lyrics pip audio session release failed: \(error.localizedDescription)")
        }
    }

    private func loadArtworkIfNeeded(_ url: URL?) {
        guard artworkURL != url else { return }
        artworkURL = url
        artwork = nil
        blurredArtwork = nil
        artworkTask?.cancel()
        blurredArtworkTask?.cancel()
        blurredArtworkTask = nil
        guard let url else { return }
        artworkTask = Task { @MainActor [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let image = UIImage(data: data) else { return }
                guard let self, self.artworkURL == url else { return }
                self.artwork = image
                self.updateBlurredArtworkIfNeeded()
                if self.active || self.startReason != nil {
                    self.renderFrame()
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.onLog?("lyrics pip artwork failed: \(error.localizedDescription)")
            }
        }
    }

    private func updateBlurredArtworkIfNeeded() {
        guard AppSettings.normalizePipBackgroundMode(state.backgroundMode) == AppSettings.pipBackgroundBlur else {
            blurredArtworkTask?.cancel()
            blurredArtworkTask = nil
            return
        }
        guard blurredArtwork == nil,
              blurredArtworkTask == nil,
              let artwork,
              let artworkURL else { return }
        blurredArtworkTask = Task { @MainActor [weak self] in
            let blurred = await Task.detached(priority: .utility) {
                Self.makeBlurredArtwork(from: artwork)
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.artworkURL == artworkURL,
                  AppSettings.normalizePipBackgroundMode(self.state.backgroundMode) == AppSettings.pipBackgroundBlur else { return }
            self.blurredArtworkTask = nil
            self.blurredArtwork = blurred
            if self.active || self.startReason != nil {
                self.renderFrame()
            }
        }
    }

    nonisolated private static func makeBlurredArtwork(from artwork: UIImage) -> UIImage? {
        guard var input = CIImage(image: artwork) else { return nil }
        let maxDimension = max(input.extent.width, input.extent.height)
        guard maxDimension > 0 else { return nil }
        let scale = min(1, 240 / maxDimension)
        input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = input.extent
        let blurred = input
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 28])
            .cropped(to: extent)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cgImage = context.createCGImage(blurred, from: extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func renderFrame() {
        let size = state.renderSize
        guard size.width > 0, size.height > 0 else { return }
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            drawFrame(in: CGRect(origin: .zero, size: size), context: context.cgContext)
        }
        guard let cgImage = image.cgImage,
              let pixelBuffer = makePixelBuffer(width: Int(size.width), height: Int(size.height)) else { return }
        draw(cgImage, into: pixelBuffer)
        guard let sampleBuffer = makeSampleBuffer(pixelBuffer: pixelBuffer) else { return }
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
        lastRenderUptime = ProcessInfo.processInfo.systemUptime
        lastRenderedPositionMs = state.positionMs
    }

#if DEBUG
    func debugFrameImage(orientation: String, showArtwork: Bool, backgroundMode: String = AppSettings.pipBackgroundCover) -> UIImage {
        let previousState = state
        let previousArtwork = artwork
        let previousBlurredArtwork = blurredArtwork
        let previousRenderedPositionMs = lastRenderedPositionMs
        let previousRenderIdentityValue = lastRenderIdentityValue
        defer {
            state = previousState
            artwork = previousArtwork
            blurredArtwork = previousBlurredArtwork
            lastRenderedPositionMs = previousRenderedPositionMs
            lastRenderIdentityValue = previousRenderIdentityValue
        }

        let firstPart = LyricsLine.VocalPart(
            id: "pip-debug-lead",
            role: "lead",
            speaker: "vocal1",
            speakerColor: "#73D7FF",
            kind: "wave",
            text: "We keep this moment",
            syllables: [
                LyricsLine.Syllable(text: "We keep ", startTimeMs: 0, endTimeMs: 3_000),
                LyricsLine.Syllable(text: "this moment", startTimeMs: 3_000, endTimeMs: 6_000)
            ]
        )
        let secondPart = LyricsLine.VocalPart(
            id: "pip-debug-duet",
            role: "duet",
            speaker: "vocal2",
            speakerColor: "#FF8FBC",
            kind: "wave",
            text: "moving in color",
            syllables: [
                LyricsLine.Syllable(text: "moving ", startTimeMs: 1_000, endTimeMs: 4_000),
                LyricsLine.Syllable(text: "in color", startTimeMs: 4_000, endTimeMs: 7_000)
            ]
        )
        state.lines = [LyricsLine(
            startTimeMs: 0,
            endTimeMs: 8_000,
            text: "We keep this moment moving in color",
            vocalParts: [firstPart, secondPart],
            translationText: "Android PiP visual parity"
        )]
        state.positionMs = 4_800
        state.title = "Midnight Signal"
        state.artist = "ivLyrics"
        state.statusText = ""
        state.showArtwork = showArtwork
        state.orientation = orientation
        state.backgroundMode = AppSettings.normalizePipBackgroundMode(backgroundMode)
        state.alignment = "center"
        state.lyricsSizePercent = 150
        state.translationSizePercent = 100
        lastRenderedPositionMs = nil
        lastRenderIdentityValue = nil
        artwork = Self.debugSampleArtwork()
        blurredArtwork = artwork.flatMap { Self.makeBlurredArtwork(from: $0) }

        let size = state.renderSize
        return UIGraphicsImageRenderer(size: size).image { context in
            drawFrame(in: CGRect(origin: .zero, size: size), context: context.cgContext)
        }
    }

    nonisolated private static func debugSampleArtwork() -> UIImage? {
        let size = CGSize(width: 320, height: 320)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [
                UIColor(red: 0.92, green: 0.45, blue: 0.28, alpha: 1).cgColor,
                UIColor(red: 0.32, green: 0.18, blue: 0.52, alpha: 1).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            UIColor.white.withAlphaComponent(0.85).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 90, y: 90, width: 140, height: 140))
            UIColor(red: 0.15, green: 0.65, blue: 0.9, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 130, y: 130, width: 60, height: 60))
        }
    }
#endif

    private func drawFrame(in rect: CGRect, context: CGContext) {
        drawBackground(in: rect, context: context)
        let layout = frameLayout(in: rect)
        if state.showArtwork {
            if let artwork {
                drawArtwork(artwork, in: layout.artworkRect, cornerRadius: layout.artworkCornerRadius, context: context)
            } else {
                drawArtworkPlaceholder(in: layout.artworkRect, cornerRadius: layout.artworkCornerRadius, context: context)
            }
            drawMetadata(layout: layout)
        }
        drawLyrics(in: layout.lyricsRect)
    }

    private func drawBackground(in rect: CGRect, context: CGContext) {
        switch AppSettings.normalizePipBackgroundMode(state.backgroundMode) {
        case AppSettings.pipBackgroundCover:
            guard let artwork else {
                drawBlurGradientBackground(in: rect, context: context)
                return
            }
            drawAspectFill(artwork, in: rect, context: context)
            UIColor.black.withAlphaComponent(0.45).setFill()
            UIRectFillUsingBlendMode(rect, .normal)
        case AppSettings.pipBackgroundBlur:
            guard let backgroundArtwork = blurredArtwork ?? artwork else {
                drawBlurGradientBackground(in: rect, context: context)
                return
            }
            drawAspectFill(backgroundArtwork, in: rect, context: context)
            UIColor.black.withAlphaComponent(0.72).setFill()
            UIRectFillUsingBlendMode(rect, .normal)
        case AppSettings.pipBackgroundGradient:
            drawBlurGradientBackground(in: rect, context: context)
        case AppSettings.pipBackgroundSolid:
            (UIColor(hexString: state.solidColor) ?? UIColor(red: 0.06, green: 0.08, blue: 0.12, alpha: 1)).setFill()
            UIRectFill(rect)
        default:
            drawBlurGradientBackground(in: rect, context: context)
        }
    }

    private func drawBlurGradientBackground(in rect: CGRect, context: CGContext) {
        let blobColors = [
            UIColor(red: 0.28, green: 0.25, blue: 0.49, alpha: 1),
            UIColor(red: 0.57, green: 0.33, blue: 0.51, alpha: 1),
            UIColor(red: 0.24, green: 0.37, blue: 0.51, alpha: 1),
            UIColor(red: 0.25, green: 0.45, blue: 0.40, alpha: 1),
            UIColor(red: 0.50, green: 0.23, blue: 0.33, alpha: 1),
            UIColor(red: 0.18, green: 0.30, blue: 0.48, alpha: 1)
        ]
        let radii: [CGFloat] = [0.80, 0.70, 0.55, 0.75, 0.50, 0.90]
        let centers = [
            CGPoint(x: 0.08, y: 0.18), CGPoint(x: 0.78, y: 0.12),
            CGPoint(x: 0.38, y: 0.42), CGPoint(x: 0.88, y: 0.58),
            CGPoint(x: 0.18, y: 0.82), CGPoint(x: 0.62, y: 0.92)
        ]

        UIColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1).setFill()
        UIRectFill(rect)
        context.saveGState()
        context.clip(to: rect)
        let maxDimension = max(rect.width, rect.height)
        for index in blobColors.indices {
            let alpha = max(0.16, 0.35 - CGFloat(index) * 0.025)
            let color = blobColors[index]
            let colors = [
                color.withAlphaComponent(alpha).cgColor,
                color.withAlphaComponent(alpha * 0.45).cgColor,
                color.withAlphaComponent(0).cgColor
            ] as CFArray
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 0.52, 1]
            ) else { continue }
            let center = CGPoint(
                x: rect.minX + rect.width * centers[index].x,
                y: rect.minY + rect.height * centers[index].y
            )
            context.drawRadialGradient(
                gradient,
                startCenter: center,
                startRadius: 0,
                endCenter: center,
                endRadius: maxDimension * radii[index],
                options: []
            )
        }
        context.restoreGState()
        UIColor.black.withAlphaComponent(0.40).setFill()
        UIRectFillUsingBlendMode(rect, .normal)
    }

    private func drawMetadata(layout: PictureInPictureFrameLayout) {
        drawText(
            state.title.isEmpty ? "ivLyrics" : state.title,
            in: layout.titleRect,
            font: pretendardFont(size: layout.titleFontSize, weight: .bold),
            color: .white,
            alignment: .left,
            lineLimit: 1,
            shadowed: true
        )
        drawText(
            state.artist,
            in: layout.artistRect,
            font: pretendardFont(size: layout.artistFontSize, weight: .regular),
            color: UIColor.white.withAlphaComponent(0.72),
            alignment: .left,
            lineLimit: 1,
            shadowed: true
        )
    }

    private func drawLyrics(in lyricRect: CGRect) {
        guard let active = state.activeLine else {
            let hasStatusText = state.lines.isEmpty && !state.statusText.isEmpty
            let fontSize = max(18, lyricRect.width * 0.055 * (hasStatusText ? 0.85 : 1))
            let labelRect = CGRect(
                x: lyricRect.minX,
                y: lyricRect.midY - fontSize * 0.8,
                width: lyricRect.width,
                height: fontSize * 1.6
            )
            drawText(
                hasStatusText ? "ivLyrics : \(state.statusText)" : "ivLyrics",
                in: labelRect,
                font: pretendardFont(size: fontSize, weight: .semibold),
                color: UIColor.white.withAlphaComponent(0.76),
                alignment: state.textAlignment,
                lineLimit: 2
            )
            return
        }

        let scale = Double(max(70, min(280, state.lyricsSizePercent))) / 100
        let primarySize = max(15, min(34, lyricRect.width * 0.061 * scale))
        let supplementSize = max(10, primarySize * 0.48 * CGFloat(AppSettings.clampPipTranslationSizePercent(state.translationSizePercent)) / 100)
        let nextSize = max(11, primarySize * 0.56)
        let renderedPrimarySize = state.typography.scaledSize(slotId: AppSettings.typoLyricsOriginal, baseSize: primarySize)
        let visiblePartCount = active.line.vocalParts.reduce(0) { count, part in
            LyricsTimelineDisplayBuilder.vocalPartDisplayText(part).trimmed.isEmpty ? count : count + 1
        }
        let stackMultiplier = 2.45 + CGFloat(max(0, min(3, visiblePartCount - 1))) * 1.35
        let primaryHeight = min(lyricRect.height * 0.74, renderedPrimarySize * stackMultiplier)
        let centeredPrimaryY = lyricRect.midY - primaryHeight / 2
        let primaryY = min(
            max(lyricRect.minY, centeredPrimaryY),
            max(lyricRect.minY, lyricRect.maxY - primaryHeight)
        )
        let primaryRect = CGRect(x: lyricRect.minX, y: primaryY, width: lyricRect.width, height: primaryHeight)
        drawKaraokeText(active, in: primaryRect, fontSize: primarySize)
        var cursor = primaryRect.maxY + 2

        for supplement in active.supplementLines.prefix(2) {
            let supplementRect = CGRect(x: lyricRect.minX, y: cursor, width: lyricRect.width, height: supplementSize * 1.5)
            drawText(
                supplement,
                in: supplementRect,
                font: typographyFont(slotId: AppSettings.typoLyricsPronunciation, baseSize: supplementSize),
                color: UIColor.white.withAlphaComponent(0.72),
                alignment: state.textAlignment,
                lineLimit: 1
            )
            cursor = supplementRect.maxY
        }

        if let next = state.nextLineText, cursor < lyricRect.maxY - nextSize {
            let nextRect = CGRect(x: lyricRect.minX, y: max(cursor + 4, lyricRect.maxY - nextSize * 1.75), width: lyricRect.width, height: nextSize * 1.45)
            drawText(
                next,
                in: nextRect,
                font: typographyFont(slotId: AppSettings.typoLyricsOriginal, baseSize: nextSize),
                color: UIColor.white.withAlphaComponent(0.34),
                alignment: state.textAlignment,
                lineLimit: 1
            )
        }
    }

    private func drawKaraokeText(_ active: ActiveLine, in rect: CGRect, fontSize: CGFloat) {
        guard rect.width > 0, rect.height > 0 else { return }
        let content = PictureInPictureKaraokeContent(
            line: active.line,
            positionMs: state.positionMs,
            alignment: state.swiftUITextAlignment,
            frameAlignment: state.swiftUIFrameAlignment,
            fontSize: fontSize,
            speakerColors: state.speakerColors,
            useCreatorSpeakerColors: state.useSyncCreatorSpeakerColors,
            karaokeDataAsLineSynced: state.karaokeDataAsLineSynced,
            syncedLyricsKaraokeAnimationEnabled: state.syncedLyricsKaraokeAnimationEnabled,
            bounceEnabled: state.karaokeBounceEffectEnabled,
            typography: state.typography
        )
        .frame(width: rect.width, height: rect.height, alignment: state.swiftUIFrameAlignment)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(rect.size)
        renderer.uiImage?.draw(in: rect)
    }

    private func drawText(
        _ text: String,
        in rect: CGRect,
        font: UIFont,
        color: UIColor,
        alignment: NSTextAlignment,
        lineLimit: Int,
        shadowed: Bool = false
    ) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return }
        var attributes = textAttributes(font: font, color: color, alignment: alignment, lineLimit: lineLimit)
        if shadowed {
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.72)
            shadow.shadowBlurRadius = 4
            shadow.shadowOffset = CGSize(width: 0, height: 1)
            attributes[.shadow] = shadow
        }
        (text as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            attributes: attributes,
            context: nil
        )
    }

    private func textAttributes(
        font: UIFont,
        color: UIColor,
        alignment: NSTextAlignment,
        lineLimit: Int = 2
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = lineLimit == 1 ? .byTruncatingTail : .byWordWrapping
        paragraph.maximumLineHeight = font.lineHeight * 1.08
        return [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
    }

    private func frameLayout(in rect: CGRect) -> PictureInPictureFrameLayout {
        let orientation = AppSettings.normalizePipOrientation(state.orientation)
        guard state.showArtwork else {
            let sidePadding: CGFloat
            switch orientation {
            case AppSettings.pipOrientationPortrait: sidePadding = 10
            case AppSettings.pipOrientationSquare: sidePadding = 14
            default: sidePadding = 18
            }
            return PictureInPictureFrameLayout(
                lyricsRect: CGRect(x: rect.minX + sidePadding, y: rect.minY, width: rect.width - sidePadding * 2, height: rect.height)
            )
        }

        switch orientation {
        case AppSettings.pipOrientationPortrait:
            let artworkRect = CGRect(x: 22, y: 26, width: 112, height: 112)
            let textX = artworkRect.maxX + 16
            return PictureInPictureFrameLayout(
                lyricsRect: CGRect(x: 18, y: 0, width: rect.width - 36, height: rect.height),
                artworkRect: artworkRect,
                artworkCornerRadius: 12,
                titleRect: CGRect(x: textX, y: 55, width: rect.maxX - 22 - textX, height: 29),
                artistRect: CGRect(x: textX, y: 89, width: rect.maxX - 22 - textX, height: 21),
                titleFontSize: 21,
                artistFontSize: 14
            )
        case AppSettings.pipOrientationSquare:
            let artworkRect = CGRect(x: 24, y: 22, width: 96, height: 96)
            let textX = artworkRect.maxX + 16
            return PictureInPictureFrameLayout(
                lyricsRect: CGRect(x: 20, y: 0, width: rect.width - 40, height: rect.height),
                artworkRect: artworkRect,
                artworkCornerRadius: 10,
                titleRect: CGRect(x: textX, y: 43, width: rect.maxX - 24 - textX, height: 30),
                artistRect: CGRect(x: textX, y: 78, width: rect.maxX - 24 - textX, height: 22),
                titleFontSize: 22,
                artistFontSize: 15
            )
        default:
            let horizontalContentWidth = rect.width - 26 - 30
            let gap: CGFloat = 24
            let weightedWidth = horizontalContentWidth - gap
            let metadataWidth = weightedWidth * 0.82 / 1.82
            let lyricsX = 26 + metadataWidth + gap
            let artworkRect = CGRect(x: 26, y: 18, width: 150, height: 150)
            return PictureInPictureFrameLayout(
                lyricsRect: CGRect(x: lyricsX, y: 18, width: rect.maxX - 30 - lyricsX, height: rect.height - 36),
                artworkRect: artworkRect,
                artworkCornerRadius: 12,
                titleRect: CGRect(x: 26, y: 182, width: metadataWidth, height: 30),
                artistRect: CGRect(x: 26, y: 217, width: metadataWidth, height: 22),
                titleFontSize: 22,
                artistFontSize: 15
            )
        }
    }

    private func pretendardFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let name: String
        switch weight {
        case .bold: name = "Pretendard-Bold"
        case .regular: name = "Pretendard-Regular"
        default: name = "Pretendard-SemiBold"
        }
        return UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    private func typographyFont(slotId: String, baseSize: CGFloat) -> UIFont {
        let style = state.typography.style(slotId)
        let size = state.typography.scaledSize(slotId: slotId, baseSize: baseSize)
        let weight: UIFont.Weight
        switch style.weight {
        case AppSettings.typoWeightBold: weight = .bold
        case AppSettings.typoWeightRegular: weight = .regular
        default: weight = .semibold
        }
        return pretendardFont(size: size, weight: weight)
    }

    private func drawArtwork(_ image: UIImage, in rect: CGRect, cornerRadius: CGFloat, context: CGContext) {
        context.saveGState()
        UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius).addClip()
        drawAspectFill(image, in: rect, context: context)
        context.restoreGState()
        UIColor.white.withAlphaComponent(0.12).setStroke()
        let path = UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: cornerRadius)
        path.lineWidth = 1
        path.stroke()
    }

    private func drawArtworkPlaceholder(in rect: CGRect, cornerRadius: CGFloat, context: CGContext) {
        guard !rect.isEmpty else { return }
        context.saveGState()
        UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius).addClip()
        UIColor(white: 0.12, alpha: 1).setFill()
        UIRectFill(rect)
        context.restoreGState()
        let symbol = UIImage(
            systemName: "music.note",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: rect.width * 0.34, weight: .semibold)
        )?.withTintColor(UIColor.white.withAlphaComponent(0.72), renderingMode: .alwaysOriginal)
        symbol?.draw(at: CGPoint(
            x: rect.midX - (symbol?.size.width ?? 0) / 2,
            y: rect.midY - (symbol?.size.height ?? 0) / 2
        ))
    }

    private func drawAspectFill(_ image: UIImage, in rect: CGRect, context: CGContext) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let target = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        context.saveGState()
        context.clip(to: rect)
        image.draw(in: target)
        context.restoreGState()
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let size = CGSize(width: CGFloat(width), height: CGFloat(height))
        if pixelBufferPool == nil || pixelBufferPoolSize != size {
            let poolAttributes: [CFString: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey: 3
            ]
            let pixelBufferAttributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                poolAttributes as CFDictionary,
                pixelBufferAttributes as CFDictionary,
                &pool
            ) == kCVReturnSuccess, let pool else { return nil }
            pixelBufferPool = pool
            pixelBufferPoolSize = size
            videoFormatDescription = nil
        }

        guard let pixelBufferPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pixelBufferPool,
            &pixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer else { return nil }

        if videoFormatDescription == nil {
            var formatDescription: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription
            ) == noErr, let formatDescription else { return nil }
            videoFormatDescription = formatDescription
        }
        return pixelBuffer
    }

    private func draw(_ image: CGImage, into pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                data: baseAddress,
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return }
        // `image` is already a rasterized CGImage. Drawing it into the BGRA bitmap
        // context writes its rows in the order consumed by CVPixelBuffer. Applying
        // UIKit's flipped drawing transform here reverses those rows a second time
        // and makes the sample-buffer video appear upside-down on device.
        context.draw(image, in: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)))
    }

    private func makeSampleBuffer(pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        guard let videoFormatDescription else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 15),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: videoFormatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }
        CMSetAttachment(
            sampleBuffer,
            key: kCMSampleAttachmentKey_DisplayImmediately,
            value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldPropagate
        )
        return sampleBuffer
    }

    private struct RenderState {
        var track: TrackSnapshot?
        var lines: [LyricsLine]
        var positionMs: Int64
        var title: String
        var artist: String
        var statusText: String
        var showArtwork: Bool
        var orientation: String
        var backgroundMode: String
        var alignment: String
        var lyricsSizePercent: Int
        var translationSizePercent: Int
        var solidColor: String
        var syncedLyricsKaraokeAnimationEnabled: Bool
        var karaokeBounceEffectEnabled: Bool
        var karaokeDataAsLineSynced: Bool
        var useSyncCreatorSpeakerColors: Bool
        var typography: AppSettings.TypographySettings
        var speakerColors: AppSettings.SpeakerColorSettings

        static let empty = RenderState(
            track: nil,
            lines: [],
            positionMs: 0,
            title: "ivLyrics",
            artist: "",
            statusText: "",
            showArtwork: true,
            orientation: AppSettings.pipOrientationSquare,
            backgroundMode: AppSettings.pipBackgroundCover,
            alignment: "center",
            lyricsSizePercent: 150,
            translationSizePercent: 100,
            solidColor: "#1e3a8a",
            syncedLyricsKaraokeAnimationEnabled: true,
            karaokeBounceEffectEnabled: true,
            karaokeDataAsLineSynced: false,
            useSyncCreatorSpeakerColors: true,
            typography: .defaults,
            speakerColors: .defaults
        )

        var renderSize: CGSize {
            switch AppSettings.normalizePipOrientation(orientation) {
            case AppSettings.pipOrientationPortrait:
                return CGSize(width: 360, height: 640)
            case AppSettings.pipOrientationSquare:
                return CGSize(width: 480, height: 480)
            default:
                return CGSize(width: 640, height: 360)
            }
        }

        var textAlignment: NSTextAlignment {
            switch AppSettings.normalizeLyricsAlignment(alignment) {
            case "right": return .right
            case "center": return .center
            default: return .left
            }
        }

        var swiftUITextAlignment: TextAlignment {
            switch AppSettings.normalizeLyricsAlignment(alignment) {
            case "right": return .trailing
            case "center": return .center
            default: return .leading
            }
        }

        var swiftUIFrameAlignment: Alignment {
            switch AppSettings.normalizeLyricsAlignment(alignment) {
            case "right": return .trailing
            case "center": return .center
            default: return .leading
            }
        }

        var activeLine: ActiveLine? {
            guard !lines.isEmpty else { return nil }
            var index = 0
            for candidate in lines.indices {
                let line = lines[candidate]
                if positionMs >= line.startTimeMs { index = candidate }
                if line.endTimeMs > line.startTimeMs,
                   positionMs >= line.startTimeMs,
                   positionMs < line.endTimeMs {
                    index = candidate
                    break
                }
            }
            let line = lines[index]
            let duration = max(1, line.endTimeMs - line.startTimeMs)
            let progress = max(0, min(1, CGFloat(positionMs - line.startTimeMs) / CGFloat(duration)))
            return ActiveLine(line: line, index: index, progress: progress)
        }

        var nextLineText: String? {
            guard let activeLine else { return nil }
            let index = activeLine.index + 1
            guard lines.indices.contains(index) else { return nil }
            let value = lines[index].text.trimmed
            return value.isEmpty ? nil : value
        }

        var renderIdentity: String {
            let line = activeLine
            return [
                track?.stableKey ?? "",
                String(line?.index ?? -1),
                title,
                artist,
                statusText,
                String(showArtwork),
                orientation,
                backgroundMode,
                alignment,
                String(lyricsSizePercent),
                String(translationSizePercent),
                solidColor,
                String(syncedLyricsKaraokeAnimationEnabled),
                String(karaokeBounceEffectEnabled),
                String(karaokeDataAsLineSynced),
                String(useSyncCreatorSpeakerColors),
                line?.line.furiganaText ?? "",
                line?.line.pronunciationText ?? "",
                line?.line.translationText ?? "",
                line?.line.vocalParts.map { [$0.furiganaText, $0.pronunciationText, $0.translationText].joined(separator: "\u{1f}") }.joined(separator: "\u{1e}") ?? "",
                String(typography.hashValue),
                String(speakerColors.hashValue)
            ].joined(separator: "|")
        }
    }

    private struct ActiveLine {
        var line: LyricsLine
        var index: Int
        var progress: CGFloat

        var supplementLines: [String] {
            [line.pronunciationText, line.translationText]
                .map(\.trimmed)
                .filter { !$0.isEmpty }
        }
    }

    private struct PictureInPictureFrameLayout {
        var lyricsRect: CGRect
        var artworkRect: CGRect = .zero
        var artworkCornerRadius: CGFloat = 0
        var titleRect: CGRect = .zero
        var artistRect: CGRect = .zero
        var titleFontSize: CGFloat = 0
        var artistFontSize: CGFloat = 0
    }
}

struct PictureInPictureKaraokeContent: View {
    var line: LyricsLine
    var positionMs: Int64
    var alignment: TextAlignment
    var frameAlignment: Alignment
    var fontSize: CGFloat
    var speakerColors: AppSettings.SpeakerColorSettings
    var useCreatorSpeakerColors: Bool
    var karaokeDataAsLineSynced: Bool
    var syncedLyricsKaraokeAnimationEnabled: Bool
    var bounceEnabled: Bool
    var typography: AppSettings.TypographySettings = .defaults

    var body: some View {
        let visibleParts = displayParts
        Group {
            if visibleParts.isEmpty {
                karaokeText(
                    text: line.text.trimmed.isEmpty ? " " : line.text,
                    rubyText: line.furiganaText,
                    syllables: line.syllables,
                    startTimeMs: line.startTimeMs,
                    endTimeMs: line.endTimeMs,
                    speaker: line.speaker,
                    speakerColor: line.speakerColor,
                    speakerFallback: line.speakerFallback,
                    kind: line.kind,
                    active: true,
                    inactiveDistance: 0
                )
            } else {
                VStack(alignment: horizontalAlignment, spacing: 0) {
                    ForEach(Array(visibleParts.enumerated()), id: \.offset) { index, part in
                        let partActive = positionMs >= part.startTimeMs
                        karaokeText(
                            text: LyricsTimelineDisplayBuilder.vocalPartDisplayText(part),
                            rubyText: part.furiganaText,
                            syllables: part.syllables,
                            startTimeMs: part.startTimeMs,
                            endTimeMs: part.endTimeMs,
                            speaker: part.speaker,
                            speakerColor: part.speakerColor,
                            speakerFallback: part.speakerFallback,
                            kind: part.kind,
                            active: partActive,
                            inactiveDistance: partActive ? 0 : 0.45,
                            effectRowSeed: index
                        )
                        .padding(.top, vocalPartTopSpacing(index: index, parts: visibleParts))
                    }
                }
                .frame(maxWidth: .infinity, alignment: frameAlignment)
            }
        }
        .font(typography.font(slotId: AppSettings.typoLyricsOriginal, baseSize: fontSize))
    }

    private var displayParts: [LyricsLine.VocalPart] {
        LyricsTimelineDisplayBuilder.orderedVocalParts(line.vocalParts)
            .filter { !LyricsTimelineDisplayBuilder.vocalPartDisplayText($0).trimmed.isEmpty }
    }

    private var horizontalAlignment: HorizontalAlignment {
        switch alignment {
        case .center: return .center
        case .trailing: return .trailing
        default: return .leading
        }
    }

    private func vocalPartTopSpacing(index: Int, parts: [LyricsLine.VocalPart]) -> CGFloat {
        guard index > 0, parts.indices.contains(index) else { return 0 }
        return parts[index].furiganaText.contains("<ruby>") ? 8 : 4
    }

    private func karaokeText(
        text: String,
        rubyText: String,
        syllables: [LyricsLine.Syllable],
        startTimeMs: Int64,
        endTimeMs: Int64,
        speaker: String,
        speakerColor: String,
        speakerFallback: String,
        kind: String,
        active: Bool,
        inactiveDistance: Double,
        effectRowSeed: Int = 0
    ) -> some View {
        let timedSyllables = karaokeDataAsLineSynced ? [] : syllables
        let hasTimedSyllables = timedSyllables.contains { $0.endTimeMs > $0.startTimeMs }
        let activeColor = LyricSpeakerPalette.activeColor(
            speaker: speaker,
            speakerColor: speakerColor,
            speakerFallback: speakerFallback,
            settings: speakerColors,
            useCreatorColors: useCreatorSpeakerColors
        )
        let inactiveColor = LyricSpeakerPalette.inactiveColor(
            speaker: speaker,
            speakerColor: speakerColor,
            speakerFallback: speakerFallback,
            settings: speakerColors,
            useCreatorColors: useCreatorSpeakerColors,
            distance: inactiveDistance
        )
        return SyllableKaraokeText(
            text: text,
            rubyText: rubyText,
            syllables: hasTimedSyllables ? timedSyllables : [],
            startTimeMs: startTimeMs,
            endTimeMs: endTimeMs,
            positionMs: positionMs,
            active: active,
            activeColor: activeColor,
            alignment: alignment,
            kind: kind,
            inactiveColor: inactiveColor,
            bounceEnabled: bounceEnabled,
            bounceTextSize: typography.scaledSize(slotId: AppSettings.typoLyricsOriginal, baseSize: fontSize),
            syntheticTimingEnabled: !hasTimedSyllables && syncedLyricsKaraokeAnimationEnabled,
            effectRowSeed: effectRowSeed
        )
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }
}

extension LyricsPictureInPictureController: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor [weak self] in self?.onSetPlaying?(playing) }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        let info = playbackInfo.read()
        return CMTimeRange(start: .zero, duration: CMTime(value: info.durationMs, timescale: 1000))
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        playbackInfo.read().isPaused
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        Task { @MainActor [weak self] in self?.renderFrame() }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        let deltaMs = Int64((CMTimeGetSeconds(skipInterval) * 1000).rounded())
        Task { @MainActor [weak self] in
            self?.onSkip?(deltaMs)
            completionHandler()
        }
    }
}

extension LyricsPictureInPictureController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let reason = self.startReason
            self.active = true
            self.startReason = nil
            self.startRetryTask?.cancel()
            if reason == .automaticTransition {
                self.onLog?("lyrics pip: automatic transition started")
            } else {
                self.onLog?("lyrics pip: started")
            }
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            self?.active = false
            self?.startReason = nil
            if self?.automaticPreparationEnabled != true {
                self?.deactivateAudioSession()
            }
            self?.onLog?("lyrics pip: stopped")
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let reason = self.startReason
            self.active = false
            self.startReason = nil
            self.onEngagementEnded?()
            self.startRetryTask?.cancel()
            if !self.automaticPreparationEnabled {
                self.deactivateAudioSession()
            }
            if reason == .automaticTransition {
                self.onLog?("lyrics pip: automatic transition failed: \(error.localizedDescription)")
            } else {
                self.onLog?("lyrics pip failed: \(error.localizedDescription)")
            }
            if reason == .explicit {
                self.onStartFailure?()
            }
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

struct LyricsPictureInPictureHostView: UIViewRepresentable {
    let controller: LyricsPictureInPictureController

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.onLayout = { controller.layoutHost() }
        controller.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: HostView, context: Context) {
        uiView.onLayout = { controller.layoutHost() }
        controller.attach(to: uiView)
        controller.layoutHost()
    }

    final class HostView: UIView {
        var onLayout: (@MainActor () -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            backgroundColor = .black
            onLayout?()
        }
    }
}

private extension UIColor {
    convenience init?(hexString: String) {
        var value = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt64(value, radix: 16) else { return nil }
        self.init(
            red: CGFloat((number >> 16) & 0xff) / 255,
            green: CGFloat((number >> 8) & 0xff) / 255,
            blue: CGFloat(number & 0xff) / 255,
            alpha: 1
        )
    }
}
