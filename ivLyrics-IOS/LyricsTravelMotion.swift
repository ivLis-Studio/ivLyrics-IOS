import Foundation

/// Line travel ported from the PC renderer: a row travels on a critically damped spring
/// (stiffness k = 7.5 over 560 ms) normalized to land exactly at u = 1, so it leaves rest with
/// zero velocity. Rows below the anchor follow in an AMLL-like cascade: the anchor and every row
/// above it start together, each row below trails the one above by a 50 ms step that shrinks by
/// 1/1.05, capped at 260 ms. A rapid line scales the whole budget into its window and a window
/// under 80 ms skips the motion. Row presentation (color, opacity, supplements) keeps its own
/// LyricsMotion timing; only the travel uses this model.
enum LyricsTravelMotion {
    static let durationMs = 560.0
    static let stiffness = 7.5
    static let staggerMs = 50.0
    static let staggerDecay = 1 / 1.05
    static let maxStaggerMs = 260.0
    static let settleReserveMs = 24.0
    static let minimumWindowMs = 80.0

    struct Timing: Equatable {
        var durationMs: Double
        var staggerMs: Double
        var maxStaggerMs: Double

        var totalMs: Double { durationMs + maxStaggerMs }
    }

    static let defaultTiming = Timing(durationMs: durationMs, staggerMs: staggerMs, maxStaggerMs: maxStaggerMs)

    /// windowMs is the time until the next line's travel starts; nil when no line follows.
    static func timing(windowMs: Double?) -> Timing {
        guard let windowMs, windowMs.isFinite, windowMs > 0 else { return defaultTiming }
        let available = max(minimumWindowMs, windowMs - settleReserveMs)
        let scale = min(1, available / defaultTiming.totalMs)
        let duration = max(1, (durationMs * scale).rounded())
        return Timing(
            durationMs: duration,
            staggerMs: staggerMs * scale,
            // Rounding the travel must not push the last row past the window.
            maxStaggerMs: max(0, min(maxStaggerMs * scale, available.rounded(.down) - duration))
        )
    }

    /// The next line arrives before any visible motion could settle: rows move without travel.
    static func skipsMotion(windowMs: Double?) -> Bool {
        guard let windowMs, windowMs.isFinite, windowMs > 0 else { return false }
        return windowMs < minimumWindowMs
    }

    /// rowsBelowAnchor <= 0 (the anchor and rows above it) starts immediately.
    static func delayMs(rowsBelowAnchor index: Int, timing: Timing) -> Double {
        guard index > 0, timing.staggerMs > 0 else { return 0 }
        let steps = timing.staggerMs * (1 - pow(staggerDecay, Double(index))) / (1 - staggerDecay)
        return min(timing.maxStaggerMs, steps)
    }

    /// p(u) = (1 - (1 + k u) e^(-k u)) / (1 - (1 + k) e^(-k)): zero velocity at u = 0, exactly 1 at u = 1.
    static func progress(_ u: Double) -> Double {
        guard u > 0 else { return 0 }
        guard u < 1 else { return 1 }
        let k = stiffness
        return (1 - (1 + k * u) * exp(-k * u)) / (1 - (1 + k) * exp(-k))
    }

    /// dp/du; zero before the travel starts and after it lands.
    static func slope(_ u: Double) -> Double {
        guard u > 0, u < 1 else { return 0 }
        let k = stiffness
        return k * k * u * exp(-k * u) / (1 - (1 + k) * exp(-k))
    }

    /// SwiftUI's spring(duration:bounce: 0) is 1 - (1 + wt)e^(-wt) with w = 2 pi / duration.
    /// Choosing w = k / travel duration gives the same curve as progress(_:) up to its
    /// normalization (it is 99.53% of the way at u = 1 and settles the rest).
    static func springResponseSeconds(_ timing: Timing) -> Double {
        timing.durationMs / 1_000 * 2 * Double.pi / stiffness
    }
}

