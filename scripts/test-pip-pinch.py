#!/usr/bin/env python3
"""Check the iPhone pinch-to-PiP thresholds and wiring. Physical-device verification is still required."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
trigger = (SRC / "PictureInPicturePinchTrigger.swift").read_text()
content = (SRC / "ContentView.swift").read_text()


def declaration(text, marker):
    start = text.index(marker)
    end = text.index("{", start) + 1
    depth = 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


# The recognizer must not take touches from scrolling, buttons or the existing gestures.
assert "pinch.cancelsTouchesInView = false" in trigger
assert "pinch.delaysTouchesBegan = false" in trigger and "pinch.delaysTouchesEnded = false" in trigger
assert "shouldRecognizeSimultaneouslyWith" in trigger
# The start runs from the pinch callback itself, which AVKit counts as the user's action.
evaluate = declaration(trigger, "private func evaluate(")
assert evaluate.index("isEnabled()") < evaluate.index("onTrigger()")
assert "triggered = true" in evaluate
root = declaration(content, "private func rootContent(")
assert "PictureInPicturePinchTrigger(" in root
assert "isEnabled: { canOpenPictureInPictureFromPinch }" in root
assert "onTrigger: openSystemLyricsPictureInPicture" in root
gate = declaration(content, "private var canOpenPictureInPictureFromPinch: Bool")
for required in ["model.currentTrack != nil", "!model.pictureInPictureController.isEngaged", "!vinylModeVisible",
                 "!showingSettings", "!model.initialSetupPresented", "model.inAppBrowserURL == nil"]:
    assert required in gate, required

policy = declaration(trigger, "enum PictureInPicturePinchPolicy")
checks = r'''
@main struct PinchChecks {
    static func main() {
        typealias P = PictureInPicturePinchPolicy
        var count = 0
        func check(_ condition: Bool, _ message: String) { count += 1; precondition(condition, message) }
        check(P.triggerScale == 0.72 && P.triggerDistance == 56, "Thresholds match Android")
        check(P.shouldTrigger(startDistance: 300, distance: 200), "A clear pinch-in triggers")
        check(P.shouldTrigger(startDistance: 300, distance: 216), "Exactly 72% triggers")
        check(!P.shouldTrigger(startDistance: 300, distance: 217), "Above 72% does not trigger")
        check(!P.shouldTrigger(startDistance: 150, distance: 100), "A small hand movement under 56pt does not trigger")
        check(P.shouldTrigger(startDistance: 200, distance: 144), "Exactly 56pt and 72% triggers")
        check(!P.shouldTrigger(startDistance: 200, distance: 300), "Pinch-out never triggers")
        check(!P.shouldTrigger(startDistance: 0, distance: 0), "No starting distance never triggers")
        print("PiP pinch: \(count) checks passed (thresholds and wiring; physical-device verification still required)")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-pip-pinch-") as directory:
    work = Path(directory)
    swift = work / "PinchChecks.swift"
    swift.write_text("import CoreGraphics\n" + policy + "\n" + checks)
    executable = work / "checks"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", str(swift), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=60)

