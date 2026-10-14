#!/usr/bin/env python3
"""Execute production LP phase/metadata/defaults policies; UI compilation is covered by CI."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
vinyl = (SRC / "VinylPlayerModeView.swift").read_text()
settings = (SRC / "AppSettings.swift").read_text()
model = (SRC / "AppViewModel.swift").read_text()
view = (SRC / "ContentView.swift").read_text()


def decl(source, prefix):
    start = source.index(prefix)
    cursor = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[start:cursor].replace("private ", "")


names = ["vinylTrackChangeAnimationsEnabled", "vinylRotationSpeedPercent", "simplifyTitleEnabled"]
code = 'import Foundation\nextension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }\n'
code += "final class AppSettings { let defaults: UserDefaults; var isBootstrapping = true\n"
start = settings.index("    private static let cloudSettingKeys:")
code += settings[start:settings.index("\n    ]", start) + 6] + "\n"
for name in names:
    code += next(line for line in settings.splitlines() if line.strip().startswith(f"@Published var {name}:")).replace("@Published ", "") + "\n"
for kind in ["Bool", "Int"]:
    code += decl(settings, f"private func set(_ key: String, _ value: {kind})") + "\n"
code += decl(settings, "func exportCloudSettings()") + "\n"
code += "init(defaults: UserDefaults) { self.defaults = defaults\n"
for name in names:
    code += next(line for line in settings.splitlines() if line.strip().startswith(f"{name} = ") and "defaults." in line) + "\n"
    assert f"{name} = loaded.{name}" in settings and name in view
code += "isBootstrapping = false\n}\n}\n"
code += "struct SpinProbe { var spinBaseDegrees = 0.0; var spinOrigin = Date(timeIntervalSince1970: 0); var spinning = true; var spinSpeedPercent = 100\n"
code += decl(vinyl, "private func spinDegrees(at") + "\n"
code += decl(vinyl, "private func freezeSpin(at").replace("func freezeSpin", "mutating func freezeSpin") + "\n}\n"
code += "struct Metadata { var title: String; var artist: String }\nstruct Track { var title: String; var artist: String }\n"
code += "struct MetadataProbe { let settings: AppSettings; var metadataTranslation: Metadata?; var currentTrack: Track?; var inputTitle = \"\"; var inputArtist = \"\"\n"
code += decl(model, "var titleText: String") + "\n" + decl(model, "var artistText: String") + "\n}\n"
checks = r'''
var count = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    count += 1; if !value() { fatalError(message) }
}
func near(_ a: Double, _ b: Double, _ message: String) { check(abs(a - b) < 1e-7, message) }
let suite = "ivlyrics-vinyl-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let s = AppSettings(defaults: defaults)
check(s.vinylTrackChangeAnimationsEnabled && s.vinylRotationSpeedPercent == 100 && !s.simplifyTitleEnabled, "Preserve all defaults")
s.vinylTrackChangeAnimationsEnabled = false; s.vinylRotationSpeedPercent = 175; s.simplifyTitleEnabled = true
let exported = s.exportCloudSettings()
check(exported.count == 3, "Cloud includes LP settings")
defaults.removePersistentDomain(forName: suite)
for (key, value) in exported { defaults.set(value, forKey: key) }
let restored = AppSettings(defaults: defaults)
check(!restored.vinylTrackChangeAnimationsEnabled && restored.vinylRotationSpeedPercent == 175 && restored.simplifyTitleEnabled, "Persist and restore LP options")
for percent in [25, 50, 100, 150, 300] {
    var spin = SpinProbe()
    near(spin.spinDegrees(at: Date(timeIntervalSince1970: 10)), 90, "Default rate is unchanged (9 degrees/sec)")
    let handoff = Date(timeIntervalSince1970: 10)
    spin.freezeSpin(at: handoff)
    spin.spinSpeedPercent = percent
    near(spin.spinDegrees(at: handoff), 90, "Changing speed preserves phase")
    near(spin.spinDegrees(at: Date(timeIntervalSince1970: 11)), 90 + Double(percent) * 0.09, "New rate takes effect continuously")
    spin.freezeSpin(at: Date(timeIntervalSince1970: 11)); spin.spinning = false
    let paused = spin.spinBaseDegrees
    near(spin.spinDegrees(at: Date(timeIntervalSince1970: 100)), paused, "Pause preserves angle")
    spin.freezeSpin(at: Date(timeIntervalSince1970: 100)); spin.spinSpeedPercent = 100
    near(spin.spinDegrees(at: Date(timeIntervalSince1970: 200)), paused, "Speed changes while paused stay still")
    spin.spinOrigin = Date(timeIntervalSince1970: 200); spin.spinning = true
    near(spin.spinDegrees(at: Date(timeIntervalSince1970: 201)), paused + 9, "Resume starts at paused phase")
}
near(VinylMotionPolicy.degrees(base: 350, elapsed: 2, spinning: true, speedPercent: 100), 8, "Rotation wraps")
check(VinylMotionPolicy.speedPercent(0) == 25 && VinylMotionPolicy.speedPercent(1000) == 300, "Speed clamps")
let titles = ["Song (Live)", "Song [Remastered]", "曲（ライブ）", "곡【버전】", "Song (feat. A (B))"]
for title in titles { check(VinylMotionPolicy.title(title, simplified: false) == title, "Opt-in preserves default titles") }
check(VinylMotionPolicy.title("Song (Live) [2020]", simplified: true) == "Song", "Version notes removed")
check(VinylMotionPolicy.title("(Song)", simplified: true) == "(Song)", "Never lose entire title")
check(VinylMotionPolicy.title("Song (open", simplified: true) == "Song (open", "Unmatched punctuation retained")
let metadata = MetadataProbe(settings: s, metadataTranslation: .init(title: "번역 제목 (Live)", artist: "번역 아티스트"), currentTrack: .init(title: "raw", artist: "raw artist"))
check(metadata.titleText == "번역 제목" && metadata.artistText == "번역 아티스트", "Record metadata path uses translated/simplified player labels")
var labels = VinylLabelSnapshots()
let a = VinylResolvedLabels(trackKey: "A", title: "번역된 A", artist: "번역 가수 A")
let b = VinylResolvedLabels(trackKey: "B", title: "번역된 B", artist: "번역 가수 B")
labels.update(a, retaining: ["A"])
labels.update(b, retaining: ["A", "B"])
check(labels.labels(for: "A", title: "Original A", artist: "Original Artist A", simplified: true) == a,
      "Outgoing record keeps its resolved title and artist after current track changes")
check(labels.labels(for: "B", title: "Original B", artist: "Original Artist B", simplified: true) == b,
      "Incoming record uses its own translation, never outgoing metadata")
let lateB = VinylResolvedLabels(trackKey: "B", title: "Updated B", artist: "Updated Artist B")
labels.update(lateB, retaining: ["A", "B"])
check(labels.values["A"] == a && labels.values["B"] == lateB, "Late incoming metadata does not overwrite outgoing labels")
let c = VinylResolvedLabels(trackKey: "C", title: "Resolved C", artist: "Artist C")
labels.update(c, retaining: ["A", "B"])
check(labels.values.count == 3 && labels.values["A"] == a, "Rapid replacement retains only visible records and current track")
labels.update(c, retaining: ["C"])
check(labels.values.count == 1 && labels.values["A"] == nil && labels.values["B"] == nil, "Completed handoff releases stale label snapshots")
check(labels.labels(for: "uncached", title: "Fallback (Live)", artist: "Fallback Artist", simplified: true).title == "Fallback",
      "Missing snapshots keep the original safe simplification fallback")
check(labels.labels(for: "uncached", title: "Fallback (Live)", artist: "Fallback Artist", simplified: false).title == "Fallback (Live)",
      "Fallback respects simplification disabled")
for size in stride(from: 40.0, through: 600, by: 5) {
    let halfWidth = VinylMotionPolicy.labelWidth(recordSize: size) / 2
    let titleTop = size * (0.5 - 0.442 + 0.055 / 2)
    let artistBottom = size * (0.567 - 0.5 + 0.04 / 2)
    let ringInnerRadius = size * (0.162 - 0.0168 / 2)
    check(hypot(halfWidth, max(titleTop, artistBottom)) < ringInnerRadius, "Label boxes stay inside album text circle")
}
print("Vinyl regression: \(count) checks passed")
'''
assert 'animateChange && effectiveAnimationsEnabled && settings.vinylTrackChangeAnimationsEnabled' in vinyl
assert 'spinning = playing && effectiveAnimationsEnabled' in vinyl
assert 'settings.vinylCenterRotationEnabled ? 0 : -rotation' in vinyl
assert 'model.titleText' in vinyl and 'model.artistText' in vinyl
assert '.onChange(of: currentResolvedLabels)' in vinyl and 'labelSnapshots.labels(for: track.stableKey' in vinyl
assert 'labelSnapshots.update(currentResolvedLabels, retaining:' in vinyl
assert '.accessibilityLabel(title)' in vinyl and '.accessibilityLabel(artist)' in vinyl
assert vinyl.count('.clipped()') >= 2
with tempfile.TemporaryDirectory(prefix="ivlyrics-vinyl-") as temp:
    path = Path(temp)
    (path / "main.swift").write_text(code + checks)
    subprocess.run(["xcrun", "swiftc", str(SRC / "VinylMotionPolicy.swift"), str(path / "main.swift"), "-o", str(path / "checks")], check=True)
    subprocess.run([str(path / "checks")], check=True)
