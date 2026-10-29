#!/usr/bin/env python3
"""Inspect an IPA's plist and Mach-O headers without extracting or changing it.

Usage: python3 inspect_ipa.py input.ipa
JSON is written to stdout. Exit 0 means inspection completed (even if encrypted);
exit 2 means the archive or selected main executable could not be inspected.
This is not a loader, signature verifier, decrypter, or compatibility test.
Only selected entry headers are read; the executable's full ZIP CRC is not checked.
"""

import argparse
import json
import lzma
import plistlib
import stat
import struct
import sys
import zipfile
import zlib
from pathlib import Path
from xml.parsers.expat import ExpatError

MAX_PLIST_BYTES = 2 * 1024 * 1024
MAX_EXECUTABLE_BYTES = 512 * 1024 * 1024
MAX_COMMAND_BYTES = 4 * 1024 * 1024
MAX_ARCHITECTURES = 64
MAX_COMMANDS = 4096
THIN_MAGICS = {
    b"\xce\xfa\xed\xfe": ("<", False), b"\xcf\xfa\xed\xfe": ("<", True),
    b"\xfe\xed\xfa\xce": (">", False), b"\xfe\xed\xfa\xcf": (">", True),
}
FAT_MAGICS = {
    b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
    b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True),
}
CPU_NAMES = {7: "i386", 0x01000007: "x86_64", 12: "arm", 0x0100000C: "arm64",
             0x0200000C: "arm64_32", 18: "ppc", 0x01000012: "ppc64"}
PLATFORMS = {
    1: ("macOS", "other"), 2: ("iOS", "device"), 3: ("tvOS", "device"),
    4: ("watchOS", "device"), 5: ("bridgeOS", "device"),
    6: ("Mac Catalyst", "other"), 7: ("iOS Simulator", "simulator"),
    8: ("tvOS Simulator", "simulator"), 9: ("watchOS Simulator", "simulator"),
    10: ("DriverKit", "other"), 11: ("visionOS", "device"),
    12: ("visionOS Simulator", "simulator"),
}


class InspectionError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise InspectionError(message)


def version(value):
    return f"{value >> 16}.{(value >> 8) & 255}.{value & 255}"


class EntryReader:
    """Bounded random reads inside a ZipExtFile; never extracts to disk."""

    def __init__(self, stream, size):
        self.stream, self.size = stream, size
        self.cached_offset, self.cached_data = 0, b""

    def read(self, offset, size):
        require(0 <= offset <= self.size and 0 <= size <= self.size - offset,
                "Mach-O read extends beyond the executable entry")
        # Reuse overlapping header reads instead of repeatedly inflating the ZIP
        # from its beginning when inspecting a slice far into a fat executable.
        cached_end = self.cached_offset + len(self.cached_data)
        prefix = b""
        if self.cached_offset <= offset < cached_end:
            prefix = self.cached_data[offset - self.cached_offset:offset - self.cached_offset + size]
        if len(prefix) == size:
            return prefix
        self.stream.seek(offset + len(prefix))
        data = prefix + self.stream.read(size - len(prefix))
        require(len(data) == size, "Truncated executable entry")
        self.cached_offset, self.cached_data = offset, data
        return data


def inspect_slice(reader, offset, size, expected_cpu=None):
    require(size >= 28, "Truncated Mach-O header")
    header_data = reader.read(offset, min(size, 32))
    magic = header_data[:4]
    require(magic in THIN_MAGICS, "Main executable slice is not a Mach-O binary")
    endian, is64 = THIN_MAGICS[magic]
    header_size = 32 if is64 else 28
    require(size >= header_size, "Truncated Mach-O header")
    header = struct.unpack(endian + ("8I" if is64 else "7I"), header_data[:header_size])
    _, cpu, subtype, file_type, ncmds, command_size, _ = header[:7]
    require(file_type == 2, f"Main executable slice has Mach-O file type {file_type}, expected MH_EXECUTE (2)")
    require(expected_cpu is None or (cpu, subtype) == expected_cpu,
            "Fat architecture table does not match its Mach-O slice")
    require(ncmds <= MAX_COMMANDS, "Too many Mach-O load commands")
    require(command_size <= MAX_COMMAND_BYTES, "Mach-O load command area exceeds inspection limit")
    require(ncmds * 8 <= command_size <= size - header_size, "Invalid Mach-O load command bounds")
    commands = reader.read(offset + header_size, command_size)
    platforms, encryptions = [], []
    cursor = 0
    for _ in range(ncmds):
        require(cursor + 8 <= command_size, "Truncated Mach-O load command")
        cmd, cmdsize = struct.unpack_from(endian + "II", commands, cursor)
        require(cmdsize >= 8 and cmdsize % (8 if is64 else 4) == 0,
                "Invalid Mach-O load command size or alignment")
        require(cmdsize <= command_size - cursor, "Mach-O load command exceeds command area")
        if cmd == 0x32:  # LC_BUILD_VERSION
            require(cmdsize >= 24, "Truncated LC_BUILD_VERSION")
            platform, minimum, sdk, ntools = struct.unpack_from(endian + "4I", commands, cursor + 8)
            require(ntools <= (cmdsize - 24) // 8, "LC_BUILD_VERSION tools exceed command bounds")
            name, environment = PLATFORMS.get(platform, (f"unknown ({platform})", "unknown"))
            platforms.append({"id": platform, "name": name, "environment": environment,
                              "minimum_os": version(minimum), "sdk": version(sdk),
                              "source": "LC_BUILD_VERSION"})
        elif cmd in (0x24, 0x25, 0x2F, 0x30):
            require(cmdsize >= 16, "Truncated LC_VERSION_MIN command")
            minimum, sdk = struct.unpack_from(endian + "II", commands, cursor + 8)
            platform = {0x24: 1, 0x25: 2, 0x2F: 3, 0x30: 4}[cmd]
            # Legacy commands predate an explicit simulator platform identifier.
            if platform in (2, 3, 4) and cpu in (7, 0x01000007):
                platform += 5
            name, environment = PLATFORMS[platform]
            platforms.append({"id": platform, "name": name, "environment": environment,
                              "minimum_os": version(minimum), "sdk": version(sdk),
                              "source": "LC_VERSION_MIN (environment inferred from architecture)"})
        elif cmd in (0x21, 0x2C):  # LC_ENCRYPTION_INFO / LC_ENCRYPTION_INFO_64
            require(cmdsize >= (24 if cmd == 0x2C else 20), "Truncated LC_ENCRYPTION_INFO")
            cryptoff, cryptsize, cryptid = struct.unpack_from(endian + "3I", commands, cursor + 8)
            require(cryptoff <= size and cryptsize <= size - cryptoff,
                    "Encryption range extends beyond Mach-O slice")
            encryptions.append({"cryptid": cryptid, "offset": cryptoff, "size": cryptsize})
        cursor += cmdsize
    require(cursor == command_size, "Mach-O sizeofcmds does not match its load commands")
    identities = {(p["id"], p["environment"]) for p in platforms}
    require(len(identities) <= 1, "Conflicting Mach-O platform load commands")
    encrypted = any(item["cryptid"] != 0 for item in encryptions) if encryptions else None
    architecture = CPU_NAMES.get(cpu, f"unknown (0x{cpu:x})")
    if cpu == 0x0100000C and (subtype & 0xFFFFFF) == 2:
        architecture = "arm64e"
    return {"architecture": architecture, "cpu_type": cpu, "cpu_subtype": subtype,
            "is_64_bit": is64, "byte_order": "little" if endian == "<" else "big",
            "offset": offset, "size": size, "file_type": "MH_EXECUTE",
            "platforms": platforms, "encryption_commands": encryptions, "encrypted": encrypted}


def inspect_macho(reader):
    require(reader.size >= 4, "Executable is too short to contain Mach-O magic")
    magic = reader.read(0, 4)
    if magic in THIN_MAGICS:
        return {"format": "thin", "slices": [inspect_slice(reader, 0, reader.size)]}
    require(magic in FAT_MAGICS, "Main executable is not a Mach-O binary")
    require(reader.size >= 8, "Truncated fat Mach-O header")
    endian, fat64 = FAT_MAGICS[magic]
    count = struct.unpack(endian + "I", reader.read(4, 4))[0]
    require(0 < count <= MAX_ARCHITECTURES, "Invalid fat Mach-O architecture count")
    entry_size = 32 if fat64 else 20
    table_end = 8 + count * entry_size
    table = reader.read(8, count * entry_size)
    slices = []
    identities = set()
    for index in range(count):
        entry = struct.unpack_from(endian + ("IIQQII" if fat64 else "5I"), table, index * entry_size)
        cpu, subtype, offset, size, alignment = entry[:5]
        require(alignment <= (63 if fat64 else 31), "Invalid fat Mach-O alignment exponent")
        require(offset >= table_end and offset <= reader.size and size <= reader.size - offset,
                "Fat Mach-O slice extends beyond executable or overlaps architecture table")
        require(offset % (1 << alignment) == 0, "Misaligned fat Mach-O slice")
        require((cpu, subtype) not in identities, "Duplicate fat Mach-O architecture")
        identities.add((cpu, subtype))
        slices.append((offset, size, cpu, subtype))
    slices.sort()
    for current, following in zip(slices, slices[1:]):
        require(current[0] + current[1] <= following[0], "Overlapping fat Mach-O slices")
    return {"format": "fat64" if fat64 else "fat", "slices": [
        inspect_slice(reader, offset, size, (cpu, subtype)) for offset, size, cpu, subtype in slices
    ]}


def selected_entry(archive, name, maximum):
    matches = [info for info in archive.infolist() if info.filename == name]
    require(len(matches) == 1, f"Expected exactly one ZIP entry for {name}")
    info = matches[0]
    require(not info.is_dir() and not stat.S_ISLNK(info.external_attr >> 16),
            f"Selected ZIP entry is a directory or symlink: {name}")
    require(not info.flag_bits & 1, f"Password-encrypted ZIP entry is unsupported: {name}")
    require(0 < info.file_size <= maximum, f"ZIP entry size is empty or exceeds inspection limit: {name}")
    return info


def inspect_ipa(path):
    report = {"schema_version": 1, "input": str(path), "inspection_status": "invalid",
              "compatibility_verified": False,
              "inspection_scope": "Metadata and Mach-O headers only; no signature, full ZIP CRC, host hook, or device runtime validation",
              "warnings": [], "errors": []}
    try:
        with zipfile.ZipFile(path, "r") as archive:
            candidates = [info.filename for info in archive.infolist()
                          if len(info.filename.split("/")) == 3
                          and info.filename.startswith("Payload/")
                          and info.filename.split("/")[1].endswith(".app")
                          and info.filename.endswith("/Info.plist")]
            require(len(candidates) == 1, "IPA must contain exactly one top-level Payload/*.app/Info.plist")
            plist_path = candidates[0]
            info = selected_entry(archive, plist_path, MAX_PLIST_BYTES)
            with archive.open(info) as stream:
                data = stream.read(MAX_PLIST_BYTES + 1)
            require(len(data) == info.file_size, "Info.plist size does not match ZIP metadata")
            try:
                metadata = plistlib.loads(data)
            except Exception as error:
                # plistlib also raises AttributeError for malformed <date>
                # elements. Keep parser failures in the JSON error contract.
                raise InspectionError(f"Unable to parse Info.plist: {error}") from error
            require(isinstance(metadata, dict), "Info.plist root must be a dictionary")
            executable = metadata.get("CFBundleExecutable")
            require(isinstance(executable, str) and executable not in ("", ".", "..")
                    and not any(char in executable for char in ("/", "\\", "\0")),
                    "CFBundleExecutable must be a nonempty file name, not a path")
            fields = {"identifier": "CFBundleIdentifier", "short_version": "CFBundleShortVersionString",
                      "version": "CFBundleVersion", "minimum_os_version": "MinimumOSVersion"}
            for key in fields.values():
                require(metadata.get(key) is None or isinstance(metadata[key], str),
                        f"{key} must be a string if present")
            report["bundle"] = {label: metadata.get(key) for label, key in fields.items()}
            report["bundle"]["executable"] = executable
            app_path = plist_path.rsplit("/", 1)[0]
            executable_path = app_path + "/" + executable
            report["archive"] = {"app_bundle_path": app_path, "executable_path": executable_path}
            info = selected_entry(archive, executable_path, MAX_EXECUTABLE_BYTES)
            with archive.open(info) as stream:
                macho = inspect_macho(EntryReader(stream, info.file_size))
            report["executable"] = macho
            encrypted = [item["encrypted"] for item in macho["slices"]]
            macho["encrypted"] = True if True in encrypted else (None if None in encrypted else False)
            if macho["encrypted"] is True:
                report["warnings"].append("Main executable contains encrypted code (nonzero cryptid); this is not a decrypted IPA")
            elif macho["encrypted"] is None:
                report["warnings"].append("At least one slice has no encryption command; decryption status is unknown")
            for item in macho["slices"]:
                if not item["platforms"]:
                    report["warnings"].append(f"{item['architecture']} has no recognized platform load command")
                elif any(p["id"] != 2 for p in item["platforms"]):
                    report["warnings"].append(f"{item['architecture']} is not identified as an iOS device slice")
            report["inspection_status"] = "complete"
    except (OSError, ValueError, TypeError, OverflowError, struct.error, zipfile.BadZipFile,
            NotImplementedError, RuntimeError, EOFError, ExpatError, zlib.error, lzma.LZMAError) as error:
        report["errors"].append(str(error))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("ipa", type=Path)
    args = parser.parse_args()
    report = inspect_ipa(args.ipa)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["inspection_status"] == "complete" else 2


if __name__ == "__main__":
    sys.exit(main())
