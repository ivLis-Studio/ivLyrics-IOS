import Foundation

/// Presentation-only retention. Timeline membership, lyric timing and scroll targets are untouched.
struct InterludeTransition {
    static let enterMs = 180.0
    static let exitSeconds = 0.24

    struct Segment: Hashable {
        var id: String
        var startMs: Int64
        var endMs: Int64
        var kind: String
        var automatic: Bool
    }

    struct Outgoing: Hashable {
        var segment: Segment
        var startedAt: TimeInterval
    }

    private(set) var active: Segment?
    var outgoing: Outgoing?
    private var scope = ""

    mutating func update(next: Segment?, positionMs: Int64, now: TimeInterval, scope: String, enabled: Bool) {
        if self.scope != scope {
            self.scope = scope
            active = next
            outgoing = nil
            return
        }
        guard enabled else { active = next; outgoing = nil; return }
        if next != active {
            // Only a normal forward handoff gets a ghost. Track/lyrics replacement, reverse
            // seeks and jumps across the gap must never resurrect an unrelated indicator.
            if let previous = active,
               positionMs >= previous.endMs,
               Double(positionMs) - Double(previous.endMs) <= 120 {
                outgoing = .init(segment: previous, startedAt: now)
            } else {
                outgoing = nil
            }
            active = next
        }
        if let outgoing, now - outgoing.startedAt >= Self.exitSeconds { self.outgoing = nil }
    }

    static func entryOpacity(positionMs: Double, startMs: Int64, enabled: Bool) -> Double {
        enabled ? smoothStep((positionMs - Double(startMs)) / enterMs) : 1
    }

    static func exitAppearance(elapsed: TimeInterval) -> (opacity: Double, scale: Double) {
        let progress = smoothStep(elapsed / exitSeconds)
        return (1 - progress, 1 - 0.06 * progress)
    }

    private static func smoothStep(_ value: Double) -> Double {
        let x = min(1, max(0, value))
        return x * x * (3 - 2 * x)
    }
}
