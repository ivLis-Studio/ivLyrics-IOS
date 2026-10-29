# Read-only IPA inspection

```sh
python3 spotify-tweak/tools/inspect_ipa.py /path/to/provided.ipa
python3 spotify-tweak/tools/test_inspect_ipa.py
```

The inspector uses Python's standard library and writes a JSON report to stdout.
It opens the ZIP in read-only mode; it does not extract files, modify the IPA,
sign anything, or contact a service. The tests create temporary synthetic IPAs.

The report includes the selected app's bundle identifier, version/build,
executable name, plist minimum OS, and each Mach-O slice's architecture, platform,
minimum OS/SDK and encryption command `cryptid`. Both byte orders, thin 32/64-bit,
and fat/fat64 headers are supported. Legacy version commands infer simulator
status from the CPU architecture; modern build-version commands identify it
explicitly, including arm64 simulators.

Exit code **0** means header inspection completed, including when encrypted code
was detected. Exit code **2** means malformed, ambiguous, missing, or unsupported
input prevented inspection; details are in `errors`. A nonzero `cryptid` is
reported as encrypted. Without an encryption command the status is `null`
(unknown), not a claim that the IPA has been decrypted.

Inspection is intentionally bounded to a 2 MiB plist, 512 MiB main executable,
64 architecture slices, and 4 MiB/4096 load commands per slice. The tool rejects
duplicate selected ZIP entries, a symlink main executable, executable path
traversal, overlapping/out-of-bounds fat slices, inconsistent CPU declarations,
and invalid load-command lengths. It does not inspect all embedded frameworks
or verify all segment contents, full executable ZIP CRC, signatures, provisioning
profiles, private classes, injection compatibility, installation, or device
behavior. `compatibility_verified` is always `false`.
