import Foundation

/// Song metadata is prepared once; each PiP update shares one selection across
/// identity checks, frame scheduling and drawing.
final class PictureInPictureLyricsTimeline {
    struct Selection {
        var activeIndex: Int?
        var activeIndices: [Int]
        var nextLineIndex: Int?
        var hasTimedKaraoke: Bool
        var hasSyntheticKaraoke = false
        var hasInlineStyles = false
        var hasContinuousEffects = false

        func usesAnimatedKaraoke(syncedAnimationEnabled: Bool, lineDisplay: Bool) -> Bool {
            guard !lineDisplay || hasInlineStyles else { return false }
            return hasTimedKaraoke || (syncedAnimationEnabled && hasSyntheticKaraoke)
        }

        func framesPerSecond(syncedAnimationEnabled: Bool, lineDisplay: Bool) -> Int32 {
            hasContinuousEffects || usesAnimatedKaraoke(
                syncedAnimationEnabled: syncedAnimationEnabled, lineDisplay: lineDisplay
            ) ? 30 : 12
        }

        static let empty = Selection(activeIndex: nil, activeIndices: [], nextLineIndex: nil, hasTimedKaraoke: false)
    }

    struct Change {
        var positionMs: Int64
        var selection: Selection
    }

    /// Increments whenever the lyric lines change.
    private(set) var revision = 0

    private var lines: [LyricsLine] = []
    private var markerFlags: [Bool] = []
    private var timedKaraokeFlags: [Bool] = []
    private var animationFlags: [AnimationFlags] = []

    private struct AnimationFlags {
        var synthetic = false
        var inline = false
        var continuous = false
    }

    private static let continuousEffectKinds: Set<String> = [
        "effect", "adlib", "pulse", "bounce", "sway", "float", "pop", "glitch",
        "wave", "sparkle", "echo", "whisper", "glow", "blur", "flicker"
    ]

    func update(lines nextLines: [LyricsLine]) {
        guard lines != nextLines else { return }
        lines = nextLines
        revision &+= 1
        markerFlags = lines.map { $0.isTimed && InstrumentalBreakMarker.isMarkerText($0.text) }
        timedKaraokeFlags = lines.map { line in
            line.syllables.contains { $0.endTimeMs > $0.startTimeMs }
                || line.vocalParts.contains { part in
                    part.syllables.contains { $0.endTimeMs > $0.startTimeMs }
                }
        }
        animationFlags = lines.map { line in
            let parts = line.vocalParts
            let syllables = parts.isEmpty ? line.syllables : parts.flatMap(\.syllables)
            let kinds = parts.isEmpty ? [line.kind] : parts.map(\.kind)
            let synthetic = parts.isEmpty
                ? !line.text.trimmed.isEmpty && line.endTimeMs > line.startTimeMs
                : parts.contains { !$0.text.trimmed.isEmpty && $0.endTimeMs > $0.startTimeMs }
            return AnimationFlags(
                synthetic: synthetic,
                inline: syllables.contains { $0.inlineStyle == true },
                continuous: kinds.contains { Self.continuousEffectKinds.contains($0.trimmed.lowercased()) }
                    || syllables.contains {
                        $0.inlineStyle == true
                            && Self.continuousEffectKinds.contains(($0.styleKind ?? "").trimmed.lowercased())
                    }
            )
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
        var selection = Selection(activeIndex: activeIndex, activeIndices: activeIndices,
                                  nextLineIndex: nextLineIndex, hasTimedKaraoke: hasTimedKaraoke)
        for index in activeIndices {
            selection.hasSyntheticKaraoke = selection.hasSyntheticKaraoke || animationFlags[index].synthetic
            selection.hasInlineStyles = selection.hasInlineStyles || animationFlags[index].inline
            selection.hasContinuousEffects = selection.hasContinuousEffects || animationFlags[index].continuous
        }
        return selection
    }

    /// The selection at `positionMs`, then one entry for each later moment the shown lyrics change
    /// (a line or vocal part starts, or a line ends) through `endMs`, at most `limit` entries.
    func changes(from positionMs: Int64, through endMs: Int64, limit: Int) -> [Change] {
        guard limit > 0 else { return [] }
        let current = selection(at: positionMs)
        var result = [Change(positionMs: positionMs, selection: current)]
        guard !lines.isEmpty else { return result }
        var times = Set<Int64>()
        for line in lines where line.isTimed {
            times.insert(line.startTimeMs)
            if line.endTimeMs > line.startTimeMs { times.insert(line.endTimeMs) }
            for part in line.vocalParts { times.insert(part.startTimeMs) }
        }
        var previousKey = changeKey(current, at: positionMs)
        for time in times.sorted() where time > positionMs && time <= endMs {
            guard result.count < limit else { break }
            let next = selection(at: time)
            let key = changeKey(next, at: time)
            guard key != previousKey else { continue }
            previousKey = key
            result.append(Change(positionMs: time, selection: next))
        }
        return result
    }

    /// What a PiP frame shows: the active rows, the next-line hint and which vocal parts have begun.
    private func changeKey(_ selection: Selection, at positionMs: Int64) -> [Int] {
        var key = [selection.activeIndex ?? -1, selection.nextLineIndex ?? -1]
        for index in selection.activeIndices {
            key.append(index)
            key.append(lines[index].vocalParts.reduce(0) { $1.startTimeMs <= positionMs ? $0 + 1 : $0 })
        }
        return key
    }
}
