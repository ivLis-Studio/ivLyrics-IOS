#!/usr/bin/env python3
"""Execute production PiP request/lifecycle methods against deterministic AVKit doubles.

These native Swift regressions cover policy and cleanup, not real-device PiP.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
source = (SRC / "LyricsPictureInPictureController.swift").read_text()
model = (SRC / "AppViewModel.swift").read_text()


def declaration(text, marker):
    start = text.index(marker)
    end = text.index("{", start) + 1
    depth = 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end].replace("private ", "")


# No lifecycle/track/audio path may authorize a request or prime auto inline PiP.
assert "canStartPictureInPictureAutomaticallyFromInline = false" in source
for removed in ["automaticTransition", "automaticPreparationEnabled", "prepareForAutomaticTransition", "StartReason"]:
    assert removed not in source + model, removed
assert source.count("startRequested = true") == 1
assert "startRequested = true" in declaration(source, "func start()")
update = declaration(source, "    func update(\n        track:")
assert "activateAudioSession()" not in update and "startPictureInPicture()" not in update
assert "guard isEngaged else { return }" in update
assert "activateAudioSession()" not in declaration(source, "override init()")
explicit = declaration(model, "func startLyricsPictureInPicture()")
assert explicit.index("updatePictureInPictureState(force: true)") < explicit.index("pictureInPictureController.start()")
assert "guard force ||" in declaration(model, "private func updatePictureInPictureState(")
for marker in ["func appWillResignActive()", "func appDidEnterBackground()", "func appDidBecomeActive()"]:
    lifecycle = declaration(model, marker)
    assert ".start()" not in lifecycle and "startLyricsPictureInPicture" not in lifecycle

prelude = r'''
import Foundation

final class Observation {
    var invalidated = false
    func invalidate() { invalidated = true }
}
@MainActor final class AVPictureInPictureController {
    static var supported = true
    static func isPictureInPictureSupported() -> Bool { supported }
    struct ContentSource {
        init(sampleBufferDisplayLayer: Int, playbackDelegate: AnyObject) {}
    }
    enum Option { case initial, new }
    weak var delegate: AnyObject?
    var canStartPictureInPictureAutomaticallyFromInline = true
    var requiresLinearPlayback = true
    var isPictureInPicturePossible = false { didSet { observer?(self, ()) } }
    var isPictureInPictureActive = false
    var starts = 0
    var stops = 0
    var observer: ((AVPictureInPictureController, Void) -> Void)?
    init(contentSource: ContentSource) {}
    func observe(_ key: KeyPath<AVPictureInPictureController, Bool>, options: [Option],
                 changeHandler: @escaping (AVPictureInPictureController, Void) -> Void) -> Observation {
        observer = changeHandler
        if options.contains(.initial) { changeHandler(self, ()) }
        return Observation()
    }
    func startPictureInPicture() { starts += 1 }
    func stopPictureInPicture() { stops += 1 }
}
protocol AVPictureInPictureControllerDelegate: AnyObject {}
@MainActor final class AVAudioSession {
    enum Category { case playback }
    enum Mode { case moviePlayback }
    enum Option { case mixWithOthers, notifyOthersOnDeactivation }
    static let session = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { session }
    var active = false
    var failActivation = false
    var activations = 0
    var releases = 0
    func setCategory(_ category: Category, mode: Mode, options: [Option]) throws {}
    func setActive(_ active: Bool, options: [Option] = []) throws {
        if active && failActivation { throw NSError(domain: "audio", code: 1) }
        self.active = active
        if active { activations += 1 } else { releases += 1 }
    }
}
struct Track { var durationMs: Int64 = 1000; var playing = true }
struct RenderState { var track: Track? = Track() }
@MainActor final class LyricsPictureInPictureController {
    var active = false
    var pictureInPictureController: AVPictureInPictureController?
    var possibleObservation: Observation?
    var displayLayer = 0
    var state = RenderState()
    var onLog: ((String) -> Void)?
    var onStartFailure: (() -> Void)?
    var onEngagementEnded: (() -> Void)?
    var renders = 0
    var lastRenderedDuration: Int64?
    func renderFrame() { renders += 1; lastRenderedDuration = state.track?.durationMs }
    func publishPlaybackState(durationMs: Int64, isPaused: Bool, force: Bool = false) {}
    init() { configurePictureInPictureController() }
'''
properties = ["startRetryTask", "startRequested", "startInFlight", "audioSessionActive"]
for name in properties:
    prelude += next(line for line in source.splitlines() if line.strip().startswith(f"private var {name}"))
    prelude = prelude.replace("private ", "") + "\n"
for marker in ["var isEngaged:", "var needsStateUpdates:", "private func configurePictureInPictureController()",
               "func start()", "private func scheduleStartRetries()", "func stop()",
               "private func finishEngagement(", "private func startIfPossible()",
               "private func activateAudioSession()", "private func deactivateAudioSession()"]:
    prelude += declaration(source, marker) + "\n"
prelude += "}\n" + declaration(source, "extension LyricsPictureInPictureController: AVPictureInPictureControllerDelegate")
prelude += r'''
@MainActor final class LifecycleProbe {
    let pictureInPictureController: LyricsPictureInPictureController
    var clockForeground = true
    var updates = 0
    var freshDuration: Int64 = 4321
    init(_ controller: LyricsPictureInPictureController) { pictureInPictureController = controller }
    func updatePictureInPictureState(force: Bool) {
        updates += 1
        if force { pictureInPictureController.state.track = Track(durationMs: freshDuration) }
    }
    func updatePlaybackClockMode(foregroundActive: Bool) { clockForeground = foregroundActive }
'''
prelude += declaration(model, "func appWillResignActive()") + "\n"
prelude += explicit + "\n}\n"
checks = r'''
@main struct PiPChecks {
    @MainActor static var count = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1
        precondition(condition(), message)
    }
    static func settle() async { try? await Task.sleep(nanoseconds: 20_000_000) }
    @MainActor static func waitForEngagementEnd(_ pip: LyricsPictureInPictureController) async {
        // Task.sleep supplies a minimum delay. Loaded CI runners can resume the
        // production retry task later than the sum of its nominal intervals.
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while pip.isEngaged && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    @MainActor static func main() async {
        let audio = AVAudioSession.sharedInstance()
        let pip = LyricsPictureInPictureController()
        let lifecycle = LifecycleProbe(pip)
        var failures = 0
        var ended = 0
        pip.onStartFailure = { failures += 1 }
        pip.onEngagementEnded = {
            ended += 1
            check(!pip.isEngaged && !audio.active, "Cleanup precedes the engagement-ended callback")
        }
        let initial = pip.pictureInPictureController!
        check(!initial.canStartPictureInPictureAutomaticallyFromInline, "AVKit auto inline entry is disabled")
        for _ in 0..<30 {
            initial.isPictureInPicturePossible.toggle()
            pip.startIfPossible()
            lifecycle.appWillResignActive()
        }
        await settle()
        check(initial.starts == 0 && audio.activations == 0 && !pip.needsStateUpdates,
              "Home/inactive/availability without a user request cannot start or activate PiP audio")
        check(lifecycle.updates == 0, "Inactive idle app never prepares PiP")

        initial.isPictureInPicturePossible = false
        check(lifecycle.startLyricsPictureInPicture(), "Manual action accepts a pending start")
        check(pip.lastRenderedDuration == lifecycle.freshDuration,
              "Explicit start force-refreshes state before rendering even when idle updates were disabled")
        check(pip.isEngaged && audio.active && initial.starts == 0, "Manual action waits for AVKit availability")
        initial.isPictureInPicturePossible = true
        await settle()
        check(initial.starts == 1, "Availability completes the explicit request")
        check(pip.start(), "Repeated manual action is idempotent")
        for _ in 0..<20 { pip.startIfPossible() }
        check(initial.starts == 1, "Do not send repeated starts while AVKit is starting")
        initial.isPictureInPictureActive = true
        pip.pictureInPictureControllerDidStartPictureInPicture(initial)
        await settle()
        check(pip.active && !pip.startRequested && !pip.startInFlight, "Successful manual start clears retry state")
        lifecycle.appWillResignActive()
        check(pip.active && initial.starts == 1 && lifecycle.updates == 2, "Manual PiP survives lifecycle changes")
        var restored = false
        pip.pictureInPictureController(initial, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { restored = $0 })
        check(restored, "Manual return-to-app restoration remains supported")
        pip.stop()
        check(initial.stops == 1, "Explicit close asks AVKit to stop")
        initial.isPictureInPictureActive = false
        pip.pictureInPictureControllerDidStopPictureInPicture(initial)
        await settle()
        check(!pip.isEngaged && !audio.active && pip.startRetryTask == nil && ended == 1, "Stopped PiP releases audio and background engagement")

        initial.isPictureInPicturePossible = false
        check(pip.start(), "Manual restart after stop works")
        pip.stop()
        initial.isPictureInPicturePossible = true
        await settle()
        check(initial.starts == 1 && failures == 0 && ended == 2, "Cancel before availability cannot be revived by KVO")

        check(pip.start(), "Manual start before cancellation")
        check(initial.starts == 2, "New manual action starts again")
        pip.stop()
        let replacement = pip.pictureInPictureController!
        check(replacement !== initial && !pip.isEngaged && !audio.active, "Cancel in flight retires the old controller")
        check(!replacement.canStartPictureInPictureAutomaticallyFromInline, "Replacement also disables auto inline entry")
        replacement.isPictureInPicturePossible = true
        check(pip.start(), "A fresh manual request works after cancellation")
        initial.isPictureInPictureActive = true
        pip.pictureInPictureControllerDidStartPictureInPicture(initial)
        pip.pictureInPictureControllerDidStopPictureInPicture(initial)
        pip.pictureInPictureController(initial, failedToStartPictureInPictureWithError: NSError(domain: "late", code: 1))
        await settle()
        check(!pip.active && pip.startRequested && replacement.starts == 1 && initial.stops >= 2,
              "Late old callbacks cannot consume a new request or reopen cancelled PiP")
        pip.pictureInPictureController(replacement, failedToStartPictureInPictureWithError: NSError(domain: "avkit", code: 1))
        await settle()
        check(failures == 1 && !pip.isEngaged && !audio.active && pip.startRetryTask == nil,
              "AVKit failure reports once and cleans audio, retries and engagement")

        audio.failActivation = true
        check(!pip.start() && !pip.isEngaged && !audio.active, "Audio activation failure does not leave a pending start")
        audio.failActivation = false
        AVPictureInPictureController.supported = false
        check(!pip.start() && !audio.active, "Unsupported PiP stays idle")
        AVPictureInPictureController.supported = true

        let unavailable = pip.pictureInPictureController!
        check(pip.start(), "Explicit unavailable request can wait")
        await waitForEngagementEnd(pip)
        check(!pip.isEngaged && !audio.active && failures == 2 && unavailable.starts == 0,
              "Availability timeout cleans up and reports the manual failure")
        unavailable.isPictureInPicturePossible = true
        await settle()
        check(unavailable.starts == 0, "Late availability after timeout is not authorization")

        check(pip.start(), "Retry after availability timeout works")
        await waitForEngagementEnd(pip)
        let afterTimeout = pip.pictureInPictureController!
        check(unavailable.starts == 1 && afterTimeout !== unavailable && failures == 3 && !audio.active,
              "In-flight timeout sends one start and retires the stuck controller")
        unavailable.isPictureInPictureActive = true
        pip.pictureInPictureControllerDidStartPictureInPicture(unavailable)
        await settle()
        check(!pip.isEngaged && unavailable.stops >= 2, "Late start after timeout is stopped")
        afterTimeout.isPictureInPicturePossible = true
        check(pip.start(), "Manual start still works after a stuck start")
        afterTimeout.isPictureInPictureActive = true
        pip.pictureInPictureControllerDidStartPictureInPicture(afterTimeout)
        await settle()
        check(pip.active && audio.active, "New manual session can run")
        pip.stop()
        afterTimeout.isPictureInPictureActive = false
        pip.pictureInPictureControllerDidStopPictureInPicture(afterTimeout)
        await settle()
        check(!pip.isEngaged && !audio.active && failures == 3, "Final close never emits a start failure")
        check(pip.start(), "Start before AVKit's active notification race")
        afterTimeout.isPictureInPictureActive = true
        pip.stop()
        pip.pictureInPictureControllerDidStartPictureInPicture(afterTimeout)
        await settle()
        check(!pip.isEngaged && !audio.active && pip.pictureInPictureController !== afterTimeout,
              "Closing between AVKit activation and didStart cannot revive the session")
        print("PiP lifecycle: \(count) native checks passed (AVKit doubles; physical-device verification still required)")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-pip-lifecycle-") as directory:
    work = Path(directory)
    swift = work / "PiPChecks.swift"
    swift.write_text(prelude + checks)
    executable = work / "checks"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", str(swift), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=60)
