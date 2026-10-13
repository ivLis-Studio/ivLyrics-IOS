#if DEBUG
import Foundation
import QuartzCore
#if os(iOS)
import UIKit
#endif

/// DEBUG-only timed karaoke track for simulator QA, where Spotify cannot play.
/// IVLYRICS_DEBUG_FIXTURE=1 loads it through the real model, display clock and renderers.
/// IVLYRICS_DEBUG_FIXTURE_START_MS selects the segment; IVLYRICS_DEBUG_FIXTURE_PAUSED=1 freezes it.
/// IVLYRICS_DEBUG_FIXTURE_TITLE replaces the title (a long one exercises the main-page marquee).
/// IVLYRICS_DEBUG_FIXTURE_FROZEN=1 keeps the position fixed while playing (static engaged vinyl).
/// IVLYRICS_DEBUG_FIXTURE_PAUSE_AFTER_S / _PLAY_AFTER_S toggle playback after a delay, and
/// IVLYRICS_DEBUG_FIXTURE_NEXT_TRACK_AFTER_S switches to a second fixture track.
enum DebugKaraokeFixture {
    static let title = "ivLyrics Motion Fixture"
    static let artist = "ivLyrics QA"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["IVLYRICS_DEBUG_FIXTURE"] == "1"
    }

    private struct Phrase {
        var text: String
        var translation: String
        var pronunciation: String = ""
    }

    // Original text written for this fixture; translations exercise the supplement rows.
    private static let phrases: [Phrase] = [
        Phrase(text: "Morning light is spilling on the floor", translation: "아침 햇살이 바닥 위로 쏟아져"),
        Phrase(text: "I can hear the city waking up", translation: "도시가 깨어나는 소리가 들려"),
        Phrase(text: "Every window humming its own song", translation: "창문마다 저마다의 노래를 흥얼거려"),
        Phrase(text: "너의 목소리가 들려", translation: "I can hear your voice", pronunciation: "neoui moksoriga deullyeo"),
        Phrase(text: "Hold the moment, do not let it go", translation: "이 순간을 붙잡아, 놓치지 마"),
        Phrase(text: "Paper planes are drifting through the rain", translation: "종이비행기가 빗속을 떠다녀"),
        Phrase(text: "Counting echoes of a distant train", translation: "멀리 떠나는 기차의 메아리를 세어"),
        Phrase(text: "Slow, slow, slowly", translation: "천천히, 천천히, 아주 천천히"),
        Phrase(text: "우리 함께 걸어가", translation: "Let us walk together", pronunciation: "uri hamkke georeoga"),
        Phrase(text: "Every heartbeat keeps the rhythm true", translation: "모든 심장 박동이 리듬을 지켜"),
        Phrase(text: "Go", translation: "가"),
        Phrase(text: "Run", translation: "달려"),
        Phrase(text: "Now", translation: "지금"),
        Phrase(text: "Jump", translation: "뛰어"),
        Phrase(text: "Higher", translation: "더 높이"),
        Phrase(text: "Faster", translation: "더 빨리"),
        Phrase(text: "Louder", translation: "더 크게"),
        Phrase(text: "Shine", translation: "빛나"),
        Phrase(text: "Starlight dancing on the silver sea", translation: "은빛 바다 위에서 춤추는 별빛"),
        Phrase(text: "Whisper softly what you want to be", translation: "되고 싶은 것을 조용히 속삭여"),
        Phrase(text: "Ooooh", translation: "오"),
        Phrase(text: "Golden hours fading into blue", translation: "황금빛 시간이 푸르게 저물어"),
        Phrase(text: "Every road will lead me back to you", translation: "모든 길은 결국 너에게로 이어져"),
        Phrase(text: "별처럼 빛나는 밤", translation: "A night that shines like stars", pronunciation: "byeolcheoreom binnaneun bam"),
        Phrase(text: "Lanterns rising over quiet streets", translation: "조용한 거리 위로 떠오르는 등불"),
        Phrase(text: "Footsteps tapping out a gentle beat", translation: "발걸음이 부드러운 박자를 두드려"),
        Phrase(text: "Stay", translation: "머물러"),
        Phrase(text: "Stay with me tonight", translation: "오늘 밤 내 곁에 있어 줘"),
        Phrase(text: "Hear the river singing to the shore", translation: "강물이 기슭에 부르는 노래를 들어"),
        Phrase(text: "Open every door", translation: "모든 문을 열어"),
        Phrase(text: "Light it up", translation: "환하게 밝혀"),
        Phrase(text: "Light it up again", translation: "다시 환하게 밝혀"),
        Phrase(text: "Carry all the colors of the dawn", translation: "새벽의 모든 색을 품고 가"),
        Phrase(text: "Sing until the morning carries on", translation: "아침이 이어질 때까지 노래해"),
        Phrase(text: "끝나지 않을 노래", translation: "A song that never ends", pronunciation: "kkeutnaji aneul norae"),
        Phrase(text: "Every star remembers who we are", translation: "모든 별은 우리가 누구인지 기억해")
    ]

    /// (duration, gap after) per line. Includes rapid lines, a long sustained word and an
    /// instrumental break so normal, retargeted and interlude transitions all occur.
    private static let schedule: [(durationMs: Int64, gapMs: Int64)] = [
        (3_200, 300), (3_000, 250), (3_400, 350), (3_100, 300), (3_300, 300),
        (3_200, 250), (3_000, 400), (3_600, 300), (3_000, 300), (3_200, 300),
        (420, 20), (360, 20), (300, 20), (280, 20), (520, 30), (380, 20), (300, 20), (650, 200),
        (3_200, 300), (3_400, 300), (2_800, 9_000),
        (3_200, 300), (3_300, 350), (3_100, 300), (3_200, 300), (3_000, 300),
        (900, 100), (3_000, 300), (3_200, 300), (1_500, 150), (700, 40), (1_200, 300),
        (3_300, 300), (3_200, 300), (3_100, 300), (3_400, 2_000)
    ]

    static func make() -> (result: LyricsResult, durationMs: Int64) {
        var lines: [LyricsLine] = []
        var cursor: Int64 = 1_500
        for (index, timing) in schedule.enumerated() {
            let phrase = phrases[index % phrases.count]
            let start = cursor
            let end = start + timing.durationMs
            lines.append(LyricsLine(
                startTimeMs: start,
                endTimeMs: end,
                text: phrase.text,
                syllables: syllables(phrase.text, startMs: start, endMs: end),
                pronunciationText: phrase.pronunciation,
                translationText: phrase.translation
            ))
            cursor = end + timing.gapMs
        }
        let result = LyricsResult(
            lines: lines,
            providerLabel: "Fixture",
            detail: "DEBUG karaoke fixture",
            karaoke: true,
            providerId: "fixture",
            syncType: "syllable",
            syncPoints: lines.count
        )
        return (result, cursor + 4_000)
    }

    /// Word chunks for Latin text and syllable blocks for Hangul, weighted by length.
    private static func syllables(_ text: String, startMs: Int64, endMs: Int64) -> [LyricsLine.Syllable] {
        let hangul = text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
        var units: [String] = []
        if hangul {
            for character in text {
                if character == " ", let last = units.popLast() {
                    units.append(last + " ")
                } else {
                    units.append(String(character))
                }
            }
        } else {
            let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            for (index, word) in words.enumerated() {
                units.append(index + 1 < words.count ? word + " " : word)
            }
        }
        let sungEnd = max(startMs + 1, endMs - min(160, (endMs - startMs) / 6))
        let weights = units.map { Double(max(1, $0.trimmingCharacters(in: .whitespaces).count)) }
        let total = weights.reduce(0, +)
        var elapsed = 0.0
        return units.enumerated().map { index, unit in
            let unitStart = startMs + Int64((Double(sungEnd - startMs) * elapsed / total).rounded())
            elapsed += weights[index]
            let unitEnd = startMs + Int64((Double(sungEnd - startMs) * elapsed / total).rounded())
            return LyricsLine.Syllable(text: unit, startTimeMs: unitStart, endTimeMs: max(unitStart + 1, unitEnd))
        }
    }
}

#if os(iOS)
@MainActor
func debugProbeCount(_ counter: DebugFrameProbe.Counter) {
    DebugFrameProbe.shared.count(counter)
}

/// Counts one evaluation of a time-driven TimelineView and stores the date it drew.
@MainActor
func debugProbeTimeline(_ counter: DebugFrameProbe.Counter, _ date: Date) {
    DebugFrameProbe.shared.recordTimeline(counter, date: date)
}

/// One vinyl tonearm evaluation: drawn rotation and progress, engagement, playback progress.
@MainActor
func debugProbeTonearm(rotation: Double, progress: Double, engagement: Double,
                       playbackProgress: Double, dragging: Bool) {
    DebugFrameProbe.shared.count(.vinylTonearmBody)
    DebugFrameProbe.shared.recordTonearm([rotation, progress, engagement, playbackProgress, dragging ? 1 : 0])
}

/// One vinyl record angle evaluation with the spin state it was computed from.
@MainActor
func debugProbeSpin(disc: Int, date: Date, angle: Double, origin: Date, base: Double, spinning: Bool) {
    DebugFrameProbe.shared.count(.vinylDiscTick)
    DebugFrameProbe.shared.recordSpin(disc: disc, date: date, angle: angle, origin: origin, base: base,
                                      spinning: spinning)
}

/// DEBUG-only frame cadence probe (IVLYRICS_DEBUG_FRAME_PROBE=1). After
/// IVLYRICS_DEBUG_PROBE_DELAY_S it records IVLYRICS_DEBUG_PROBE_DURATION_S seconds of
/// display-link frames, main-thread awake time per frame, the lyric scroll offset and every
/// karaoke fill evaluation, then writes Documents/ivlyrics-probe-<IVLYRICS_DEBUG_PROBE_NAME>.json.
@MainActor
final class DebugFrameProbe: NSObject {
    static let shared = DebugFrameProbe()

    /// Per-frame evaluation counters; the frame record stores the counts since the previous frame.
    enum Counter: Int, CaseIterable {
        case timelineBody, lineBody, karaokeBody, glyphBody, flowLayoutUpdate, flowLayoutMake,
             preparationMiss, previewBody, scrollBody,
             // Time-driven decoration TimelineViews (see debugProbeTimeline).
             marqueeTick, previewInterludeTick, previewSkeletonTick, lyricsSkeletonTick,
             interludeBarsTick, vinylSceneTick,
             vinylTonearmBody, vinylDiscTick, vinylSceneBody
    }

    private struct FrameRecord {
        var callback: Double
        var timestamp: Double
        var target: Double
        var busy: Double
        var longestWake: Double
        var scrollY: Double
        var counts: [Int]
    }

    private struct FillRecord {
        var time: Double
        var singleLine: Bool
        var active: Bool
        var lineStart: Int64
        var lineEnd: Int64
        var position: Double
        var fill: Double
        var bounce: Double
    }

    private struct OffsetRecord {
        var time: Double
        var relativeIndex: Int
        var offset: Double
    }

    /// One playback-clock tick: when the callback ran, the vsync uptime it paints from, the
    /// painted continuous position and the whole-millisecond position sampled at callback time.
    private struct ClockRecord {
        var callback: Double
        var frame: Double
        var painted: Double
        var callbackSampled: Double
    }

    /// One TimelineView content evaluation: when it ran and the date it drew, both on the
    /// media clock of the frame records.
    private struct TimelineRecord {
        var time: Double
        var site: Int
        var date: Double
    }

    private(set) var recording = false
    private var link: CADisplayLink?
    private var observers: [CFRunLoopObserver] = []
    private var wakeTime = Double.nan
    private var frames: [FrameRecord] = []
    private var fills: [FillRecord] = []
    private var offsets: [OffsetRecord] = []
    private var clocks: [ClockRecord] = []
    private var timelines: [TimelineRecord] = []
    private var tonearms: [[Double]] = []
    private var spins: [[Double]] = []
    private var events: [[String: Any]] = []
    private var cpuStart = (user: 0.0, system: 0.0)
    private var startTime = 0.0
    private var uptimeMinusMediaTime = 0.0
    private weak var scrollView: UIScrollView?
    private var lastScrollLookup = 0.0
    private var name = "probe"
    private var counters = [Int](repeating: 0, count: Counter.allCases.count)

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["IVLYRICS_DEBUG_FRAME_PROBE"] == "1"
    }

    func count(_ counter: Counter) {
        guard recording else { return }
        counters[counter.rawValue] += 1
    }

    func scheduleFromEnvironment() {
        guard Self.isEnabled, link == nil else { return }
        let environment = ProcessInfo.processInfo.environment
        let delay = Double(environment["IVLYRICS_DEBUG_PROBE_DELAY_S"] ?? "") ?? 3
        let duration = Double(environment["IVLYRICS_DEBUG_PROBE_DURATION_S"] ?? "") ?? 20
        name = environment["IVLYRICS_DEBUG_PROBE_NAME"] ?? "probe"
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            start()
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [self] in
                finish()
            }
        }
    }

    func recordFill(singleLine: Bool, active: Bool, lineStart: Int64, lineEnd: Int64,
                    position: Double, fill: Double, bounce: Double) {
        guard recording else { return }
        fills.append(FillRecord(time: CACurrentMediaTime(), singleLine: singleLine, active: active,
                                lineStart: lineStart, lineEnd: lineEnd, position: position,
                                fill: fill, bounce: bounce))
    }

    func recordOffset(relativeIndex: Int, offset: Double) {
        guard recording else { return }
        offsets.append(OffsetRecord(time: CACurrentMediaTime(), relativeIndex: relativeIndex, offset: offset))
    }

    func recordClock(callbackUptime: Double, frameUptime: Double, painted: Double, callbackSampled: Double) {
        guard recording else { return }
        clocks.append(ClockRecord(callback: callbackUptime, frame: frameUptime, painted: painted,
                                  callbackSampled: callbackSampled))
    }

    func recordTimeline(_ counter: Counter, date: Date) {
        guard recording else { return }
        counters[counter.rawValue] += 1
        let now = CACurrentMediaTime()
        let mediaDate = now + date.timeIntervalSince(Date())
        timelines.append(TimelineRecord(time: now, site: counter.rawValue, date: mediaDate))
    }

    func recordTonearm(_ values: [Double]) {
        guard recording else { return }
        tonearms.append([CACurrentMediaTime()] + values)
    }

    /// Dates are stored on the media clock of the frame records.
    func recordSpin(disc: Int, date: Date, angle: Double, origin: Date, base: Double, spinning: Bool) {
        guard recording else { return }
        let now = CACurrentMediaTime()
        let wall = Date()
        spins.append([now, Double(disc), now + date.timeIntervalSince(wall), angle,
                      now + origin.timeIntervalSince(wall), base, spinning ? 1 : 0])
    }

    func recordEvent(_ kind: String, _ values: [String: Any] = [:]) {
        guard recording else { return }
        var event = values
        event["kind"] = kind
        event["time"] = CACurrentMediaTime()
        events.append(event)
    }

    private func start() {
        frames.reserveCapacity(6_000)
        fills.reserveCapacity(40_000)
        offsets.reserveCapacity(40_000)
        clocks.reserveCapacity(6_000)
        timelines.reserveCapacity(40_000)
        tonearms.reserveCapacity(12_000)
        spins.reserveCapacity(24_000)
        cpuStart = Self.cpuTimes()
        startTime = CACurrentMediaTime()
        // DisplayRefreshClock passes CADisplayLink.timestamp as playback uptime.
        uptimeMinusMediaTime = ProcessInfo.processInfo.systemUptime - CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        let maximum = Float(UIScreen.main.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: maximum, preferred: maximum)
        link.add(to: .main, forMode: .common)
        self.link = link
        // Every main-thread wake (display links, SwiftUI updates, Core Animation commits,
        // timers) is summed into the frame interval in which it ends.
        let wake = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.wakeTime = CACurrentMediaTime() }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.mainThreadWillSleep() }
        }
        for observer in [wake, sleep].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
        recording = true
        print("IVLYRICS_PROBE_START \(name)")
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if now - lastScrollLookup > 0.5 || scrollView?.window == nil {
            scrollView = Self.findLyricsScrollView()
            lastScrollLookup = now
        }
        let scrollY = scrollView.map { Double($0.layer.presentation()?.bounds.origin.y ?? $0.contentOffset.y) } ?? .nan
        frames.append(FrameRecord(callback: now, timestamp: link.timestamp, target: link.targetTimestamp,
                                  busy: 0, longestWake: 0, scrollY: scrollY, counts: counters))
        counters = [Int](repeating: 0, count: Counter.allCases.count)
    }

    private func mainThreadWillSleep() {
        let now = CACurrentMediaTime()
        defer { wakeTime = .nan }
        guard recording, !frames.isEmpty, wakeTime.isFinite else { return }
        let awake = now - wakeTime
        frames[frames.count - 1].busy += awake
        frames[frames.count - 1].longestWake = max(frames[frames.count - 1].longestWake, awake)
    }

    private func finish() {
        guard recording else { return }
        recording = false
        link?.invalidate()
        link = nil
        for observer in observers {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        observers = []
        let cpu = Self.cpuTimes()
        func number(_ value: Double) -> Any { value.isFinite ? value : NSNull() }
        let report: [String: Any] = [
            "name": name,
            "elapsed": CACurrentMediaTime() - startTime,
            "cpuUser": cpu.user - cpuStart.user,
            "cpuSystem": cpu.system - cpuStart.system,
            "maximumFramesPerSecond": UIScreen.main.maximumFramesPerSecond,
            "uptimeMinusMediaTime": uptimeMinusMediaTime,
            "frames": frames.map { [number($0.callback), number($0.timestamp), number($0.target),
                                    number($0.busy), number($0.scrollY), number($0.longestWake), $0.counts] },
            "counterNames": Counter.allCases.map { "\($0)" },
            "fills": fills.map { [number($0.time), $0.singleLine ? 1 : 0, $0.active ? 1 : 0,
                                  $0.lineStart, $0.lineEnd, number($0.position), number($0.fill),
                                  number($0.bounce)] },
            "offsets": offsets.map { [number($0.time), $0.relativeIndex, number($0.offset)] },
            "clocks": clocks.map { [number($0.callback), number($0.frame), number($0.painted),
                                   number($0.callbackSampled)] },
            "timelines": timelines.map { [number($0.time), $0.site, number($0.date)] },
            "tonearm": tonearms.map { $0.map(number) },
            "spins": spins.map { $0.map(number) },
            "events": events
        ]
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent("ivlyrics-probe-\(name).json")
        if let data = try? JSONSerialization.data(withJSONObject: report) {
            try? data.write(to: url, options: .atomic)
        }
        print("IVLYRICS_PROBE_DONE \(url.path)")
    }

    private static func cpuTimes() -> (user: Double, system: Double) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return (
            Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000,
            Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        )
    }

    private static func findLyricsScrollView() -> UIScrollView? {
        var best: UIScrollView?
        func visit(_ view: UIView) {
            if let scroll = view as? UIScrollView, !scroll.isHidden,
               scroll.contentSize.height > (best?.contentSize.height ?? 0) {
                best = scroll
            }
            view.subviews.forEach(visit)
        }
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .forEach(visit)
        return best
    }
}
#endif
#endif
