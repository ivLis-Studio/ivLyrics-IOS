import Foundation

/// PC's expressive karaoke motion ("karaoke-motion-style": "expressive"). Each timing unit follows
/// keyframe targets through damped springs, so sung units swell, lift and glow with a small
/// overshoot. On the line being sung, units not reached yet rest slightly smaller and lower, and
/// long held notes move letter by letter.
///
/// PC steps its springs on every display frame from the unit's onset, starting at the pending pose.
/// The goals depend only on the unit's progress, so the trajectory depends only on its duration:
/// it is simulated once per duration and read by playback position, which keeps PiP frames,
/// previews and seeks deterministic.
enum KaraokeExpressiveMotion {
    static let settleMs = 820.0
    static let emphasisMinMs = 1_000.0
    static let pendingScale = 0.95
    static let pendingOffsetEm = 0.012
    /// PC eases the pending pose in over 240 ms when the line becomes the one being sung.
    static let poseEaseMs = 240.0

    struct Values: Equatable {
        var scale: Double
        /// Vertical offset in ems of the row's font size; negative lifts.
        var offsetEm: Double
        /// Glow strength (0...0.8) of the active color around the glyphs.
        var glow: Double

        static let idle = Values(scale: 1, offsetEm: 0, glow: 0)
    }

    /// One moving unit: the window it moves in and its curve family.
    struct Unit: Equatable {
        var startMs: Double
        var endMs: Double
        var emphasis: Bool
    }

    struct Segment {
        var text: String
        var startMs: Double
        var endMs: Double
    }

    /// Values for a unit at `positionMs`. `pendingPose` (0...1) applies the resting pose to units the
    /// line being sung has not reached; elsewhere it is 0 and those units stay idle.
    static func values(_ unit: Unit, positionMs: Double, pendingPose: Double) -> Values {
        guard positionMs.isFinite, unit.startMs.isFinite, unit.endMs.isFinite else { return .idle }
        let elapsed = positionMs - unit.startMs
        if elapsed < 0 {
            let pose = min(1, max(0, pendingPose))
            guard pose > 0 else { return .idle }
            return Values(scale: 1 - (1 - pendingScale) * pose, offsetEm: pendingOffsetEm * pose, glow: 0)
        }
        let duration = max(0, unit.endMs - unit.startMs)
        guard elapsed < duration + settleMs else { return .idle }
        return trajectory(durationMs: duration, emphasis: unit.emphasis).sample(elapsedMs: elapsed)
    }

    /// Strength of the pending pose for a row: eased in over the 240 ms before the line starts while
    /// it is the line being sung, and absent once every unit has been reached.
    static func pendingPose(active: Bool, positionMs: Double, lineStartMs: Double, lineEndMs: Double) -> Double {
        guard active, positionMs.isFinite, lineStartMs.isFinite else { return 0 }
        if lineEndMs > lineStartMs, positionMs >= lineEndMs { return 0 }
        return smooth((positionMs - (lineStartMs - poseEaseMs)) / poseEaseMs)
    }

    /// The moving unit of each display segment, as PC classifies a character-timed line: syllabic
    /// scripts move per glyph; a space-delimited word moves as one unit unless it is held, or long
    /// enough to move letter by letter ("emphasis"). Hyphens and periods end a unit. Rows displayed
    /// per word move per word. Whitespace and untimed segments do not move.
    static func units(for segments: [Segment], wordGranularity: Bool) -> [Unit?] {
        var units = [Unit?](repeating: nil, count: segments.count)
        if wordGranularity {
            for (index, segment) in segments.enumerated() where !isWhitespace(segment.text) {
                guard segment.startMs.isFinite, segment.endMs.isFinite else { continue }
                units[index] = Unit(startMs: segment.startMs, endMs: segment.endMs, emphasis: false)
            }
            return units
        }
        for range in unitRanges(segments) {
            let pieces = segments[range]
            let text = pieces.map(\.text).joined()
            var start = Double.infinity
            var end = -Double.infinity
            for piece in pieces where piece.startMs.isFinite && piece.endMs.isFinite {
                start = min(start, piece.startMs)
                end = max(end, piece.endMs)
            }
            guard start.isFinite, end.isFinite else { continue }
            let duration = end - start
            let letterCount = text.count
            // Punctuation is drawn but is not an extra sung letter.
            let sungLetters = text.filter { $0.isLetter || $0.isNumber }.count
            let hasLetterWindow = duration >= Double(letterCount) * 45
            let longerWord = sungLetters >= 7 && duration >= 600
            let mode: Mode
            if containsSyllabicScript(text) {
                mode = .glyph
            } else if letterCount > 1, letterCount <= 24, hasLetterWindow,
                      longerWord || duration >= emphasisMinMs {
                mode = .emphasis
            } else {
                mode = .word
            }
            for index in range {
                let segment = segments[index]
                switch mode {
                case .word:
                    units[index] = Unit(startMs: start, endMs: end, emphasis: false)
                case .glyph, .emphasis:
                    guard segment.startMs.isFinite, segment.endMs.isFinite else { continue }
                    units[index] = Unit(
                        startMs: segment.startMs, endMs: segment.endMs,
                        emphasis: mode == .emphasis || segment.endMs - segment.startMs >= emphasisMinMs
                    )
                }
            }
        }
        return units
    }

    static func smooth(_ value: Double) -> Double {
        let x = min(1, max(0, value))
        return x * x * (3 - 2 * x)
    }

    // MARK: Classification

    private enum Mode { case glyph, word, emphasis }

    private static func isWhitespace(_ text: String) -> Bool {
        text.isEmpty || text.allSatisfy(\.isWhitespace)
    }

    private static func isSeparator(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { [".", "-", "\u{2010}", "\u{2011}"].contains($0) }
    }

    private static let syllabicScript = try? NSRegularExpression(
        pattern: "[\\p{Han}\\p{Hiragana}\\p{Katakana}\\p{Hangul}\\p{Thai}\\p{Lao}\\p{Khmer}\\p{Myanmar}]"
    )

    private static func containsSyllabicScript(_ text: String) -> Bool {
        guard let syllabicScript else { return false }
        return syllabicScript.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// PC's unit ranges: split at whitespace and after a separator run, which stays with the piece
    /// before it (a leading run stays with the first piece). Never creates an empty unit.
    private static func unitRanges(_ segments: [Segment]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        var hasText = false
        var afterSeparator = false
        func flush(_ index: Int) {
            if index > start { ranges.append(start..<index) }
            start = index
            hasText = false
            afterSeparator = false
        }
        for (index, segment) in segments.enumerated() {
            if isWhitespace(segment.text) {
                flush(index)
                start = index + 1
                continue
            }
            let separator = isSeparator(segment.text)
            if afterSeparator, !separator, hasText { flush(index) }
            if !separator { hasText = true }
            afterSeparator = separator
        }
        flush(segments.count)
        return ranges
    }

    // MARK: Springs

    private typealias Curve = [(progress: Double, value: Double)]
    private struct Curves {
        let scale: Curve
        let offset: Curve
        let glow: Curve
    }
    private static let wordCurves = Curves(
        scale: [(0, pendingScale), (0.7, 1.05), (1, 1)],
        offset: [(0, pendingOffsetEm), (0.9, -0.03), (1, 0)],
        glow: [(0, 0), (0.15, 0.5), (0.6, 0.5), (1, 0)]
    )
    private static let emphasisCurves = Curves(
        scale: [(0, pendingScale), (0.7, 1.14), (1, 1)],
        offset: [(0, pendingOffsetEm), (0.9, -0.05), (1, 0)],
        glow: [(0, 0), (0.15, 0.8), (0.6, 0.8), (1, 0)]
    )
    /// (frequency in Hz, damping ratio): underdamped for a visible overshoot, settled within 820 ms.
    private static let scaleSpring = (frequency: 1.05, damping: 0.62)
    private static let offsetSpring = (frequency: 1.5, damping: 0.45)
    private static let glowSpring = (frequency: 1.2, damping: 0.6)
    private static let stepMs = 4.0
    private static let maxDurationMs = 30_000.0

    static func sampleCurve(_ points: [(progress: Double, value: Double)], _ progress: Double) -> Double {
        guard let first = points.first else { return 0 }
        if progress <= first.progress { return first.value }
        for index in 1..<points.count where progress <= points[index].progress {
            let previous = points[index - 1]
            let next = points[index]
            let t = (progress - previous.progress) / max(1e-6, next.progress - previous.progress)
            return previous.value + (next.value - previous.value) * t * t * (3 - 2 * t)
        }
        return points[points.count - 1].value
    }

    private struct Spring {
        var position: Double
        var velocity = 0.0

        /// Closed-form step of an underdamped spring toward a fixed goal, exact for any step.
        mutating func step(toward goal: Double, seconds: Double, frequency: Double, damping: Double) {
            let omega = 2 * Double.pi * frequency
            let offset = position - goal
            let decay = exp(-damping * omega * seconds)
            let dampedOmega = omega * (1 - damping * damping).squareRoot()
            let cosine = cos(dampedOmega * seconds)
            let sine = sin(dampedOmega * seconds)
            position = goal + decay * (offset * cosine + ((velocity + damping * omega * offset) / dampedOmega) * sine)
            velocity = decay * (velocity * cosine - ((damping * omega * velocity + omega * omega * offset) / dampedOmega) * sine)
        }
    }

    private final class Trajectory {
        let scale: [Float]
        let offset: [Float]
        let glow: [Float]

        init(scale: [Float], offset: [Float], glow: [Float]) {
            self.scale = scale
            self.offset = offset
            self.glow = glow
        }

        func sample(elapsedMs: Double) -> Values {
            let position = max(0, elapsedMs / stepMs)
            let index = min(scale.count - 1, Int(position))
            let next = min(scale.count - 1, index + 1)
            let t = Float(position - Double(index))
            func read(_ values: [Float]) -> Double { Double(values[index] + (values[next] - values[index]) * t) }
            return Values(scale: read(scale), offsetEm: read(offset), glow: max(0, read(glow)))
        }
    }

    private static let cacheLock = NSLock()
    private static var trajectories: [Int: Trajectory] = [:]
    private static var trajectoryOrder: [Int] = []
    private static let trajectoryLimit = 96

    private static func trajectory(durationMs: Double, emphasis: Bool) -> Trajectory {
        let duration = min(maxDurationMs, max(0, durationMs.rounded()))
        let key = Int(duration) * 2 + (emphasis ? 1 : 0)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = trajectories[key] { return cached }
        let built = simulate(durationMs: duration, emphasis: emphasis)
        trajectories[key] = built
        trajectoryOrder.append(key)
        if trajectoryOrder.count > trajectoryLimit {
            trajectories[trajectoryOrder.removeFirst()] = nil
        }
        return built
    }

    private static func simulate(durationMs: Double, emphasis: Bool) -> Trajectory {
        let curves = emphasis ? emphasisCurves : wordCurves
        let count = Int(((durationMs + settleMs) / stepMs).rounded(.up)) + 1
        var scale = Spring(position: pendingScale)
        var offset = Spring(position: pendingOffsetEm)
        var glow = Spring(position: 0)
        var scales = [Float](), offsets = [Float](), glows = [Float]()
        scales.reserveCapacity(count)
        offsets.reserveCapacity(count)
        glows.reserveCapacity(count)
        let seconds = stepMs / 1_000
        for index in 0..<count {
            if index > 0 {
                let elapsed = Double(index) * stepMs
                let progress = durationMs > 0 ? min(1, elapsed / durationMs) : 1
                scale.step(toward: sampleCurve(curves.scale, progress), seconds: seconds,
                           frequency: scaleSpring.frequency, damping: scaleSpring.damping)
                offset.step(toward: sampleCurve(curves.offset, progress), seconds: seconds,
                            frequency: offsetSpring.frequency, damping: offsetSpring.damping)
                glow.step(toward: sampleCurve(curves.glow, progress), seconds: seconds,
                          frequency: glowSpring.frequency, damping: glowSpring.damping)
            }
            scales.append(Float(scale.position))
            offsets.append(Float(offset.position))
            glows.append(Float(glow.position))
        }
        return Trajectory(scale: scales, offset: offsets, glow: glows)
    }
}
