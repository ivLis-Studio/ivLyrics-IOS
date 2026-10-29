#!/usr/bin/env python3
"""Build and run an offline synthetic UIKit host; never installs Spotify."""
import argparse
import json
import plistlib
import subprocess
import time
from pathlib import Path

UI = Path(__file__).resolve().parent
ROOT = UI.parents[1]
BUNDLE = "kr.ivlis.ivlyrics.tweak-ui-harness"


def run(args, **kwargs):
    kwargs.setdefault("check", True)
    return subprocess.run(args, text=True, **kwargs)


def output(args):
    return run(args, capture_output=True).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="Dedicated iOS simulator UUID")
    args = parser.parse_args()
    work = UI / ".build"
    app = work / "ivLyricsUIHarness.app"
    app.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((ROOT / "spotify-tweak/Core/sources.json").read_text())
    sdk = output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"])
    sources = [ROOT / source for source in manifest["sources"]]
    sources += sorted(UI.glob("*.swift")) + [UI / "Harness/HarnessMain.swift"]
    command = ["xcrun", "--sdk", "iphonesimulator", "swiftc", "-swift-version", "5", "-parse-as-library", "-target", "arm64-apple-ios17.0-simulator",
               "-sdk", sdk, "-module-name", "IVLyricsUIHarness", "-g", "-Onone"]
    for framework in dict.fromkeys(manifest["frameworks"] + ["UIKit", "UniformTypeIdentifiers"]):
        command += ["-framework", framework]
    run(command + list(map(str, sources)) + ["-o", str(app / "ivLyricsUIHarness")])
    (app / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": BUNDLE, "CFBundleExecutable": "ivLyricsUIHarness", "CFBundleName": "ivLyrics UI Fixture",
        "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
        "MinimumOSVersion": "17.0", "LSRequiresIPhoneOS": True, "UIDeviceFamily": [1, 2],
        "UILaunchScreen": {}, "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"]
    }))
    run(["codesign", "--force", "--sign", "-", str(app)], capture_output=True)
    devices = json.loads(output(["xcrun", "simctl", "list", "devices", "--json"]))
    device = next(d for group in devices["devices"].values() for d in group if d["udid"] == args.device)
    if device["state"] != "Booted":
        run(["xcrun", "simctl", "boot", args.device])
    run(["xcrun", "simctl", "bootstatus", args.device, "-b"])
    run(["xcrun", "simctl", "install", args.device, str(app)])
    container = Path(output(["xcrun", "simctl", "get_app_container", args.device, BUNDLE, "data"]))
    result = container / "Documents/ui-checks.json"
    if result.exists():
        result.unlink()  # Only this fixture's previous generated result.
    run(["xcrun", "simctl", "terminate", args.device, BUNDLE], capture_output=True, check=False)
    run(["xcrun", "simctl", "launch", args.device, BUNDLE])
    deadline = time.monotonic() + 60
    while not result.exists():
        if time.monotonic() > deadline:
            raise RuntimeError("Synthetic UIKit harness did not finish within 60 seconds")
        time.sleep(0.5)
    report = json.loads(result.read_text())
    (work / "ui-checks.json").write_text(json.dumps(report, indent=2) + "\n")
    run(["xcrun", "simctl", "io", args.device, "screenshot", str(work / "ui-screenshot.png")])
    print(json.dumps({"report": report, "screenshot": str(work / "ui-screenshot.png"), "spotify_runtime_tested": False}, indent=2))
    if report["failures"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
