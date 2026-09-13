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
cache = source[source.index("final class KaraokeRenderPreparationCache {"):source.index("private struct KaraokeBounceMetrics {")]
# Exercise the production defaults and cloud merge with a disposable preferences suite,
# without constructing the app's unrelated network/keychain dependencies.
settings_source = (ROOT / "ivLyrics-IOS/AppSettings.swift").read_text()
default_properties = ("metadataTranslationEnabled", "syncedLyricsKaraokeAnimationEnabled")
default_assignments = "\n".join(
    next(line for line in settings_source.splitlines() if line.strip().startswith(f"{name} = defaults.object(forKey:"))
    for name in default_properties
)
cloud_keys_start = settings_source.index("    private static let cloudSettingKeys:")
cloud_keys_end = settings_source.index("\n    ]", cloud_keys_start) + len("\n    ]")
cloud_keys = settings_source[cloud_keys_start:cloud_keys_end]
cloud_merge_start = settings_source.index("        for key in Self.cloudSettingKeys {", settings_source.index("    func importCloudSettings("))
cloud_merge_end = settings_source.index("\n\n        let loaded = AppSettings(defaults: defaults)", cloud_merge_start)
motion_start = source.index("private enum LyricsMotion {")
motion_end = source.index("private struct LyricsTimelineEdgeFadeMask:", motion_start)
motion = source[motion_start:motion_end].replace("private enum LyricsMotion", "enum LyricsMotion")
# Compare against the shipped eager search while executing the production curve.
baseline_motion = subprocess.check_output(
    ["git", "show", "4e3c721:ivLyrics-IOS/ContentView.swift"], cwd=ROOT, text=True
)
baseline_motion = baseline_motion[baseline_motion.index("private enum LyricsMotion {"):baseline_motion.index("private struct LyricsTimelineEdgeFadeMask:")].replace("private enum LyricsMotion", "enum BaselineLyricsMotion")
settings_probe = """
private struct SettingsDefaultsProbe {
    let defaults: UserDefaults
    var metadataTranslationEnabled: Bool
    var syncedLyricsKaraokeAnimationEnabled: Bool
""" + cloud_keys + """
    init(defaults: UserDefaults) {
        self.defaults = defaults
""" + default_assignments + """
    }
    mutating func importCloudSettings(_ values: [String: Any]) {
""" + settings_source[cloud_merge_start:cloud_merge_end] + """
        self = Self(defaults: defaults)
    }
}
"""
fixtures = r'''
import Foundation
struct Animation {
    static func timingCurve(_ a: Double, _ b: Double, _ c: Double, _ d: Double, duration: Double) -> Animation { Animation() }
}
var centeringStartReads = 0
struct LyricsTimelineDisplayItem {
    var start: Int64
    var startTimeMs: Int64 { centeringStartReads += 1; return start }
}
struct LyricsLine { struct Syllable: Equatable { var text: String; var startTimeMs: Int64; var endTimeMs: Int64 } }
struct CulturalAnnotation: Equatable { var note: String }
enum KaraokeSyllableTimingNormalizer { struct FillTiming { var startTimeMs: Int64; var endTimeMs: Int64 } }
'''
ruby_source = (ROOT / "ivLyrics-IOS/FuriganaRepository.swift").read_text()
fixtures += "enum FuriganaRepository {\n" + ruby_source[
    ruby_source.index("    struct RubyAnnotation:"):ruby_source.index("    private static func containsKanji(")
] + "}\n"
checks = r'''
var assertions = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    assertions += 1
    if !value() { fatalError(label) }
}
func near(_ first: Double, _ second: Double, _ label: String, tolerance: Double = 0.0001) {
    check(abs(first - second) <= tolerance, label)
}
for starts: [Int64] in [[], [0], [0, 0, 0, 400], [1000, 200, 300, 1600], [0, 40, 80, 120], [0, 1000, 10000]] {
    let items = starts.map { LyricsTimelineDisplayItem(start: $0) }
    for target in -1...items.count {
        near(LyricsMotion.centeringDuration(items: items, targetIndex: target),
             BaselineLyricsMotion.centeringDuration(items: items, targetIndex: target),
             "Centering preserves source-order timing at every boundary")
    }
}
let centeringItems = (0..<500).map { LyricsTimelineDisplayItem(start: Int64($0 * 400)) }
centeringStartReads = 0
let previousCentering = (100..<200).map { BaselineLyricsMotion.centeringDuration(items: centeringItems, targetIndex: $0) }
let previousCenteringReads = centeringStartReads
centeringStartReads = 0
let currentCentering = (100..<200).map { LyricsMotion.centeringDuration(items: centeringItems, targetIndex: $0) }
check(currentCentering == previousCentering, "All centering durations stay identical")
check(centeringStartReads == 200 && previousCenteringReads == 35050, "Centering stops at the next distinct start")
check(PlaybackClockMode(foregroundActive: true, pictureInPictureEngaged: false) == .display, "Foreground uses native display cadence")
check(PlaybackClockMode(foregroundActive: true, pictureInPictureEngaged: true) == .display, "Foreground PiP does not start a second clock")
check(PlaybackClockMode(foregroundActive: false, pictureInPictureEngaged: true) == .backgroundPictureInPicture, "Background PiP retains an independent playback clock")
check(PlaybackClockMode(foregroundActive: false, pictureInPictureEngaged: false) == .stopped, "Closing background PiP stops playback work")
do {
    let suite = "ivlyrics-defaults-regression-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var settings = SettingsDefaultsProbe(defaults: defaults)
    check(!settings.metadataTranslationEnabled && !settings.syncedLyricsKaraokeAnimationEnabled, "Fresh settings disable title translation and virtual karaoke")
    settings.importCloudSettings(["ui_lang": "ko"])
    check(!settings.metadataTranslationEnabled && !settings.syncedLyricsKaraokeAnimationEnabled, "Older cloud settings with absent keys retain new defaults")
    settings.importCloudSettings(["metadata_translation_enabled": true, "synced_lyrics_karaoke_animation": true])
    check(settings.metadataTranslationEnabled && settings.syncedLyricsKaraokeAnimationEnabled, "Explicit cloud opt-ins are preserved")
    settings = SettingsDefaultsProbe(defaults: defaults)
    check(settings.metadataTranslationEnabled && settings.syncedLyricsKaraokeAnimationEnabled, "Saved opt-ins survive reload after upgrade")
    settings.importCloudSettings(["ui_lang": "en", "metadata_translation_enabled": NSNull()])
    check(settings.metadataTranslationEnabled && settings.syncedLyricsKaraokeAnimationEnabled, "Absent or null cloud keys do not erase saved choices")
    settings.importCloudSettings(["metadata_translation_enabled": false, "synced_lyrics_karaoke_animation": false])
    settings = SettingsDefaultsProbe(defaults: defaults)
    check(!settings.metadataTranslationEnabled && !settings.syncedLyricsKaraokeAnimationEnabled, "Explicit opt-outs survive import and reload")
    defaults.set(true, forKey: "metadata_translation_enabled")
    defaults.set(true, forKey: "synced_lyrics_karaoke_animation")
    defaults.removeObject(forKey: "metadata_translation_enabled")
    defaults.removeObject(forKey: "synced_lyrics_karaoke_animation")
    settings = SettingsDefaultsProbe(defaults: defaults)
    check(!settings.metadataTranslationEnabled && !settings.syncedLyricsKaraokeAnimationEnabled, "Clearing stored choices restores off defaults")
}
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
let pipStore = KaraokeRenderPreparationStore()
var pipPreparations = 0
// Each loop models a newly created PiP content root. The store belongs to its controller.
for _ in 0..<180 {
    for voice in 0..<4 {
        var voiceKey = key
        voiceKey.text = "voice \(voice) 日本語 العربية"
        let row = pipStore.cache(for: "part:\(voice)")
        _ = row.value(for: voiceKey) {
            pipPreparations += 1
            return .init(source: [], display: [], fillTimings: [], annotations: [], motionProfiles: [])
        }
    }
}
check(pipPreparations == 4, "180 fresh PiP frames reuse four independent vocal preparations")
let persistentRow = pipStore.cache(for: "part:0")
check(persistentRow === pipStore.cache(for: "part:0"), "Position and seek do not replace PiP row cache")
pipStore.removeAll()
check(persistentRow !== pipStore.cache(for: "part:0"), "Track replacement releases PiP preparation")
let oldest = pipStore.cache(for: "oldest")
for index in 0..<40 { _ = pipStore.cache(for: "new:\(index)") }
check(oldest !== pipStore.cache(for: "oldest"), "PiP row identities cannot grow memory without bound")
var resultCache = BoundedLRUCache<String, Int>(capacity: 3)
resultCache.insert(1, forKey: "track-a|old")
resultCache.insert(2, forKey: "track-b|old")
resultCache.insert(3, forKey: "track-a|new")
check(resultCache.value(forKey: "track-a|old") == 1, "Recent furigana result remains reusable")
resultCache.insert(4, forKey: "track-c|old")
check(resultCache.value(forKey: "track-b|old") == nil, "Least recently used full result is evicted")
check(resultCache.keys.count == 3, "Result memory remains bounded")
resultCache.removeValues { key, _ in key.hasPrefix("track-a|") }
check(resultCache.value(forKey: "track-a|old") == nil && resultCache.value(forKey: "track-a|new") == nil, "Track invalidation removes all text revisions")
check(resultCache.value(forKey: "track-c|old") == 4, "Track invalidation preserves unrelated songs")
resultCache.removeAll()
check(resultCache.keys.isEmpty, "Memory pressure can release all retained results")
resultCache.insert(4, forKey: "track-c|old")
check(resultCache.value(forKey: "track-c|old") == 4, "Disk rehydration works after memory purge")
var retryPolicy = SpotifyPlaybackRetryPolicy()
retryPolicy.receivedFailure(now: 100, retryAfter: 45)
near(retryPolicy.remainingDelay(now: 103), 42, "429 retains Retry-After deadline")
retryPolicy.receivedPlayback(hasTrack: true, now: 105)
near(retryPolicy.remainingDelay(now: 105), 40, "Late successful overlapping poll cannot erase a newer 429")
retryPolicy.receivedPlayback(hasTrack: false, now: 106)
near(retryPolicy.remainingDelay(now: 106), 39, "Late empty overlapping poll also preserves server deadline")
retryPolicy.requestImmediateRefresh()
near(retryPolicy.remainingDelay(now: 110), 35, "User command cannot bypass server rate limit")
near(retryPolicy.remainingDelay(now: 145), 0, "429 expires without repeated extension")
retryPolicy.receivedPlayback(hasTrack: true, now: 145)
near(retryPolicy.remainingDelay(now: 145), 0, "Successful playback restores normal polling")
for attempt in 0..<6 { retryPolicy.receivedFailure(now: 200 + Double(attempt) * 30) }
near(retryPolicy.remainingDelay(now: 350), 30, "Transient failures back off to bounded 30 seconds")
retryPolicy.requestImmediateRefresh()
near(retryPolicy.remainingDelay(now: 350), 0, "Foreground can recover immediately from network failure")
for _ in 0..<6 { retryPolicy.receivedPlayback(hasTrack: false, now: 400) }
near(retryPolicy.remainingDelay(now: 400), 15, "Empty playback backs off to 15 seconds")
retryPolicy.receivedPlayback(hasTrack: true, now: 415)
near(retryPolicy.remainingDelay(now: 415), 0, "Playback resumption clears empty-result backoff")
near(SpotifyPlaybackRetryPolicy.retryAfterSeconds("600")!, 600, "Long server retry intervals are honored")
check(SpotifyPlaybackRetryPolicy.retryAfterSeconds("invalid") == nil, "Malformed retry header uses caller fallback")
check(SpotifyPlaybackRetryPolicy.retryAfterSeconds("nan") == nil, "Non-finite retry header is rejected")
near(SpotifyPlaybackRetryPolicy.retryAfterSeconds("Thu, 01 Jan 1970 00:01:00 GMT", now: Date(timeIntervalSince1970: 0))!, 60, "HTTP-date retry headers are supported")
print("PLAYBACK_REGRESSIONS_PASSED assertions=\(assertions)")
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-ios-regression-") as path:
    work = Path(path)
    (work / "main.swift").write_text(fixtures + motion + baseline_motion + settings_probe + cache + checks)
    sources = [ROOT / "ivLyrics-IOS/KaraokeMotionProfile.swift", ROOT / "ivLyrics-IOS/SupplementProviderProgress.swift", ROOT / "ivLyrics-IOS/OpenDBRefreshPolicy.swift", ROOT / "ivLyrics-IOS/DisplayRefreshClock.swift", ROOT / "ivLyrics-IOS/BoundedLRUCache.swift", ROOT / "ivLyrics-IOS/SpotifyPlaybackRetryPolicy.swift", work / "main.swift"]
    subprocess.run(["xcrun", "swiftc", *map(str, sources), "-o", str(work / "regression")], check=True)
    subprocess.run([str(work / "regression")], check=True)
