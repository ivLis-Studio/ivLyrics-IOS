#!/usr/bin/env python3
"""Exercise the production URL, community timing, and per-track provider policy code."""
from pathlib import Path
import subprocess,tempfile
src=Path(__file__).resolve().parents[1]/'ivLyrics-IOS'
video=(src/'YouTubeBackgroundRepository.swift').read_text()
models=(src/'Models.swift').read_text()
settings=(src/'AppSettings.swift').read_text()
policy=settings[settings.index('        func selectingLyricsProvider('):settings.index('        func isLyricsTypeEnabled(')]
code='import Foundation\nextension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }\nenum TrackSnapshot { static func normalizeIsrc(_ s: String) -> String { s.uppercased() } }\n'
code+=models[models.index('struct YouTubeVideoInfo:'):models.index('struct SpotifyResolvedTrack:')]
code+=video[video.index('extension YouTubeVideoInfo {'):].replace('nonisolated enum','enum')
code+='''
enum AppSettings {
    static let defaultLyricsProviderOrder = ["lrclib", "paxsenix", "lyricsplus", "unison"]
    static let lyricsTypeKaraoke = "karaoke", lyricsTypeSynced = "synced", lyricsTypePlain = "plain"
    static func lyricsProviderById(_ id: String) -> String? { defaultLyricsProviderOrder.contains(id) ? id : nil }
    static func normalizedLyricsProviderOrder(_ ids: [String]) -> [String] { ids + defaultLyricsProviderOrder.filter { !ids.contains($0) } }
    struct Snapshot {
        var lyricsProviderOrder = defaultLyricsProviderOrder
        var lyricsProviderEnabled = ["lrclib": true, "paxsenix": false, "lyricsplus": true, "unison": true]
        var lyricsProviderTypes = ["paxsenix": ["karaoke": false, "synced": false, "plain": false]]
        var preferSyncDataProvider = true
        var preferLyricsTypeOverProviderOrder = false
'''+policy+'''    }
}
@main struct Checks {
    static func main() throws {
        let id = "Abc_123-xy"
        let videoID = "Abc_123-xyz"
        for value in [videoID, "https://youtu.be/" + videoID, "https://www.youtube.com/watch?v=" + videoID + "&t=12", "https://m.youtube.com/shorts/" + videoID] {
            precondition(YouTubeVideoSelection.extractId(value) == videoID)
        }
        for value in [id, "https://youtube.com.evil.test/watch?v=" + videoID, "javascript:" + videoID, "https://youtu.be/a/b", "https://youtube.com/embed/../" + videoID] {
            precondition(YouTubeVideoSelection.extractId(value) == nil)
        }
        let info = YouTubeVideoInfo.fromJson(fallbackIsrc: "", object: ["videoId": videoID, "startTime": 12.5])!
        precondition(info.isrc.isEmpty && info.hasCaptionStartTime && info.captionStartTimeSeconds == 12.5)
        precondition(try JSONDecoder().decode(YouTubeVideoInfo.self, from: JSONEncoder().encode(info)) == info)
        let original = AppSettings.Snapshot()
        let selected = original.selectingLyricsProvider("paxsenix")
        precondition(selected.enabledLyricsProviderOrder == ["paxsenix"])
        precondition(selected.lyricsProviderTypes["paxsenix"]!.values.allSatisfy { $0 })
        precondition(!selected.preferSyncDataProvider && selected.preferLyricsTypeOverProviderOrder)
        precondition(original.lyricsProviderEnabled["paxsenix"] == false)
        precondition(original.selectingLyricsProvider("").enabledLyricsProviderOrder == original.enabledLyricsProviderOrder)
        print("Track selection regression: URL validation, timing, persistence, provider isolation passed")
    }
}
'''
# Throwing work cannot be inside precondition's non-throwing autoclosure.
code=code.replace('precondition(try JSONDecoder().decode(YouTubeVideoInfo.self, from: JSONEncoder().encode(info)) == info)','let decoded = try JSONDecoder().decode(YouTubeVideoInfo.self, from: JSONEncoder().encode(info)); precondition(decoded == info)')
with tempfile.TemporaryDirectory(prefix='ivlyrics-track-selection-') as temp:
    p=Path(temp)/'Checks.swift';p.write_text(code)
    subprocess.run(['xcrun','swiftc','-parse-as-library',str(p),'-o',temp+'/checks'],check=True)
    subprocess.run([temp+'/checks'],check=True)
