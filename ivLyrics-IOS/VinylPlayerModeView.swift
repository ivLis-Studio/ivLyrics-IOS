import Foundation
import SwiftUI

#if os(iOS)
import UIKit
#endif

struct VinylPlayerModeView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    // Keeps the tonearm and active lyric renderer synchronized with the shared playback clock.
    @EnvironmentObject private var playbackClock: PlaybackClock
    @Binding var isPresented: Bool

    @State private var displayedTrack: TrackSnapshot?
    @State private var incomingTrack: TrackSnapshot?
    @State private var trackTransitionProgress: CGFloat = 0
    @State private var outgoingRecordBehindSleeve = false
    @State private var trackTransitionToken = UUID()
    @State private var entranceProgress: CGFloat = 0
    @State private var playProgress: CGFloat = 0
    @State private var tonearmEngagement: CGFloat = 0
    @State private var playbackSequenceToken = UUID()
    @State private var spinBaseDegrees: Double = 0
    @State private var spinOrigin = Date()
    @State private var spinning = false
    @State private var spinToken = UUID()
    @State private var accentColors: [String: Color] = [:]
    @State private var artworkImages: [String: UIImage] = [:]
    @GestureState private var tonearmDragState: VinylTonearmDragState?

    var body: some View {
        GeometryReader { proxy in
            let geometry = VinylSceneGeometry(
                container: proxy.size,
                playProgress: playProgress,
                entranceProgress: entranceProgress,
                albumScale: CGFloat(AppSettings.clampVinylSizePercent(settings.vinylAlbumSizePercent)) / 100,
                recordScale: CGFloat(AppSettings.clampVinylSizePercent(settings.vinylRecordSizePercent)) / 100,
                lyricsVisible: settings.vinylLyricsEnabled,
                culturalAnnotationsVisible: settings.culturalAnnotationsEnabled
            )
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !spinning || !settings.vinylAnimationsEnabled)) { timeline in
                scene(
                    geometry: geometry,
                    spinDegrees: spinDegrees(at: timeline.date)
                )
            }

            if settings.vinylLyricsEnabled {
                MainLyricPreviewPanel(
                    chromeless: true,
                    typographyOverride: settings.typographySettings().forVinylPreview,
                    showsCulturalAnnotations: true
                )
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
            }

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
        .onChange(of: settings.vinylAnimationsEnabled) { _, enabled in
            updateAnimationPreference(enabled)
        }
        .onDisappear {
            trackTransitionToken = UUID()
            spinToken = UUID()
            playbackSequenceToken = UUID()
            freezeSpin(at: Date())
        }
    }

    @ViewBuilder
    private func scene(geometry: VinylSceneGeometry, spinDegrees: Double) -> some View {
        if let displayedTrack {
            ZStack(alignment: .topLeading) {
                if incomingTrack != nil {
                    outgoingLayers(
                        track: displayedTrack,
                        geometry: geometry,
                        spinDegrees: spinDegrees
                    )
                    incomingLayers(geometry: geometry, spinDegrees: spinDegrees)
                } else {
                    let frontRecordProgress = vinylSmoothStep(0.54, 0.76, playProgress)
                    disc(
                        track: displayedTrack,
                        frame: geometry.record,
                        rotation: spinDegrees,
                        interactive: true
                    )
                    .zIndex(0)

                    cover(
                        track: displayedTrack,
                        frame: geometry.cover,
                        rotation: geometry.coverRotation,
                        closeEnabled: true
                    )
                    .zIndex(1)

                    if frontRecordProgress > 0 {
                        disc(
                            track: displayedTrack,
                            frame: geometry.record,
                            rotation: spinDegrees,
                            interactive: frontRecordProgress > 0.04
                        )
                        .opacity(frontRecordProgress)
                        .zIndex(2)
                    }
                }

                tonearm(geometry: geometry)
                    .allowsHitTesting(incomingTrack == nil)
                    .zIndex(8)
            }
            .frame(width: geometry.container.width, height: geometry.container.height)
        }
    }

    @ViewBuilder
    private func outgoingLayers(
        track: TrackSnapshot,
        geometry: VinylSceneGeometry,
        spinDegrees: Double
    ) -> some View {
        let sleevePhase = vinylSmoothStep(
            VinylSequence.trackRecordCleared,
            VinylSequence.trackRecordSleeved,
            trackTransitionProgress
        )
        let clearPhase = vinylSmoothStep(
            0,
            VinylSequence.trackRecordCleared,
            trackTransitionProgress
        )
        let departPhase = vinylSmoothStep(
            VinylSequence.trackRecordSleeved,
            VinylSequence.trackAlbumDeparted,
            trackTransitionProgress
        )
        let opacity = 1 - departPhase
        let outgoingCover = geometry.outgoingCover(departProgress: departPhase)
        let outgoingRecord = geometry.outgoingRecord(
            clearProgress: clearPhase,
            sleeveProgress: sleevePhase,
            departProgress: departPhase
        )

        disc(
            track: track,
            frame: outgoingRecord,
            rotation: spinDegrees,
            interactive: false
        )
        .opacity(opacity)
        .zIndex(outgoingRecordBehindSleeve ? 0 : 2)

        cover(
            track: track,
            frame: outgoingCover,
            rotation: vinylLerp(geometry.coverRotation, 0, sleevePhase),
            closeEnabled: false
        )
        .opacity(opacity)
        .zIndex(1)
    }

    @ViewBuilder
    private func incomingLayers(geometry: VinylSceneGeometry, spinDegrees: Double) -> some View {
        if let incomingTrack {
            let coverPhase = vinylSmoothStep(
                VinylSequence.trackAlbumDeparted,
                VinylSequence.trackAlbumArrived,
                trackTransitionProgress
            )
            let recordPhase = vinylSmoothStep(
                VinylSequence.trackAlbumArrived,
                VinylSequence.trackRecordEmerged,
                trackTransitionProgress
            )
            let raisePhase = vinylSmoothStep(
                VinylSequence.trackRecordEmerged,
                VinylSequence.trackRecordRaised,
                trackTransitionProgress
            )
            let incomingCover = geometry.incomingCover(progress: coverPhase)
            let incomingRecord = geometry.incomingRecord(
                progress: recordPhase
            )

            disc(
                track: incomingTrack,
                frame: incomingRecord,
                rotation: spinDegrees,
                interactive: false
            )
            .opacity(recordPhase * (1 - raisePhase))
            .zIndex(3)

            cover(
                track: incomingTrack,
                frame: incomingCover,
                rotation: vinylLerp(16, geometry.coverRotation, coverPhase),
                closeEnabled: false
            )
            .opacity(coverPhase)
            .zIndex(4)

            disc(
                track: incomingTrack,
                frame: incomingRecord,
                rotation: spinDegrees,
                interactive: false
            )
            .opacity(recordPhase * raisePhase)
            .zIndex(5)
        }
    }

    private func cover(
        track: TrackSnapshot,
        frame: CGRect,
        rotation: Double,
        closeEnabled: Bool
    ) -> some View {
        VinylAlbumCover(
            track: track,
            artwork: artworkImages[track.stableKey]
        )
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
        VinylDisc(
            track: track,
            accent: accentColor(for: track),
            centerCounterRotation: settings.vinylCenterRotationEnabled ? 0 : -rotation
        )
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
        let style = AppSettings.normalizeVinylTonearmStyle(settings.vinylTonearmStyle)
        let finish = AppSettings.normalizeVinylTonearmFinish(settings.vinylTonearmFinish)
        let sizeScale = CGFloat(AppSettings.clampVinylTonearmSizePercent(settings.vinylTonearmSizePercent)) / 100
        let linear = style == AppSettings.vinylTonearmStyleLinear
        let trackParkProgress = incomingTrack == nil
            ? 1
            : 1 - vinylSmoothStep(0, VinylSequence.trackRecordSleeved, trackTransitionProgress)
        let engagement = Double(tonearmEngagement * trackParkProgress)
        let parkedProgress = linear
            ? VinylTonearmGeometry.linearParkProgress
            : VinylTonearmGeometry.progress(forRotation: VinylTonearmGeometry.parkDegrees)
        let progress = tonearmDragState?.progress
            ?? vinylLerp(parkedProgress, playbackProgress, engagement)
        let rotation = tonearmDragState?.rotation
            ?? vinylLerp(
                VinylTonearmGeometry.parkDegrees,
                VinylTonearmGeometry.rotation(for: playbackProgress),
                engagement
            )
        let points = VinylTonearmGeometry.points(
            record: geometry.record,
            rotation: rotation,
            style: style,
            sizeScale: sizeScale,
            progress: progress
        )

        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                VinylTonearmArtwork.draw(
                    context: context,
                    record: geometry.record,
                    rotation: rotation,
                    progress: progress,
                    style: style,
                    finish: finish,
                    sizeScale: sizeScale
                )
            }
            .allowsHitTesting(false)

            Color.clear
                .frame(width: 68, height: 68)
                .contentShape(Circle())
                .position(points.head)
                .gesture(tonearmDragGesture(geometry: geometry, style: style, sizeScale: sizeScale))
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

    private func tonearmDragGesture(
        geometry: VinylSceneGeometry,
        style: String,
        sizeScale: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(VinylCoordinateSpace.name))
            .updating($tonearmDragState) { value, state, _ in
                state = updatedTonearmDragState(
                    location: value.location,
                    startLocation: value.startLocation,
                    record: geometry.record,
                    style: style,
                    sizeScale: sizeScale,
                    existing: state
                )
            }
            .onEnded { value in
                let drag = updatedTonearmDragState(
                    location: value.location,
                    startLocation: value.startLocation,
                    record: geometry.record,
                    style: style,
                    sizeScale: sizeScale,
                    existing: tonearmDragState
                )
                let moved = hypot(
                    value.location.x - value.startLocation.x,
                    value.location.y - value.startLocation.y
                ) > 18
                let ejected = drag.seeking && (
                    (drag.linear
                        ? drag.rawProgress <= VinylTonearmGeometry.linearEjectProgress
                        : drag.rawRotation <= VinylTonearmGeometry.ejectDegrees)
                        || moved && !geometry.record.contains(value.location)
                )
                performHaptic(ejected ? .rigid : .light)
                if ejected {
                    model.pausePlayback()
                    return
                }
                if drag.seeking {
                    guard model.durationMs > 0 else { return }
                    model.seek(toPlaybackPositionMs: Int64((Double(model.durationMs) * drag.progress).rounded()))
                } else if (drag.linear
                            ? drag.progress >= VinylTonearmGeometry.linearCuePlayProgress
                            : drag.rotation >= VinylTonearmGeometry.cuePlayDegrees),
                          model.currentTrack?.playing != true {
                    model.togglePlayback()
                }
            }
    }

    private func updatedTonearmDragState(
        location: CGPoint,
        startLocation: CGPoint,
        record: CGRect,
        style: String,
        sizeScale: CGFloat,
        existing: VinylTonearmDragState?
    ) -> VinylTonearmDragState {
        let linear = style == AppSettings.vinylTonearmStyleLinear
        var next = existing ?? {
            let seeking = model.currentTrack?.playing == true
            if linear {
                let initialProgress = seeking ? playbackProgress : VinylTonearmGeometry.linearParkProgress
                return VinylTonearmDragState(
                    seeking: seeking,
                    linear: true,
                    pointerOffset: initialProgress - VinylTonearmGeometry.linearPointerProgress(
                        startLocation,
                        record: record,
                        sizeScale: sizeScale
                    ),
                    rotation: VinylTonearmGeometry.rotation(for: initialProgress),
                    rawRotation: VinylTonearmGeometry.rotation(for: initialProgress),
                    progress: initialProgress,
                    rawProgress: initialProgress
                )
            }
            let initialRotation = seeking
                ? VinylTonearmGeometry.rotation(for: playbackProgress)
                : VinylTonearmGeometry.parkDegrees
            return VinylTonearmDragState(
                seeking: seeking,
                linear: false,
                pointerOffset: initialRotation - VinylTonearmGeometry.pointerAngle(startLocation, record: record),
                rotation: initialRotation,
                rawRotation: initialRotation,
                progress: VinylTonearmGeometry.progress(forRotation: initialRotation),
                rawProgress: VinylTonearmGeometry.progress(forRotation: initialRotation)
            )
        }()
        if next.linear {
            let candidate = VinylTonearmGeometry.linearPointerProgress(
                location,
                record: record,
                sizeScale: sizeScale
            ) + next.pointerOffset
            next.rawProgress = candidate
            next.progress = next.seeking
                ? max(VinylTonearmGeometry.linearParkProgress, min(1, candidate))
                : max(VinylTonearmGeometry.linearParkProgress, min(0, candidate))
            next.rotation = VinylTonearmGeometry.rotation(for: next.progress)
            next.rawRotation = next.rotation
            return next
        }
        var candidate = VinylTonearmGeometry.pointerAngle(location, record: record) + next.pointerOffset
        while candidate - next.rotation > 180 { candidate -= 360 }
        while candidate - next.rotation < -180 { candidate += 360 }
        next.rawRotation = candidate
        next.rotation = next.seeking
            ? max(VinylTonearmGeometry.parkDegrees, min(VinylTonearmGeometry.endDegrees, candidate))
            : max(VinylTonearmGeometry.parkDegrees, min(VinylTonearmGeometry.startDegrees, candidate))
        next.progress = VinylTonearmGeometry.progress(forRotation: next.rotation)
        next.rawProgress = next.progress
        return next
    }

    private var playbackProgress: Double {
        guard model.durationMs > 0 else { return 0 }
        return max(0, min(1, Double(model.nowPositionMs) / Double(model.durationMs)))
    }

    private var loadingIndicatorText: String? {
        if model.status == .loading || model.lyricsResult.lines.isEmpty && model.lyricsResult.detail.lowercased().contains("loading") {
            return model.lyricsLoadingText
        }
        if model.lyricsSupplementTranslationLoading {
            return model.aiTranslationLoadingText
        }
        if model.lyricsSupplementPronunciationLoading {
            return model.aiPronunciationLoadingText
        }
        if model.lyricsSupplementFuriganaLoading {
            return settings.t("loading.pronunciation")
        }
        if model.culturalAnnotationsLoading {
            return model.culturalAnnotationsLoadingText
        }
        return nil
    }

    private func enter() {
        displayedTrack = model.currentTrack
        incomingTrack = nil
        trackTransitionProgress = 0
        outgoingRecordBehindSleeve = false
        entranceProgress = 0
        playProgress = 0
        tonearmEngagement = 0
        spinning = false
        spinOrigin = Date()
        if let displayedTrack {
            loadAccent(for: displayedTrack)
        }
        if settings.vinylAnimationsEnabled {
            DispatchQueue.main.async {
                withAnimation(.timingCurve(0.18, 0.82, 0.22, 1, duration: 0.78)) {
                    entranceProgress = 1
                }
            }
        } else {
            entranceProgress = 1
        }
        updatePlaying(
            model.currentTrack?.playing == true,
            animated: settings.vinylAnimationsEnabled
        )
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
        guard animateChange && settings.vinylAnimationsEnabled else {
            self.displayedTrack = next
            incomingTrack = nil
            return
        }

        let token = UUID()
        trackTransitionToken = token
        Task { @MainActor in
            var preparedTrack = next
            for _ in 0..<8 {
                guard preparedTrack.artworkURL == displayedTrack.artworkURL else { break }
                try? await Task.sleep(nanoseconds: 40_000_000)
                guard trackTransitionToken == token,
                      let current = model.currentTrack,
                      current.stableKey == next.stableKey else { return }
                preparedTrack = current
            }
            let asset = await VinylArtworkAccent.asset(for: preparedTrack)
            guard trackTransitionToken == token,
                  model.currentTrack?.stableKey == preparedTrack.stableKey else { return }
            accentColors[preparedTrack.stableKey] = asset.color
            if let image = asset.image {
                artworkImages[preparedTrack.stableKey] = image
            }
            incomingTrack = preparedTrack
            trackTransitionProgress = 0
            outgoingRecordBehindSleeve = false
            withAnimation(.timingCurve(0.20, 0.74, 0.24, 1, duration: 0.18)) {
                trackTransitionProgress = VinylSequence.trackRecordCleared
            }
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard trackTransitionToken == token else { return }
            var layerTransaction = Transaction()
            layerTransaction.disablesAnimations = true
            withTransaction(layerTransaction) {
                outgoingRecordBehindSleeve = true
            }
            withAnimation(.timingCurve(0.22, 0.76, 0.28, 1, duration: 0.68)) {
                trackTransitionProgress = VinylSequence.trackRecordSleeved
            }
            try? await Task.sleep(nanoseconds: 680_000_000)
            guard trackTransitionToken == token else { return }
            withAnimation(.timingCurve(0.50, 0, 0.72, 0.30, duration: 0.48)) {
                trackTransitionProgress = VinylSequence.trackAlbumDeparted
            }
            try? await Task.sleep(nanoseconds: 480_000_000)
            guard trackTransitionToken == token else { return }
            withAnimation(.timingCurve(0.18, 0.72, 0.16, 1, duration: 0.70)) {
                trackTransitionProgress = VinylSequence.trackAlbumArrived
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard trackTransitionToken == token else { return }
            withAnimation(.timingCurve(0.16, 0.78, 0.18, 1, duration: 0.72)) {
                trackTransitionProgress = VinylSequence.trackRecordEmerged
            }
            try? await Task.sleep(nanoseconds: 720_000_000)
            guard trackTransitionToken == token else { return }
            withAnimation(.timingCurve(0.20, 0.76, 0.20, 1, duration: 0.36)) {
                trackTransitionProgress = VinylSequence.trackRecordRaised
            }
            try? await Task.sleep(nanoseconds: 360_000_000)
            guard trackTransitionToken == token else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                self.displayedTrack = incomingTrack ?? preparedTrack
            }
            withAnimation(.linear(duration: 0.096)) {
                trackTransitionProgress = 1
            }
            try? await Task.sleep(nanoseconds: 96_000_000)
            guard trackTransitionToken == token else { return }
            withTransaction(transaction) {
                incomingTrack = nil
                trackTransitionProgress = 0
                outgoingRecordBehindSleeve = false
                tonearmEngagement = 0
            }
            if model.currentTrack?.playing == true {
                withAnimation(.timingCurve(0.18, 0.76, 0.22, 1, duration: 0.72)) {
                    tonearmEngagement = 1
                }
            }
        }
    }

    private func refreshCurrentTrackAsset() {
        guard let current = model.currentTrack else { return }
        if incomingTrack?.stableKey == current.stableKey {
            return
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
            let asset = await VinylArtworkAccent.asset(for: track)
            guard !Task.isCancelled else { return }
            let currentAssetKeys = [displayedTrack, incomingTrack]
                .compactMap { candidate -> String? in
                    guard let candidate else { return nil }
                    return candidate.stableKey + "|" + (candidate.artworkURL?.absoluteString ?? "")
                }
            guard currentAssetKeys.contains(assetKey) else { return }
            accentColors[key] = asset.color
            if let image = asset.image {
                artworkImages[key] = image
            }
        }
    }

    private func updatePlaying(_ playing: Bool, animated: Bool) {
        let token = UUID()
        spinToken = token
        playbackSequenceToken = token
        guard settings.vinylAnimationsEnabled, animated else {
            freezeSpin(at: Date())
            spinning = playing
            spinOrigin = Date()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                playProgress = playing ? 1 : 0
                tonearmEngagement = playing ? 1 : 0
            }
            return
        }
        if playing {
            freezeSpin(at: Date())
            spinning = false
            let fullSequence = playProgress <= 0.05 && tonearmEngagement <= 0.05
            Task { @MainActor in
                if fullSequence {
                    withAnimation(.timingCurve(0.18, 0.76, 0.22, 1, duration: 0.78)) {
                        playProgress = 0.72
                    }
                    try? await Task.sleep(nanoseconds: 780_000_000)
                    guard playbackSequenceToken == token else { return }
                    try? await Task.sleep(nanoseconds: 220_000_000)
                    guard playbackSequenceToken == token else { return }
                    withAnimation(.timingCurve(0.18, 0.76, 0.22, 1, duration: 0.56)) {
                        playProgress = 1
                    }
                    try? await Task.sleep(nanoseconds: 560_000_000)
                    guard playbackSequenceToken == token else { return }
                    withAnimation(.timingCurve(0.18, 0.76, 0.22, 1, duration: 0.72)) {
                        tonearmEngagement = 1
                    }
                    try? await Task.sleep(nanoseconds: 720_000_000)
                } else {
                    withAnimation(.timingCurve(0.18, 0.76, 0.22, 1, duration: 0.72)) {
                        playProgress = 1
                        tonearmEngagement = 1
                    }
                    try? await Task.sleep(nanoseconds: 720_000_000)
                }
                guard playbackSequenceToken == token,
                      model.currentTrack?.playing == true else { return }
                spinOrigin = Date()
                spinning = true
            }
        } else {
            let fullSequence = playProgress >= 0.95
            Task { @MainActor in
                withAnimation(.timingCurve(0.28, 0, 0.34, 1, duration: 0.72)) {
                    tonearmEngagement = 0
                }
                try? await Task.sleep(nanoseconds: 720_000_000)
                guard playbackSequenceToken == token else { return }
                freezeSpin(at: Date())
                spinning = false
                guard fullSequence else {
                    withAnimation(.timingCurve(0.28, 0, 0.34, 1, duration: 0.78)) {
                        playProgress = 0
                    }
                    return
                }
                withAnimation(.timingCurve(0.28, 0, 0.34, 1, duration: 0.46)) {
                    playProgress = 0.88
                }
                try? await Task.sleep(nanoseconds: 460_000_000)
                guard playbackSequenceToken == token else { return }
                withAnimation(.linear(duration: 0.07)) {
                    playProgress = 0.72
                }
                try? await Task.sleep(nanoseconds: 70_000_000)
                guard playbackSequenceToken == token else { return }
                withAnimation(.timingCurve(0.28, 0, 0.34, 1, duration: 0.78)) {
                    playProgress = 0
                }
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
        guard settings.vinylAnimationsEnabled else {
            isPresented = false
            return
        }
        withAnimation(.timingCurve(0.22, 0.74, 0.28, 1, duration: 0.36)) {
            isPresented = false
        }
    }

    private func updateAnimationPreference(_ enabled: Bool) {
        guard !enabled else {
            updatePlaying(model.currentTrack?.playing == true, animated: false)
            return
        }
        trackTransitionToken = UUID()
        spinToken = UUID()
        playbackSequenceToken = UUID()
        freezeSpin(at: Date())
        spinning = false
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            displayedTrack = model.currentTrack ?? incomingTrack ?? displayedTrack
            incomingTrack = nil
            trackTransitionProgress = 0
            outgoingRecordBehindSleeve = false
            entranceProgress = 1
            playProgress = model.currentTrack?.playing == true ? 1 : 0
            tonearmEngagement = model.currentTrack?.playing == true ? 1 : 0
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
    let artwork: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.96, green: 0.19, blue: 0.52), Color(red: 0.30, green: 0.10, blue: 0.46)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                if let artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
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
    let centerCounterRotation: Double

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

                ZStack {
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
                .frame(width: size, height: size)
                .rotationEffect(.degrees(centerCounterRotation))
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

private enum VinylSequence {
    static let trackDuration: CGFloat = 3.216
    static let trackRecordCleared: CGFloat = 0.180 / trackDuration
    static let trackRecordSleeved: CGFloat = 0.860 / trackDuration
    static let trackAlbumDeparted: CGFloat = 1.340 / trackDuration
    static let trackAlbumArrived: CGFloat = 2.040 / trackDuration
    static let trackRecordEmerged: CGFloat = 2.760 / trackDuration
    static let trackRecordRaised: CGFloat = 3.120 / trackDuration
}

private struct VinylSceneGeometry {
    let container: CGSize
    let cover: CGRect
    let record: CGRect
    let coverRotation: Double
    let lyricHeight: CGFloat
    let lyricBottom: CGFloat
    let isLandscape: Bool

    init(
        container: CGSize,
        playProgress: CGFloat,
        entranceProgress: CGFloat,
        albumScale: CGFloat,
        recordScale: CGFloat,
        lyricsVisible: Bool,
        culturalAnnotationsVisible: Bool
    ) {
        self.container = container
        isLandscape = container.width > container.height
        lyricHeight = lyricsVisible
            ? (culturalAnnotationsVisible
                ? (isLandscape ? 126 : 162)
                : (isLandscape ? 102 : 136))
            : 0
        lyricBottom = lyricsVisible ? (isLandscape ? 8 : 14) : 0
        let lyricReserve = lyricsVisible ? lyricHeight + lyricBottom + (isLandscape ? 14 : 22) : 0
        let availableHeight = max(220, container.height - lyricReserve)
        let rawSize = isLandscape
            ? min(container.width * 0.31, availableHeight * 0.74)
            : min(container.width * 0.72, availableHeight * 0.48)
        let safeAlbumScale = min(1.4, max(0.7, albumScale))
        let safeRecordScale = min(1.4, max(0.7, recordScale))
        let maximumScale = max(1, max(safeAlbumScale, safeRecordScale))
        let heightConstrainedSize = min(rawSize, availableHeight * 0.94 / maximumScale)
        let widthConstrainedSize = isLandscape
            ? heightConstrainedSize
            : min(heightConstrainedSize, container.width * 0.94 / maximumScale)
        let size = max(isLandscape ? 150 : 184, min(widthConstrainedSize, availableHeight * 0.78))
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
            cover = vinylScaledRect(
                CGRect(x: coverX, y: centerY - size * 0.5, width: size, height: size),
                scale: safeAlbumScale
            )
            record = vinylScaledRect(
                CGRect(x: recordX, y: centerY - size * 0.5, width: size, height: size),
                scale: safeRecordScale
            )
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
            cover = vinylScaledRect(
                CGRect(
                    x: coverCenterX - coverSize * 0.5,
                    y: coverCenterY - coverSize * 0.5,
                    width: coverSize,
                    height: coverSize
                ),
                scale: safeAlbumScale
            )
            record = vinylScaledRect(
                CGRect(x: recordX, y: recordY, width: size, height: size),
                scale: safeRecordScale
            )
        }
        let playingCoverRotation = isLandscape ? -5.0 : -3.0
        coverRotation = vinylLerp(0, playingCoverRotation, vinylSmoothStep(0.28, 1, playProgress))
            + vinylLerp(-2, 0, entrance)
    }

    func incomingCover(progress: CGFloat) -> CGRect {
        let start = CGRect(
            x: container.width + cover.width * 0.18,
            y: isLandscape ? -cover.height * 0.38 : container.height + cover.height * 0.18,
            width: cover.width,
            height: cover.height
        )
        return vinylInterpolate(start, cover, progress)
    }

    func incomingRecord(progress: CGFloat) -> CGRect {
        let hidden = CGRect(
            x: cover.midX - record.width * 0.5,
            y: cover.midY - record.height * 0.5,
            width: record.width,
            height: record.height
        )
        return vinylInterpolate(hidden, record, progress)
    }

    func outgoingCover(departProgress: CGFloat) -> CGRect {
        cover.offsetBy(
            dx: 0,
            dy: -(max(cover.maxY, record.maxY) + 36) * departProgress
        )
    }

    func outgoingRecord(
        clearProgress: CGFloat,
        sleeveProgress: CGFloat,
        departProgress: CGFloat
    ) -> CGRect {
        let clearOffset = isLandscape
            ? CGVector(dx: max(0, cover.maxX - record.minX) + record.width * 0.04, dy: 0)
            : CGVector(dx: 0, dy: max(0, cover.maxY - record.minY) + record.height * 0.04)
        let cleared = record.offsetBy(
            dx: clearOffset.dx * clearProgress,
            dy: clearOffset.dy * clearProgress
        )
        let sleeved = CGRect(
            x: cover.midX - record.width * 0.5,
            y: cover.midY - record.height * 0.5,
            width: record.width,
            height: record.height
        )
        return vinylInterpolate(cleared, sleeved, sleeveProgress).offsetBy(
            dx: 0,
            dy: -(max(cover.maxY, record.maxY) + 36) * departProgress
        )
    }
}

private struct VinylTonearmDragState {
    let seeking: Bool
    let linear: Bool
    let pointerOffset: Double
    var rotation: Double
    var rawRotation: Double
    var progress: Double
    var rawProgress: Double
}

private enum VinylTonearmGeometry {
    // Desktop VinylPlayerMode.js rotates its 260 x 620 SVG by these values.
    static let startDegrees = -5.4
    static let endDegrees = 18.0
    static let parkDegrees = -14.0
    static let ejectDegrees = -8.2
    static let cuePlayDegrees = -7.2
    static let linearParkProgress = -0.44
    static let linearEjectProgress = -0.2
    static let linearCuePlayProgress = -0.08
    static let linearTravel: CGFloat = 95
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

    static func points(
        record: CGRect,
        rotation: Double,
        style: String = AppSettings.vinylTonearmStyleS,
        sizeScale: CGFloat = 1,
        progress: Double = 0
    ) -> Points {
        let scale = record.width / viewBoxHeight * sizeScale
        if style == AppSettings.vinylTonearmStyleLinear {
            let outerX = record.minX + record.width * 0.86
            let pivot = CGPoint(
                x: outerX - linearTravel * scale * CGFloat(progress),
                y: record.minY + record.height * 0.1032
            )
            return Points(
                pivot: pivot,
                head: CGPoint(x: pivot.x - 10 * scale, y: pivot.y + (544 - 64) * scale),
                radius: record.width * 0.5,
                scale: scale
            )
        }
        let pivot = CGPoint(
            x: record.minX + record.width * 0.8766,
            y: record.minY + record.height * 0.1032
        )
        return Points(
            pivot: pivot,
            head: point(headSVG, record: record, rotation: rotation, sizeScale: sizeScale),
            radius: record.width * 0.5,
            scale: scale
        )
    }

    static func point(
        _ svgPoint: CGPoint,
        record: CGRect,
        rotation: Double,
        sizeScale: CGFloat = 1
    ) -> CGPoint {
        let scale = record.width / viewBoxHeight * sizeScale
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

    static func linearPointerProgress(
        _ location: CGPoint,
        record: CGRect,
        sizeScale: CGFloat
    ) -> Double {
        let scale = max(0.0001, record.width / viewBoxHeight * sizeScale)
        let outerX = record.minX + record.width * 0.86
        return Double((outerX - location.x) / (linearTravel * scale))
    }
}

private enum VinylTonearmArtwork {
    private struct Appearance {
        let base: [Color]
        let tube: [Color]
        let housing: Color
        let edge: Color
        let highlight: Color
        let needle: Color
    }

    static func draw(
        context: GraphicsContext,
        record: CGRect,
        rotation: Double,
        progress: Double,
        style: String,
        finish: String,
        sizeScale: CGFloat
    ) {
        let appearance = appearance(for: finish)
        if style == AppSettings.vinylTonearmStyleLinear {
            drawLinear(
                context: context,
                record: record,
                progress: progress,
                appearance: appearance,
                sizeScale: sizeScale
            )
            return
        }

        let points = VinylTonearmGeometry.points(
            record: record,
            rotation: rotation,
            style: style,
            sizeScale: sizeScale,
            progress: progress
        )
        let scale = points.scale
        let point: (CGFloat, CGFloat) -> CGPoint = { x, y in
            VinylTonearmGeometry.point(
                CGPoint(x: x, y: y),
                record: record,
                rotation: rotation,
                sizeScale: sizeScale
            )
        }

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
                    .init(color: appearance.base[0].opacity(0.88), location: 0),
                    .init(color: appearance.base[1].opacity(0.72), location: 0.58),
                    .init(color: appearance.base[2].opacity(0.58), location: 1)
                ]),
                center: VinylTonearmGeometry.point(
                    CGPoint(x: 172, y: 43),
                    record: record,
                    rotation: 0,
                    sizeScale: sizeScale
                ),
                startRadius: 0,
                endRadius: 95 * scale
            )
        )
        let baseShadow = base.applying(CGAffineTransform(translationX: 0, y: 2 * scale))
        context.stroke(baseShadow, with: .color(.black.opacity(0.14)), lineWidth: 3 * scale)
        context.stroke(base, with: .color(appearance.edge.opacity(0.72)), lineWidth: 2 * scale)

        let arm = armPath(style: style, highlight: false, point: point)
        context.stroke(
            arm,
            with: .color(.black.opacity(0.32)),
            style: StrokeStyle(lineWidth: 17 * scale, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            arm,
            with: .linearGradient(
                tubeGradient(appearance),
                startPoint: point(28, 280),
                endPoint: point(210, 280)
            ),
            style: StrokeStyle(lineWidth: 14 * scale, lineCap: .round, lineJoin: .round)
        )

        context.stroke(
            armPath(style: style, highlight: true, point: point),
            with: .color(appearance.highlight),
            style: StrokeStyle(lineWidth: 3 * scale, lineCap: .round)
        )

        let pivotHousing = polygon([
            (151, 35), (200, 39), (215, 66), (207, 109),
            (170, 111), (151, 91), (144, 61)
        ], point: point)
        drawHousing(pivotHousing, context: context, scale: scale, appearance: appearance)

        var pivotHighlight = Path()
        pivotHighlight.move(to: point(158, 42))
        pivotHighlight.addLine(to: point(194, 45))
        pivotHighlight.addLine(to: point(207, 65))
        pivotHighlight.addLine(to: point(202, 91))
        context.stroke(
            pivotHighlight,
            with: .color(appearance.highlight),
            style: StrokeStyle(lineWidth: 4 * scale, lineCap: .round, lineJoin: .round)
        )

        let headshell = polygon([
            (47, 490), (75, 508), (54, 546), (30, 540),
            (17, 522), (24, 506)
        ], point: point)
        drawHousing(headshell, context: context, scale: scale, appearance: appearance)

        var headHighlight = Path()
        headHighlight.move(to: point(28, 509))
        headHighlight.addLine(to: point(66, 517))
        headHighlight.addLine(to: point(49, 539))
        context.stroke(
            headHighlight,
            with: .color(appearance.highlight),
            style: StrokeStyle(lineWidth: 4 * scale, lineCap: .round, lineJoin: .round)
        )

        var needle = Path()
        needle.move(to: point(35, 539))
        needle.addLine(to: point(33, 555))
        needle.move(to: point(48, 542))
        needle.addLine(to: point(53, 557))
        context.stroke(
            needle,
            with: .color(appearance.needle),
            style: StrokeStyle(lineWidth: 5 * scale, lineCap: .square)
        )
    }

    private static func drawLinear(
        context: GraphicsContext,
        record: CGRect,
        progress: Double,
        appearance: Appearance,
        sizeScale: CGFloat
    ) {
        let points = VinylTonearmGeometry.points(
            record: record,
            rotation: 0,
            style: AppSettings.vinylTonearmStyleLinear,
            sizeScale: sizeScale,
            progress: progress
        )
        let scale = points.scale
        let outerX = record.minX + record.width * 0.86
        let railY = record.minY + record.height * 0.1032
        let railStart = CGPoint(x: outerX - 140 * scale, y: railY)
        let railEnd = CGPoint(x: outerX + 60 * scale, y: railY)

        var railShadow = Path()
        railShadow.move(to: CGPoint(x: railStart.x, y: railStart.y + 4 * scale))
        railShadow.addLine(to: CGPoint(x: railEnd.x, y: railEnd.y + 4 * scale))
        context.stroke(
            railShadow,
            with: .color(.black.opacity(0.3)),
            style: StrokeStyle(lineWidth: 20 * scale, lineCap: .round)
        )
        var rail = Path()
        rail.move(to: railStart)
        rail.addLine(to: railEnd)
        context.stroke(
            rail,
            with: .linearGradient(tubeGradient(appearance), startPoint: railStart, endPoint: railEnd),
            style: StrokeStyle(lineWidth: 16 * scale, lineCap: .round)
        )
        for center in [railStart, railEnd] {
            var cap = Path()
            cap.addEllipse(in: CGRect(
                x: center.x - 18 * scale,
                y: center.y - 18 * scale,
                width: 36 * scale,
                height: 36 * scale
            ))
            context.fill(cap, with: .color(appearance.housing))
            context.stroke(cap, with: .color(appearance.edge), lineWidth: 2 * scale)
        }

        let point: (CGFloat, CGFloat) -> CGPoint = { x, y in
            CGPoint(
                x: points.pivot.x + (x - 170) * scale,
                y: points.pivot.y + (y - 64) * scale
            )
        }
        var arm = Path()
        arm.move(to: point(170, 87))
        arm.addLine(to: point(170, 476))
        arm.addLine(to: point(160, 510))
        context.stroke(
            arm,
            with: .color(.black.opacity(0.32)),
            style: StrokeStyle(lineWidth: 17 * scale, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            arm,
            with: .linearGradient(
                tubeGradient(appearance),
                startPoint: point(140, 280),
                endPoint: point(200, 280)
            ),
            style: StrokeStyle(lineWidth: 14 * scale, lineCap: .round, lineJoin: .round)
        )
        var armHighlight = Path()
        armHighlight.move(to: point(165, 91))
        armHighlight.addLine(to: point(165, 472))
        context.stroke(
            armHighlight,
            with: .color(appearance.highlight),
            style: StrokeStyle(lineWidth: 3 * scale, lineCap: .round)
        )

        let carriage = polygon([(144, 38), (196, 38), (196, 104), (144, 104)], point: point)
        drawHousing(carriage, context: context, scale: scale, appearance: appearance)
        var carriageHighlight = Path()
        carriageHighlight.move(to: point(153, 48))
        carriageHighlight.addLine(to: point(187, 48))
        carriageHighlight.addLine(to: point(187, 86))
        context.stroke(
            carriageHighlight,
            with: .color(appearance.highlight),
            style: StrokeStyle(lineWidth: 4 * scale, lineCap: .round, lineJoin: .round)
        )

        let headshell = polygon([
            (139, 487), (182, 487), (184, 529), (146, 542), (132, 523)
        ], point: point)
        drawHousing(headshell, context: context, scale: scale, appearance: appearance)
        var headHighlight = Path()
        headHighlight.move(to: point(146, 496))
        headHighlight.addLine(to: point(174, 496))
        headHighlight.addLine(to: point(175, 521))
        context.stroke(
            headHighlight,
            with: .color(appearance.highlight),
            style: StrokeStyle(lineWidth: 4 * scale, lineCap: .round, lineJoin: .round)
        )
        var needle = Path()
        needle.move(to: point(149, 537))
        needle.addLine(to: point(148, 555))
        needle.move(to: point(164, 533))
        needle.addLine(to: point(168, 552))
        context.stroke(
            needle,
            with: .color(appearance.needle),
            style: StrokeStyle(lineWidth: 5 * scale, lineCap: .square)
        )
    }

    private static func armPath(
        style: String,
        highlight: Bool,
        point: (CGFloat, CGFloat) -> CGPoint
    ) -> Path {
        var path = Path()
        if style == AppSettings.vinylTonearmStyleStraight {
            path.move(to: point(highlight ? 184 : 189, highlight ? 79 : 75))
            path.addLine(to: point(highlight ? 53 : 58, highlight ? 508 : 513))
            return path
        }
        if style == AppSettings.vinylTonearmStyleJ {
            path.move(to: point(highlight ? 184 : 189, highlight ? 79 : 75))
            path.addLine(to: point(highlight ? 175 : 181, highlight ? 369 : 372))
            path.addCurve(
                to: point(highlight ? 55 : 58, highlight ? 507 : 513),
                control1: point(highlight ? 173 : 179, highlight ? 424 : 432),
                control2: point(highlight ? 135 : 139, highlight ? 474 : 481)
            )
            return path
        }
        path.move(to: point(highlight ? 184 : 189, highlight ? 79 : 75))
        path.addCurve(
            to: point(highlight ? 74 : 78, highlight ? 469 : 474),
            control1: point(highlight ? 178 : 184, highlight ? 179 : 172),
            control2: point(highlight ? 145 : 151, 330)
        )
        if !highlight { path.addLine(to: point(58, 513)) }
        return path
    }

    private static func drawHousing(
        _ path: Path,
        context: GraphicsContext,
        scale: CGFloat,
        appearance: Appearance
    ) {
        let shadow = path.applying(CGAffineTransform(translationX: 2 * scale, y: 5 * scale))
        context.fill(shadow, with: .color(.black.opacity(0.18)))
        context.fill(path, with: .color(appearance.housing))
        context.stroke(path, with: .color(appearance.edge), lineWidth: scale)
    }

    private static func polygon(
        _ values: [(CGFloat, CGFloat)],
        point: (CGFloat, CGFloat) -> CGPoint
    ) -> Path {
        var path = Path()
        guard let first = values.first else { return path }
        path.move(to: point(first.0, first.1))
        for value in values.dropFirst() {
            path.addLine(to: point(value.0, value.1))
        }
        path.closeSubpath()
        return path
    }

    private static func tubeGradient(_ appearance: Appearance) -> Gradient {
        Gradient(stops: [
            .init(color: appearance.tube[0], location: 0),
            .init(color: appearance.tube[1], location: 0.24),
            .init(color: appearance.tube[2], location: 0.55),
            .init(color: appearance.tube[3], location: 1)
        ])
    }

    private static func appearance(for finish: String) -> Appearance {
        if finish == AppSettings.vinylTonearmFinishBlack {
            return Appearance(
                base: [Color(white: 0.34), Color(white: 0.145), Color(white: 0.035)],
                tube: [Color(white: 0.02), Color(white: 0.34), Color(white: 0.12), Color(white: 0.01)],
                housing: Color(white: 0.10).opacity(0.98),
                edge: Color(white: 0.37).opacity(0.9),
                highlight: .white.opacity(0.34),
                needle: Color(white: 0.67)
            )
        }
        if finish == AppSettings.vinylTonearmFinishSilver {
            return Appearance(
                base: [Color(white: 0.96), Color(white: 0.76), Color(white: 0.48)],
                tube: [Color(white: 0.35), Color(white: 0.86), Color(white: 0.97), Color(white: 0.46)],
                housing: Color(white: 0.73).opacity(0.98),
                edge: Color(white: 0.40).opacity(0.88),
                highlight: .white.opacity(0.76),
                needle: Color(white: 0.74)
            )
        }
        return Appearance(
            base: [.white, Color(white: 0.985), Color(white: 0.933)],
            tube: [Color(white: 0.667), Color(white: 0.98), .white, Color(white: 0.733)],
            housing: Color(white: 0.988).opacity(0.97),
            edge: Color(white: 0.90).opacity(0.80),
            highlight: .white.opacity(0.95),
            needle: Color(white: 0.933)
        )
    }
}

private enum VinylArtworkAccent {
    struct Asset {
        let color: Color
        let image: UIImage?
    }

    static func asset(for track: TrackSnapshot) async -> Asset {
        let fallback = fallbackColor(key: track.stableKey)
        guard let url = track.artworkURL else {
            return Asset(color: fallback, image: nil)
        }
        let request = URLRequest(
            url: url,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 0.32
        )
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              !Task.isCancelled,
              let image = UIImage(data: data) else {
            return Asset(color: fallback, image: nil)
        }
        let color = averageColor(image).map(Color.init(uiColor:)) ?? fallback
        return Asset(color: color, image: image)
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

private func vinylScaledRect(_ rect: CGRect, scale: CGFloat) -> CGRect {
    let safeScale = min(1.4, max(0.7, scale))
    let width = rect.width * safeScale
    let height = rect.height * safeScale
    return CGRect(
        x: rect.midX - width * 0.5,
        y: rect.midY - height * 0.5,
        width: width,
        height: height
    )
}

private func vinylInterpolate(_ start: CGRect, _ end: CGRect, _ progress: CGFloat) -> CGRect {
    CGRect(
        x: vinylLerp(start.minX, end.minX, progress),
        y: vinylLerp(start.minY, end.minY, progress),
        width: vinylLerp(start.width, end.width, progress),
        height: vinylLerp(start.height, end.height, progress)
    )
}
