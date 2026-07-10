import AVFoundation
import AVKit
import Combine
import CoreMedia
import CoreVideo
import SwiftUI
import UIKit

@MainActor
final class LyricsPictureInPictureController: NSObject, ObservableObject {
    @Published private(set) var active = false

    var needsStateUpdates: Bool { active || startRequested }

    var onSetPlaying: ((Bool) -> Void)?
    var onSkip: ((Int64) -> Void)?
    var onLog: ((String) -> Void)?
    var onStartFailure: (() -> Void)?

    private let displayLayer = AVSampleBufferDisplayLayer()
    private var pictureInPictureController: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private weak var hostView: UIView?
    private var state = RenderState.empty
    private var artwork: UIImage?
    private var artworkURL: URL?
    private var artworkTask: Task<Void, Never>?
    private var startRetryTask: Task<Void, Never>?
    private var startRequested = false
    private var lastRenderUptime: TimeInterval = 0
    private var audioSessionActive = false

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.requiresLinearPlayback = false
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            Task { @MainActor [weak self] in
                guard let self, self.startRequested, controller.isPictureInPicturePossible else { return }
                self.startIfPossible()
            }
        }
        pictureInPictureController = controller
    }

    deinit {
        artworkTask?.cancel()
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
        settings: AppSettings.Snapshot
    ) {
        let nextState = RenderState(
            track: track,
            lines: lyrics.lines,
            positionMs: positionMs,
            title: title,
            artist: artist,
            showArtwork: settings.pipShowArtwork,
            orientation: settings.pipOrientation,
            alignment: settings.pipLyricsTextAlignment,
            lyricsSizePercent: settings.pipLyricsSizePercent,
            solidColor: settings.backgroundSolidColor,
            syncedLyricsKaraokeAnimationEnabled: settings.syncedLyricsKaraokeAnimationEnabled,
            karaokeBounceEffectEnabled: settings.karaokeBounceEffectEnabled,
            karaokeDataAsLineSynced: settings.karaokeDataAsLineSynced,
            useSyncCreatorSpeakerColors: settings.useSyncCreatorSpeakerColors,
            typography: settings.typography,
            speakerColors: settings.speakerColors
        )
        let forceRender = nextState.renderIdentity != state.renderIdentity
        state = nextState
        loadArtworkIfNeeded(track?.artworkURL)
        guard active || startRequested else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        if forceRender || uptime - lastRenderUptime >= (1.0 / 30.0) {
            renderFrame()
        }
    }

    @discardableResult
    func start() -> Bool {
        guard AVPictureInPictureController.isPictureInPictureSupported(), pictureInPictureController != nil else {
            onLog?("lyrics pip: system Picture in Picture is not supported")
            return false
        }
        guard activateAudioSession() else { return false }
        startRequested = true
        renderFrame()
        startIfPossible()
        guard !active else { return true }
        startRetryTask?.cancel()
        startRetryTask = Task { @MainActor [weak self] in
            for delay in [100_000_000, 300_000_000, 700_000_000] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay)
                guard let self, !Task.isCancelled, self.startRequested, !self.active else { return }
                self.renderFrame()
                self.startIfPossible()
            }
            guard let self, self.startRequested, !self.active else { return }
            self.startRequested = false
            self.deactivateAudioSession()
            self.onLog?("lyrics pip: Picture in Picture is not currently available")
            self.onStartFailure?()
        }
        return true
    }

    func stop() {
        startRequested = false
        startRetryTask?.cancel()
        if pictureInPictureController?.isPictureInPictureActive == true {
            pictureInPictureController?.stopPictureInPicture()
        } else {
            deactivateAudioSession()
        }
    }

    private func startIfPossible() {
        guard startRequested,
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
        artworkTask?.cancel()
        guard let url else { return }
        artworkTask = Task { @MainActor [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let image = UIImage(data: data) else { return }
                self?.artwork = image
                if self?.active == true || self?.startRequested == true {
                    self?.renderFrame()
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.onLog?("lyrics pip artwork failed: \(error.localizedDescription)")
            }
        }
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
    }

#if DEBUG
    func debugFrameImage(orientation: String, showArtwork: Bool) -> UIImage {
        let previousState = state
        let previousArtwork = artwork
        defer {
            state = previousState
            artwork = previousArtwork
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
        state.showArtwork = showArtwork
        state.orientation = orientation
        state.alignment = "center"
        state.lyricsSizePercent = 150
        artwork = nil

        let size = state.renderSize
        return UIGraphicsImageRenderer(size: size).image { context in
            drawFrame(in: CGRect(origin: .zero, size: size), context: context.cgContext)
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
        if let artwork {
            drawAspectFill(artwork, in: rect, context: context)
            UIColor.black.withAlphaComponent(0.72).setFill()
            UIRectFill(rect)
        } else {
            let base = UIColor(hexString: state.solidColor) ?? UIColor(red: 0.06, green: 0.08, blue: 0.12, alpha: 1)
            let colors = [
                base.withAlphaComponent(1).cgColor,
                UIColor(red: 0.08, green: 0.09, blue: 0.14, alpha: 1).cgColor,
                UIColor.black.cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.58, 1]) {
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
            }
        }
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
            let fontSize = max(18, lyricRect.width * 0.055)
            let labelRect = CGRect(
                x: lyricRect.minX,
                y: lyricRect.midY - fontSize * 0.8,
                width: lyricRect.width,
                height: fontSize * 1.6
            )
            drawText(
                "ivLyrics",
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
        let supplementSize = max(10, primarySize * 0.48)
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
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        return status == kCVReturnSuccess ? pixelBuffer : nil
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
        context.translateBy(x: 0, y: CGFloat(CVPixelBufferGetHeight(pixelBuffer)))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)))
    }

    private func makeSampleBuffer(pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
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
        var showArtwork: Bool
        var orientation: String
        var alignment: String
        var lyricsSizePercent: Int
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
            showArtwork: true,
            orientation: AppSettings.pipOrientationSquare,
            alignment: "center",
            lyricsSizePercent: 150,
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
                String(showArtwork),
                orientation,
                alignment,
                String(lyricsSizePercent),
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
        Group {
            if displayParts.isEmpty {
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
                VStack(alignment: horizontalAlignment, spacing: 3) {
                    ForEach(Array(displayParts.enumerated()), id: \.offset) { index, part in
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
        MainActor.assumeIsolated {
            let durationMs = max(1, state.track?.durationMs ?? 0)
            return CMTimeRange(start: .zero, duration: CMTime(value: durationMs, timescale: 1000))
        }
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        MainActor.assumeIsolated { !(state.track?.playing ?? false) }
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
            self?.active = true
            self?.startRequested = false
            self?.startRetryTask?.cancel()
            self?.onLog?("lyrics pip: started")
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            self?.active = false
            self?.startRequested = false
            self?.deactivateAudioSession()
            self?.onLog?("lyrics pip: stopped")
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.active = false
            self?.startRequested = false
            self?.deactivateAudioSession()
            self?.onLog?("lyrics pip failed: \(error.localizedDescription)")
            self?.onStartFailure?()
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
        controller.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: HostView, context: Context) {
        controller.attach(to: uiView)
        controller.layoutHost()
    }

    final class HostView: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            backgroundColor = .black
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
