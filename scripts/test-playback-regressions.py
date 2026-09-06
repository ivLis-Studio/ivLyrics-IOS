#!/usr/bin/env python3
"""Run production Swift motion/progress/cache policies without network, playback or an iOS device."""
from pathlib import Path
import subprocess
import tempfile
import plistlib

ROOT = Path(__file__).resolve().parents[1]
with (ROOT / "ivLyrics-IOS/Info.plist").open("rb") as plist:
    assert plistlib.load(plist).get("CADisableMinimumFrameDurationOnPhone") is True, "iPhone ProMotion opt-in missing"
source = (ROOT / "ivLyrics-IOS/ContentView.swift").read_text()
cache = source[source.index("private final class KaraokeRenderPreparationCache {"):source.index("private struct KaraokeBounceMetrics {")]
fixtures = r'''
import Foundation
struct LyricsLine { struct Syllable: Equatable { var text: String; var startTimeMs: Int64; var endTimeMs: Int64 } }
struct CulturalAnnotation: Equatable { var note: String }
enum KaraokeSyllableTimingNormalizer { struct FillTiming { var startTimeMs: Int64; var endTimeMs: Int64 } }
enum FuriganaRepository { struct RubyAnnotation {} }
'''
checks = r'''
var assertions = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    assertions += 1
    if !value() { fatalError(label) }
}
func near(_ first: Double, _ second: Double, _ label: String, tolerance: Double = 0.0001) {
    check(abs(first - second) <= tolerance, label)
}
check(PlaybackClockMode(foregroundActive: true, pictureInPictureEngaged: false) == .display, "Foreground uses native display cadence")
check(PlaybackClockMode(foregroundActive: true, pictureInPictureEngaged: true) == .display, "Foreground PiP does not start a second clock")
check(PlaybackClockMode(foregroundActive: false, pictureInPictureEngaged: true) == .backgroundPictureInPicture, "Background PiP retains an independent playback clock")
check(PlaybackClockMode(foregroundActive: false, pictureInPictureEngaged: false) == .stopped, "Closing background PiP stops playback work")
check(OpenDBRefreshPolicy.isFresh(nowMs: 1000 + 6 * 60 * 60 * 1000 - 1, fetchedAtMs: 1000), "OpenDB reuses index for six hours")
check(!OpenDBRefreshPolicy.isFresh(nowMs: 1000 + 6 * 60 * 60 * 1000, fetchedAtMs: 1000), "OpenDB refreshes at six hours")
check(!OpenDBRefreshPolicy.isFresh(nowMs: 1000, fetchedAtMs: 0), "Missing fetch timestamp is stale")
check(!OpenDBRefreshPolicy.isFresh(nowMs: 999, fetchedAtMs: 1000), "Clock rollback cannot make index permanently fresh")
let fast = KaraokeMotionProfile(startMs: 0, holdEndMs: 400, cadenceMs: 90, gapMs: 0)
near(fast.riseMs, 85.5, "PC fast rise")
near(fast.releaseMs, 110, "PC fast release")
near(fast.amplitude, 1.1, "PC fast lift")
near(fast.scaleAmount, 0.006, "PC fast scale")
near(fast.values(positionMs: 200, textSize: 22).offsetY, -0.55, "Font-relative fast lift")
let slow = KaraokeMotionProfile(startMs: 0, holdEndMs: 2000, cadenceMs: 320, gapMs: 800)
near(slow.riseMs, 189, "PC slow rise")
near(slow.releaseMs, 630, "PC sustained release with gap")
near(slow.amplitude, 5.6, "PC sustained lift")
near(slow.values(positionMs: 2315, textSize: 44).offsetY, -2.8, "PC continuous half release")
near(slow.values(positionMs: 2000, textSize: 44).scale, 1.03, "PC held scale")
for time in [-1.0, 2630, 5000] {
    near(slow.values(positionMs: time, textSize: 22).offsetY, 0, "Motion lifetime")
    near(slow.values(positionMs: time, textSize: 22).scale, 1, "Motion lifetime scale")
}
let fractional1 = fast.values(positionMs: 35.0, textSize: 22).offsetY
let fractional2 = fast.values(positionMs: 35.1, textSize: 22).offsetY
check(fractional1 != fractional2 && abs(fractional1 - fractional2) < 0.01, "Native motion is continuous without CSS transition")
let weighted = KaraokeMotionProfile.prepare(source: [.init(text: "a", startMs: 0, endMs: 100), .init(text: "bbbb", startMs: 100, endMs: 900)],
    display: [.init(text: "abbbb", startMs: 0, endMs: 900)])
// Unit cadences100/400; neighbor mean250 =>local137.5/362.5; 1:4 char-weighted317.5.
let weightedExpected = KaraokeMotionProfile(startMs: 0, holdEndMs: 900, cadenceMs: 317.5, gapMs: 0)
near(weighted[0]!.amplitude, weightedExpected.amplitude, "Merged display groups weight cadence by characters")
let heldSource = [KaraokeMotionProfile.Unit(text: "hold ", startMs: 0, endMs: 2000)]
let heldDisplay = [KaraokeMotionProfile.Unit(text: "h", startMs: 0, endMs: 400),
                   KaraokeMotionProfile.Unit(text: "o", startMs: 400, endMs: 800),
                   KaraokeMotionProfile.Unit(text: "l", startMs: 800, endMs: 1200),
                   KaraokeMotionProfile.Unit(text: "d", startMs: 1200, endMs: 1600),
                   KaraokeMotionProfile.Unit(text: " ", startMs: 1600, endMs: 2000)]
let profiles = KaraokeMotionProfile.prepare(source: heldSource, display: heldDisplay)
check(profiles.count == heldDisplay.count && profiles.last! == nil, "Whitespace has no bounce")
check(profiles[0]!.holdEndMs == 2000, "Compact source unit retains sustained glyphs")
let word = KaraokeMotionProfile.prepare(source: heldSource,
    display: [.init(text: "hold", startMs: 0, endMs: 1600), .init(text: " ", startMs: 1600, endMs: 2000)])
check(word[0]!.holdEndMs == 2000, "Whole-word hold includes source trailing space")
let longText = String(repeating: "a", count: 30)
let longProfiles = KaraokeMotionProfile.prepare(source: [.init(text: longText, startMs: 0, endMs: 6000)],
    display: longText.enumerated().map { .init(text: String($0.element), startMs: Double($0.offset * 200), endMs: Double(($0.offset + 1) * 200)) })
check(longProfiles[0]!.holdEndMs == 200, "Whole-line timing cannot suspend earlier glyphs")
let secondVocal = KaraokeMotionProfile.prepare(source: [.init(text: "B", startMs: 700, endMs: 900)],
    display: [.init(text: "B", startMs: 700, endMs: 900)])
check(secondVocal[0]!.startMs == 700 && profiles[0]!.startMs == 0, "Vocal rows retain independent onsets")
near(KaraokeEffectTiming.bounceOffset(timeMs: 780 * 0.32), -0.16, "PC named bounce peak")
near(KaraokeEffectTiming.bounceOffset(timeMs: 780 * 0.58), 0.035, "PC named bounce rebound")
near(KaraokeEffectTiming.waveOffset(timeMs: 920 * 0.35), -0.11, "PC wave peak")
near(KaraokeEffectTiming.waveOffset(timeMs: 920 * 0.70), 0.03, "PC wave rebound")
near(KaraokeEffectTiming.adlibOffset(timeMs: 525), -1.5 / 44, "PC adlib font normalization")
near(KaraokeEffectTiming.popScale(timeMs: 1080 * 0.18), 1.035, "PC pop peak")
check(abs(KaraokeEffectTiming.popScale(timeMs: 194.3) - KaraokeEffectTiming.popScale(timeMs: 194.5)) < 0.001, "Pop is continuous at its old snap boundary")
var progress = SupplementProviderProgress()
let firstRequest = progress.begin(trackKey: "same-track")
check(progress.translation.isEmpty, "No selected-provider guess before execution")
progress.update(request: firstRequest, trackKey: "same-track", task: "translation", provider: "Bing Translate")
progress.update(request: firstRequest, trackKey: "same-track", task: "pronunciation", provider: "OpenAI ChatGPT")
check(progress.translation == "Bing Translate" && progress.pronunciation == "OpenAI ChatGPT", "Concurrent providers independent")
progress.update(request: firstRequest, trackKey: "same-track", task: "translation", provider: "Google Translate")
check(progress.translation == "Google Translate", "Fallback reports actual executing provider")
let retry = progress.begin(trackKey: "same-track")
progress.update(request: firstRequest, trackKey: "same-track", task: "translation", provider: "Gemini")
check(progress.translation.isEmpty, "Old retry callback rejected for same track")
progress.update(request: retry, trackKey: "other-track", task: "translation", provider: "Gemini")
check(progress.translation.isEmpty, "Track-mismatched callback rejected")
progress.update(request: retry, trackKey: "same-track", task: "translation", provider: "Google Translate")
progress.setLoading(pronunciation: true, translation: false)
check(progress.translation.isEmpty, "Completed provider label cleared")
progress.invalidate()
check(!progress.isCurrent(retry, trackKey: "same-track"), "Cancellation invalidates progress")
private let cache = KaraokeRenderPreparationCache()
private var key = KaraokeRenderPreparationCache.Key(text: "lyrics", ruby: "", syllables: [], granularity: "character", locale: "en", annotations: [], start: 0, end: 1000, synthetic: true)
var preparations = 0
private func prepared() -> KaraokeRenderPreparationCache.Value {
    preparations += 1
    return .init(source: [], display: [], fillTimings: [], annotations: [], motionProfiles: [])
}
for _ in 0..<180 { _ = cache.value(for: key, prepare: prepared) }
check(preparations == 1, "180 display frames reuse timing/text preparation")
key.granularity = "word"
_ = cache.value(for: key, prepare: prepared)
key.ruby = "reading"
_ = cache.value(for: key, prepare: prepared)
key.annotations = [.init(note: "annotation")]
_ = cache.value(for: key, prepare: prepared)
key.syllables = [.init(text: "lyrics", startTimeMs: 100, endTimeMs: 1000)]
_ = cache.value(for: key, prepare: prepared)
check(preparations == 5, "Granularity/ruby/annotations/timing changes invalidate preparation")
print("PLAYBACK_REGRESSIONS_PASSED assertions=\(assertions)")
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-ios-regression-") as path:
    work = Path(path)
    (work / "main.swift").write_text(fixtures + cache + checks)
    sources = [ROOT / "ivLyrics-IOS/KaraokeMotionProfile.swift", ROOT / "ivLyrics-IOS/SupplementProviderProgress.swift", ROOT / "ivLyrics-IOS/OpenDBRefreshPolicy.swift", ROOT / "ivLyrics-IOS/DisplayRefreshClock.swift", work / "main.swift"]
    subprocess.run(["xcrun", "swiftc", *map(str, sources), "-o", str(work / "regression")], check=True)
    subprocess.run([str(work / "regression")], check=True)
