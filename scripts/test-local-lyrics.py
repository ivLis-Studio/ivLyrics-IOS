#!/usr/bin/env python3
"""Exercise the production importer and durable store with real temporary files."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
models = (SRC / "Models.swift").read_text()
production = models[:models.index("enum AppStatus:")]
production += (SRC / "TinySegmenter.swift").read_text()
production += "\nextension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }\n"
production += (SRC / "LrcParser.swift").read_text()
production += (SRC / "LocalLyricsStore.swift").read_text()
checks = r'''
var checks = 0
func check(_ value: @autoclosure () throws -> Bool) throws {
    checks += 1; if try !value() { fatalError("check \(checks)") }
}
func rejects(_ block: () throws -> Void) throws {
    var rejected = false
    do { try block() } catch { rejected = true }
    try check(rejected)
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let store = LocalLyricsStore(root: root.appendingPathComponent("saved"))
let lrc = "[ar:Artist]\r\n[offset:-250]\r[00:20.50][00:01.5]안녕 🌈\n[00:10,001]World\n[00:10.001]번역"
let result = try LocalLyricsStore.parse(lrc, durationMs: 21000)
try check(result.providerId == "local" && result.syncType == "line")
try check(result.lines.count == 4)
try check(result.lines[0].startTimeMs == 1250 && result.lines[0].text == "안녕 🌈")
try check(result.lines[1].startTimeMs == 9751)
try check(result.lines[1].endTimeMs == 20250 && result.lines[2].endTimeMs == 20250)
try check(result.lines[3].endTimeMs == 21000)
try check(LocalLyricsStore.parse("[offset:-5000]\n[00:01]A", durationMs: 0).lines[0].startTimeMs == 0)
try check(LocalLyricsStore.parse("[offset:1000]\n[00:01]A", durationMs: 0).lines[0].startTimeMs == 2000)
try check(LocalLyricsStore.parse("[ti:Song]\nHello\rWorld", durationMs: 0).lines.count == 2)
for text in ["", " \n", "[ti:Song]\n[ar:Artist]", "[00:01]\n[00:02] "] {
    try rejects { _ = try LocalLyricsStore.parse(text, durationMs: 0) }
}
for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian] {
    let bom: [UInt8] = encoding == .utf8 ? [0xef, 0xbb, 0xbf] : encoding == .utf16LittleEndian ? [0xff, 0xfe] : [0xfe, 0xff]
    let data = Data(bom) + lrc.data(using: encoding)!
    try check(LocalLyricsStore.decode(data) == lrc)
    let url = root.appendingPathComponent("input.lrc")
    try data.write(to: url)
    try check(LocalLyricsStore.read(url) == lrc)
}
for data in [Data(), Data([0xff]), Data([0]), Data(repeating: 65, count: LocalLyricsStore.maxBytes + 1)] {
    try rejects { _ = try LocalLyricsStore.decode(data) }
}
try store.save(key: "song-one", text: lrc)
let freshStore = LocalLyricsStore(root: root.appendingPathComponent("saved"))
try check(freshStore.load(key: "song-one", durationMs: 21000)?.lines.count == 4)
try check(freshStore.load(key: "song-two", durationMs: 21000) == nil)
try store.save(key: "song-two", text: "Other\nLyrics")
try store.remove(key: "song-one")
try check(freshStore.load(key: "song-one", durationMs: 21000) == nil)
try check(freshStore.load(key: "song-two", durationMs: 0)?.lines.count == 2)
// UTF-16 input expands when normalized to UTF-8; still readable after restart.
let large = String(repeating: "가", count: 360_000)
try check(large.data(using: .utf16)!.count < LocalLyricsStore.maxBytes)
try store.save(key: "large", text: large)
try check(freshStore.load(key: "large", durationMs: 0)?.lines.first?.text == large)
print("Local lyrics: \(checks) checks passed (production importer, real temporary files)")
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-local-lyrics-") as directory:
    work = Path(directory)
    source = work / "main.swift"
    source.write_text(production + "\n" + checks)
    binary = work / "checks"
    subprocess.run(["swiftc", str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(work)], check=True)
