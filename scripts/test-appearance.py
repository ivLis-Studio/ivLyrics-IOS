#!/usr/bin/env python3
"""Execute production appearance policies and settings with isolated preferences (no Xcode)."""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
settings = (SRC / "AppSettings.swift").read_text()
view = (SRC / "ContentView.swift").read_text()
video = (SRC / "YouTubeBackdropView.swift").read_text()


def declaration(source, prefix):
    start = source.index(prefix)
    first = source.index("{", start)
    depth = 1
    end = first + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end].replace("private ", "")


names = ["titleTapAction", "landscapeOriginalLyricsEnabled", "landscapeArtworkEnabled",
         "lyricsNotFoundNoticeEnabled", "backgroundVideoFallback", "backgroundVideoAspect", "backgroundVideoEdgeToEdge"]
cloud_start = settings.index("    private static let cloudSettingKeys:")
cloud_end = settings.index("\n    ]", cloud_start) + len("\n    ]")
merge_start = settings.index("        for key in Self.cloudSettingKeys {", settings.index("    func importCloudSettings("))
merge_end = settings.index("\n\n        let loaded =", merge_start)
code = 'import Foundation\nextension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }\n'
code += "final class AppSettings {\nlet defaults: UserDefaults\nvar isBootstrapping = true\nvar revisions = 0\nfunc bumpBackgroundRevisionIfNeeded() { revisions += 1 }\n"
code += settings[cloud_start:cloud_end] + "\n"
for constant in ["backgroundGradient", "backgroundBlurGradient", "backgroundVideo", "backgroundSolid"]:
    code += next(line for line in settings.splitlines() if line.strip().startswith(f"static let {constant} =")) + "\n"
for name in names:
    code += next(line for line in settings.splitlines() if line.strip().startswith(f"@Published var {name}:" )).replace("@Published ", "") + "\n"
code += "init(defaults: UserDefaults) { self.defaults = defaults\n"
for name in names:
    code += next(line for line in settings.splitlines() if line.strip().startswith(f"{name} = ") and "defaults." in line) + "\n"
code += "isBootstrapping = false\n}\n"
for prefix in ["private func set(_ key: String, _ value: String)", "private func set(_ key: String, _ value: Bool)",
               "func exportCloudSettings()", "static func normalizeVideoFallback(", "static func normalizeBackgroundMode(",
               "static func normalizeHexColor(", "static func clampBackgroundVideoScale(", "struct BackgroundSettings:",
               "private static func backgroundSettingsJson(", "private static func backgroundSettings(from"]:
    code += declaration(settings, prefix) + "\n"
code += "func importCloudSettings(_ values: [String: Any]) {\n" + settings[merge_start:merge_end] + "\nlet loaded = AppSettings(defaults: defaults)\n"
for name in names:
    assignment = f"{name} = loaded.{name}"
    assert assignment in settings
    code += assignment + "\n"
code += "}\n}\n"
checks = r'''
var count = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    count += 1; if !value() { fatalError(label) }
}
let suite = "ivlyrics-appearance-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let s = AppSettings(defaults: defaults)
check(s.titleTapAction == "track", "Preserve existing title navigation default")
check(s.landscapeOriginalLyricsEnabled && s.landscapeArtworkEnabled && s.lyricsNotFoundNoticeEnabled, "Existing visibility defaults")
check(s.backgroundVideoFallback == AppSettings.backgroundBlurGradient && s.backgroundVideoAspect == "fill" && s.backgroundVideoEdgeToEdge, "Preserve old video defaults")
s.titleTapAction = "disabled"; s.landscapeOriginalLyricsEnabled = false; s.landscapeArtworkEnabled = false
s.lyricsNotFoundNoticeEnabled = false; s.backgroundVideoFallback = AppSettings.backgroundSolid
s.backgroundVideoAspect = "stretch"; s.backgroundVideoEdgeToEdge = false
let cloud = s.exportCloudSettings()
check(cloud.count == 7, "All new settings exported")
defaults.removePersistentDomain(forName: suite)
s.importCloudSettings(cloud.merging(["spotify_client_secret": "never sync"]) { a, _ in a })
let restored = AppSettings(defaults: defaults)
check(restored.titleTapAction == "disabled" && !s.landscapeOriginalLyricsEnabled && !s.landscapeArtworkEnabled && !s.lyricsNotFoundNoticeEnabled, "Cloud reload updates observed visibility")
check(restored.backgroundVideoAspect == "stretch" && !restored.backgroundVideoEdgeToEdge && restored.backgroundVideoFallback == AppSettings.backgroundSolid, "Video preferences survive restart/cloud sync")
check(defaults.string(forKey: "spotify_client_secret") == nil, "Cloud allowlist remains intact")
let background = AppSettings.BackgroundSettings(mode: AppSettings.backgroundVideo, brightness: 100, blur: 0, noise: false, reduceMotion: false, solidColor: "#123456", videoScale: 100, videoFallback: AppSettings.backgroundSolid, videoAspect: "fit", videoEdgeToEdge: false)
let json = AppSettings.backgroundSettingsJson(background)
check(AppSettings.backgroundSettings(from: json, fallback: background) == background, "Per-track background fields round-trip")
let legacy = AppSettings.backgroundSettings(from: ["mode": AppSettings.backgroundVideo], fallback: background)
check(legacy.videoAspect == "fit" && !legacy.videoEdgeToEdge, "Old track overrides inherit new global fields")
for aspect in ["fit", "fill", "stretch"] { check(AppearancePolicy.videoAspect(aspect) == aspect, "Supported aspect") }
check(AppearancePolicy.videoAspect("invalid") == "fill", "Invalid aspect fallback")
check(AppSettings.normalizeVideoFallback(AppSettings.backgroundVideo) == AppSettings.backgroundBlurGradient, "No recursive video fallback")
check(AppearancePolicy.videoDimOpacity(100) == 0 && AppearancePolicy.videoDimOpacity(0) == 1, "Native video brightness endpoints")
for value in -10...110 {
    check((0...1).contains(AppearancePolicy.videoDimOpacity(value)), "Dimming clamps")
    if value < 110 { check(AppearancePolicy.videoDimOpacity(value) >= AppearancePolicy.videoDimOpacity(value + 1), "Dimming is monotonic") }
}
check(AppearancePolicy.videoStageCSS("fit").contains("min(100vw"), "Fit preserves full 16:9 frame")
check(AppearancePolicy.videoStageCSS("fill").contains("min-width:"), "Fill covers viewport")
for uri in ["spotify:album:abc123", "spotify:playlist:abc123", "spotify:artist:abc123", "spotify:track:abc123"] {
    let destination = AppearancePolicy.spotifyDestination(uri)!
    check(destination.app.absoluteString == uri && destination.web.host == "open.spotify.com", "Navigation only deep link")
}
for uri in ["", "javascript:alert(1)", "https://evil.test", "spotify:playlist:../bad", "spotify:playlist:", "spotify:local:a:b:c", "spotify:playlist:a?play=true"] {
    check(AppearancePolicy.spotifyDestination(uri) == nil, "Reject unsafe/absent context")
}
print("Appearance regression: \(count) checks passed")
'''

# Wiring checks complement the executed policies; they do not claim SwiftUI/WKWebView visual QA.
for name in names:
    assert name in view
assert view.count("model.handleTitleTap()") == 3
assert '.environment(\\.originalLyricsVisible, settings.landscapeOriginalLyricsEnabled)' in view
assert 'if originalLyricsVisible {' in view and 'if useVocalPartSupplements {' in view
assert 'scaleY(var(--stretch-y,1))' in video and "reportVideo('failed')" in video
assert 'videoVisible ? AppearancePolicy.videoDimOpacity' in view
assert "func handleTitleTap()" in (SRC / "AppViewModel.swift").read_text()
with tempfile.TemporaryDirectory(prefix="ivlyrics-appearance-") as temp:
    path = Path(temp)
    (path / "main.swift").write_text(code + checks)
    subprocess.run(["xcrun", "swiftc", str(SRC / "AppearancePolicy.swift"), str(path / "main.swift"), "-o", str(path / "checks")], check=True)
    subprocess.run([str(path / "checks")], check=True)
