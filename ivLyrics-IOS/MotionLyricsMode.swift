import Combine
import Foundation
import SwiftUI

#if os(iOS)
import UIKit
import WebKit

// Motion lyrics: the desktop kinetic-typography presentation, shown over the player background.
//
// The presentation itself is the desktop one. Resources/MotionLyricsPage.html is built in the
// ivLyrics repository (.github/scripts/build_motion_mobile.mjs) from the desktop scripts and
// runs them unchanged in a web view; this file sends it the song and the playback position,
// answers its two requests (an AI direction, the direction cache) and turns the player
// background with its camera. Edit the presentation there, not here.

// MARK: - The song as the page reads it

enum MotionLyricsSong {
    /// Lines with word or character timing can play; a line-synced song cannot (the words would
    /// leave the singing).
    static func canPlay(_ lyrics: LyricsResult) -> Bool {
        lyrics.karaoke && lyrics.lines.contains { line in
            !line.syllables.isEmpty || line.vocalParts.contains { !$0.syllables.isEmpty }
        }
    }

    /// The JSON the page takes in setTrack, in the desktop app's line format. Empty without a track.
    static func json(track: TrackSnapshot?, lyrics: LyricsResult, accentHex: String, language: String) -> String {
        guard let track, track.hasUsableMetadata else { return "" }
        let object: [String: Any] = [
            "uri": uri(for: track),
            "title": track.title,
            "artist": track.artist,
            "accent": accentHex,
            "language": language,
            "lyrics": lyrics.karaoke ? lyrics.lines.map(line) : []
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }

    static func uri(for track: TrackSnapshot) -> String {
        track.trackId.isEmpty
            ? "ivlyrics:track:" + String(IvLyricsUtilities.sha256(track.stableKey).prefix(22))
            : "spotify:track:" + track.trackId
    }

    private static func line(_ line: LyricsLine) -> [String: Any] {
        var object: [String: Any] = [
            "text": line.text,
            "startTime": line.startTimeMs,
            "endTime": line.endTimeMs,
            "syllables": line.syllables.map(syllable)
        ]
        if !line.translationText.trimmed.isEmpty {
            object["text2"] = line.translationText
        }
        // The first lead part leads the line; the others sing with it (a duet partner is another lead).
        // Without a part marked lead (only other voices, or unmarked parts) the first one sung leads.
        let sung = line.vocalParts.filter { !$0.syllables.isEmpty }
        if let lead = sung.first(where: { $0.role == "lead" }) ?? sung.first {
            object["vocals"] = [
                "lead": part(lead),
                "background": sung.filter { $0.id != lead.id }.map(part)
            ]
        }
        return object
    }

    private static func part(_ part: LyricsLine.VocalPart) -> [String: Any] {
        ["text": part.text, "role": part.role, "speaker": part.speaker, "syllables": part.syllables.map(syllable)]
    }

    private static func syllable(_ syllable: LyricsLine.Syllable) -> [String: Any] {
        ["text": syllable.text, "startTime": syllable.startTimeMs, "endTime": syllable.endTimeMs]
    }
}

// MARK: - The player background follows the motion camera

/// Rotation, zoom and offset the page's camera asks of the background (CSS pixels are points).
struct MotionBackdropFrame: Equatable {
    var rotate: Double = 0
    var scale: Double = 1
    var x: Double = 0
    var y: Double = 0

    static let identity = MotionBackdropFrame()
}

/// Published on every frame the camera moves, so only MotionBackdropFollower observes it.
final class MotionBackdropCamera: ObservableObject {
    @Published var frame = MotionBackdropFrame.identity
}

struct MotionBackdropFollower: ViewModifier {
    @ObservedObject var camera: MotionBackdropCamera
    /// The centre of the screen within the background's own bounds. The page turns and zooms
    /// about the screen centre and leaves little spare cover, and the background is laid out
    /// inside the safe area (uneven in landscape) while it draws to the screen edges.
    var screenCenter: UnitPoint = .center

    func body(content: Content) -> some View {
        let frame = camera.frame
        // CSS applies scale, then rotate, then translate; so do these.
        content
            .scaleEffect(frame.scale, anchor: screenCenter)
            .rotationEffect(.degrees(frame.rotate), anchor: screenCenter)
            .offset(x: frame.x, y: frame.y)
    }

    static func screenCenter(size: CGSize, safeArea: EdgeInsets) -> UnitPoint {
        UnitPoint(
            x: 0.5 + (safeArea.trailing - safeArea.leading) / max(1, 2 * size.width),
            y: 0.5 + (safeArea.bottom - safeArea.top) / max(1, 2 * size.height)
        )
    }
}

// MARK: - Orientation

/// The presentation is composed for a wide screen. On a phone the mode turns the interface to
/// landscape and holds it there; closing it returns to the orientation it was opened in.
enum MotionLyricsOrientation {
    private(set) static var landscapeHeld = false
    private static var openedInPortrait = false

    static var supported: UIInterfaceOrientationMask {
        if landscapeHeld { return .landscape }
        return UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    static func hold(_ held: Bool) {
        guard UIDevice.current.userInterfaceIdiom == .phone, landscapeHeld != held else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if held {
            openedInPortrait = scenes.contains { $0.interfaceOrientation.isPortrait }
        }
        landscapeHeld = held
        for scene in scenes {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            if held {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
            } else if openedInPortrait {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
    }
}

/// SwiftUI has no other way to narrow the supported orientations while the app runs.
final class IvLyricsAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        MotionLyricsOrientation.supported
    }
}

// MARK: - The page

struct MotionLyricsWebView: UIViewRepresentable {
    /// What the page asks of the app.
    struct Bridge {
        /// The AI provider's raw answer to the page's prompt.
        var direct: (String) async throws -> String
        var cached: (String) async -> String
        var store: (String, String) -> Void
        /// The page's verdict on the song it was given: track URI, playable.
        var eligible: (String, Bool) -> Void
        var background: (MotionBackdropFrame) -> Void
        var log: (String) -> Void
    }

    var songJSON: String
    var positionMs: Double
    var playing: Bool
    var rate: Double
    var labels: [String: String]
    var aiAvailable: Bool
    var insets: EdgeInsets
    var bridge: Bridge

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(WeakHandler(context.coordinator), name: Coordinator.handlerName)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        // Touches belong to the mode's own controls.
        view.isUserInteractionEnabled = false
        context.coordinator.webView = view
        context.coordinator.bridge = bridge
        if let url = Bundle.main.url(forResource: "MotionLyricsPage", withExtension: "html") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            bridge.log("motion lyrics page is missing from the bundle")
        }
        return view
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.bridge = bridge
        coordinator.wanted = Coordinator.Wanted(
            songJSON: songJSON,
            options: Coordinator.optionsJSON(labels: labels, aiAvailable: aiAvailable, insets: insets),
            positionMs: positionMs,
            playing: playing,
            rate: rate
        )
        coordinator.flush()
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.handlerName)
        coordinator.bridge?.background(.identity)
    }

    /// The user content controller retains its handler; the coordinator must not be kept by it.
    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: Coordinator?

        init(_ target: Coordinator) {
            self.target = target
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.receive(message.body)
        }
    }

    final class Coordinator: NSObject {
        static let handlerName = "ivLyricsMotion"

        struct Wanted {
            var songJSON: String
            var options: String
            var positionMs: Double
            var playing: Bool
            var rate: Double
        }

        weak var webView: WKWebView?
        var bridge: Bridge?
        var wanted: Wanted?
        private var ready = false
        private var sentSong: String?
        private var sentOptions: String?

        static func optionsJSON(labels: [String: String], aiAvailable: Bool, insets: EdgeInsets) -> String {
            json([
                "labels": labels,
                "ai": aiAvailable,
                "background": true,
                "insets": [
                    "top": Double(insets.top),
                    "right": Double(insets.trailing),
                    "bottom": Double(insets.bottom),
                    "left": Double(insets.leading)
                ]
            ])
        }

        /// Sends what changed. Options go first: the page reads them when it takes a song.
        func flush() {
            guard ready, let wanted else { return }
            if sentOptions != wanted.options {
                sentOptions = wanted.options
                run("ivLyricsMotionHost.configure(\(wanted.options))")
            }
            if sentSong != wanted.songJSON {
                sentSong = wanted.songJSON
                run("ivLyricsMotionHost.setTrack(\(wanted.songJSON.isEmpty ? "null" : wanted.songJSON))")
            }
            run("ivLyricsMotionHost.setPlayback({position:\(Int64(wanted.positionMs.rounded())),playing:\(wanted.playing),rate:\(wanted.rate > 0 ? wanted.rate : 1)})")
        }

        func receive(_ body: Any) {
            guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                sentSong = nil
                sentOptions = nil
                flush()
            case "eligible":
                bridge?.eligible(message["uri"] as? String ?? "", message["value"] as? Bool ?? false)
            case "background":
                bridge?.background(MotionBackdropFrame(
                    rotate: number(message["rotate"], 0),
                    scale: number(message["scale"], 1),
                    x: number(message["x"], 0),
                    y: number(message["y"], 0)
                ))
            case "direct":
                answer(message) { bridge, prompt in try await bridge.direct(prompt) } key: { $0["prompt"] as? String }
            case "cacheGet":
                answer(message) { bridge, key in await bridge.cached(key) } key: { $0["key"] as? String }
            case "cacheSet":
                if let key = message["key"] as? String, let value = message["value"] as? String {
                    bridge?.store(key, value)
                }
            case "error":
                bridge?.log("motion lyrics page: \(message["message"] as? String ?? "error")")
            default:
                break
            }
        }

        private func answer(
            _ message: [String: Any],
            _ work: @escaping (Bridge, String) async throws -> String,
            key: ([String: Any]) -> String?
        ) {
            guard let id = (message["id"] as? NSNumber)?.intValue, let input = key(message), let bridge else { return }
            Task { @MainActor [weak self] in
                let result: [String: Any]
                do {
                    result = ["ok": true, "value": try await work(bridge, input)]
                } catch {
                    result = ["ok": false, "error": error.localizedDescription]
                }
                self?.run("ivLyricsMotionHost.resolve(\(id),\(Self.json(result)))")
            }
        }

        private func run(_ script: String) {
            webView?.evaluateJavaScript(script) { [weak self] _, error in
                if let error { self?.bridge?.log("motion lyrics page call failed: \(error.localizedDescription)") }
            }
        }

        private func number(_ value: Any?, _ fallback: Double) -> Double {
            (value as? NSNumber)?.doubleValue ?? fallback
        }

        private static func json(_ object: [String: Any]) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: object),
                  let text = String(data: data, encoding: .utf8) else { return "{}" }
            return text
        }
    }
}

// MARK: - The mode

struct MotionLyricsModeView: View {
    private static let sampleEpoch = Date(timeIntervalSinceReferenceDate: 0)
    /// The page keeps its own clock between reports.
    private static let positionSampleInterval: TimeInterval = 0.25
    private static let controlsHideDelay: TimeInterval = {
#if DEBUG
        // UI tests on a loaded runner cannot land two taps within three seconds.
        if let raw = ProcessInfo.processInfo.environment["IVLYRICS_DEBUG_MOTION_CONTROLS_S"],
           let seconds = TimeInterval(raw), seconds > 0 {
            return seconds
        }
#endif
        return 3
    }()
    /// The close button sits in the top trailing corner; the page keeps its small print clear of it.
    private static let closeButtonReserve: CGFloat = 52

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    @Binding var isPresented: Bool
    let camera: MotionBackdropCamera

    @State private var songJSON = ""
    @State private var accentHex = ""
    /// The track the page last judged, and its verdict.
    @State private var judgedURI = ""
    @State private var judgedPlayable = true
    @State private var controlsVisible = true
    @State private var controlsToken = UUID()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                TimelineView(.periodic(from: Self.sampleEpoch, by: Self.positionSampleInterval)) { _ in
                    MotionLyricsWebView(
                        songJSON: songJSON,
                        positionMs: model.motionLyricsPositionMs(),
                        playing: model.currentTrack?.playing ?? false,
                        rate: model.currentTrack?.playbackSpeed ?? 1,
                        labels: [
                            "directing": settings.t("motion.directing"),
                            "failed": settings.t("motion.direct_failed")
                        ],
                        aiAvailable: model.motionDirectionAvailable,
                        insets: pageInsets(proxy.safeAreaInsets),
                        bridge: bridge
                    )
                }
                .ignoresSafeArea()
                .accessibilityHidden(true)

                if showsUnavailableNotice {
                    Text(settings.t("motion.unavailable"))
                        .font(.pretendard(14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.46), in: Capsule())
                        .padding(.horizontal, 24)
                        .transition(.opacity)
                }

                closeButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 14)
                    .padding(.trailing, 16)
                    .opacity(controlsVisible ? 1 : 0)
                    .allowsHitTesting(controlsVisible)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contentShape(Rectangle())
        .onTapGesture { showControls() }
        .task(id: model.currentTrackKey) { await refreshAccent() }
        .onAppear {
            refreshSong()
            showControls()
            MotionLyricsOrientation.hold(true)
            // Nobody touches the screen while a song plays.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            MotionLyricsOrientation.hold(false)
            UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
            camera.frame = .identity
        }
        .onChange(of: model.lyricsResult) { _, _ in refreshSong() }
        .onChange(of: model.currentTrackKey) { _, _ in refreshSong() }
        .onChange(of: accentHex) { _, _ in refreshSong() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("motion.root")
    }

    private var closeButton: some View {
        Button {
            close()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.42), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(settings.t("button.close"))
        .accessibilityIdentifier("motion.close")
    }

    /// Only once the song's lyrics have loaded and the page has turned them down.
    private var showsUnavailableNotice: Bool {
        guard let track = model.currentTrack, !model.lyricsResult.lines.isEmpty else { return false }
        return judgedURI == MotionLyricsSong.uri(for: track) && !judgedPlayable
    }

    private func pageInsets(_ safeArea: EdgeInsets) -> EdgeInsets {
        var insets = safeArea
        insets.trailing += Self.closeButtonReserve
        return insets
    }

    private var bridge: MotionLyricsWebView.Bridge {
        MotionLyricsWebView.Bridge(
            direct: { prompt in try await model.requestMotionDirection(prompt: prompt) },
            cached: { key in await model.cachedMotionDirection(key) },
            store: { key, value in model.storeMotionDirection(key, value: value) },
            eligible: { uri, playable in
                withAnimation(.easeOut(duration: 0.2)) {
                    judgedURI = uri
                    judgedPlayable = playable
                }
            },
            background: { frame in
                if camera.frame != frame { camera.frame = frame }
            },
            log: { message in model.logMotionLyrics(message) }
        )
    }

    private func refreshSong() {
        songJSON = MotionLyricsSong.json(
            track: model.currentTrack,
            lyrics: model.lyricsResult,
            accentHex: accentHex,
            language: model.effectiveSelectedRuleSourceLang
        )
    }

    private func refreshAccent() async {
        guard let track = model.currentTrack else { return }
        let color = await VinylArtworkAccent.asset(for: track).color
        guard !Task.isCancelled else { return }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: nil) else { return }
        accentHex = String(
            format: "#%02x%02x%02x",
            Int((max(0, min(1, red)) * 255).rounded()),
            Int((max(0, min(1, green)) * 255).rounded()),
            Int((max(0, min(1, blue)) * 255).rounded())
        )
    }

    private func showControls() {
        let token = UUID()
        controlsToken = token
        withAnimation(.easeOut(duration: 0.18)) { controlsVisible = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.controlsHideDelay) {
            guard controlsToken == token else { return }
            withAnimation(.easeOut(duration: 0.4)) { controlsVisible = false }
        }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.26)) {
            isPresented = false
        }
    }
}
#endif
