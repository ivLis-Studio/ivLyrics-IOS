#!/usr/bin/env python3
"""Check native UI-test wiring/isolation, fixture initialization and real manual-search cancellation.

This is NOT screenshot acceptance. SettingsLayoutUITests must be run on an iPhone
Simulator through the shared ivLyrics-IOS scheme for rendered layout evidence.
"""
from pathlib import Path
import json
import re
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
# Preserve the production defaults path; only the explicit Debug fixture is seeded.
normal_init = init.split("#endif", 1)[1]
for field, key in {
    "inputTitle": "title", "inputArtist": "artist", "inputAlbum": "album",
    "inputDuration": "duration", "inputSpotifyId": "spotify_id", "inputIsrc": "isrc",
}.items():
    assert f'{field} = defaults.string(forKey: "manual_track_{key}") ?? ""' in normal_init
switch = declaration(controls, "struct SettingsSwitchStyle:")
assert ".toggleStyle(.switch)" in switch and "Button {" not in switch and ".frame(minHeight: 44)" in switch
assert "height: 44" in declaration(controls, "func sizeThatFits(")
assert 'TextField(settings.t("settings.search")' in content and '"settings.search"' in ui_tests
assert '"lyrics.menu.video.apply"' in popup and '"lyrics.menu.regenerate"' in popup
assert 'settings.t("tmi.regenerate")' not in popup
assert 'Color.black.opacity(0.56)' in popup and 'scrollableContentHeight' not in popup
assert "attachment.lifetime = .keepAlways" in ui_tests and "app.screenshot()" in ui_tests
assert "XCTAssertGreaterThanOrEqual(element.frame.height, 44" in ui_tests

# Compile the actual Debug initializer prefix with native Combine @Published.
# Pull every required input declaration from production so a newly added input
# cannot silently escape the fixture's definite-initialization regression.
input_declarations = re.findall(r"^    @Published var input\w+: [^\n=]+$", model, re.MULTILINE)
assert len(input_declarations) >= 6
fixture_init = init.split("#endif", 1)[0] + '#endif\n        fatalError("Fixture-only probe")\n    }'
initialization_prelude = r'''
import Combine
import Foundation
struct AppSettings {
    func globalSyncOffsetMs() -> Int { 37 }
    func t(_ key: String) -> String { key }
}
enum DebugSettingsUIHarness { static let enabled = true }
enum AppStatus { case idle, loaded }
struct TrackSnapshot: Equatable {
    let title, artist, album, mediaId: String
    let durationMs, positionMs: Int64
    let playing: Bool
}
struct LyricsLine: Equatable {
    let startTimeMs, endTimeMs: Int64
    let text, pronunciationText, translationText: String
}
struct LyricsResult: Equatable {
    let lines: [LyricsLine]
    let providerLabel, detail: String
    let karaoke: Bool
    let providerId: String
    static func empty(_ text: String) -> Self {
        Self(lines: [], providerLabel: "", detail: text, karaoke: false, providerId: "")
    }
}
@MainActor final class InitializationProbe: ObservableObject {
    let settings: AppSettings
    @Published private(set) var currentTrack: TrackSnapshot?
    @Published private(set) var lyricsResult = LyricsResult.empty("")
    @Published private(set) var baseLyricsResult = LyricsResult.empty("")
    @Published private(set) var status: AppStatus = .idle
    @Published var globalOffsetMs = 0
    @Published private(set) var manualLrclibStatus = ""
    @Published private(set) var updateStatus = ""
'''
initialization_checks = r'''
}
@main struct InitializationChecks {
    @MainActor static func main() {
        let model = InitializationProbe(settings: AppSettings())
        guard let track = model.currentTrack else { fatalError("Missing fixture track") }
        precondition(model.inputTitle == track.title && model.inputArtist == track.artist)
        precondition(model.inputAlbum == track.album && model.inputDuration == "180")
        precondition(model.inputSpotifyId.isEmpty && model.inputIsrc.isEmpty)
        precondition(!track.playing && model.status == .loaded)
        precondition(!model.lyricsResult.lines.isEmpty && model.baseLyricsResult == model.lyricsResult)
        precondition(model.globalOffsetMs == 37)
        precondition(model.manualLrclibStatus == "lyrics.lrclib_search.ready")
        precondition(model.updateStatus == "update.status_idle")
        print("Settings UI regression: native Combine Debug initializer and all required inputs passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-settings-init-") as temp:
    path = Path(temp)
    source = initialization_prelude + "\n".join(input_declarations) + "\n" + fixture_init + initialization_checks
    (path / "Initialization.swift").write_text(source)
    subprocess.run(["xcrun", "swiftc", "-D", "DEBUG", "-parse-as-library", str(path / "Initialization.swift"), "-o", str(path / "initialization")], check=True)
    subprocess.run([str(path / "initialization")], check=True)
    # A canary proves this is a definite-initialization check, not only parsing.
    missing_input = source.replace("inputDuration = String(track.durationMs / 1_000)", "// Deliberately omit inputDuration", 1)
    assert missing_input != source
    (path / "MissingInput.swift").write_text(missing_input)
    rejected = subprocess.run(["xcrun", "swiftc", "-D", "DEBUG", "-parse-as-library", "-c", str(path / "MissingInput.swift"), "-o", str(path / "missing.o")], capture_output=True, text=True)
    assert rejected.returncode != 0 and "inputDuration" in rejected.stderr, rejected.stderr or "Missing input unexpectedly compiled"

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
