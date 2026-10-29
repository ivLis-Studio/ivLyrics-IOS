#!/usr/bin/env python3
"""Build/inspect an unverified injection payload using Xcode and Python's standard library."""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
PACKAGING = ROOT / "packaging"
LIBRARY = "ivLyricsSpotify.dylib"
INSTALL_NAME = "@rpath/" + LIBRARY
PAYLOAD_DIRECTORY = "Library/MobileSubstrate/DynamicLibraries"
PACKAGE_ID = "kr.ivlis.ivlyrics.spotify.preview"
PACKAGE_VERSION = "0.2.0"
MIN_IOS = "17.0"
TARGET = "arm64-apple-ios" + MIN_IOS
AR_MAGIC = b"!<arch>\n"


def run(arguments: list[str], *, capture: bool = False) -> str:
    result = subprocess.run(arguments, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else ""


def xcode_tool(name: str) -> str:
    return run(["xcrun", "--sdk", "iphoneos", "--find", name], capture=True)


def parse_control(data: bytes) -> dict[str, str]:
    fields: dict[str, str] = {}
    previous = ""
    for line in data.decode("utf-8").splitlines():
        if line.startswith(" "):
            if not previous:
                raise ValueError("Invalid control continuation")
            fields[previous] += "\n" + line[1:]
        elif line:
            key, separator, value = line.partition(":")
            if not separator or key in fields:
                raise ValueError("Invalid or repeated control field")
            previous = key
            fields[key] = value.strip()
    return fields


def archive_tar(entries: dict[str, tuple[bytes, int]]) -> bytes:
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name, (data, mode) in sorted(entries.items()):
            safe = PurePosixPath(name)
            if safe.is_absolute() or ".." in safe.parts:
                raise ValueError("Unsafe archive path: " + name)
            info = tarfile.TarInfo("./" + name)
            info.size = len(data)
            info.mode = mode
            info.uid = info.gid = info.mtime = 0
            info.uname = info.gname = "root"
            archive.addfile(info, io.BytesIO(data))
    return gzip.compress(output.getvalue(), mtime=0)


def write_ar(path: Path, entries: dict[str, bytes]) -> None:
    with path.open("wb") as output:
        output.write(AR_MAGIC)
        for name, data in entries.items():
            if len(name.encode("ascii")) > 15 or "/" in name:
                raise ValueError("Unsupported ar member name")
            # Debian uses short, space-padded member names. A trailing slash is
            # interpreted literally by the BSD ar shipped with macOS.
            header = (f"{name:<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(data):<10}`\n").encode("ascii")
            if len(header) != 60:
                raise ValueError("Invalid ar header size")
            output.write(header)
            output.write(data)
            if len(data) % 2:
                output.write(b"\n")


def read_ar(path: Path) -> dict[str, bytes]:
    data = path.read_bytes()
    if not data.startswith(AR_MAGIC):
        raise ValueError("Not an ar/Debian archive")
    offset = len(AR_MAGIC)
    entries: dict[str, bytes] = {}
    while offset < len(data):
        header = data[offset:offset + 60]
        if len(header) != 60 or header[58:] != b"`\n":
            raise ValueError("Invalid ar member header")
        name = header[:16].decode("ascii").strip().removesuffix("/")
        size = int(header[48:58].decode("ascii").strip())
        offset += 60
        if size < 0 or offset + size > len(data) or name in entries:
            raise ValueError("Invalid ar member size or duplicate")
        entries[name] = data[offset:offset + size]
        offset += size + size % 2
    if offset != len(data):
        raise ValueError("Invalid ar member padding")
    return entries


def read_tar(data: bytes) -> dict[str, bytes]:
    entries: dict[str, bytes] = {}
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        for member in archive:
            path = PurePosixPath(member.name)
            name = str(path)
            if path.is_absolute() or ".." in path.parts or not member.isfile() or name in entries:
                raise ValueError("Unexpected or unsafe tar member: " + member.name)
            stream = archive.extractfile(member)
            if stream is None:
                raise ValueError("Missing tar member data")
            entries[name] = stream.read()
    return entries


def verify_dependencies(dependencies: list[str], rpaths: list[str]) -> None:
    for dependency in dependencies:
        if dependency == INSTALL_NAME:
            continue
        if dependency.startswith("/System/Library/Frameworks/"):
            continue
        if re.fullmatch(r"/usr/lib/(?:swift/)?lib[A-Za-z0-9_.+-]+\.dylib", dependency):
            continue
        if re.fullmatch(r"@rpath/libswift[A-Za-z0-9_]+\.dylib", dependency) and "/usr/lib/swift" in rpaths:
            continue
        raise ValueError("Non-system or unresolved dylib dependency: " + dependency)
    if not rpaths or any(path != "/usr/lib/swift" for path in rpaths):
        raise ValueError("Unexpected runtime search path: " + repr(rpaths))


def verify_dylib(path: Path) -> dict[str, object]:
    architecture = run([xcode_tool("lipo"), "-archs", str(path)], capture=True)
    if architecture != "arm64":
        raise ValueError("Expected a thin arm64 dylib, got " + architecture)
    headers = run([xcode_tool("otool"), "-hv", str(path)], capture=True)
    if not re.search(r"\bDYLIB\b", headers):
        raise ValueError("Mach-O file type is not MH_DYLIB")
    build = run([xcode_tool("vtool"), "-show-build", str(path)], capture=True)
    if not re.search(r"\bplatform\s+IOS\b", build) or not re.search(r"\bminos\s+17\.0(?:\.0)?\s", build + "\n"):
        raise ValueError("Expected iPhoneOS (not simulator) with minimum iOS 17.0: " + build)
    identifiers = run([xcode_tool("otool"), "-D", str(path)], capture=True).splitlines()[1:]
    if identifiers != [INSTALL_NAME]:
        raise ValueError("Unexpected LC_ID_DYLIB: " + repr(identifiers))
    load_commands = run([xcode_tool("otool"), "-l", str(path)], capture=True)
    rpaths = re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset", load_commands)
    dependencies = [line.strip().split(" (compatibility", 1)[0] for line in
                    run([xcode_tool("otool"), "-L", str(path)], capture=True).splitlines()[1:]]
    verify_dependencies(dependencies, rpaths)
    undefined = run([xcode_tool("nm"), "-u", str(path)], capture=True)
    if re.search(r"MSHook|MSFindSymbol|_logos|LHHook|Substrate", undefined):
        raise ValueError("Unexpected jailbreak hooking runtime symbol")
    symbols = run([xcode_tool("nm"), "-g", str(path)], capture=True)
    required_exports = ["_IVLyricsSpotifyBootstrap", "_IVLyricsSpotifyHostAvailabilityChanged",
                        "_IVLyricsSpotifyInstallHostHooks", "_IVLyricsSpotifyHostIsAvailable",
                        "_IVLyricsSpotifyUISetSeekHandler", "_OBJC_CLASS_$_IVLyricsSpotifyBridge",
                        "_OBJC_CLASS_$_IVLyricsSpotifyUI"]
    defined_exports = {line.split()[-1] for line in symbols.splitlines() if len(line.split()) == 3}
    if missing := set(required_exports) - defined_exports:
        raise ValueError("Missing module/host/UI entry points: " + ", ".join(sorted(missing)))
    run(["codesign", "--verify", "--strict", "--verbose=2", str(path)])
    return {"architecture": architecture, "platform": "iPhoneOS", "minimum_ios": MIN_IOS,
            "install_name": INSTALL_NAME, "dependencies": dependencies, "rpaths": rpaths,
            "required_exports": required_exports,
            "codesign": "verified ad-hoc development signature; injector must re-sign for installation",
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def verify_deb(path: Path) -> dict[str, object]:
    members = read_ar(path)
    if list(members) != ["debian-binary", "control.tar.gz", "data.tar.gz"] or members["debian-binary"] != b"2.0\n":
        raise ValueError("Unexpected Debian archive layout")
    control_files = read_tar(members["control.tar.gz"])
    if set(control_files) != {"control"}:
        raise ValueError("Maintainer scripts or unexpected control members are not permitted")
    control = parse_control(control_files["control"])
    if (control.get("Package"), control.get("Version"), control.get("Architecture")) != (PACKAGE_ID, PACKAGE_VERSION, "iphoneos-arm"):
        raise ValueError("Unexpected package identity/version/legacy architecture label")
    if any(key in control for key in ("Depends", "Pre-Depends")):
        raise ValueError("This injection archive must not require jailbreak system packages")
    payload = read_tar(members["data.tar.gz"])
    dylib_name = PAYLOAD_DIRECTORY + "/" + LIBRARY
    plist_name = PAYLOAD_DIRECTORY + "/ivLyricsSpotify.plist"
    if set(payload) != {dylib_name, plist_name}:
        raise ValueError("Payload must contain only the ivLyrics library and filter plist")
    if plistlib.loads(payload[plist_name]) != {"Filter": {"Bundles": ["com.spotify.client"]}}:
        raise ValueError("Unexpected injection bundle filter")
    with tempfile.TemporaryDirectory(prefix="ivlyrics-verify-") as directory:
        dylib = Path(directory) / LIBRARY
        dylib.write_bytes(payload[dylib_name])
        report = verify_dylib(dylib)
    return {"package": control["Package"], "version": control["Version"],
            "host_integration_verified": False, "spotify_playback_ui_adapter_implemented": True,
            "statically_inspected_spotify": {"version": "9.1.60", "build": "916001969"},
            "spotify_ipa_included": False,
            "deb_sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "dylib": report}


def swift_sources(manifest: Path) -> list[Path]:
    data = json.loads(manifest.read_text())
    listed = data.get("sources")
    if not isinstance(listed, list) or not listed or not all(isinstance(item, str) for item in listed):
        raise ValueError("Core/sources.json must contain a nonempty sources array")
    sources = []
    for name in listed:
        path = (REPO / name).resolve()
        if not path.is_relative_to(REPO.resolve()) or path.suffix != ".swift" or not path.is_file():
            raise ValueError("Source must be an existing Swift file inside this repository: " + name)
        sources.append(path)
    sources.extend(sorted((ROOT / "Core").glob("*.swift")))
    sources.extend(sorted((ROOT / "src").glob("*.swift")))
    # Harness sources under UI/Harness belong to a synthetic test app only.
    sources.extend(sorted((ROOT / "UI").glob("*.swift")))
    return list(dict.fromkeys(path.resolve() for path in sources))


def build(output: Path) -> Path:
    output.mkdir(parents=True, exist_ok=True)
    objects = output / "objects"
    objects.mkdir(exist_ok=True)
    sdk = run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], capture=True)
    sources = swift_sources(ROOT / "Core" / "sources.json")
    native_sources = sorted(path for path in (ROOT / "src").rglob("*") if path.suffix in (".m", ".mm", ".c", ".cc", ".cpp"))
    if not native_sources or not list((ROOT / "src").glob("*.swift")):
        raise ValueError("Both the supplied ObjC bootstrap and Swift runtime sources are required")
    object_files = []
    for index, source in enumerate(native_sources):
        destination = objects / f"{index}-{source.stem}.o"
        command = [xcode_tool("clang"), "-target", TARGET, "-isysroot", sdk, "-fmodules", "-O2",
                   "-fmodules-cache-path=" + str(output / "module-cache"), "-Werror=unguarded-availability-new",
                   "-I", str(ROOT / "src"), "-c", str(source), "-o", str(destination)]
        if source.suffix in (".m", ".mm"):
            command.append("-fobjc-arc")
        if source.suffix in (".mm", ".cc", ".cpp"):
            command.append("-std=c++17")
        run(command)
        object_files.append(destination)
    dylib = output / LIBRARY
    run([xcode_tool("swiftc"), "-emit-library", "-parse-as-library", "-module-name", "IVLyricsSpotify",
         "-swift-version", "5", "-target", TARGET, "-sdk", sdk, "-Onone", "-g",
         "-module-cache-path", str(output / "module-cache"),
         "-framework", "Foundation", "-framework", "UIKit", "-framework", "CryptoKit", "-framework", "NaturalLanguage",
         "-framework", "Security",
         "-Xlinker", "-install_name", "-Xlinker", INSTALL_NAME,
         "-Xlinker", "-rpath", "-Xlinker", "/usr/lib/swift",
         *map(str, sources), *map(str, object_files), "-o", str(dylib)])
    run(["codesign", "--force", "--sign", "-", "--identifier", PACKAGE_ID, "--timestamp=none", str(dylib)])
    verify_dylib(dylib)
    plist = (PACKAGING / "ivLyricsSpotify.plist").read_bytes()
    control = (PACKAGING / "control").read_bytes()
    installed_size = (dylib.stat().st_size + len(plist) + 1023) // 1024
    control += f"Installed-Size: {installed_size}\n".encode("ascii")
    deb = output / f"ivlyrics-spotify-preview_{PACKAGE_VERSION}_iphoneos-arm.deb"
    write_ar(deb, {"debian-binary": b"2.0\n", "control.tar.gz": archive_tar({"control": (control, 0o644)}),
                   "data.tar.gz": archive_tar({PAYLOAD_DIRECTORY + "/" + LIBRARY: (dylib.read_bytes(), 0o755),
                                               PAYLOAD_DIRECTORY + "/ivLyricsSpotify.plist": (plist, 0o644)})})
    report = verify_deb(deb)
    report["sdk"] = sdk
    report["sources"] = {str(path.relative_to(REPO.resolve())): hashlib.sha256(path.read_bytes()).hexdigest()
                         for path in sources + native_sources}
    inputs = [ROOT / "Core" / "sources.json", Path(__file__).resolve(), PACKAGING / "control",
              PACKAGING / "ivLyricsSpotify.plist", *sorted((ROOT / "src").glob("*.h"))]
    report["build_inputs"] = {str(path.relative_to(REPO.resolve())): hashlib.sha256(path.read_bytes()).hexdigest()
                              for path in inputs}
    (output / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"deb": str(deb), "dylib": str(dylib), "verification": str(output / "verification.json"),
                      "host_integration_verified": False, "spotify_playback_ui_adapter_implemented": True}, indent=2))
    return deb


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--allow-unverified", action="store_true", help="explicitly build the unverified development preview")
    parser.add_argument("--output", type=Path, default=PACKAGING / "out", help="build directory (default is git-ignored)")
    parser.add_argument("--verify", type=Path, metavar="DEB", help="inspect an existing preview archive without building")
    args = parser.parse_args()
    if args.verify:
        print(json.dumps(verify_deb(args.verify.resolve()), indent=2))
        return 0
    if not args.allow_unverified:
        parser.error("Spotify host integration has not been verified on a real device. "
                     "Use --allow-unverified only to build a development payload.")
    if not shutil.which("xcrun") or not shutil.which("codesign"):
        parser.error("Full Xcode command-line tools and codesign are required on macOS.")
    build(args.output.resolve())
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print("Packaging failed: " + str(error), file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        raise SystemExit(1)
