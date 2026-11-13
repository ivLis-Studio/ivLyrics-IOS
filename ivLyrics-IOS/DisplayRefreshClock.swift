enum PlaybackClockMode: Equatable {
    case display, backgroundPictureInPicture, stopped

    init(foregroundActive: Bool, pictureInPictureEngaged: Bool) {
        self = foregroundActive ? .display : (pictureInPictureEngaged ? .backgroundPictureInPicture : .stopped)
    }
}

#if os(iOS)
import UIKit

/// Uses the display in the foreground and preserves sample-buffer PiP updates in the background.
/// Foreground ticks carry the frame's vsync time (CADisplayLink.timestamp, on the same uptime
/// clock as ProcessInfo.systemUptime): the frame-start basis the PC renderer (requestAnimationFrame
/// time) and Android (Choreographer frameTimeNanos) paint from. Consecutive frames therefore
/// advance by exactly one frame interval, free of callback jitter. Background PiP ticks pass nil
/// (sampled on call).
///
/// While nothing moves (playback paused, no lyric travel in flight, PiP not engaged) the owner marks
/// the clock idle: the display link pauses, so it no longer holds a ProMotion display at its full
/// rate, and a half-second timer keeps the low-rate duties (PiP priming, Spotify DJ correction).
/// Leaving idle resumes the link at the next vsync.
final class DisplayRefreshClock: NSObject {
    static let idleTickInterval: TimeInterval = 0.5

    private var displayLink: CADisplayLink?
    private var backgroundTimer: Timer?
    private var idleTimer: Timer?
    private var mode = PlaybackClockMode.display
    private(set) var idle = false
    private let tick: (TimeInterval?) -> Void

    init(tick: @escaping (TimeInterval?) -> Void) {
        self.tick = tick
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(refresh(_:)))
        let maximum = Float(UIScreen.main.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: maximum, preferred: maximum)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func refresh(_ link: CADisplayLink) { tick(link.timestamp) }

    func setMode(_ nextMode: PlaybackClockMode) {
        guard mode != nextMode else { return }
        mode = nextMode
        applyIdle()
        backgroundTimer?.invalidate()
        backgroundTimer = nil
        guard nextMode == .backgroundPictureInPicture else { return }
        // A background display link is not a clock for the PiP sample-buffer renderer.
        // Retain its prior timer cadence; the owner limits PiP rendering to 30fps.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick(nil)
        }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        backgroundTimer = timer
    }

    /// Returns true when the clock left idle, so the caller can paint the current frame at once.
    @discardableResult
    func setIdle(_ nextIdle: Bool) -> Bool {
        guard idle != nextIdle else { return false }
        idle = nextIdle
        applyIdle()
        return !nextIdle && mode == .display
    }

    private func applyIdle() {
        let foreground = mode == .display
        displayLink?.isPaused = !foreground || idle
        idleTimer?.invalidate()
        idleTimer = nil
        guard foreground, idle else { return }
        let timer = Timer(timeInterval: Self.idleTickInterval, repeats: true) { [weak self] _ in
            self?.tick(nil)
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    func invalidate() {
        displayLink?.invalidate()
        displayLink = nil
        backgroundTimer?.invalidate()
        backgroundTimer = nil
        idleTimer?.invalidate()
        idleTimer = nil
        mode = .stopped
    }
}
#endif
