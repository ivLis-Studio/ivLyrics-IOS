#!/usr/bin/env python3
"""Check production PiP rectangles and supplement roles on host Swift.

Verifies geometry/text metadata only, not UIKit/SwiftUI pixels or visual quality.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
controller = (SRC / "LyricsPictureInPictureController.swift").read_text()
settings = (SRC / "AppSettings.swift").read_text()
models = (SRC / "Models.swift").read_text()


def declaration(source, prefix):
    start = source.index(prefix)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end].replace("private ", "")


code = 'import Foundation\nimport CoreGraphics\nextension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }\n'
code += models[models.index("struct LyricsLine:"):models.index("enum LyricsTextShaping {")]
code += 'enum IvLyricsUtilities { static func lyricsTextsEquivalent(_ left: String, _ right: String) -> Bool { left.trimmed == right.trimmed } }\n'
code += "enum AppSettings {\n"
for name in ["pipOrientationPortrait", "pipOrientationSquare", "pipOrientationLandscape", "typoLyricsPronunciation", "typoLyricsTranslation"]:
    code += next(line for line in settings.splitlines() if line.strip().startswith(f"static let {name} =")) + "\n"
code += declaration(settings, "static func normalizePipOrientation(") + "\n}\n"
code += declaration(controller, "private struct PictureInPictureFrameLayout {") + "\n"
code += declaration(controller, "private struct PictureInPictureSupplementLine:") + "\n"
code += declaration(controller, "private struct ActiveLine {") + "\n"
code += 'struct LayoutProbe { struct State { var orientation: String; var showArtwork: Bool }; var state: State\n'
code += declaration(controller, "private func frameLayout(in") + "\n}\n"
assert "ForEach(active.supplements)" in controller
assert ".fixedSize(horizontal: false, vertical: true)" in controller
assert "preparationStore: karaokePreparationStore" in controller
assert "sourceLineIndex: active.index" in controller
checks = r'''
var count = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    count += 1
    if !value() { fatalError(label) }
}
for (orientation, width, height) in [("portrait", 360.0, 640.0), ("square", 480, 480), ("landscape", 640, 360)] {
    let canvas = CGRect(x: 0, y: 0, width: width, height: height)
    for artwork in [true, false] {
        let layout = LayoutProbe(state: .init(orientation: orientation, showArtwork: artwork)).frameLayout(in: canvas)
        check(canvas.contains(layout.lyricsRect) && !layout.lyricsRect.isEmpty, "Lyrics remain within every orientation")
        if artwork {
            check(!layout.lyricsRect.intersects(layout.artworkRect), "Artwork never occupies the reserved lyric area")
            check(!layout.lyricsRect.intersects(layout.titleRect) && !layout.lyricsRect.intersects(layout.artistRect), "Metadata never overlaps lyrics")
            if orientation != "landscape" {
                check(layout.lyricsRect.minY >= layout.artworkRect.maxY + 18, "Portrait/square reserve artwork and breathing room")
                check(layout.lyricsRect.maxY <= canvas.maxY - 16, "Wrapped supplements retain bottom margin")
            }
        } else {
            check(layout.lyricsRect.minY == 0 && layout.lyricsRect.height == height, "Hiding artwork preserves full-height lyrics")
        }
    }
}
var line = LyricsLine(startTimeMs: 0, endTimeMs: 5000, text: "Original",
                      pronunciationText: "Reading first\nReading second", translationText: "번역 첫째\n번역 둘째")
var active = ActiveLine(line: line, index: 0, progress: 0.5)
check(active.supplements.map(\.text) == [line.pronunciationText, line.translationText], "Every supplement keeps its multiline text")
check(active.supplements.map(\.typographySlotID) == [AppSettings.typoLyricsPronunciation, AppSettings.typoLyricsTranslation], "Reading and translation use separate typography slots")
line.pronunciationText = "Original"
active.line = line
check(active.supplements.count == 1 && active.supplements.first?.id == "translation", "Duplicate pronunciation is omitted without losing translation")
check(active.supplements.first?.typographySlotID == AppSettings.typoLyricsTranslation, "Translation-only content keeps its own font")
active.line.pronunciationText = ""
active.line.translationText = ""
check(active.supplements.isEmpty, "Empty supplements add no rows")
print("PIP_LAYOUT_PASSED assertions=\(count)")
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-ios-pip-layout-") as directory:
    work = Path(directory)
    main = work / "main.swift"
    main.write_text(code + checks)
    subprocess.run(["xcrun", "swiftc", str(main), "-o", str(work / "checks")], check=True)
    subprocess.run([str(work / "checks")], check=True)
