#!/usr/bin/env python3
"""Compile the production ObjC adapter against a synthetic macOS host, offline.

This validates ABI gates, IMP chaining, metadata, seek and native-view restoration.
UIKit geometry, real Spotify execution and signing are explicitly not covered.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    fixtures = ROOT / "tools" / "fixtures"
    with tempfile.TemporaryDirectory(prefix="ivlyrics-host-") as folder:
        binary = Path(folder) / "host-fixture"
        subprocess.run([
            "xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fblocks", "-fmodules",
            "-DIVL_HOST_TESTING=1", "-Wall", "-Wextra", "-Wno-unused-parameter",
            "-I", str(fixtures), "-I", str(ROOT / "src"),
            str(ROOT / "src" / "SpotifyHost.m"), str(fixtures / "HostFixture.m"),
            "-framework", "Foundation", "-o", str(binary),
        ], check=True)
        for mode in ("version", "build", "executable", "missing", "seek_abi", "layout_abi", "lyrics_missing", "lyrics_superclass", "thread", "valid"):
            subprocess.run([str(binary), mode], check=True)
    print("Host fixtures passed. Actual Spotify / UIKit behavior remains unverified.")


if __name__ == "__main__":
    main()
