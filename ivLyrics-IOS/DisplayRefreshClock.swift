enum PlaybackClockMode: Equatable {
    case display, backgroundPictureInPicture, stopped

    init(foregroundActive: Bool, pictureInPictureEngaged: Bool) {
        self = foregroundActive ? .display : (pictureInPictureEngaged ? .backgroundPictureInPicture : .stopped)
    }
}

#if os(iOS)
import UIKit

/// Uses the display in the foreground and preserves sample-buffer PiP updates in the background.
final class DisplayRefreshClock: NSObject {
    private var displayLink: CADisplayLink?
    private var backgroundTimer: Timer?
    private var mode = PlaybackClockMode.display
    private let tick: () -> Void

    init(tick: @escaping () -> Void) {
        self.tick = tick
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(refresh))
        let maximum = Float(UIScreen.main.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: maximum, preferred: maximum)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func refresh() { tick() }

    func setMode(_ nextMode: PlaybackClockMode) {
        guard mode != nextMode else { return }
        mode = nextMode
        displayLink?.isPaused = nextMode != .display
        backgroundTimer?.invalidate()
        backgroundTimer = nil
        guard nextMode == .backgroundPictureInPicture else { return }
        // A background display link is not a clock for the PiP sample-buffer renderer.
        // Retain its prior timer cadence; the owner limits PiP rendering to 30fps.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        backgroundTimer = timer
    }

    func invalidate() {
        displayLink?.invalidate()
        displayLink = nil
        backgroundTimer?.invalidate()
        backgroundTimer = nil
        mode = .stopped
    }
}
#endif
