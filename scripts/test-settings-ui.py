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
assert "height: 44" in declaration(declaration(controls, "struct SettingsSlider:"), "func sizeThatFits(")
assert 'SettingsSearchField(prompt: settings.t("settings.search")' in content and '"settings.search"' in ui_tests
native_search = declaration(controls, "struct SettingsSearchField:")
assert "UITextField()" in native_search and "max(48, preferredFont.lineHeight + 20)" in native_search
assert "field.adjustsFontSizeToFitWidth = false" in native_search
assert 'field.accessibilityIdentifier = "settings.search"' in native_search
assert "func textFieldShouldReturn(" in native_search and "field.resignFirstResponder()" in native_search
update_search = declaration(native_search, "func updateUIView(")
assert "scheduleFocus(field)" in update_search
assert "becomeFirstResponder()" not in update_search and "resignFirstResponder()" not in update_search
assert "if field.font != font" in update_search
assert ".strokeBorder(SettingsDesign.strongBorder)" in controls
assert 'SettingsActionLabel(title: resetTitle)' in popup
assert 'SettingsActionLabel(title: delta > 0' in popup
assert 'lyrics.menu.offset.video.delta.' in ui_tests and 'lyrics.menu.offset.video.reset' in ui_tests
assert '.accessibilityIdentifier("settings.root")' not in declaration(content, "struct SettingsView:")
assert 'case "accessibility5": return .accessibility5' in harness
assert ui_tests.count('textSize: "accessibility5"') >= 2
assert "viewport.contains(element.frame)" in ui_tests and "frame.minY < viewport.minY" in ui_tests
assert "withVelocity: .slow, thenHoldForDuration: 0.25" in ui_tests
assert '"lyrics.menu.video.apply"' in popup and '"lyrics.menu.regenerate"' in popup
assert 'settings.t("tmi.regenerate")' not in popup
assert 'Color.black.opacity(0.56)' in popup and 'scrollableContentHeight' not in popup
assert "attachment.lifetime = .keepAlways" in ui_tests and "XCUIScreen.main.screenshot()" in ui_tests
assert "launch-\\(surface)-missing-marker" in ui_tests and "invalid-touch-target-" in ui_tests
assert "XCTAssertGreaterThanOrEqual(element.frame.height, 44" in ui_tests

drag_math = declaration(ui_tests, "private static func revealDragDistance(").replace("private static func", "func", 1)
drag_checks = r'''
let viewport = CGRect(x: 236, y: 96, width: 402, height: 262)
let above = CGRect(x: 236, y: 42.3, width: 402, height: 68) // Exact fourth-CI failure.
let below = CGRect(x: 236, y: 357, width: 402, height: 68)
let down = revealDragDistance(for: above, in: viewport)
let up = revealDragDistance(for: below, in: viewport)
precondition(abs(down - 77.7) < 0.0001 && viewport.contains(above.offsetBy(dx: 0, dy: down)))
precondition(abs(up + 91) < 0.0001 && viewport.contains(below.offsetBy(dx: 0, dy: up)))
precondition(revealDragDistance(for: above.offsetBy(dx: 0, dy: down), in: viewport) == 0)
// Exact fifth-CI near-edge failures: the prior 9–10pt gesture never started a pan.
let almostVisible = CGRect(x: 236, y: 292, width: 402, height: 68)
let edgeDrag = revealDragDistance(for: almostVisible, in: viewport)
precondition(abs(edgeDrag + 26) < 0.0001)
for slop: CGFloat in [0, 10, 16] {
    precondition(viewport.contains(almostVisible.offsetBy(dx: 0, dy: edgeDrag + slop)))
}
let aiViewport = CGRect(x: 1, y: 242, width: 400, height: 631)
let almostVisibleSwitch = CGRect(x: 305.5, y: 846.7, width: 61, height: 28)
let switchDrag = revealDragDistance(for: almostVisibleSwitch, in: aiViewport)
precondition(abs(switchDrag + 25.7) < 0.0001)
precondition(aiViewport.contains(almostVisibleSwitch.offsetBy(dx: 0, dy: switchDrag + 16)))
for y: CGFloat in [-1000, 1000] {
    let distance = revealDragDistance(for: CGRect(x: 236, y: y, width: 402, height: 68), in: viewport)
    precondition(abs(distance) <= viewport.height * 0.4)
    precondition(viewport.minY < viewport.midY + distance && viewport.midY + distance < viewport.maxY)
}
precondition(revealDragDistance(for: nil, in: viewport) < 0)
print("Settings UI regression: exact native reveal frames, direction, containment and bounded drag checks passed")
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-settings-drag-") as temp:
    path = Path(temp)
    (path / "Drag.swift").write_text("import Foundation\nimport CoreGraphics\n" + drag_math + drag_checks)
    subprocess.run(["xcrun", "swiftc", str(path / "Drag.swift"), "-o", str(path / "drag")], check=True)
    subprocess.run([str(path / "drag")], check=True)

# Execute the real coordinator's deferred focus logic with an SDK-free field double.
# UIKit rendering still requires native CI, but stale queued requests and synchronous
# responder changes are deterministic host regressions rather than timing guesses.
coordinator = declaration(native_search, "final class Coordinator:")
focus_prelude = r'''
import Foundation
protocol UITextFieldDelegate {}
final class UITextField: NSObject {
    var text: String? = ""
    var window: NSObject? = NSObject()
    var isFirstResponder = false
    var becomes = 0, resigns = 0
    func becomeFirstResponder() { isFirstResponder = true; becomes += 1 }
    func resignFirstResponder() { isFirstResponder = false; resigns += 1 }
}
final class InputState { var text = "", focused = false }
struct SettingsSearchField {
    let state: InputState
    var text: String { get { state.text } nonmutating set { state.text = newValue } }
    var isFocused: Bool { get { state.focused } nonmutating set { state.focused = newValue } }
}
'''
focus_checks = r'''
@main struct FocusChecks {
    @MainActor static func main() async throws {
        let state = InputState(), field = UITextField()
        let coordinator = Coordinator(SettingsSearchField(state: state))
        var checks = 0
        func check(_ value: @autoclosure () -> Bool) {
            checks += 1; precondition(value(), "Native search focus contract failed")
        }
        state.focused = true; coordinator.scheduleFocus(field)
        check(!field.isFirstResponder) // No UIKit focus change during updateUIView.
        try await Task.sleep(for: .milliseconds(10))
        check(field.isFirstResponder && field.becomes == 1)
        coordinator.scheduleFocus(field)
        try await Task.sleep(for: .milliseconds(10))
        check(field.becomes == 1) // Idempotent updates do not reopen the keyboard.
        state.focused = false; coordinator.scheduleFocus(field)
        check(field.isFirstResponder)
        try await Task.sleep(for: .milliseconds(10))
        check(!field.isFirstResponder && field.resigns == 1)
        state.focused = true; coordinator.scheduleFocus(field)
        state.focused = false; coordinator.scheduleFocus(field)
        try await Task.sleep(for: .milliseconds(10))
        check(!field.isFirstResponder && field.becomes == 1)
        state.focused = true; coordinator.scheduleFocus(field); coordinator.cancelFocusRequests()
        try await Task.sleep(for: .milliseconds(10))
        check(!field.isFirstResponder)
        field.window = nil; coordinator.scheduleFocus(field)
        try await Task.sleep(for: .milliseconds(10))
        check(!field.isFirstResponder)
        field.text = "artist"; coordinator.changed(field)
        check(state.text == "artist")
        state.focused = false; coordinator.textFieldDidBeginEditing(field)
        check(state.focused)
        coordinator.textFieldDidEndEditing(field)
        check(!state.focused)
        field.isFirstResponder = true; state.focused = true
        check(coordinator.textFieldShouldReturn(field) && !state.focused && !field.isFirstResponder)
        print("Settings UI regression: \(checks) deferred native-search focus checks passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-settings-focus-") as temp:
    path = Path(temp)
    (path / "Focus.swift").write_text(focus_prelude + coordinator + focus_checks)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(path / "Focus.swift"), "-o", str(path / "focus")], check=True)
    subprocess.run([str(path / "focus")], check=True)

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
            let oldTask = p.manualTask
            p.inputTitle = "fresh"; p.searchManualCandidates()
            let currentTask = p.manualTask
            await oldTask?.value
            await currentTask?.value
            check(p.manualCandidates == ["fresh"], "Late cancelled completion cannot replace new results")
            check(!p.searchingManualCandidates, "Latest request clears busy state")
            check(p.toasts.isEmpty, "Cancellation must not emit an error toast")
        }
        let empty = Probe(); empty.inputTitle = "slow-error"; empty.searchManualCandidates()
        let canceledTask = empty.manualTask
        empty.inputTitle = ""; empty.searchManualCandidates()
        await canceledTask?.value
        check(empty.manualCandidates.isEmpty && !empty.searchingManualCandidates, "Empty search cancels previous request")
        check(empty.manualLrclibStatus == "lyrics.lrclib_search.empty_title" && empty.toasts.isEmpty, "Cancelled error cannot replace empty-state feedback")
        let moved = Probe(); moved.inputTitle = "slow-success"; moved.searchManualCandidates()
        moved.currentTrackKey = "replacement"
        await moved.manualTask?.value
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
