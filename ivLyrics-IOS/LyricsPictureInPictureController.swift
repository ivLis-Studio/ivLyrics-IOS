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
            speakerColors: settings.speakerColors
        )
        let forceRender = nextState.renderIdentity != state.renderIdentity
        state = nextState
        loadArtworkIfNeeded(track?.artworkURL)
        guard active || startRequested else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        if forceRender || uptime - lastRenderUptime >= 0.1 {
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

    private func drawFrame(in rect: CGRect, context: CGContext) {
        drawBackground(in: rect, context: context)
        let padding = max(16, rect.width * 0.045)
        let artworkFrame = artworkRect(in: rect, padding: padding)
        if let artwork, !artworkFrame.isEmpty {
            drawArtwork(artwork, in: artworkFrame, cornerRadius: max(10, artworkFrame.width * 0.07), context: context)
        }
        let contentRect = textRect(in: rect, artworkFrame: artworkFrame, padding: padding)
        drawMetadata(in: contentRect)
        drawLyrics(in: contentRect)
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

    private func drawMetadata(in rect: CGRect) {
        let titleSize = max(14, min(27, rect.width * 0.052))
        let artistSize = max(11, titleSize * 0.66)
        let titleRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: titleSize * 1.35)
        drawText(
            state.title.isEmpty ? "ivLyrics" : state.title,
            in: titleRect,
            font: .systemFont(ofSize: titleSize, weight: .bold),
            color: .white,
            alignment: .left,
            lineLimit: 1
        )
        let artistRect = CGRect(x: rect.minX, y: titleRect.maxY + 1, width: rect.width, height: artistSize * 1.4)
        drawText(
            state.artist,
            in: artistRect,
            font: .systemFont(ofSize: artistSize, weight: .medium),
            color: UIColor.white.withAlphaComponent(0.72),
            alignment: .left,
            lineLimit: 1
        )
    }

    private func drawLyrics(in rect: CGRect) {
        let metadataHeight = max(48, min(76, rect.height * 0.25))
        let lyricRect = CGRect(x: rect.minX, y: rect.minY + metadataHeight, width: rect.width, height: max(0, rect.height - metadataHeight))
        guard let active = state.activeLine else {
            drawText(
                "ivLyrics",
                in: lyricRect,
                font: .systemFont(ofSize: max(18, lyricRect.width * 0.055), weight: .semibold),
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
        let visiblePartCount = active.line.vocalParts.reduce(0) { count, part in
            LyricsTimelineDisplayBuilder.vocalPartDisplayText(part).trimmed.isEmpty ? count : count + 1
        }
        let stackMultiplier = 2.45 + CGFloat(max(0, min(3, visiblePartCount - 1))) * 1.35
        let primaryHeight = min(lyricRect.height * 0.74, primarySize * stackMultiplier)
        let centeredPrimaryY = rect.midY - primaryHeight / 2
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
                font: .systemFont(ofSize: supplementSize, weight: .medium),
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
                font: .systemFont(ofSize: nextSize, weight: .semibold),
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
        lineLimit: Int
    ) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return }
        let attributes = textAttributes(font: font, color: color, alignment: alignment, lineLimit: lineLimit)
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

    private func artworkRect(in rect: CGRect, padding: CGFloat) -> CGRect {
        guard state.showArtwork, artwork != nil else { return .zero }
        switch state.orientation {
        case AppSettings.pipOrientationPortrait:
            let side = min(rect.width - padding * 2, rect.height * 0.34)
            return CGRect(x: rect.midX - side / 2, y: padding, width: side, height: side)
        case AppSettings.pipOrientationSquare:
            let side = min(rect.width * 0.28, rect.height * 0.28)
            return CGRect(x: padding, y: padding, width: side, height: side)
        default:
            let side = min(rect.height - padding * 2, rect.width * 0.30)
            return CGRect(x: padding, y: padding, width: side, height: side)
        }
    }

    private func textRect(in rect: CGRect, artworkFrame: CGRect, padding: CGFloat) -> CGRect {
        guard !artworkFrame.isEmpty else { return rect.insetBy(dx: padding, dy: padding) }
        switch state.orientation {
        case AppSettings.pipOrientationPortrait:
            let top = artworkFrame.maxY + padding * 0.75
            return CGRect(x: padding, y: top, width: rect.width - padding * 2, height: max(0, rect.maxY - padding - top))
        default:
            let left = artworkFrame.maxX + padding
            return CGRect(x: left, y: padding, width: max(0, rect.maxX - padding - left), height: rect.height - padding * 2)
        }
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
            duration: CMTime(value: 1, timescale: 10),
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
                String(speakerColors.hashValue)
            ].joined(separator: "|")
        }
    }

    private struct ActiveLine {
        var line: LyricsLine
        var index: Int
        var progress: CGFloat

        var supplementLines: [String] {
            [line.furiganaText, line.pronunciationText, line.translationText]
                .map(\.trimmed)
                .filter { !$0.isEmpty }
        }
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

    var body: some View {
        Group {
            if displayParts.isEmpty {
                karaokeText(
                    text: line.text.trimmed.isEmpty ? " " : line.text,
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
                    ForEach(Array(displayParts.enumerated()), id: \.offset) { _, part in
                        let partActive = positionMs >= part.startTimeMs
                        karaokeText(
                            text: LyricsTimelineDisplayBuilder.vocalPartDisplayText(part),
                            syllables: part.syllables,
                            startTimeMs: part.startTimeMs,
                            endTimeMs: part.endTimeMs,
                            speaker: part.speaker,
                            speakerColor: part.speakerColor,
                            speakerFallback: part.speakerFallback,
                            kind: part.kind,
                            active: partActive,
                            inactiveDistance: partActive ? 0 : 0.45
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: frameAlignment)
            }
        }
        .font(.system(size: fontSize, weight: .bold))
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
        syllables: [LyricsLine.Syllable],
        startTimeMs: Int64,
        endTimeMs: Int64,
        speaker: String,
        speakerColor: String,
        speakerFallback: String,
        kind: String,
        active: Bool,
        inactiveDistance: Double
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
            bounceTextSize: fontSize,
            syntheticTimingEnabled: !hasTimedSyllables && syncedLyricsKaraokeAnimationEnabled
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
