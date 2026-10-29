#!/usr/bin/env python3
"""Synthetic archive/header regressions; no Spotify IPA or device is involved."""

import hashlib
import io
import json
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
import warnings
import zipfile
from pathlib import Path

import inspect_ipa as inspector


def macho(cpu=0x0100000C, subtype=0, platform=2, cryptid=0, endian="<", is64=True,
          legacy=False, encryption=True, file_type=2):
    minimum, sdk = 17 << 16, (18 << 16) | (1 << 8)
    build = (struct.pack(endian + "4I", 0x25, 16, minimum, sdk) if legacy else
             struct.pack(endian + "6I", 0x32, 24, platform, minimum, sdk, 0))
    header_size, crypt_size = (32, 24) if is64 else (28, 20)
    payload_offset = header_size + len(build) + (crypt_size if encryption else 0)
    crypt = struct.pack(endian + ("6I" if is64 else "5I"),
                        *([0x2C if is64 else 0x21, crypt_size, payload_offset, 32, cryptid]
                          + ([0] if is64 else []))) if encryption else b""
    commands = build + crypt
    header = [0xFEEDFACF if is64 else 0xFEEDFACE, cpu, subtype, file_type,
              2 if encryption else 1, len(commands), 0] + ([0] if is64 else [])
    return struct.pack(endian + f"{len(header)}I", *header) + commands + bytes(32)


def fat(slices, endian=">", fat64=False):
    entry_size = 32 if fat64 else 20
    next_offset = ((8 + len(slices) * entry_size + 255) // 256) * 256
    table, pieces = [], []
    for cpu, subtype, data in slices:
        entry = [cpu, subtype, next_offset, len(data), 8] + ([0] if fat64 else [])
        table.append(struct.pack(endian + ("IIQQII" if fat64 else "5I"), *entry))
        pieces.append((next_offset, data))
        next_offset += ((len(data) + 255) // 256) * 256
    result = bytearray(struct.pack(endian + "II", 0xCAFEBABF if fat64 else 0xCAFEBABE, len(slices))
                       + b"".join(table))
    for offset, data in pieces:
        result.extend(bytes(offset - len(result)))
        result.extend(data)
    return bytes(result)


class InspectorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = self.root / "fixture.ipa"
        self.metadata = {"CFBundleIdentifier": "test.synthetic.host", "CFBundleVersion": "42",
                         "CFBundleShortVersionString": "1.2.3", "CFBundleExecutable": "Host",
                         "MinimumOSVersion": "17.0"}

    def archive(self, executable=None, metadata=None, plist_bytes=None, extra=(), omit_executable=False):
        metadata = self.metadata if metadata is None else metadata
        executable = macho() if executable is None else executable
        plist_bytes = plistlib.dumps(metadata) if plist_bytes is None else plist_bytes
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("Payload/Host.app/Info.plist", plist_bytes)
                if not omit_executable:
                    archive.writestr("Payload/Host.app/Host", executable)
                for name, contents in extra:
                    archive.writestr(name, contents)
        return inspector.inspect_ipa(self.path)

    def invalid(self, report, text):
        self.assertEqual(report["inspection_status"], "invalid", report)
        self.assertTrue(any(text in message for message in report["errors"]), report)
        self.assertFalse(report["compatibility_verified"])

    def test_valid_arm64_device_metadata_and_no_mutations(self):
        report = self.archive()
        before = hashlib.sha256(self.path.read_bytes()).digest()
        report = inspector.inspect_ipa(self.path)
        self.assertEqual(before, hashlib.sha256(self.path.read_bytes()).digest())
        self.assertEqual([p.name for p in self.root.iterdir()], ["fixture.ipa"])
        self.assertEqual(report["inspection_status"], "complete")
        self.assertFalse(report["compatibility_verified"])
        self.assertEqual(report["bundle"], {"identifier": "test.synthetic.host", "version": "42",
                         "short_version": "1.2.3", "executable": "Host", "minimum_os_version": "17.0"})
        item = report["executable"]["slices"][0]
        self.assertEqual(item["architecture"], "arm64")
        self.assertEqual(item["platforms"][0]["environment"], "device")
        self.assertEqual(item["platforms"][0]["minimum_os"], "17.0.0")
        self.assertFalse(report["executable"]["encrypted"])

    def test_binary_plist(self):
        report = self.archive(plist_bytes=plistlib.dumps(self.metadata, fmt=plistlib.FMT_BINARY))
        self.assertEqual(report["inspection_status"], "complete")

    def test_encrypted_ipa_is_explicit_not_invalid_structure(self):
        report = self.archive(macho(cryptid=1))
        self.assertEqual(report["inspection_status"], "complete")
        self.assertTrue(report["executable"]["encrypted"])
        self.assertEqual(report["executable"]["slices"][0]["encryption_commands"][0]["cryptid"], 1)
        self.assertIn("not a decrypted IPA", report["warnings"][0])

    def test_absent_encryption_command_is_unknown(self):
        report = self.archive(macho(encryption=False))
        self.assertIsNone(report["executable"]["encrypted"])
        self.assertTrue(any("unknown" in warning for warning in report["warnings"]))

    def test_simulator_platform_is_not_inferred_from_arm64_alone(self):
        report = self.archive(macho(platform=7))
        item = report["executable"]["slices"][0]
        self.assertEqual(item["architecture"], "arm64")
        self.assertEqual(item["platforms"][0]["environment"], "simulator")
        self.assertTrue(any("not identified as an iOS device" in warning for warning in report["warnings"]))

    def test_legacy_x86_simulator_and_big_endian_32_bit(self):
        for endian in ("<", ">"):
            with self.subTest(endian=endian):
                report = self.archive(macho(cpu=7, endian=endian, is64=False, legacy=True))
                item = report["executable"]["slices"][0]
                self.assertEqual(item["platforms"][0]["name"], "iOS Simulator")
                self.assertFalse(item["is_64_bit"])

    def test_fat_and_fat64_both_endians_report_every_slice(self):
        for endian in ("<", ">"):
            for fat64 in (False, True):
                with self.subTest(endian=endian, fat64=fat64):
                    data = fat([(0x0100000C, 0, macho()),
                                (0x01000007, 3, macho(cpu=0x01000007, subtype=3, platform=7, cryptid=1))],
                               endian=endian, fat64=fat64)
                    report = self.archive(data)
                    self.assertEqual(report["inspection_status"], "complete", report)
                    self.assertEqual(len(report["executable"]["slices"]), 2)
                    self.assertTrue(report["executable"]["encrypted"])

    def test_arm64e_subtype(self):
        report = self.archive(macho(subtype=0x80000002))
        self.assertEqual(report["executable"]["slices"][0]["architecture"], "arm64e")

    def test_invalid_zip_and_missing_path(self):
        self.path.write_bytes(b"not zip")
        self.invalid(inspector.inspect_ipa(self.path), "zip")
        self.path.unlink()
        self.invalid(inspector.inspect_ipa(self.path), "No such file")

    def test_malformed_xml_and_non_dictionary_plist(self):
        self.invalid(self.archive(plist_bytes=b"<?xml version='1.0'?><plist><dict>"), "no element")
        self.invalid(self.archive(plist_bytes=plistlib.dumps([])), "dictionary")

    def test_malformed_plist_date_is_a_json_error_not_a_traceback(self):
        data = b'<?xml version="1.0"?><plist><dict><key>x</key><date>bad</date></dict></plist>'
        self.invalid(self.archive(plist_bytes=data), "Unable to parse Info.plist")

    def test_missing_executable_and_traversal_names(self):
        self.invalid(self.archive(omit_executable=True), "exactly one ZIP entry")
        for name in ("../Host", "/Host", "a\\Host", "..", ""):
            with self.subTest(name=name):
                self.invalid(self.archive(metadata={**self.metadata, "CFBundleExecutable": name}), "file name")

    def test_duplicate_and_ambiguous_app_entries(self):
        self.invalid(self.archive(extra=[("Payload/Host.app/Host", macho())]), "exactly one ZIP entry")
        self.invalid(self.archive(extra=[("Payload/Other.app/Info.plist", plistlib.dumps(self.metadata))]), "top-level")

    def test_executable_symlink_rejected(self):
        info = zipfile.ZipInfo("Payload/Host.app/Host")
        info.create_system = 3
        info.external_attr = 0o120777 << 16
        self.invalid(self.archive(omit_executable=True, extra=[(info, b"elsewhere")]), "symlink")

    def test_invalid_magic_truncated_header_and_non_executable(self):
        self.invalid(self.archive(b"bad binary"), "not a Mach-O")
        self.invalid(self.archive(macho()[:31]), "Truncated")
        self.invalid(self.archive(macho(file_type=6)), "expected MH_EXECUTE")

    def test_load_command_bounds_and_alignment(self):
        for field_offset, value, message in [(20, 0xFFFFFFFF, "inspection limit"),
                                             (16, 4097, "Too many"),
                                             (36, 0, "size or alignment"),
                                             (36, 25, "size or alignment"),
                                             (36, 512, "exceeds command area")]:
            with self.subTest(field_offset=field_offset, value=value):
                data = bytearray(macho())
                struct.pack_into("<I", data, field_offset, value)
                self.invalid(self.archive(data), message)

    def test_build_tools_encryption_and_conflicting_platform_bounds(self):
        data = bytearray(macho())
        struct.pack_into("<I", data, 52, 1)
        self.invalid(self.archive(data), "tools exceed")
        data = bytearray(macho())
        struct.pack_into("<I", data, 64, len(data) + 1)
        self.invalid(self.archive(data), "Encryption range")
        data = bytearray(macho())
        data[56:80] = struct.pack("<6I", 0x32, 24, 7, 17 << 16, 18 << 16, 0)
        self.invalid(self.archive(data), "Conflicting")

    def test_fat_invalid_count_bounds_alignment_and_cpu(self):
        data = fat([(0x0100000C, 0, macho())]) + bytes(256)
        for offset, value, message in [(4, 65, "architecture count"), (16, 0xFFFFFF00, "extends beyond"),
                                        (24, 32, "alignment exponent"), (16, 257, "Misaligned"),
                                        (8, 7, "does not match")]:
            with self.subTest(offset=offset, value=value):
                changed = bytearray(data)
                struct.pack_into(">I", changed, offset, value)
                self.invalid(self.archive(changed), message)

    def test_overlapping_fat_slices_rejected(self):
        data = bytearray(fat([(0x0100000C, 0, macho()), (0x01000007, 3, macho(cpu=0x01000007, subtype=3))]))
        struct.pack_into(">I", data, 36, 256)
        self.invalid(self.archive(data), "Overlapping")

    def test_bounded_reader_and_oversized_plist(self):
        reader = inspector.EntryReader(io.BytesIO(b"abc"), 3)
        for offset, size in [(-1, 1), (0, -1), (3, 1), (4, 0)]:
            with self.assertRaises(inspector.InspectionError):
                reader.read(offset, size)
        self.invalid(self.archive(plist_bytes=bytes(inspector.MAX_PLIST_BYTES + 1)), "inspection limit")

    def test_cli_valid_and_invalid_are_json_with_explicit_exit_codes(self):
        for data, expected_exit in [(macho(cryptid=1), 0), (b"invalid", 2)]:
            with self.subTest(expected_exit=expected_exit):
                self.archive(data)
                result = subprocess.run([sys.executable, str(Path(inspector.__file__)), str(self.path)],
                                        capture_output=True, text=True, check=False)
                self.assertEqual(result.returncode, expected_exit, result.stderr)
                self.assertFalse(json.loads(result.stdout)["compatibility_verified"])
                self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
