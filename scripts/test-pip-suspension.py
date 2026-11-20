#!/usr/bin/env python3
"""Run the PiP background-suspension queue with production timeline and controller code.

iOS can suspend the app while its PiP window stays open, which froze the window on one line.
These native checks drive the production change list and suspension state machine against
UIKit/AVKit doubles. Whether a suspended app's layer presents the queued frames still needs an
iPhone.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
source = (SRC / "LyricsPictureInPictureController.swift").read_text()
model = (SRC / "AppViewModel.swift").read_text()
models = (SRC / "Models.swift").read_text()


def section(text, start, end):
    first = text.index(start)
    return text[first:text.index(end, first + len(start))]


def declaration(text, marker):
    start = text.index(marker)
    end = text.index("{", start) + 1
    depth = 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end].replace("private ", "")


# Wiring: lifecycle hooks, cleanup, and no keep-alive audio.
background = declaration(model, "func appDidEnterBackground()")
assert background.index("pictureInPictureController.applicationDidEnterBackground()") < background.index("guard spotifyLivePolling")
assert "pictureInPictureController.applicationDidBecomeActive()" in declaration(model, "func appDidBecomeActive()")
assert "endSuspensionHandling()" in declaration(source, "private func finishEngagement(")
render = declaration(source, "private func renderFrame()")
assert render.index("discardSuspensionSchedule()") < render.index("displayLayer.enqueue(")
for forbidden in ["AVAudioPlayer", "AVAudioEngine", "silence", "silent"]:
    assert forbidden not in source, forbidden
assert "canStartPictureInPictureAutomaticallyFromInline = false" in source
assert "lyricsTimeline.changes(from:" in declaration(source, "private func queueSuspensionFrames()")

timeline = section(models, "enum InstrumentalBreakMarker {", "struct TrackSnapshot:")
timeline += section(models, "struct LyricsLine:", "enum LyricsTextShaping {")
timeline += (SRC / "PictureInPictureLyricsTimeline.swift").read_text()
timeline += (SRC / "CulturalAnnotation.swift").read_text()

prelude = r'''
import Foundation
import CoreMedia
extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
enum AppSettings {
    static let karaokeDisplayLine = "line"
    static func normalizeKaraokeDisplayGranularity(_ value: String) -> String { value }
}
enum Clock { static var now: TimeInterval = 1_000 }
struct UIBackgroundTaskIdentifier: Equatable {
    var raw: Int
    static let invalid = UIBackgroundTaskIdentifier(raw: 0)
}
@MainActor final class UIApplication {
    enum State { case active, inactive, background }
    static let shared = UIApplication()
    var applicationState = State.active
    var backgroundTimeRemaining: TimeInterval = 30
    var grantsTasks = true
    var begun = 0
    var nextTask = 1
    var tasks: [Int: @MainActor @Sendable () -> Void] = [:]
    func beginBackgroundTask(withName name: String?,
                             expirationHandler: (@MainActor @Sendable () -> Void)?) -> UIBackgroundTaskIdentifier {
        guard grantsTasks else { return .invalid }
        begun += 1
        defer { nextTask += 1 }
        tasks[nextTask] = expirationHandler ?? {}
        return UIBackgroundTaskIdentifier(raw: nextTask)
    }
    func endBackgroundTask(_ task: UIBackgroundTaskIdentifier) { tasks[task.raw] = nil }
    func expire() { for handler in Array(tasks.values) { handler() } }
}
struct FakeSample {
    var pts: Double
    var immediate: Bool
    var positionMs: Int64
    var granularity: String
    var synthetic: Bool
    var activeIndex: Int?
}
@MainActor final class FakeLayer {
    enum Status { case rendering, failed }
    var status = Status.rendering
    var requiresFlushToResumeDecoding = false
    var controlTimebase: CMTimebase?
    var pending: [FakeSample] = []
    var flushes = 0
    func flush() { flushes += 1; pending.removeAll() }
    func enqueue(_ sample: FakeSample) { pending.append(sample) }
}
struct Track { var stableKey = "track-a"; var playing = true; var durationMs: Int64 = 200_000 }
struct State {
    var track: Track? = Track()
    var positionMs: Int64 = 0
    var karaokeDisplayGranularity = "character"
    var syncedLyricsKaraokeAnimationEnabled = true
    var selection = PictureInPictureLyricsTimeline.Selection.empty
}
@MainActor final class Controller {
    var isEngaged = true
    let displayLayer = FakeLayer()
    var state = State()
    let lyricsTimeline = PictureInPictureLyricsTimeline()
    var lastRenderUptime: TimeInterval = 0
    var lastRenderedPositionMs: Int64?
    var logs: [String] = []
    var onLog: ((String) -> Void)?
    var frames = 0
    init() { onLog = { [weak self] in self?.logs.append($0) } }
    func makeFrameSampleBuffer(presentationTime: CMTime, displayImmediately: Bool) -> FakeSample? {
        frames += 1
        return FakeSample(pts: CMTimeGetSeconds(presentationTime), immediate: displayImmediately,
                          positionMs: state.positionMs, granularity: state.karaokeDisplayGranularity,
                          synthetic: state.syncedLyricsKaraokeAnimationEnabled, activeIndex: state.selection.activeIndex)
    }
'''
members = declaration(source, "private struct SuspensionSchedule {") + "\n"
for line in source.splitlines():
    stripped = line.strip()
    if stripped.startswith("private static let suspension") or any(
        stripped.startswith(f"private var {name}") for name in
        ["suspension", "lastSuspensionCheckUptime", "lastEngagedUpdateUptime", "stateUptime"]
    ):
        members += stripped.replace("private ", "") + "\n"
for marker in ["func applicationDidEnterBackground()", "func applicationDidBecomeActive()",
               "private func endSuspensionHandling()", "private func beginSuspensionTask()",
               "private func endSuspensionTask()", "private func suspensionScheduleCoversPlayback(",
               "private func queueSuspensionFrames()", "private func discardSuspensionSchedule()",
               "private func ensureControlTimebase()", "private func renderFrame()"]:
    members += declaration(source, marker) + "\n"
update_tail = section(source, "        let updateGap = uptime - lastEngagedUpdateUptime",
                      "        let elapsed = uptime - lastRenderUptime")
assert "suspensionScheduleCoversPlayback(uptime: uptime, updateGap: updateGap) { return }" in update_tail
assert "guard isEngaged else { return }\n        let uptime = ProcessInfo.processInfo.systemUptime\n" + update_tail in source
members += r'''
    /// Mirrors the production update tail: the suspension check, then a live frame.
    func tick(_ positionMs: Int64, at uptime: TimeInterval) -> Bool {
        Clock.now = uptime
        state.positionMs = positionMs
        state.selection = lyricsTimeline.selection(at: positionMs)
        guard isEngaged else { return false }
''' + update_tail.replace("{ return }", "{ return false }") + r'''
        renderFrame()
        return true
    }
}
'''
members = members.replace("ProcessInfo.processInfo.systemUptime", "Clock.now")

checks = r'''
@main struct SuspensionChecks {
    @MainActor static var count = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1
        precondition(condition(), message)
    }
    static func line(_ start: Int64, _ end: Int64, _ text: String) -> LyricsLine {
        LyricsLine(startTimeMs: start, endTimeMs: end, text: text,
                   syllables: [.init(text: text, startTimeMs: start, endTimeMs: end)])
    }
    @MainActor static func main() {
        // 30 lines of 4s with 0.5s gaps from 10s, and a duet whose second voice enters mid-line.
        var lines = (0..<30).map { index -> LyricsLine in
            let start = Int64(10_000 + index * 4_500)
            return line(start, start + 4_000, "line \(index)")
        }
        let lead = LyricsLine.VocalPart(id: "lead", role: "lead", speaker: "v1", kind: "",
                                        text: "lead", syllables: [.init(text: "lead", startTimeMs: 150_000, endTimeMs: 154_000)])
        let duet = LyricsLine.VocalPart(id: "duet", role: "duet", speaker: "v2", kind: "",
                                        text: "duet", syllables: [.init(text: "duet", startTimeMs: 152_000, endTimeMs: 154_000)])
        lines.append(LyricsLine(startTimeMs: 150_000, endTimeMs: 154_000, text: "lead duet", vocalParts: [lead, duet]))

        // Upcoming changes: the current selection first, then each visible change in order.
        let timeline = PictureInPictureLyricsTimeline()
        timeline.update(lines: lines)
        let revision = timeline.revision
        timeline.update(lines: lines)
        check(timeline.revision == revision, "Unchanged lines keep the revision")
        let changes = timeline.changes(from: 12_000, through: 160_000, limit: 100)
        check(changes.first?.positionMs == 12_000 && changes.first?.selection.activeIndex == 0, "Current selection leads")
        check(zip(changes, changes.dropFirst()).allSatisfy { $0.positionMs < $1.positionMs }, "Changes are in time order")
        check(changes.dropFirst().allSatisfy { $0.positionMs > 12_000 && $0.positionMs <= 160_000 }, "Changes stay in range")
        for index in 1..<30 {
            let start = Int64(10_000 + index * 4_500)
            check(changes.contains { $0.positionMs == start && $0.selection.activeIndex == index }, "Line \(index) start is queued")
        }
        check(!changes.contains { $0.positionMs == 14_000 }, "A line end that shows nothing new is skipped")
        check(changes.contains { $0.positionMs == 150_000 && $0.selection.activeIndex == 30 }, "Duet line start")
        check(changes.contains { $0.positionMs == 152_000 && $0.selection.activeIndex == 30 }, "Second voice entry")
        check(timeline.changes(from: 12_000, through: 160_000, limit: 4).count == 4, "Limit counts the current frame")
        check(timeline.changes(from: 12_000, through: 20_000, limit: 100).map(\.positionMs) == [12_000, 14_500, 19_000],
              "Changes stop at the horizon")
        check(timeline.changes(from: 12_000, through: 20_000, limit: 0).isEmpty, "No frames for a zero limit")
        let empty = PictureInPictureLyricsTimeline()
        check(empty.changes(from: 5_000, through: 60_000, limit: 10).count == 1, "Without lyrics only the current frame")
        timeline.update(lines: Array(lines.dropLast()))
        check(timeline.revision == revision &+ 1, "Changed lines advance the revision")

        // Foreground: live frames, no background work.
        let app = UIApplication.shared
        let pip = Controller()
        pip.lyricsTimeline.update(lines: lines)
        var now: TimeInterval = 1_000
        var position: Int64 = 20_000
        func step(_ seconds: TimeInterval = 1.0 / 30) -> Bool {
            now += seconds
            position += Int64((seconds * 1_000).rounded())
            return pip.tick(position, at: now)
        }
        check(step() && app.begun == 0, "Foreground renders live without a background task")

        // Background with time left: live frames continue under a background task.
        app.applicationState = .background
        pip.applicationDidEnterBackground()
        check(app.begun == 1 && app.tasks.count == 1 && pip.suspensionSchedule == nil, "Entering background begins one task")
        for _ in 0..<60 { check(step(), "Live frames while background time remains") }

        // Nearly out of background time: queue the upcoming lines and release the task.
        app.backgroundTimeRemaining = 5
        var framesBefore = pip.frames
        var rendered = true
        for _ in 0..<40 where rendered {
            framesBefore = pip.frames
            rendered = step()
        }
        check(!rendered && pip.suspensionSchedule != nil && app.tasks.isEmpty, "Queued before suspension; task ended")
        let queued = pip.displayLayer.pending
        let anchor = pip.suspensionSchedule!.anchorPositionMs
        check(queued.count == min(32, pip.lyricsTimeline.changes(from: anchor, through: 200_000, limit: 32).count),
              "One frame per upcoming change")
        check(pip.frames - framesBefore == queued.count, "Queue draws each frame once")
        check(queued.first!.immediate && queued.dropFirst().allSatisfy { !$0.immediate }, "Only the current frame is immediate")
        check(queued.allSatisfy { $0.granularity == "line" && !$0.synthetic }, "Queued lines are drawn whole")
        check(queued.allSatisfy { abs(($0.pts - queued[0].pts) * 1_000 - Double($0.positionMs - anchor)) < 1 },
              "Each frame is timed to its lyric change")
        check(pip.state.karaokeDisplayGranularity == "character" && pip.state.syncedLyricsKaraokeAnimationEnabled
                && pip.state.positionMs == position, "Live render state is restored")
        check(pip.displayLayer.controlTimebase != nil, "The layer presents against a host-time timebase")
        check(pip.logs.contains { $0.contains("queued \(queued.count) lyric frames") }, "Queue is logged")

        // Still running shortly after: the queue stays; no live frame is put behind it.
        let flushes = pip.displayLayer.flushes
        for _ in 0..<60 { check(!step(), "Queue covers playback while it matches") }
        check(pip.displayLayer.flushes == flushes && pip.displayLayer.pending.count == queued.count, "Queue untouched")

        // Suspended for 25s, then woken in the background: the queue still matches.
        check(!step(25), "Queue survives a suspension gap")
        check(pip.suspensionSchedule!.resumedAfterGap, "The gap is recorded")
        for _ in 0..<400 { check(!step(), "After a real suspension the queue keeps covering") }

        // A seek while woken: live frames take over and a new task prepares the next suspension.
        position += 30_000
        let begunBeforeSeek = app.begun
        check(step(), "A seek renders live")
        check(pip.suspensionSchedule == nil && pip.displayLayer.pending.count == 1 && pip.displayLayer.pending[0].immediate,
              "The queue is discarded before the live frame")
        check(app.begun == begunBeforeSeek + 1 && app.tasks.count == 1, "A new task is begun")

        // The expiration handler queues as a fallback.
        app.backgroundTimeRemaining = 30
        _ = step()
        app.expire()
        check(pip.suspensionSchedule != nil && app.tasks.isEmpty, "Expiration queues frames and ends the task")

        // A live frame from another caller (artwork, PiP resize) drops the queue first.
        pip.renderFrame()
        check(pip.suspensionSchedule == nil && pip.displayLayer.pending.count == 1, "Other live renders discard the queue")
        app.backgroundTimeRemaining = 3
        for _ in 0..<40 { _ = step() }
        check(pip.suspensionSchedule != nil, "Queue rebuilt without a task once time is short")

        // Track change while woken: live frames.
        pip.state.track?.stableKey = "track-b"
        check(step(), "A new track renders live")
        check(pip.suspensionSchedule == nil, "Queue discarded for the new track")

        // Back in the app: everything is released.
        app.applicationState = .active
        pip.applicationDidBecomeActive()
        check(!pip.suspensionArmed && app.tasks.isEmpty && pip.suspensionSchedule == nil, "Foreground releases the queue and task")
        check(step(), "Foreground renders live")

        // iOS keeps the app running after the queue: return to live frames for this stay.
        app.applicationState = .background
        app.backgroundTimeRemaining = 30
        pip.applicationDidEnterBackground()
        app.backgroundTimeRemaining = 4
        var liveAgain = false
        for _ in 0..<(30 * 12) where !liveAgain {
            let wasQueued = pip.suspensionSchedule != nil
            liveAgain = step() && wasQueued
        }
        check(liveAgain && !pip.suspensionArmed && pip.suspensionSchedule == nil, "Kept alive: live frames resume")
        let framesAfterLive = pip.frames
        for _ in 0..<90 { check(step(), "Live for the rest of the stay") }
        check(pip.frames == framesAfterLive + 90, "No more queues in this stay")
        app.applicationState = .active
        pip.applicationDidBecomeActive()

        // No background time at all: queue on entering background.
        app.applicationState = .background
        app.grantsTasks = false
        pip.applicationDidEnterBackground()
        check(pip.suspensionSchedule != nil && app.tasks.isEmpty, "Queued at once without background time")
        app.applicationState = .active
        pip.applicationDidBecomeActive()

        // Paused playback has nothing to queue and stays cheap.
        pip.state.track?.playing = false
        app.applicationState = .background
        pip.applicationDidEnterBackground()
        check(pip.suspensionSchedule == nil, "Paused playback queues nothing")
        let pausedFrames = pip.frames
        for _ in 0..<90 { _ = step() }
        check(pip.frames - pausedFrames <= 90, "Paused ticks draw at most one frame each")
        app.applicationState = .active
        pip.applicationDidBecomeActive()
        app.grantsTasks = true
        pip.state.track?.playing = true

        // Without PiP nothing is prepared.
        pip.isEngaged = false
        app.applicationState = .background
        let begunIdle = app.begun
        pip.applicationDidEnterBackground()
        check(app.begun == begunIdle && !pip.suspensionArmed, "No PiP, no background task")
        print("PiP suspension: \(count) native checks passed (UIKit/AVKit doubles; iPhone verification still required)")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-pip-suspension-") as directory:
    work = Path(directory)
    swift = work / "SuspensionChecks.swift"
    swift.write_text(prelude + members + timeline + checks)
    executable = work / "checks"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", str(swift), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=60)

