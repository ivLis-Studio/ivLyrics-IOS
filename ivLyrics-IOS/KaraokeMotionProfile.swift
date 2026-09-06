import Foundation

/// PC 6.6.8 adaptive motion, with CSS-pixel lift normalized to the row's chosen font size.
/// Timing preparation is independent of the display clock and each vocal row owns its profiles.
struct KaraokeMotionProfile: Equatable {
    let startMs: Double
    let holdEndMs: Double
    let riseMs: Double
    let releaseMs: Double
    let amplitude: Double
    let scaleAmount: Double

    init(startMs: Double, holdEndMs: Double, cadenceMs: Double, gapMs: Double) {
        let calm = Self.smooth((cadenceMs - 90) / 230)
        let sustained = Self.smooth((holdEndMs - startMs - 700) / 900)
        self.startMs = startMs
        self.holdEndMs = holdEndMs
        riseMs = max(1, min(holdEndMs - startMs, 220, 45 + cadenceMs * 0.45))
        releaseMs = min(700, 110 + 220 * calm + 100 * sustained + min(800, max(0, gapMs)) * 0.25 * calm)
        amplitude = 1.1 + 3.9 * calm + sustained * 0.6
        scaleAmount = 0.006 + 0.024 * calm
    }

    func values(positionMs: Double, textSize: Double) -> (offsetY: Double, scale: Double) {
        guard positionMs.isFinite, positionMs >= startMs, positionMs < holdEndMs + releaseMs else { return (0, 1) }
        let strength = positionMs < holdEndMs
            ? Self.smooth((positionMs - startMs) / riseMs)
            : 1 - Self.smooth((positionMs - holdEndMs) / releaseMs)
        // PC masks quantization with a 75ms CSS transition. At native display cadence,
        // evaluate the same envelope continuously, without lagging seeks or pause changes.
        return (-amplitude * strength * max(0, textSize) / 44, 1 + scaleAmount * strength)
    }

    static func smooth(_ value: Double) -> Double {
        let x = min(1, max(0, value))
        return x * x * (3 - 2 * x)
    }

    struct Unit {
        var text: String
        var startMs: Double
        var endMs: Double
    }

    /// Character offsets map display groups back to provider units without merging vocal rows.
    static func prepare(source: [Unit], display: [Unit]) -> [KaraokeMotionProfile?] {
        struct SourceGroup {
            var range: Range<Int>
            var start: Double
            var end: Double
            var count: Int
            var characterRanges: [Range<Int>]
            var cadence: Double = 0
            var localCadence: Double = 0
            var gap: Double = 0
        }
        var groups: [SourceGroup] = []
        var offset = 0
        for unit in source {
            let firstGroup = groups.count
            var runStart: Int?
            var count = 0
            var characterRanges: [Range<Int>] = []
            for character in unit.text {
                let value = String(character)
                let whitespace = value.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
                if whitespace {
                    if let start = runStart {
                        groups.append(SourceGroup(range: start..<offset, start: unit.startMs, end: unit.endMs,
                                                  count: count, characterRanges: characterRanges))
                    }
                    runStart = nil
                    count = 0
                    characterRanges = []
                } else {
                    if runStart == nil { runStart = offset }
                    count += 1
                    characterRanges.append(offset..<(offset + value.utf16.count))
                }
                offset += value.utf16.count
            }
            if let start = runStart {
                groups.append(SourceGroup(range: start..<offset, start: unit.startMs, end: unit.endMs,
                                          count: count, characterRanges: characterRanges))
            }
            // A whole-phrase source is split proportionally; compact source words retain their hold.
            if groups.count - firstGroup > 1 {
                let unitLength = max(1, unit.text.utf16.count)
                let unitStart = offset - unitLength
                for index in firstGroup..<groups.count {
                    groups[index].start = unit.startMs + (unit.endMs - unit.startMs)
                        * Double(groups[index].range.lowerBound - unitStart) / Double(unitLength)
                    groups[index].end = unit.startMs + (unit.endMs - unit.startMs)
                        * Double(groups[index].range.upperBound - unitStart) / Double(unitLength)
                }
            }
        }
        for index in groups.indices {
            groups[index].cadence = max(0, groups[index].end - groups[index].start) / sqrt(Double(max(1, groups[index].count)))
        }
        for index in groups.indices {
            var sum = 0.0
            var count = 0
            var lastStart: Double?
            for neighbor in max(0, index - 2)...min(groups.count - 1, index + 2) {
                if lastStart == groups[neighbor].start { continue }
                lastStart = groups[neighbor].start
                sum += min(600, groups[neighbor].cadence)
                count += 1
            }
            groups[index].localCadence = groups[index].cadence * 0.75 + sum / Double(max(1, count)) * 0.25
            groups[index].gap = index + 1 < groups.count ? max(0, groups[index + 1].start - groups[index].end) : 0
        }
        var displayOffset = 0
        return display.map { unit in
            let range = displayOffset..<(displayOffset + unit.text.utf16.count)
            displayOffset = range.upperBound
            guard unit.endMs > unit.startMs,
                  !unit.text.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) else { return nil }
            let matches = groups.indices.filter { groups[$0].range.overlaps(range) }
            guard let firstIndex = matches.first, let lastIndex = matches.last else { return nil }
            let first = groups[firstIndex]
            let last = groups[lastIndex]
            var cadenceTotal = 0.0
            var characterCount = 0
            for index in matches {
                let count = groups[index].characterRanges.filter { $0.overlaps(range) }.count
                cadenceTotal += groups[index].localCadence * Double(count)
                characterCount += count
            }
            let cadence = cadenceTotal / Double(max(1, characterCount))
            let wholeUnit = firstIndex == lastIndex && range.lowerBound <= first.range.lowerBound && range.upperBound >= first.range.upperBound
            let sustain = unit.text.count == 1 && first.count <= 24
                ? smooth((first.end - first.start - 750) / 650) * smooth((first.cadence - 170) / 200) : 0
            let holdEnd = wholeUnit ? max(unit.endMs, first.end) : unit.endMs + max(0, first.end - unit.endMs) * sustain
            return KaraokeMotionProfile(startMs: unit.startMs, holdEndMs: holdEnd, cadenceMs: cadence,
                                        gapMs: holdEnd >= last.end ? last.gap : 0)
        }
    }
}

/// The PC's explicit lyric-kind keyframes. Values are font-relative except the 1.5px adlib lift.
enum KaraokeEffectTiming {
    private static let bounce = [(0.0, 0.0), (0.32, -0.16), (0.58, 0.035), (0.76, -0.045), (1.0, 0.0)]
    private static let wave = [(0.0, 0.0), (0.35, -0.11), (0.70, 0.03), (1.0, 0.0)]
    private static let pop = [(0.0, 1.0), (0.18, 1.035), (0.34, 0.996), (1.0, 1.0)]
    private static let adlib = [(0.0, 0.0), (0.5, -1.5 / 44.0), (1.0, 0.0)]

    static func bounceOffset(timeMs: Double) -> Double {
        keyframes(timeMs: timeMs, periodMs: 780, points: bounce, curve: (0.2, 0.85, 0.24, 1))
    }
    static func waveOffset(timeMs: Double) -> Double {
        keyframes(timeMs: timeMs, periodMs: 920, points: wave, curve: (0.42, 0, 0.58, 1))
    }
    static func popScale(timeMs: Double) -> Double {
        keyframes(timeMs: timeMs, periodMs: 1_080, points: pop, curve: (0.18, 0.9, 0.36, 1))
    }
    static func adlibOffset(timeMs: Double) -> Double {
        keyframes(timeMs: timeMs, periodMs: 1_050, points: adlib, curve: (0.42, 0, 0.58, 1))
    }

    private static func keyframes(timeMs: Double, periodMs: Double, points: [(Double, Double)],
                                  curve: (Double, Double, Double, Double)) -> Double {
        let phase = ((timeMs.truncatingRemainder(dividingBy: periodMs) + periodMs)
            .truncatingRemainder(dividingBy: periodMs)) / periodMs
        for index in 1..<points.count where phase <= points[index].0 {
            let previous = points[index - 1]
            let next = points[index]
            let fraction = (phase - previous.0) / (next.0 - previous.0)
            let eased = cubicBezier(fraction, curve)
            return previous.1 + (next.1 - previous.1) * eased
        }
        return points.last?.1 ?? 0
    }

    private static func cubicBezier(_ x: Double, _ curve: (Double, Double, Double, Double)) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        func coordinate(_ t: Double, _ first: Double, _ second: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * first + 3 * (1 - t) * t * t * second + t * t * t
        }
        var low = 0.0
        var high = 1.0
        for _ in 0..<14 {
            let middle = (low + high) / 2
            if coordinate(middle, curve.0, curve.2) < x { low = middle } else { high = middle }
        }
        return coordinate((low + high) / 2, curve.1, curve.3)
    }
}
