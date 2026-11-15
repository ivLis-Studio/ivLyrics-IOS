#!/usr/bin/env python3
"""Motion lyrics: the song the page is given, and the wiring around the page.

The presentation itself is the desktop one (Resources/MotionLyricsPage.html is built and tested
in the ivLyrics repository). This runs the production song mapping against controlled lyrics and
checks that the page, its strings and the mode's entry points are in place. No simulator.
"""
from pathlib import Path
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
motion = (SRC / "MotionLyricsMode.swift").read_text()
models = (SRC / "Models.swift").read_text()
content = (SRC / "ContentView.swift").read_text()
menu = (SRC / "LyricsMetaMenuView.swift").read_text()

song = motion[motion.index("enum MotionLyricsSong {"):motion.index("// MARK: - The player background")]
lines = models[models.index("struct LyricsLine:"):models.index("enum LyricsTextShaping {")]
checks = r'''
import Foundation

extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
enum IvLyricsUtilities { static func sha256(_ value: String) -> String { String(repeating: "ab", count: 32) } }
struct LyricsResult { var lines: [LyricsLine]; var karaoke: Bool }
struct TrackSnapshot {
    var title = "Song"; var artist = "Singer"; var trackId = ""; var stableKey = "song|singer|1"
    var hasUsableMetadata = true
}

var count = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    count += 1; if !value() { fatalError(message) }
}
func timed(_ words: [String], _ start: Int64) -> [LyricsLine.Syllable] {
    words.enumerated().map { .init(text: $0.element, startTimeMs: start + Int64($0.offset) * 300, endTimeMs: start + Int64($0.offset + 1) * 300) }
}
func decode(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}

let plain = LyricsLine(startTimeMs: 1000, endTimeMs: 2800, text: "Every road", syllables: timed(["Every ", "road"], 1000), translationText: "모든 길")
let untranslated = LyricsLine(startTimeMs: 3000, endTimeMs: 3600, text: "to you", syllables: timed(["to ", "you"], 3000))
let lead = LyricsLine.VocalPart(id: "a", role: "lead", speaker: "v1", kind: "vocal", text: "Hold on", syllables: timed(["Hold ", "on"], 5000))
let partner = LyricsLine.VocalPart(id: "b", role: "lead", speaker: "v2", kind: "vocal", text: "I will", syllables: timed(["I ", "will"], 5200))
let backing = LyricsLine.VocalPart(id: "c", role: "background", speaker: "v1", kind: "vocal", text: "ooh", syllables: timed(["ooh"], 5400))
let silent = LyricsLine.VocalPart(id: "d", role: "background", speaker: "v1", kind: "vocal", text: "(ah)", syllables: [])
let voices = LyricsLine(startTimeMs: 5000, endTimeMs: 6200, text: "Hold on I will ooh", syllables: timed(["Hold ", "on"], 5000), vocalParts: [lead, partner, backing, silent])
let lineSynced = LyricsLine(startTimeMs: 1000, endTimeMs: 3000, text: "No word timing")

check(MotionLyricsSong.canPlay(.init(lines: [plain], karaoke: true)), "Word-timed lyrics play")
check(MotionLyricsSong.canPlay(.init(lines: [LyricsLine(startTimeMs: 5000, endTimeMs: 6200, text: "Hold on", vocalParts: [lead])], karaoke: true)), "Timing that lives only in the vocal parts plays")
check(!MotionLyricsSong.canPlay(.init(lines: [lineSynced], karaoke: true)), "Lines without word timing do not play")
check(!MotionLyricsSong.canPlay(.init(lines: [plain], karaoke: false)), "Line-synced results do not play")
check(!MotionLyricsSong.canPlay(.init(lines: [], karaoke: true)), "No lyrics, nothing to play")

check(MotionLyricsSong.json(track: nil, lyrics: .init(lines: [plain], karaoke: true), accentHex: "", language: "") == "", "No track, no song")
check(MotionLyricsSong.json(track: TrackSnapshot(hasUsableMetadata: false), lyrics: .init(lines: [plain], karaoke: true), accentHex: "", language: "") == "", "A track without metadata is no song")
check(MotionLyricsSong.uri(for: TrackSnapshot(trackId: "4LhDEsC2tzaVuZbWAaCLrP")) == "spotify:track:4LhDEsC2tzaVuZbWAaCLrP", "Spotify tracks keep their URI")
check(MotionLyricsSong.uri(for: TrackSnapshot()) == "ivlyrics:track:" + String(repeating: "ab", count: 11), "Other tracks get a stable key the page can cache by")

let object = decode(MotionLyricsSong.json(track: TrackSnapshot(trackId: "id1"), lyrics: .init(lines: [plain, untranslated, voices], karaoke: true), accentHex: "#ff8800", language: "en"))
check(object["uri"] as? String == "spotify:track:id1" && object["title"] as? String == "Song" && object["artist"] as? String == "Singer", "Track identity")
check(object["accent"] as? String == "#ff8800" && object["language"] as? String == "en", "Accent and language")
let sent = object["lyrics"] as? [[String: Any]] ?? []
check(sent.count == 3, "Every line is sent")
check(sent[0]["text"] as? String == "Every road" && (sent[0]["startTime"] as? NSNumber)?.int64Value == 1000 && (sent[0]["endTime"] as? NSNumber)?.int64Value == 2800, "Line text and times")
let syllables = sent[0]["syllables"] as? [[String: Any]] ?? []
check(syllables.count == 2 && syllables[1]["text"] as? String == "road" && (syllables[1]["startTime"] as? NSNumber)?.int64Value == 1300 && (syllables[1]["endTime"] as? NSNumber)?.int64Value == 1600, "Syllable times in the desktop field names")
check(sent[0]["text2"] as? String == "모든 길", "The translation rides along")
check(sent[1]["text2"] == nil && sent[1]["vocals"] == nil, "No translation or voices when the line has none")
let vocals = sent[2]["vocals"] as? [String: Any] ?? [:]
let sentLead = vocals["lead"] as? [String: Any] ?? [:]
let others = vocals["background"] as? [[String: Any]] ?? []
check(sentLead["text"] as? String == "Hold on" && sentLead["speaker"] as? String == "v1", "The first lead part leads")
check(others.count == 2, "Parts without timing are left out")
check(others[0]["role"] as? String == "lead" && others[0]["speaker"] as? String == "v2", "A second lead part is a duet partner")
check(others[1]["role"] as? String == "background" && (others[1]["syllables"] as? [[String: Any]])?.count == 1, "Background vocals keep their timing")
let unsynced = decode(MotionLyricsSong.json(track: TrackSnapshot(trackId: "id1"), lyrics: .init(lines: [plain], karaoke: false), accentHex: "", language: ""))
check((unsynced["lyrics"] as? [Any])?.isEmpty == true, "A line-synced result sends no lyrics, so the page turns it down")
print("Motion lyrics regression: \(count) checks passed")
'''

# The page and the calls into it.
page = (SRC / "Resources" / "MotionLyricsPage.html").read_text()
assert page.startswith('<!doctype html>\n<html lang="en" data-motion-build="'), "MotionLyricsPage.html is the built page"
for call in ("configure", "setTrack", "setPlayback", "resolve"):
    assert "ivLyricsMotionHost." + call + "(" in motion and ("\t\t" + call + ",") in page, call
assert 'forResource: "MotionLyricsPage", withExtension: "html"' in motion
assert "messageHandlers?.ivLyricsMotion" in page and 'static let handlerName = "ivLyricsMotion"' in motion
for message in ("ready", "eligible", "background", "direct", "cacheGet", "cacheSet", "error"):
    assert 'case "' + message + '"' in motion and 'type: "' + message + '"' in page, message
# Touches belong to the mode; the user content controller must not keep the coordinator alive.
assert "view.isUserInteractionEnabled = false" in motion
assert "WeakHandler(context.coordinator)" in motion and "removeScriptMessageHandler(forName: Coordinator.handlerName)" in motion

# A phone is held in landscape while the mode is open, and released when it closes.
appear = motion[motion.index("        .onAppear {"):motion.index("        .onChange(of: model.lyricsResult)")]
assert "MotionLyricsOrientation.hold(true)" in appear and "MotionLyricsOrientation.hold(false)" in appear
assert "UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn" in appear
assert "guard UIDevice.current.userInterfaceIdiom == .phone" in motion
assert "if landscapeHeld { return .landscape }" in motion
assert "@UIApplicationDelegateAdaptor(IvLyricsAppDelegate.self)" in content

# Entry points: the lyrics menu (not with Reduce Motion), and only for songs that can play.
assert 'settings.t("motion.mode")' in menu and "openMotion: motionModeEntry" in content
assert "accessibilityReduceMotion ? nil : { presentMotionMode() }" in content
present = content[content.index("    private func presentMotionMode() {"):content.index("    private func updateLandscapeAutoHide")]
assert present.index("MotionLyricsSong.canPlay(model.lyricsResult)") < present.index("motionModeVisible = true")
assert 'settings.t("motion.unavailable")' in present
assert "if motionModeVisible { return true }" in content
# The background turns about the screen centre, not the centre of its safe-area bounds.
assert "screenCenter: MotionBackdropFollower.screenCenter(size: size, safeArea: safeAreaInsets)" in content
assert ".scaleEffect(frame.scale, anchor: screenCenter)" in motion and ".rotationEffect(.degrees(frame.rotate), anchor: screenCenter)" in motion

# The AI answers through the app's own provider, and accepted directions are kept on disk.
repository = (SRC / "AiLyricsRepository.swift").read_text()
assert 'RawResponseDiskCache(namespace: "motion_direction"' in repository
assert "motionDirectionDiskCache.clear()" in repository
assert "!snapshot.provider.translationOnly && snapshot.hasApiKey && snapshot.hasModel" in (SRC / "AppViewModel.swift").read_text()

strings = json.loads((SRC / "Resources" / "AppI18nStrings.json").read_text())
for locale, values in strings.items():
    for key in ("motion.mode", "motion.unavailable", "motion.directing", "motion.direct_failed"):
        assert values.get(key, "").strip(), f"{locale} lacks {key}"

with tempfile.TemporaryDirectory(prefix="ivlyrics-motion-") as temp:
    path = Path(temp)
    (path / "main.swift").write_text(checks.replace("import Foundation\n", "import Foundation\n" + lines + song, 1))
    subprocess.run(["xcrun", "swiftc", "-O", str(path / "main.swift"), "-o", str(path / "checks")], check=True)
    subprocess.run([str(path / "checks")], check=True)
