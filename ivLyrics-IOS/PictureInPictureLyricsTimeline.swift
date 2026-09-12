import Foundation

/// Song metadata is prepared once; each PiP update shares one selection across
/// identity checks, frame scheduling and drawing.
final class PictureInPictureLyricsTimeline {
    struct Selection {
        var activeIndex: Int?
        var activeIndices: [Int]
        var nextLineIndex: Int?
        var hasTimedKaraoke: Bool

        static let empty = Selection(activeIndex: nil, activeIndices: [], nextLineIndex: nil, hasTimedKaraoke: false)
    }

    private var lines: [LyricsLine] = []
    private var markerFlags: [Bool] = []
    private var timedKaraokeFlags: [Bool] = []

    func update(lines nextLines: [LyricsLine]) {
        guard lines != nextLines else { return }
        lines = nextLines
        markerFlags = lines.map { $0.isTimed && InstrumentalBreakMarker.isMarkerText($0.text) }
        timedKaraokeFlags = lines.map { line in
            line.syllables.contains { $0.endTimeMs > $0.startTimeMs }
                || line.vocalParts.contains { part in
                    part.syllables.contains { $0.endTimeMs > $0.startTimeMs }
                }
        }
    }

    func selection(at positionMs: Int64) -> Selection {
        guard !lines.isEmpty else { return .empty }
        var activeIndex = 0
        var foundActiveLine = false
        var activeIndices: [Int] = []
        var nextLineIndex: Int?
        var hasTimedKaraoke = false
        for index in lines.indices {
            let line = lines[index]
            let started = positionMs >= line.startTimeMs
            let withinLine = started && positionMs < line.endTimeMs
            // Preserve the first enclosing source row, including untimed/marker
            // fallback behavior and source order for overlapping or unsorted rows.
            if !foundActiveLine {
                if started { activeIndex = index }
                if line.endTimeMs > line.startTimeMs, withinLine {
                    activeIndex = index
                    foundActiveLine = true
                }
            }
            if nextLineIndex == nil, !started { nextLineIndex = index }
            if line.isTimed, withinLine, !markerFlags[index] {
                activeIndices.append(index)
                hasTimedKaraoke = hasTimedKaraoke || timedKaraokeFlags[index]
            }
        }
        if activeIndices.isEmpty {
            activeIndices = [activeIndex]
            hasTimedKaraoke = timedKaraokeFlags[activeIndex]
        }
        return Selection(activeIndex: activeIndex, activeIndices: activeIndices,
                         nextLineIndex: nextLineIndex, hasTimedKaraoke: hasTimedKaraoke)
    }
}
