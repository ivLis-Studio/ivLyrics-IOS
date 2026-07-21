import Foundation
import SwiftUI

#if os(iOS)
import UIKit
#endif

struct VinylPlayerModeView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    // Keeps the tonearm and active lyric renderer synchronized with the shared 30 Hz clock.
    @EnvironmentObject private var playbackClock: PlaybackClock
    @Binding var isPresented: Bool

    @State private var displayedTrack: TrackSnapshot?
    @State private var incomingTrack: TrackSnapshot?
    @State private var trackTransitionProgress: CGFloat = 0
    @State private var trackTransitionToken = UUID()
    @State private var entranceProgress: CGFloat = 0
    @State private var playProgress: CGFloat = 0
    @State private var spinBaseDegrees: Double = 0
    @State private var spinOrigin = Date()
    @State private var spinning = false
    @State private var spinToken = UUID()
    @State private var accentColors: [String: Color] = [:]
    @GestureState private var tonearmDragState: VinylTonearmDragState?

    var body: some View {
        GeometryReader { proxy in
            let geometry = VinylSceneGeometry(
                container: proxy.size,
                playProgress: playProgress,
                entranceProgress: entranceProgress
            )
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !spinning)) { timeline in
                scene(
                    geometry: geometry,
                    spinDegrees: spinDegrees(at: timeline.date)
                )
            }

            MainLyricPreviewPanel(chromeless: true)
                .frame(
                    width: max(0, proxy.size.width - (geometry.isLandscape ? 64 : 32)),
                    height: geometry.lyricHeight
                )
                .position(
                    x: proxy.size.width * 0.5,
                    y: proxy.size.height - geometry.lyricBottom - geometry.lyricHeight * 0.5
                )
                .contentShape(Rectangle())
                .zIndex(20)

            if let loadingText = loadingIndicatorText {
                VinylLoadingIndicator(text: loadingText)
                    .padding(.top, max(12, proxy.safeAreaInsets.top + 8))
                    .padding(.leading, geometry.isLandscape ? 24 : 18)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(30)
            }
        }
        .coordinateSpace(name: VinylCoordinateSpace.name)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(settings.t("vinyl.mode"))
        .onAppear(perform: enter)
        .onChange(of: model.currentTrack?.stableKey ?? "") { _, _ in
            synchronizeTrack(animateChange: true)
        }
        .onChange(of: model.currentTrack) { _, _ in
            refreshCurrentTrackAsset()
        }
        .onChange(of: model.currentTrack?.playing == true) { _, playing in
            updatePlaying(playing, animated: true)
        }
        .onDisappear {
            trackTransitionToken = UUID()
            spinToken = UUID()
            freezeSpin(at: Date())
        }
    }

    @ViewBuilder
    private func scene(geometry: VinylSceneGeometry, spinDegrees: Double) -> some View {
        if let displayedTrack {
            let frontRecordProgress = vinylSmoothStep(0.54, 0.76, playProgress)
            ZStack(alignment: .topLeading) {
                disc(
                    track: displayedTrack,
                    frame: geometry.record,
                    rotation: spinDegrees,
                    interactive: incomingTrack == nil
                )
                .zIndex(1)

                cover(
                    track: displayedTrack,
                    frame: geometry.cover,
                    rotation: geometry.coverRotation,
                    closeEnabled: incomingTrack == nil
                )
                .zIndex(2)

                if incomingTrack != nil {
                    incomingLayers(geometry: geometry, spinDegrees: spinDegrees)
                } else if frontRecordProgress > 0 {
                    disc(
                        track: displayedTrack,
                        frame: geometry.record,
                        rotation: spinDegrees,
                        interactive: frontRecordProgress > 0.04
                    )
                    .opacity(frontRecordProgress)
                    .zIndex(3)
                }

                tonearm(geometry: geometry)
                    .opacity(tonearmOpacity)
                    .allowsHitTesting(incomingTrack == nil)
                    .zIndex(8)
            }
            .frame(width: geometry.container.width, height: geometry.container.height)
        }
    }

    @ViewBuilder
    private func incomingLayers(geometry: VinylSceneGeometry, spinDegrees: Double) -> some View {
        if let incomingTrack {
            let coverPhase = vinylSmoothStep(0, 0.46, trackTransitionProgress)
            let recordPhase = vinylSmoothStep(0.36, 0.84, trackTransitionProgress)
            let raisePhase = vinylSmoothStep(0.74, 0.94, trackTransitionProgress)
            let incomingCover = geometry.incomingCover(progress: coverPhase)
            let incomingRecord = geometry.incomingRecord(
                cover: incomingCover,
                progress: recordPhase
            )

            disc(
                track: incomingTrack,
                frame: incomingRecord,
                rotation: spinDegrees,
                interactive: false
            )
            .opacity(1 - raisePhase)
            .zIndex(3)

            cover(
                track: incomingTrack,
                frame: incomingCover,
                rotation: vinylLerp(16, geometry.coverRotation, coverPhase),
                closeEnabled: false
            )
            .zIndex(4)

            disc(
                track: incomingTrack,
                frame: incomingRecord,
                rotation: spinDegrees,
                interactive: false
            )
            .opacity(raisePhase)
            .zIndex(5)
        }
    }

    private func cover(
        track: TrackSnapshot,
        frame: CGRect,
        rotation: Double,
        closeEnabled: Bool
    ) -> some View {
        VinylAlbumCover(track: track)
            .frame(width: frame.width, height: frame.height)
            .rotationEffect(.degrees(rotation))
            .position(x: frame.midX, y: frame.midY)
            .contentShape(RoundedRectangle(cornerRadius: max(4, frame.width * 0.024), style: .continuous))
            .gesture(coverGesture(enabled: closeEnabled))
            .allowsHitTesting(closeEnabled)
            .accessibilityLabel(settings.t("vinyl.close_hint"))
            .accessibilityHint(settings.t("vinyl.tmi_hint"))
            .accessibilityAddTraits(closeEnabled ? .isButton : [])
    }

    private func disc(
        track: TrackSnapshot,
        frame: CGRect,
        rotation: Double,
        interactive: Bool
    ) -> some View {
        VinylDisc(track: track, accent: accentColor(for: track))
            .frame(width: frame.width, height: frame.height)
            .rotationEffect(.degrees(rotation))
            .position(x: frame.midX, y: frame.midY)
            .contentShape(Circle())
            .onTapGesture {
                guard interactive else { return }
                model.togglePlayback()
            }
            .allowsHitTesting(interactive)
            .accessibilityLabel(settings.t("vinyl.record_hint"))
            .accessibilityAddTraits(interactive ? .isButton : [])
    }

    private func coverGesture(enabled: Bool) -> some Gesture {
        LongPressGesture(minimumDuration: 0.52, maximumDistance: 18)
            .exclusively(before: TapGesture())
            .onEnded { result in
                switch result {
                case .first(let completed):
                    guard enabled, completed else { return }
                    performHaptic(.medium)
                    model.showTmiForCurrentTrack(bypassCache: false)
                case .second:
                    if enabled { close() }
                }
            }
    }

    private func tonearm(geometry: VinylSceneGeometry) -> some View {
        let rotation = tonearmDragState?.rotation
            ?? (model.currentTrack?.playing == true
                ? VinylTonearmGeometry.rotation(for: playbackProgress)
                : VinylTonearmGeometry.parkDegrees)
        let points = VinylTonearmGeometry.points(record: geometry.record, rotation: rotation)

        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                VinylTonearmArtwork.draw(
                    context: context,
                    record: geometry.record,
                    rotation: rotation
                )
            }
            .allowsHitTesting(false)

            Color.clear
                .frame(width: 68, height: 68)
                .contentShape(Circle())
                .position(points.head)
                .gesture(tonearmDragGesture(geometry: geometry))
                .accessibilityElement()
                .accessibilityLabel(settings.t("vinyl.tonearm_hint"))
                .accessibilityAdjustableAction { direction in
                    let delta = max(5_000, model.durationMs / 20)
                    switch direction {
                    case .increment:
                        model.seek(toPlaybackPositionMs: min(model.durationMs, model.nowPositionMs + delta))
                    case .decrement:
                        model.seek(toPlaybackPositionMs: max(0, model.nowPositionMs - delta))
                    @unknown default:
                        break
                    }
                }
        }
        .frame(width: geometry.container.width, height: geometry.container.height)
    }

    private func tonearmDragGesture(geometry: VinylSceneGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(VinylCoordinateSpace.name))
            .updating($tonearmDragState) { value, state, _ in
                state = updatedTonearmDragState(
                    location: value.location,
                    startLocation: value.startLocation,
                    record: geometry.record,
                    existing: state
                )
            }
            .onEnded { value in
                let drag = updatedTonearmDragState(
                    location: value.location,
                    startLocation: value.startLocation,
                    record: geometry.record,
                    existing: tonearmDragState
                )
                let moved = hypot(
                    value.location.x - value.startLocation.x,
                    value.location.y - value.startLocation.y
                ) > 18
                let ejected = drag.seeking && (
                    drag.rawRotation <= VinylTonearmGeometry.ejectDegrees
                        || moved && !geometry.record.contains(value.location)
                )
                performHaptic(ejected ? .rigid : .light)
                if ejected {
                    if model.currentTrack?.playing == true {
                        model.togglePlayback()
                    }
                    return
                }
                if drag.seeking {
                    guard model.durationMs > 0 else { return }
                    model.seek(toPlaybackPositionMs: Int64((Double(model.durationMs) * drag.progress).rounded()))
                } else if drag.rotation >= VinylTonearmGeometry.cuePlayDegrees,
                          model.currentTrack?.playing != true {
                    model.togglePlayback()
                }
            }
    }

    private func updatedTonearmDragState(
        location: CGPoint,
        startLocation: CGPoint,
        record: CGRect,
        existing: VinylTonearmDragState?
    ) -> VinylTonearmDragState {
        var next = existing ?? {
            let seeking = model.currentTrack?.playing == true
            let initialRotation = seeking
                ? VinylTonearmGeometry.rotation(for: playbackProgress)
                : VinylTonearmGeometry.parkDegrees
            return VinylTonearmDragState(
                seeking: seeking,
                pointerOffset: initialRotation - VinylTonearmGeometry.pointerAngle(startLocation, record: record),
                rotation: initialRotation,
                rawRotation: initialRotation,
                progress: VinylTonearmGeometry.progress(forRotation: initialRotation)
            )
        }()
        var candidate = VinylTonearmGeometry.pointerAngle(location, record: record) + next.pointerOffset
        while candidate - next.rotation > 180 { candidate -= 360 }
        while candidate - next.rotation < -180 { candidate += 360 }
        next.rawRotation = candidate
        next.rotation = next.seeking
            ? max(VinylTonearmGeometry.parkDegrees, min(VinylTonearmGeometry.endDegrees, candidate))
            : max(VinylTonearmGeometry.parkDegrees, min(VinylTonearmGeometry.startDegrees, candidate))
        next.progress = VinylTonearmGeometry.progress(forRotation: next.rotation)
        return next
    }

    private var playbackProgress: Double {
        guard model.durationMs > 0 else { return 0 }
        return max(0, min(1, Double(model.nowPositionMs) / Double(model.durationMs)))
    }

    private var tonearmOpacity: Double {
        guard incomingTrack != nil else { return 1 }
        let outgoing = 1 - vinylSmoothStep(0.02, 0.20, trackTransitionProgress)
        let incoming = vinylSmoothStep(0.88, 1, trackTransitionProgress)
        return Double(max(outgoing, incoming))
    }

    private var loadingIndicatorText: String? {
        if model.status == .loading || model.lyricsResult.lines.isEmpty && model.lyricsResult.detail.lowercased().contains("loading") {
            return settings.t("status.lyrics_loading")
        }
        if model.lyricsSupplementTranslationLoading {
            return settings.t("loading.translation")
        }
        if model.lyricsSupplementPronunciationLoading || model.lyricsSupplementFuriganaLoading {
            return settings.t("loading.pronunciation")
        }
        return nil
    }

    private func enter() {
        displayedTrack = model.currentTrack
        incomingTrack = nil
        trackTransitionProgress = 0
        entranceProgress = 0
        playProgress = model.currentTrack?.playing == true ? 1 : 0
        spinning = false
        spinOrigin = Date()
        if let displayedTrack {
            loadAccent(for: displayedTrack)
        }
        DispatchQueue.main.async {
            withAnimation(.timingCurve(0.18, 0.82, 0.22, 1, duration: 0.78)) {
                entranceProgress = 1
            }
        }
        updatePlaying(model.currentTrack?.playing == true, animated: false)
    }

    private func synchronizeTrack(animateChange: Bool) {
        guard let next = model.currentTrack, next.hasUsableMetadata else {
            close()
            return
        }
        guard let displayedTrack else {
            self.displayedTrack = next
            return
        }
        if displayedTrack.stableKey == next.stableKey {
            self.displayedTrack = next
            return
        }
        guard animateChange else {
            self.displayedTrack = next
            incomingTrack = nil
            return
        }

        let token = UUID()
        trackTransitionToken = token
        incomingTrack = next
        loadAccent(for: next)
        trackTransitionProgress = 0
        DispatchQueue.main.async {
            withAnimation(.timingCurve(0.16, 0.76, 0.20, 1, duration: 1.48)) {
                trackTransitionProgress = 1
            }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_520_000_000)
            guard trackTransitionToken == token else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                self.displayedTrack = incomingTrack ?? next
                incomingTrack = nil
                trackTransitionProgress = 0
            }
        }
    }

    private func refreshCurrentTrackAsset() {
        guard let current = model.currentTrack else { return }
        if incomingTrack?.stableKey == current.stableKey {
            incomingTrack = current
        } else if displayedTrack?.stableKey == current.stableKey {
            displayedTrack = current
        }
        loadAccent(for: current)
    }

    private func accentColor(for track: TrackSnapshot) -> Color {
        accentColors[track.stableKey] ?? VinylArtworkAccent.fallbackColor(key: track.stableKey)
    }

    private func loadAccent(for track: TrackSnapshot) {
        let key = track.stableKey
        let assetKey = key + "|" + (track.artworkURL?.absoluteString ?? "")
        Task { @MainActor in
            let color = await VinylArtworkAccent.color(for: track)
            guard !Task.isCancelled else { return }
            let currentAssetKeys = [displayedTrack, incomingTrack]
                .compactMap { candidate -> String? in
                    guard let candidate else { return nil }
                    return candidate.stableKey + "|" + (candidate.artworkURL?.absoluteString ?? "")
                }
            guard currentAssetKeys.contains(assetKey) else { return }
            accentColors[key] = color
        }
    }

    private func updatePlaying(_ playing: Bool, animated: Bool) {
        let token = UUID()
        spinToken = token
        if playing {
            let animation = Animation.timingCurve(0.18, 0.76, 0.22, 1, duration: animated ? 1.08 : 0.01)
            withAnimation(animation) {
                playProgress = 1
            }
            let delay = animated ? 0.86 : 0.66
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard spinToken == token, model.currentTrack?.playing == true else { return }
                spinOrigin = Date()
                spinning = true
            }
        } else {
            freezeSpin(at: Date())
            spinning = false
            withAnimation(.timingCurve(0.28, 0, 0.34, 1, duration: animated ? 0.88 : 0.01)) {
                playProgress = 0
            }
        }
    }

    private func spinDegrees(at date: Date) -> Double {
        guard spinning else { return spinBaseDegrees }
        return (spinBaseDegrees + max(0, date.timeIntervalSince(spinOrigin)) * 9).truncatingRemainder(dividingBy: 360)
    }

    private func freezeSpin(at date: Date) {
        spinBaseDegrees = spinDegrees(at: date)
        spinOrigin = date
    }

    private func close() {
        guard isPresented else { return }
        performHaptic(.soft)
        withAnimation(.timingCurve(0.22, 0.74, 0.28, 1, duration: 0.36)) {
            isPresented = false
        }
    }

    private func performHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
#if os(iOS)
        UIImpactFeedbackGenerator(style: style).impactOccurred()
#endif
    }
}

private struct VinylAlbumCover: View {
    let track: TrackSnapshot

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.96, green: 0.19, blue: 0.52), Color(red: 0.30, green: 0.10, blue: 0.46)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                if let url = track.artworkURL {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: max(4, proxy.size.width * 0.024), style: .continuous))
            .shadow(color: .black.opacity(0.26), radius: max(7, proxy.size.width * 0.045), y: 5)
        }
    }
}

private struct VinylDisc: View {
    let track: TrackSnapshot
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: [Color(white: 0.14), Color(white: 0.035), Color(white: 0.10)],
                        center: UnitPoint(x: 0.36, y: 0.30),
                        startRadius: 0,
                        endRadius: size * 0.52
                    ))
                    .shadow(color: .black.opacity(0.34), radius: size * 0.045, y: size * 0.018)

                Canvas { context, canvasSize in
                    let center = CGPoint(x: canvasSize.width * 0.5, y: canvasSize.height * 0.5)
                    for index in 0..<34 {
                        let inset = size * (0.035 + CGFloat(index) * 0.0113)
                        let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
                        context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(index.isMultiple(of: 4) ? 0.055 : 0.020)), lineWidth: max(0.55, size * 0.0019))
                    }
                    var glint = Path()
                    glint.addArc(center: center, radius: size * 0.43, startAngle: .degrees(208), endAngle: .degrees(316), clockwise: false)
                    context.stroke(glint, with: .linearGradient(
                        Gradient(colors: [.clear, .white.opacity(0.11), .clear]),
                        startPoint: CGPoint(x: size * 0.18, y: size * 0.72),
                        endPoint: CGPoint(x: size * 0.82, y: size * 0.18)
                    ), lineWidth: size * 0.018)
                }

                Circle()
                    .fill(RadialGradient(
                        colors: [Color(red: 0.188, green: 0.149, blue: 0.165), Color(red: 0.129, green: 0.098, blue: 0.110)],
                        center: UnitPoint(x: 0.5, y: 0.45),
                        startRadius: 0,
                        endRadius: size * 0.224
                    ))
                    .frame(width: size * 0.447, height: size * 0.447)
                Circle()
                    .stroke(accent, lineWidth: max(1, size * 0.004))
                    .frame(width: size * 0.441, height: size * 0.441)
                Circle()
                    .stroke(accent.opacity(0.52), lineWidth: max(0.7, size * 0.0022))
                    .frame(width: size * 0.376, height: size * 0.376)

                VinylCircularText(
                    text: circularLabel,
                    radius: size * 0.162,
                    upper: true,
                    color: accent.opacity(0.78),
                    fontSize: max(5.5, size * 0.0168)
                )
                VinylCircularText(
                    text: circularLabel,
                    radius: size * 0.162,
                    upper: false,
                    color: accent.opacity(0.70),
                    fontSize: max(5.5, size * 0.0168)
                )

                Text(track.title)
                    .font(.pretendard(max(10, size * 0.0455), weight: .bold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.54)
                    .frame(width: size * 0.35)
                    .position(x: size * 0.5, y: size * 0.442)
                Text(track.artist)
                    .font(.pretendard(max(7, size * 0.0245), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .frame(width: size * 0.35)
                    .position(x: size * 0.5, y: size * 0.567)

                Circle()
                    .fill(Color(white: 0.82))
                    .frame(width: max(4, size * 0.0188), height: max(4, size * 0.0188))
            }
        }
    }

    private var circularLabel: String {
        let source = track.album.trimmed.isEmpty ? "\(track.title) · \(track.artist)" : track.album
        return String(source.prefix(34)).uppercased()
    }
}

private struct VinylCircularText: View {
    let text: String
    let radius: CGFloat
    let upper: Bool
    let color: Color
    let fontSize: CGFloat

    var body: some View {
        let characters = Array(text)
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width * 0.5, y: proxy.size.height * 0.5)
            ForEach(Array(characters.enumerated()), id: \.offset) { index, character in
                let fraction = characters.count <= 1 ? 0.5 : Double(index) / Double(characters.count - 1)
                let angle = upper
                    ? vinylLerp(-156, -24, fraction)
                    : vinylLerp(156, 24, fraction)
                let radians = angle * .pi / 180
                Text(String(character))
                    .font(.pretendard(fontSize, weight: .semibold))
                    .foregroundStyle(color)
                    .rotationEffect(.degrees(angle + (upper ? 90 : -90)))
                    .position(
                        x: center.x + CGFloat(cos(radians)) * radius,
                        y: center.y + CGFloat(sin(radians)) * radius
                    )
            }
        }
        .allowsHitTesting(false)
    }
}

private struct VinylLoadingIndicator: View {
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
        .foregroundStyle(.white.opacity(0.90))
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(.black.opacity(0.24), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.08)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct VinylSceneGeometry {
    let container: CGSize
    let cover: CGRect
    let record: CGRect
    let coverRotation: Double
    let lyricHeight: CGFloat
    let lyricBottom: CGFloat
    let isLandscape: Bool

    init(container: CGSize, playProgress: CGFloat, entranceProgress: CGFloat) {
        self.container = container
        isLandscape = container.width > container.height
        lyricHeight = isLandscape ? 102 : 136
        lyricBottom = isLandscape ? 8 : 14
        let lyricReserve = lyricHeight + lyricBottom + (isLandscape ? 14 : 22)
        let availableHeight = max(220, container.height - lyricReserve)
        let rawSize = isLandscape
            ? min(container.width * 0.31, availableHeight * 0.74)
            : min(container.width * 0.72, availableHeight * 0.48)
        let size = max(isLandscape ? 150 : 184, min(rawSize, availableHeight * 0.78))
        let entrance = vinylSmoothStep(0, 1, entranceProgress)
        let entryOffset = (1 - entrance) * (isLandscape ? 34 : 50)

        if isLandscape {
            let centerY = availableHeight * 0.49 + entryOffset
            let pausedCoverX = container.width * 0.50 - size * 0.701
            let playingCoverX = container.width * 0.50 - size * 0.91
            let coverX = vinylLerp(pausedCoverX, playingCoverX, playProgress)
            let pausedRecordX = pausedCoverX + size * 0.402
            let playingRecordX = playingCoverX + size * 0.82
            let recordX = vinylLerp(pausedRecordX, playingRecordX, playProgress)
            cover = CGRect(x: coverX, y: centerY - size * 0.5, width: size, height: size)
            record = CGRect(x: recordX, y: centerY - size * 0.5, width: size, height: size)
        } else {
            let centerX = container.width * 0.5
            let pausedCoverY = max(34, availableHeight * 0.10) + entryOffset
            let playingCoverY = max(26, availableHeight * 0.065) + entryOffset
            let coverSize = vinylLerp(size, size * 0.78, playProgress)
            let coverCenterX = vinylLerp(centerX, centerX + size * 0.03, playProgress)
            let coverCenterY = vinylLerp(
                pausedCoverY + size * 0.50,
                playingCoverY + size * 0.49,
                playProgress
            )
            let recordX = centerX - size * 0.5
            let recordY = vinylLerp(pausedCoverY + size * 0.40, playingCoverY + size * 0.58, playProgress)
            cover = CGRect(
                x: coverCenterX - coverSize * 0.5,
                y: coverCenterY - coverSize * 0.5,
                width: coverSize,
                height: coverSize
            )
            record = CGRect(x: recordX, y: recordY, width: size, height: size)
        }
        let playingCoverRotation = isLandscape ? -5.0 : -3.0
        coverRotation = vinylLerp(0, playingCoverRotation, vinylSmoothStep(0.28, 1, playProgress))
            + vinylLerp(-2, 0, entrance)
    }

    func incomingCover(progress: CGFloat) -> CGRect {
        let start = CGRect(
            x: container.width + cover.width * 0.18,
            y: -cover.height * (isLandscape ? 0.26 : 0.10),
            width: cover.width,
            height: cover.height
        )
        return vinylInterpolate(start, cover, progress)
    }

    func incomingRecord(cover incomingCover: CGRect, progress: CGFloat) -> CGRect {
        vinylInterpolate(incomingCover, record, progress)
    }
}

private struct VinylTonearmDragState {
    let seeking: Bool
    let pointerOffset: Double
    var rotation: Double
    var rawRotation: Double
    var progress: Double
}

private enum VinylTonearmGeometry {
    // Desktop VinylPlayerMode.js rotates its 260 x 620 SVG by these values.
    static let startDegrees = -5.4
    static let endDegrees = 18.0
    static let parkDegrees = -14.0
    static let ejectDegrees = -8.2
    static let cuePlayDegrees = -7.2
    static let viewBoxHeight: CGFloat = 620
    static let pivotSVG = CGPoint(x: 183, y: 64)
    static let headSVG = CGPoint(x: 46, y: 524)

    struct Points {
        let pivot: CGPoint
        let head: CGPoint
        let radius: CGFloat
        let scale: CGFloat
    }

    static func rotation(for progress: Double) -> Double {
        vinylLerp(startDegrees, endDegrees, max(0, min(1, progress)))
    }

    static func progress(forRotation rotation: Double) -> Double {
        max(0, min(1, (rotation - startDegrees) / (endDegrees - startDegrees)))
    }

    static func points(record: CGRect, rotation: Double) -> Points {
        let scale = record.width / viewBoxHeight
        let pivot = CGPoint(
            x: record.minX + record.width * 0.8766,
            y: record.minY + record.height * 0.1032
        )
        return Points(
            pivot: pivot,
            head: point(headSVG, record: record, rotation: rotation),
            radius: record.width * 0.5,
            scale: scale
        )
    }

    static func point(_ svgPoint: CGPoint, record: CGRect, rotation: Double) -> CGPoint {
        let scale = record.width / viewBoxHeight
        let pivot = CGPoint(
            x: record.minX + record.width * 0.8766,
            y: record.minY + record.height * 0.1032
        )
        let localX = (svgPoint.x - pivotSVG.x) * scale
        let localY = (svgPoint.y - pivotSVG.y) * scale
        let radians = rotation * .pi / 180
        return CGPoint(
            x: pivot.x + localX * CGFloat(cos(radians)) - localY * CGFloat(sin(radians)),
            y: pivot.y + localX * CGFloat(sin(radians)) + localY * CGFloat(cos(radians))
        )
    }

    static func pointerAngle(_ location: CGPoint, record: CGRect) -> Double {
        let pivot = points(record: record, rotation: 0).pivot
        var degrees = atan2(location.y - pivot.y, location.x - pivot.x) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }
}

private enum VinylTonearmArtwork {
    static func draw(context: GraphicsContext, record: CGRect, rotation: Double) {
        let points = VinylTonearmGeometry.points(record: record, rotation: rotation)
        let scale = points.scale

        var base = Path()
        base.addEllipse(in: CGRect(
            x: points.pivot.x - 66 * scale,
            y: points.pivot.y - 66 * scale,
            width: 132 * scale,
            height: 132 * scale
        ))
        context.fill(
            base,
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: .white.opacity(0.88), location: 0),
                    .init(color: Color(white: 0.985).opacity(0.62), location: 0.58),
                    .init(color: Color(white: 0.933).opacity(0.34), location: 1)
                ]),
                center: VinylTonearmGeometry.point(CGPoint(x: 172, y: 43), record: record, rotation: 0),
                startRadius: 0,
                endRadius: 95 * scale
            )
        )
        let baseShadow = base.applying(CGAffineTransform(translationX: 0, y: 2 * scale))
        context.stroke(baseShadow, with: .color(.black.opacity(0.14)), lineWidth: 3 * scale)
        context.stroke(base, with: .color(Color(white: 0.86).opacity(0.62)), lineWidth: 2 * scale)

        var arm = Path()
        arm.move(to: p(189, 75, record, rotation))
        arm.addCurve(
            to: p(78, 474, record, rotation),
            control1: p(184, 172, record, rotation),
            control2: p(151, 330, record, rotation)
        )
        arm.addLine(to: p(58, 513, record, rotation))
        context.stroke(
            arm,
            with: .color(.black.opacity(0.32)),
            style: StrokeStyle(lineWidth: 17 * scale, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            arm,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(white: 0.667), location: 0),
                    .init(color: Color(white: 0.98), location: 0.24),
                    .init(color: .white, location: 0.55),
                    .init(color: Color(white: 0.733), location: 1)
                ]),
                startPoint: p(28, 280, record, rotation),
                endPoint: p(210, 280, record, rotation)
            ),
            style: StrokeStyle(lineWidth: 14 * scale, lineCap: .round, lineJoin: .round)
        )

        var armHighlight = Path()
        armHighlight.move(to: p(184, 79, record, rotation))
        armHighlight.addCurve(
            to: p(74, 469, record, rotation),
            control1: p(178, 179, record, rotation),
            control2: p(145, 330, record, rotation)
        )
        context.stroke(
            armHighlight,
            with: .color(.white.opacity(0.94)),
            style: StrokeStyle(lineWidth: 3 * scale, lineCap: .round)
        )

        let pivotHousing = polygon([
            (151, 35), (200, 39), (215, 66), (207, 109),
            (170, 111), (151, 91), (144, 61)
        ], record: record, rotation: rotation)
        drawHousing(pivotHousing, context: context, scale: scale)

        var pivotHighlight = Path()
        pivotHighlight.move(to: p(158, 42, record, rotation))
        pivotHighlight.addLine(to: p(194, 45, record, rotation))
        pivotHighlight.addLine(to: p(207, 65, record, rotation))
        pivotHighlight.addLine(to: p(202, 91, record, rotation))
        context.stroke(
            pivotHighlight,
            with: .color(.white.opacity(0.95)),
            style: StrokeStyle(lineWidth: 4 * scale, lineCap: .round, lineJoin: .round)
        )

        let headshell = polygon([
            (47, 490), (75, 508), (54, 546), (30, 540),
            (17, 522), (24, 506)
        ], record: record, rotation: rotation)
        drawHousing(headshell, context: context, scale: scale)

        var headHighlight = Path()
        headHighlight.move(to: p(28, 509, record, rotation))
        headHighlight.addLine(to: p(66, 517, record, rotation))
        headHighlight.addLine(to: p(49, 539, record, rotation))
        context.stroke(
            headHighlight,
            with: .color(.white.opacity(0.95)),
            style: StrokeStyle(lineWidth: 4 * scale, lineCap: .round, lineJoin: .round)
        )

        var needle = Path()
        needle.move(to: p(35, 539, record, rotation))
        needle.addLine(to: p(33, 555, record, rotation))
        needle.move(to: p(48, 542, record, rotation))
        needle.addLine(to: p(53, 557, record, rotation))
        context.stroke(
            needle,
            with: .color(Color(white: 0.933)),
            style: StrokeStyle(lineWidth: 5 * scale, lineCap: .square)
        )
    }

    private static func drawHousing(_ path: Path, context: GraphicsContext, scale: CGFloat) {
        let shadow = path.applying(CGAffineTransform(translationX: 2 * scale, y: 5 * scale))
        context.fill(shadow, with: .color(.black.opacity(0.18)))
        context.fill(path, with: .color(Color(white: 0.988).opacity(0.97)))
        context.stroke(path, with: .color(Color(white: 0.90).opacity(0.80)), lineWidth: scale)
    }

    private static func polygon(
        _ values: [(CGFloat, CGFloat)],
        record: CGRect,
        rotation: Double
    ) -> Path {
        var path = Path()
        guard let first = values.first else { return path }
        path.move(to: p(first.0, first.1, record, rotation))
        for value in values.dropFirst() {
            path.addLine(to: p(value.0, value.1, record, rotation))
        }
        path.closeSubpath()
        return path
    }

    private static func p(_ x: CGFloat, _ y: CGFloat, _ record: CGRect, _ rotation: Double) -> CGPoint {
        VinylTonearmGeometry.point(CGPoint(x: x, y: y), record: record, rotation: rotation)
    }
}

private enum VinylArtworkAccent {
    static func color(for track: TrackSnapshot) async -> Color {
        let fallback = fallbackColor(key: track.stableKey)
        guard let url = track.artworkURL,
              let (data, _) = try? await URLSession.shared.data(from: url),
              !Task.isCancelled,
              let image = UIImage(data: data),
              let sampled = averageColor(image) else {
            return fallback
        }
        return Color(uiColor: sampled)
    }

    static func fallbackColor(key: String) -> Color {
        let hash = key.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        let hue = CGFloat(abs(hash % 360)) / 360
        return Color(hue: hue, saturation: 0.62, brightness: 1)
    }

    private static func averageColor(_ image: UIImage) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        guard let context = CGContext(
            data: &pixels,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 16 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 16, height: 16))

        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var count = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255
            let maximum = max(r, g, b)
            let minimum = min(r, g, b)
            guard maximum > 0.14, maximum - minimum > 0.045 else { continue }
            red += r
            green += g
            blue += b
            count += 1
        }
        guard count > 0 else { return nil }
        let source = UIColor(red: red / count, green: green / count, blue: blue / count, alpha: 1)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        guard source.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil) else {
            return source
        }
        return UIColor(
            hue: hue,
            saturation: max(0.46, min(0.82, saturation)),
            brightness: max(0.78, min(1, brightness)),
            alpha: 1
        )
    }
}

private enum VinylCoordinateSpace {
    static let name = "ivlyrics.vinyl.mode"
}

private func vinylSmoothStep<T: BinaryFloatingPoint>(_ start: T, _ end: T, _ value: T) -> T {
    guard end > start else { return value >= end ? 1 : 0 }
    let progress = max(0, min(1, (value - start) / (end - start)))
    return progress * progress * (3 - 2 * progress)
}

private func vinylLerp<T: BinaryFloatingPoint>(_ start: T, _ end: T, _ progress: T) -> T {
    start + (end - start) * max(0, min(1, progress))
}

private func vinylInterpolate(_ start: CGRect, _ end: CGRect, _ progress: CGFloat) -> CGRect {
    CGRect(
        x: vinylLerp(start.minX, end.minX, progress),
        y: vinylLerp(start.minY, end.minY, progress),
        width: vinylLerp(start.width, end.width, progress),
        height: vinylLerp(start.height, end.height, progress)
    )
}
