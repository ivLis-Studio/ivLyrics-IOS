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
# Execute the shipping view-model import/remove methods with an isolated store,
# and the repository's early local override before a synthetic remote cache.
view_model = (SRC / "AppViewModel.swift").read_text()
actions = view_model[view_model.index("    func importLocalLyrics("):view_model.index("    func searchManualCandidates(")]
actions = actions.replace("let store = LocalLyricsStore()", "let store = localStore").replace("LocalLyricsStore().remove", "localStore.remove")
repository = (SRC / "LyricsRepository.swift").read_text()
local_start = repository.index("        if let imported = try LocalLyricsStore().load(")
local_end = repository.index("        let cacheKey = lyricsCacheKey(", local_start)
local_lookup = repository[local_start:local_end].replace("LocalLyricsStore()", "localStore")
loaded_start = repository.index("    struct LoadedLyrics:")
loaded_end = repository.index("\n    }", loaded_start) + len("\n    }")
production += repository[loaded_start:loaded_end]
production += '''
private struct ImportSettings { func t(_ key: String) -> String { key } }
@MainActor private final class ImportProbe {
    let localStore: LocalLyricsStore
    let settings = ImportSettings()
    var currentTrack: TrackSnapshot
    var currentTrackKey: String { currentTrack.stableKey }
    var displayed: LyricsResult
    var toasts: [String] = []
    var reloads = 0
    static var remote: LyricsResult { LyricsResult(lines: [.init(startTimeMs: 0, endTimeMs: 1000, text: "Remote cached")], providerLabel: "LRCLIB", detail: "", karaoke: false) }
    init(store: LocalLyricsStore, track: TrackSnapshot) { localStore = store; currentTrack = track; displayed = Self.remote }
    func showSavedToast(_ text: String) { toasts.append(text) }
    func reloadLyrics(bypassCache: Bool) {
        reloads += 1
        displayed = try! lookup(currentTrack).result
    }
    func lookup(_ track: TrackSnapshot) throws -> LoadedLyrics {
        let key = track.stableKey
''' + local_lookup + '''
        return LoadedLyrics(trackKey: key, result: Self.remote, artworkURL: nil, logs: [], resolvedIsrc: track.isrc, resolvedSpotifyTrackId: track.trackId)
    }
''' + actions + "\n}\n"
checks = r'''
@main private struct LocalLyricsChecks {
@MainActor static func main() async throws {
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

let firstFile = root.appendingPathComponent("first.lrc")
let secondFile = root.appendingPathComponent("second.lrc")
let invalidFile = root.appendingPathComponent("invalid.lrc")
try Data("[00:01]First".utf8).write(to: firstFile)
try Data("[00:02]Second".utf8).write(to: secondFile)
try Data("[ti:Only metadata]".utf8).write(to: invalidFile)
let old = store.beginImport(key: "overlap")
let newest = freshStore.beginImport(key: "overlap")
try check(freshStore.importFile(secondFile, key: "overlap", durationMs: 3000, request: newest))
try check(!store.importFile(firstFile, key: "overlap", durationMs: 3000, request: old))
try check(!store.finishImport(key: "overlap", request: old))
try check(freshStore.finishImport(key: "overlap", request: newest))
try check(store.load(key: "overlap", durationMs: 3000)?.lines.first?.text == "Second")
let pendingRemoval = store.beginImport(key: "overlap")
try freshStore.remove(key: "overlap")
try check(!store.importFile(firstFile, key: "overlap", durationMs: 3000, request: pendingRemoval))
try check(!store.finishImport(key: "overlap", request: pendingRemoval))
try check(store.load(key: "overlap", durationMs: 3000) == nil)
let savedBeforeRemoval = store.beginImport(key: "overlap")
try check(store.importFile(firstFile, key: "overlap", durationMs: 3000, request: savedBeforeRemoval))
try freshStore.remove(key: "overlap")
try check(!store.finishImport(key: "overlap", request: savedBeforeRemoval))
try check(store.load(key: "overlap", durationMs: 3000) == nil)
let independentA = store.beginImport(key: "independent-a")
let independentB = freshStore.beginImport(key: "independent-b")
try freshStore.remove(key: "independent-a")
try check(store.importFile(secondFile, key: "independent-b", durationMs: 3000, request: independentB))
try check(store.finishImport(key: "independent-b", request: independentB))
try check(!store.importFile(firstFile, key: "independent-a", durationMs: 3000, request: independentA))
let invalid = store.beginImport(key: "independent-b")
try rejects { _ = try store.importFile(invalidFile, key: "independent-b", durationMs: 3000, request: invalid) }
try check(store.finishImport(key: "independent-b", request: invalid))
try check(store.load(key: "independent-b", durationMs: 3000)?.lines.first?.text == "Second")

let track = TrackSnapshot(title: "Song", artist: "Artist", album: "Album", mediaId: "spotify:track:5RCOXpwf6rpZi6HGRACY3S", durationMs: 3000)
let other = TrackSnapshot(title: "Other", artist: "Artist", durationMs: 4000)
let model = ImportProbe(store: store, track: track)
model.importLocalLyrics(from: firstFile, for: track)
let firstDeadline = ProcessInfo.processInfo.systemUptime + 3
while model.toasts.isEmpty && ProcessInfo.processInfo.systemUptime < firstDeadline { try await Task.sleep(nanoseconds: 1_000_000) }
try check(model.displayed.providerId == "local" && model.displayed.lines.first?.text == "First")
try check(model.reloads == 1 && model.toasts == ["lyrics.local.saved"])
let relaunched = ImportProbe(store: freshStore, track: track)
relaunched.reloadLyrics(bypassCache: false)
try check(relaunched.displayed.providerId == "local" && relaunched.displayed.lines.first?.text == "First")
relaunched.removeLocalLyrics(for: track)
try check(relaunched.displayed.lines.first?.text == "Remote cached")
try check(relaunched.toasts == ["lyrics.local.removed"])
model.toasts = []
model.importLocalLyrics(from: secondFile, for: track)
model.currentTrack = other
model.reloadLyrics(bypassCache: false)
let reloadCount = model.reloads
let secondDeadline = ProcessInfo.processInfo.systemUptime + 3
while model.toasts.isEmpty && ProcessInfo.processInfo.systemUptime < secondDeadline { try await Task.sleep(nanoseconds: 1_000_000) }
try check(model.reloads == reloadCount && model.displayed.lines.first?.text == "Remote cached")
try check(store.load(key: track.stableKey, durationMs: 3000)?.lines.first?.text == "Second")
try check(store.load(key: other.stableKey, durationMs: 4000) == nil)
model.currentTrack = track
model.reloadLyrics(bypassCache: false)
try check(model.displayed.lines.first?.text == "Second")
print("Local lyrics: \(checks) checks passed (production importer, real temporary files)")
}
}
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-local-lyrics-") as directory:
    work = Path(directory)
    source = work / "main.swift"
    source.write_text(production + "\n" + checks)
    binary = work / "checks"
    subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(work)], check=True)
