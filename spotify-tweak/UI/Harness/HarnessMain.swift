import UIKit

private var recordedSeek: Int64 = -1
private func receiveSeek(_ value: Int64) { recordedSeek = value }

private actor FixtureProvider {
    var calls: [String] = []
    private var pending: CheckedContinuation<Void, Never>?
    func load(_ track: TrackSnapshot) async throws -> LyricsResult? {
        calls.append(track.title)
        if track.title == "Slow" { await withCheckedContinuation { pending = $0 } }
        if track.title == "Empty" { return nil }
        let words = ["A quiet moment", "The city wakes", "We follow the morning light", "One step at a time",
                     "Across the open sky", "Every color comes alive", "Keep this feeling close", "The road is ours tonight"]
        let lines = (0..<24).map { index in
            LyricsLine(startTimeMs: Int64(index * 2500), endTimeMs: Int64((index + 1) * 2500),
                       text: words[index % words.count], syllables: [
                        .init(text: words[index % words.count], startTimeMs: Int64(index * 2500), endTimeMs: Int64((index + 1) * 2500))])
        }
        return LyricsResult(lines: lines, providerLabel: "Offline fixture", detail: "Synthetic lyrics for UI testing",
                            karaoke: true, providerId: "fixture", syncType: "word")
    }
    func release() { pending?.resume(); pending = nil }
}

@main
@MainActor final class IVLUIHarnessApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var retainedOwner: IVLyricsSpotifyUI?
    private var failures: [String] = []
    private var checks = 0

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let controller = UIViewController()
        controller.view.backgroundColor = .black
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        Task { await run(controller) }
        return true
    }

    private func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value { failures.append(message); NSLog("[UI fixture] FAIL: %@", message) }
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !(await condition()) {
            if ProcessInfo.processInfo.systemUptime >= deadline { throw NSError(domain: "Fixture timeout", code: 1) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    private func state(_ title: String, position: Int64 = 0, playing: Bool = false) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["title": title, "artist": "ivLyrics UI fixture",
            "album": "Synthetic host", "durationMs": 60000, "positionMs": position, "playing": playing, "speed": 1])
        return String(decoding: data, as: UTF8.self)
    }
    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    private func finish(_ root: URL) {
        let data = try! JSONSerialization.data(withJSONObject: ["checks": checks, "failures": failures,
            "spotify_runtime_tested": false, "network_used": false], options: [.prettyPrinted, .sortedKeys])
        try? data.write(to: root.appendingPathComponent("ui-checks.json"), options: .atomic)
    }
    private func run(_ controller: UIViewController) async {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let storage = root.appendingPathComponent(UUID().uuidString)
        let fixture = FixtureProvider()
        let loader = IVLCoreLoader(storageDirectory: storage, fetchLyrics: { try await fixture.load($0) })
        let owner = IVLyricsSpotifyUI(loader: loader)
        retainedOwner = owner
        let cardHost = UIView(); let fullHost = UIView()
        let native = UILabel(); native.text = "Synthetic native lyrics"; native.textColor = .white
        let fullNative = UIView()
        cardHost.addSubview(native)
        fullHost.addSubview(fullNative)
        [cardHost, fullHost].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; controller.view.addSubview($0) }
        NSLayoutConstraint.activate([
            cardHost.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 16),
            cardHost.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -16),
            cardHost.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor, constant: 8),
            cardHost.heightAnchor.constraint(equalToConstant: 250),
            fullHost.topAnchor.constraint(equalTo: cardHost.bottomAnchor, constant: 16),
            fullHost.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            fullHost.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            fullHost.bottomAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.bottomAnchor)
        ])
        do {
            owner.attachCardToView(cardHost)
            owner.attachCardToView(cardHost)
            owner.attachFullscreenToView(fullHost)
            let card = cardHost.subviews.compactMap { $0 as? IVLLyricsSurface }.first!
            let full = fullHost.subviews.compactMap { $0 as? IVLLyricsSurface }.first!
            controller.view.layoutIfNeeded()
            check(cardHost.subviews.filter { $0 is IVLLyricsSurface }.count == 1, "Repeated attachment is idempotent")
            check(card.isHidden && !native.isHidden, "No-track state leaves native content untouched")
            check(card.accessibilityIdentifier?.hasPrefix("ivlyrics.spotify.") == true, "Host can identify its module child")
            var readyEvents: [Bool] = []
            owner.onReadyChanged = { readyEvents.append($0) }
            owner.updateStateJSON(state("Morning light"))
            try await wait { owner.hasTrackAndLyrics }
            controller.view.layoutIfNeeded()
            check(!card.isHidden && !full.isHidden, "Both attached surfaces show lyrics")
            check(!native.isHidden, "Module never hides native views")
            check(full.table.numberOfRows(inSection: 0) == 24, "Original model rows render in the table")
            check(full.table.visibleCells.count > 0, "UIKit lays out visible lyric cells")
            check(card.bounds.size == cardHost.bounds.size, "Card fills host bounds")
            owner.updateStateJSON(state("Morning light", position: 17500))
            full.updatePlayback(); controller.view.layoutIfNeeded()
            check(full.activeIndex == 7, "Line activation uses playback position")
            try await wait { full.table.contentOffset.y > 0 }
            check(full.table.contentOffset.y > 0, "Active lyric auto-scrolls into view")
            owner.seekHandler = receiveSeek
            full.tableView(full.table, didSelectRowAt: IndexPath(row: 3, section: 0))
            check(recordedSeek == 7500, "Row tap invokes seek callback in milliseconds")
            full.tableView(full.table, didSelectRowAt: IndexPath(row: 1000, section: 0))
            check(recordedSeek == 7500, "Stale row selection is ignored safely")
            check(full.clockRunning, "Mounted surface runs its playback clock")
            owner.detachFromView(fullHost)
            check(!full.clockRunning, "Detached surface stops its clock")
            check(fullHost.subviews.count == 1 && fullNative.superview === fullHost,
                  "Host detach removes only this module's own surface")
            owner.attachFullscreenToView(fullHost)

            owner.updateStateJSON(state("Slow"))
            try await wait { await fixture.calls.contains("Slow") }
            owner.updateStateJSON(state("Second song"))
            try await wait { owner.hasTrackAndLyrics }
            await fixture.release()
            try await Task.sleep(nanoseconds: 40_000_000)
            check(owner.track?.title == "Second song", "Late provider cannot restore the previous track")

            let file = root.appendingPathComponent("fixture.lrc")
            try Data("[00:01]Imported first line\n[00:03]Imported second line".utf8).write(to: file)
            let captured = owner.track!
            owner.chooseFile(from: controller)
            try await wait { controller.presentedViewController is UIDocumentPickerViewController }
            let picker = controller.presentedViewController as! UIDocumentPickerViewController
            try await wait { picker.view.window != nil && !picker.isBeingPresented }
            check(!picker.allowsMultipleSelection, "Real document picker allows one LRC/TXT file")
            owner.updateStateJSON(state("Third song"))
            try await wait { owner.hasTrackAndLyrics }
            owner.documentPicker(picker, didPickDocumentsAt: [file])
            await withCheckedContinuation { continuation in
                controller.dismiss(animated: false) { continuation.resume() }
            }
            try await wait { (try? await loader.load(track: IVLyricsSpotifyUI.coreTrack(captured)))?.providerID == "local" }
            check(owner.track?.title == "Third song" && owner.result?.providerId == "fixture", "Picker completion saves to captured song without replacing current lyrics")
            owner.updateStateJSON(state("Second song"))
            try await wait { owner.result?.providerId == "local" }
            check(owner.result?.lines.first?.text == "Imported first line", "Imported original LRC parser result displays")
            let invalidFile = root.appendingPathComponent("invalid.lrc")
            try Data().write(to: invalidFile)
            owner.importFile(invalidFile, for: captured)
            try await wait { !owner.loading }
            check(owner.result?.lines.first?.text == "Imported first line", "Failed import preserves the existing lyrics")
            let captions = descendants(card).compactMap { $0 as? UILabel }
                .filter { $0.accessibilityIdentifier == "ivlyrics.provider" }
            check(captions.first?.text == IVLUIText.importFailed && !card.isHidden,
                  "Failed import remains visible in the caption while old lyrics stay on screen")
            let restarted = IVLCoreLoader(storageDirectory: storage)
            check(try await restarted.load(track: IVLyricsSpotifyUI.coreTrack(captured))?.providerID == "local", "Local override persists across loader recreation")
            owner.importFile(file, for: captured)
            owner.removeLocal(for: captured)
            try await wait { owner.hasTrackAndLyrics && owner.result?.providerId == "fixture" }
            check(try await restarted.load(track: IVLyricsSpotifyUI.coreTrack(captured)) == nil, "Removal prevents a queued import from resurrecting local lyrics")
            check(owner.result?.providerId == "fixture", "Removal restores provider lyrics")

            owner.updateStateJSON(state("Empty"))
            try await wait { !owner.loading }
            check(!owner.hasTrackAndLyrics && card.isHidden, "No result restores native fallback readiness")
            owner.presentFromViewController(controller)
            try await wait { controller.presentedViewController is UINavigationController }
            check(controller.presentedViewController is UINavigationController, "Explicit screen remains available for importing without lyrics")
            await withCheckedContinuation { continuation in
                controller.dismiss(animated: false) { continuation.resume() }
            }
            owner.updateStateJSON(state("Morning light", position: 5000))
            try await wait { owner.hasTrackAndLyrics }
            owner.updateStateJSON("{invalid}")
            check(!owner.hasTrackAndLyrics && owner.track == nil, "Malformed host state clears stale content")
            owner.updateStateJSON(state("Morning light", position: 7500))
            try await wait { owner.hasTrackAndLyrics }
            owner.hostDisconnected()
            check(!owner.hasTrackAndLyrics && card.isHidden, "Host disconnect cancels and hides module content")
            check(readyEvents.contains(true) && readyEvents.last == false, "Readiness callback publishes fallback transitions")

            // Leave a deterministic, paused view for simctl screenshot review.
            owner.updateStateJSON(state("Morning light", position: 7500))
            try await wait { owner.hasTrackAndLyrics }
            controller.view.layoutIfNeeded()
            check(failures.isEmpty, "All UI behavior assertions passed")
        } catch { failures.append("Unexpected fixture failure: \(error)") }
        finish(root)
    }
}
