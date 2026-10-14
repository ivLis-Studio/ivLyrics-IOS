#!/usr/bin/env python3
"""Check native UI-test wiring/isolation and execute the real manual-search cancellation path.

This is NOT screenshot acceptance. SettingsLayoutUITests must be run on an iPhone
Simulator through the shared ivLyrics-IOS scheme for rendered layout evidence.
"""
from pathlib import Path
import json
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
model = (SRC / "AppViewModel.swift").read_text()
controls = (SRC / "SettingsDesign.swift").read_text()
content = (SRC / "ContentView.swift").read_text()
popup = (SRC / "LyricsMetaMenuView.swift").read_text()
harness = (SRC / "DebugSettingsUIHarness.swift").read_text()
ui_tests = (ROOT / "ivLyrics-IOSUITests/SettingsLayoutUITests.swift").read_text()


def declaration(source, prefix):
    start = source.index(prefix)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


scheme = ET.parse(ROOT / "ivLyrics-IOS.xcodeproj/xcshareddata/xcschemes/ivLyrics-IOS.xcscheme").getroot()
assert scheme.find("TestAction").attrib["buildConfiguration"] == "Debug"
testables = scheme.findall("TestAction/Testables/TestableReference/BuildableReference")
assert any(test.attrib["BlueprintName"] == "ivLyrics-IOSUITests" for test in testables)
for entry in scheme.findall("BuildAction/BuildActionEntries/BuildActionEntry"):
    if entry.find("BuildableReference").attrib["BlueprintName"] == "ivLyrics-IOSUITests":
        assert entry.attrib["buildForTesting"] == "YES" and entry.attrib["buildForArchiving"] == "NO"
project = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(ROOT / "ivLyrics-IOS.xcodeproj/project.pbxproj")], text=True))
objects = project["objects"]
target = next(value for value in objects.values() if value.get("name") == "ivLyrics-IOSUITests" and value["isa"] == "PBXNativeTarget")
assert target["productType"] == "com.apple.product-type.bundle.ui-testing"
assert objects[target["fileSystemSynchronizedGroups"][0]]["path"] == "ivLyrics-IOSUITests"
for config in objects[target["buildConfigurationList"]]["buildConfigurations"]:
    assert objects[config]["buildSettings"]["SKIP_INSTALL"] == "YES"
assert harness.startswith("#if DEBUG\n") and "#if !DEBUG\nimport SwiftUI" in harness
release_extension = harness.split("#if !DEBUG", 1)[1]
assert "{ self }" in release_extension and "DebugSettingsUIHarness" not in release_extension
assert ui_tests.startswith("#if DEBUG\n") and ui_tests.rstrip().endswith("#endif")
assert "--ivlyrics-ui-test" in harness and "UserDefaults(suiteName:" in harness
assert "ContentView()" not in harness and "AppSettings.shared" not in harness
assert "DebugSettingsUIHarness.credentialService" in (SRC / "SecureStringStore.swift").read_text()
for file, marker in [("SpotifyUserPlaybackService.swift", "override init()"), ("LyricsRepository.swift", "init()"), ("LyricsPictureInPictureController.swift", "override init()")]:
    initializer = declaration((SRC / file).read_text(), marker)
    assert "#if DEBUG\n        if DebugSettingsUIHarness.enabled { return }\n#endif" in initializer
init = declaration(model, "init(settings: AppSettings)")
assert init.index("if DebugSettingsUIHarness.enabled") < init.index('defaults.string(forKey: "manual_track_title")')
assert init.index("if DebugSettingsUIHarness.enabled") < init.index("startBluetoothRouteMonitoring()")
switch = declaration(controls, "struct SettingsSwitchStyle:")
assert ".toggleStyle(.switch)" in switch and "Button {" not in switch and ".frame(minHeight: 44)" in switch
assert "height: 44" in declaration(controls, "func sizeThatFits(")
assert 'TextField(settings.t("settings.search")' in content and '"settings.search"' in ui_tests
assert '"lyrics.menu.video.apply"' in popup and '"lyrics.menu.regenerate"' in popup
assert 'settings.t("tmi.regenerate")' not in popup
assert 'Color.black.opacity(0.56)' in popup and 'scrollableContentHeight' not in popup
assert "attachment.lifetime = .keepAlways" in ui_tests and "app.screenshot()" in ui_tests
assert "XCTAssertGreaterThanOrEqual(element.frame.height, 44" in ui_tests

method = declaration(model, "func searchManualCandidates()")
prelude = r'''
import Foundation
extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
struct FixtureSettings {
    func t(_ key: String) -> String { key }
    func tf(_ key: String, _ value: CVarArg) -> String { key }
}
enum FixtureError: Error { case failed }
final class FixtureRepository: @unchecked Sendable {
    func searchManualLrclib(track: String?, title: String, artist: String) async throws -> [String] {
        // Intentionally non-cooperative: a cancelled transport may still finish or throw late.
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + (title.hasPrefix("slow") ? 0.10 : 0.01)) {
                if title == "slow-error" { continuation.resume(throwing: FixtureError.failed) }
                else { continuation.resume(returning: [title]) }
            }
        }
    }
}
@MainActor final class Probe {
    let settings = FixtureSettings(), lyricsRepository = FixtureRepository()
    var inputTitle = "", inputArtist = ""
    var currentTrack: String? = "track", currentTrackKey = "track"
    var manualCandidates: [String] = [], manualLrclibStatus = ""
    var searchingManualCandidates = false
    var manualTask: Task<Void, Never>?
    var manualSearchRequestID = UUID()
    var toasts: [String] = []
    func appendLog(_ value: String) {}
    func showSavedToast(_ value: String) { toasts.append(value) }
'''
checks = r'''
}
@main struct Checks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            count += 1; if !value() { fatalError(label) }
        }
        for slow in ["slow-error", "slow-success"] {
            let p = Probe(); p.inputTitle = slow; p.searchManualCandidates()
            try await Task.sleep(for: .milliseconds(5))
            p.inputTitle = "fresh"; p.searchManualCandidates()
            try await Task.sleep(for: .milliseconds(150))
            check(p.manualCandidates == ["fresh"], "Late cancelled completion cannot replace new results")
            check(!p.searchingManualCandidates, "Latest request clears busy state")
            check(p.toasts.isEmpty, "Cancellation must not emit an error toast")
        }
        let empty = Probe(); empty.inputTitle = "slow-error"; empty.searchManualCandidates()
        try await Task.sleep(for: .milliseconds(5))
        empty.inputTitle = ""; empty.searchManualCandidates()
        try await Task.sleep(for: .milliseconds(150))
        check(empty.manualCandidates.isEmpty && !empty.searchingManualCandidates, "Empty search cancels previous request")
        check(empty.manualLrclibStatus == "lyrics.lrclib_search.empty_title" && empty.toasts.isEmpty, "Cancelled error cannot replace empty-state feedback")
        let moved = Probe(); moved.inputTitle = "slow-success"; moved.searchManualCandidates()
        moved.currentTrackKey = "replacement"
        try await Task.sleep(for: .milliseconds(150))
        check(moved.manualCandidates.isEmpty && !moved.searchingManualCandidates, "Track change rejects stale results and releases busy state")
        print("Settings UI regression: native target/isolation checks and \(count) async-search checks passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-settings-ui-") as temp:
    path = Path(temp)
    (path / "Checks.swift").write_text(prelude + method + checks)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(path / "Checks.swift"), "-o", str(path / "checks")], check=True)
    subprocess.run([str(path / "checks")], check=True)
