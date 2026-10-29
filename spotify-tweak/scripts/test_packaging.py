#!/usr/bin/env python3
"""Archive and dependency policy checks; the real build additionally inspects Mach-O/signing."""
import io
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

import build_deb


class PackagingTests(unittest.TestCase):
    def test_ar_round_trip_and_even_alignment(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "preview.deb"
            entries = {"debian-binary": b"2.0\n", "control.tar.gz": b"odd", "data.tar.gz": b"even"}
            build_deb.write_ar(path, entries)
            self.assertEqual(build_deb.read_ar(path), entries)
            path.write_bytes(path.read_bytes()[:-1])
            with self.assertRaises(ValueError):
                build_deb.read_ar(path)

    def test_tar_has_only_expected_regular_files(self):
        entries = {"control": (b"Package: preview\n", 0o644), "Library/payload.dylib": (b"payload", 0o755)}
        archive = build_deb.archive_tar(entries)
        self.assertEqual(build_deb.read_tar(archive), {name: value[0] for name, value in entries.items()})
        self.assertEqual(archive, build_deb.archive_tar(entries))
        with self.assertRaises(ValueError):
            build_deb.archive_tar({"../escape": (b"payload", 0o644)})

    @unittest.skipUnless(shutil.which("ar"), "system ar is unavailable")
    def test_system_ar_reads_debian_members_by_name(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "preview.deb"
            entries = {"debian-binary": b"2.0\n", "control.tar.gz": b"odd", "data.tar.gz": b"even"}
            build_deb.write_ar(path, entries)
            for name, expected in entries.items():
                with self.subTest(member=name):
                    result = subprocess.run(["ar", "-p", str(path), name], check=True, capture_output=True)
                    self.assertEqual(result.stdout, expected)

    def test_verifier_rejects_links(self):
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode="w:gz") as archive:
            entry = tarfile.TarInfo("Library/link")
            entry.type = tarfile.SYMTYPE
            entry.linkname = "/private/data"
            archive.addfile(entry)
        with self.assertRaises(ValueError):
            build_deb.read_tar(output.getvalue())

    def test_control_contains_no_jailbreak_dependencies(self):
        fields = build_deb.parse_control((build_deb.PACKAGING / "control").read_bytes())
        self.assertEqual(fields["Version"], "0.1.0")
        self.assertEqual(fields["Architecture"], "iphoneos-arm")
        self.assertNotIn("Depends", fields)
        self.assertNotIn("Pre-Depends", fields)
        self.assertIn("not verified", fields["Description"])
        self.assertIn("Spotify playback/UI adapter is not implemented", fields["Description"])

    def test_system_swift_dependencies_use_system_rpath(self):
        build_deb.verify_dependencies([build_deb.INSTALL_NAME, "/usr/lib/libobjc.A.dylib",
                                       "/System/Library/Frameworks/UIKit.framework/UIKit",
                                       "@rpath/libswiftCore.dylib", "@rpath/libswift_Concurrency.dylib"], ["/usr/lib/swift"])
        for dependency, rpaths in (("@rpath/libswiftCore.dylib", []),
                                   ("/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate", ["/usr/lib/swift"]),
                                   ("@rpath/Unexpected.framework/Unexpected", ["/usr/lib/swift"]),
                                   ("/usr/lib/libobjc.A.dylib", ["/tmp/developer-runtime"])):
            with self.subTest(dependency=dependency, rpaths=rpaths), self.assertRaises(ValueError):
                build_deb.verify_dependencies([dependency], rpaths)

    def test_default_build_requires_explicit_preview_option(self):
        result = subprocess.run([sys.executable, str(Path(build_deb.__file__))], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("--allow-unverified", result.stderr)
        self.assertIn("Spotify playback/UI adapter is not implemented", result.stderr)


if __name__ == "__main__":
    unittest.main()
