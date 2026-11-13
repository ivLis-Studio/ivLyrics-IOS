#!/usr/bin/env python3
"""Check the iPhone Duo vertical-bar settings wiring. Rendering needs the iOS 27.1 SDK and an iPhone Duo."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
bar = (SRC / "VerticalBar.swift").read_text()
content = (SRC / "ContentView.swift").read_text()
harness = (SRC / "DebugSettingsUIHarness.swift").read_text()


def declaration(text, marker):
    start = text.index(marker)
    end = text.index("{", start) + 1
    depth = 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


count = 0


def check(condition, message):
    global count
    count += 1
    assert condition, message


# The 27.1 APIs exist only in SwiftUI 8.0.85+ (the iOS 27.0 SDK lacks them) and only run on iOS 27.1+.
guard = "#if canImport(SwiftUI, _version: 8.0.85)"
code = "\n".join(line for line in bar.splitlines() if not line.strip().startswith("//"))
check(code.count(guard) == 3, "every 27.1 API use is behind the SwiftUI SDK version guard")
for api in ["toolbarVerticalEdge", "NavigationStack"]:
    for match in re.finditer(api, code):
        before = code[:match.start()]
        check(before.rfind(guard) > before.rfind("#endif"), f"{api} is compiled only with the 27.1 SDK")
host = declaration(bar, "struct VerticalBarHost")
check("if #available(iOS 27.1, *)" in host, "the navigation container is added only on iOS 27.1+")
check(host.count("content") >= 3, "older SDKs and systems keep the bare root")
toolbar = declaration(bar, "private struct VerticalBarSettingsToolbar")
check("@available(iOS 27.1, *)" in bar[:bar.index("private struct VerticalBarSettingsToolbar")], "the toolbar modifier is 27.1-only")
check("let vertical = allowed && toolbarVerticalEdge != nil" in toolbar, "only a system vertical bar takes the item")
# Horizontal-bar devices and poses keep their layout: the navigation bar stays hidden there.
check(".toolbar(vertical ? .visible : .hidden, for: .navigationBar)" in toolbar, "the bar is hidden without a vertical bar")
check("if vertical && !hidden" in toolbar and "ToolbarItem(placement: .topBarTrailing)" in toolbar, "the item sits in the system bar")
check('Label(title, systemImage: "ellipsis")' in toolbar, "the item carries a title for overflow and VoiceOver")
check(".onChange(of: vertical, initial: true)" in toolbar and "placed = value" in toolbar, "the page learns where the button is")

# Production and the player UI fixture both host the root in the container.
app_root = declaration(content, "private struct ProductionAppRoot")
check(re.search(r"VerticalBarHost \{\s*ContentView\(\)\s*\}", app_root) is not None, "the app root is hosted")
check(re.search(r"VerticalBarHost \{\s*ContentView\(\)\s*\}", harness) is not None, "the player fixture is hosted")

body = declaration(content, "    var body: some View {\n        GeometryReader { geometry in\n            let isLandscape")
item = body[body.index(".verticalBarSettingsItem("):]
check("allowed: !isLandscape" in item, "landscape keeps its own auto-hiding command bar")
check("hidden: verticalBarSettingsCovered" in item and "placed: $settingsInVerticalBar" in item, "item state is wired")
check("showingSettings = true" in item[:item.index(".contentShape")], "the item opens settings")
covered = declaration(content, "private var verticalBarSettingsCovered: Bool")
for overlay in ["vinylModeVisible", "showingLyricsMetaMenu", "showingLogs", "model.inAppBrowserURL != nil",
                "model.tmiPresented", "model.updateDialogPresented", "model.firstLanguagePrompt != nil",
                "model.researchTokenConsentPresented"]:
    check(overlay in covered, f"{overlay} covers the vertical-bar item like the page button")
check("lyricsPageVisible" not in covered, "the lyrics page keeps the vertical-bar item")

# The page buttons give way only when the system bar has the item.
portrait = declaration(content, "private func portraitContent(")
row = portrait[portrait.index("if !settingsInVerticalBar {"):portrait.index("Spacer(minLength: 0)")]
check("AndroidMoreIcon()" in row and ".frame(height: 56)" in row, "the main page row is dropped with its button")
overlay = declaration(content, "private struct LyricsPageOverlay")
header = overlay[overlay.index("if !settingsInVerticalBar {"):]
check(header.index("Button(action: openSettings)") < header.index('.accessibilityIdentifier("lyrics.settings")'), "the lyrics header button is gated")
check("settingsInVerticalBar: settingsInVerticalBar," in declaration(content, "private func overlayContent("), "the lyrics page is told")
landscape = declaration(content, "private struct LandscapeCommandBar")
check("settingsInVerticalBar" not in landscape, "the landscape command bar is unchanged")

print(f"iPhone Duo vertical bar: {count} checks passed (wiring only; rendering needs the iOS 27.1 SDK on an iPhone Duo)")
