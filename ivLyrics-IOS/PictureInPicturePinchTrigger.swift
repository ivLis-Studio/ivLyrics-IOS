import SwiftUI
import UIKit

/// Thresholds shared with Android: the fingers must close to 72% of their starting
/// distance and by at least 56 points before a pinch opens lyrics Picture in Picture.
enum PictureInPicturePinchPolicy {
    static let triggerScale: CGFloat = 0.72
    static let triggerDistance: CGFloat = 56

    static func shouldTrigger(startDistance: CGFloat, distance: CGFloat) -> Bool {
        guard startDistance > 0, distance >= 0 else { return false }
        return distance / startDistance <= triggerScale
            && startDistance - distance >= triggerDistance
    }
}

/// Opens lyrics Picture in Picture from a two-finger pinch-in anywhere on the player.
/// The recognizer sits on the window beside the existing gestures and never cancels their
/// touches; the start runs inside the pinch, which AVKit treats as the user's action.
struct PictureInPicturePinchTrigger: UIViewRepresentable {
    var isEnabled: () -> Bool
    var onTrigger: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.coordinator = context.coordinator
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onTrigger = onTrigger
        return view
    }

    func updateUIView(_ uiView: InstallerView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onTrigger = onTrigger
        uiView.coordinator = context.coordinator
        context.coordinator.install(on: uiView.window)
    }

    static func dismantleUIView(_ uiView: InstallerView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class InstallerView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.install(on: window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isEnabled: () -> Bool = { false }
        var onTrigger: () -> Void = {}
        private var recognizer: UIPinchGestureRecognizer?
        private var startDistance: CGFloat = 0
        private var triggered = false

        func install(on window: UIWindow?) {
            if let recognizer, recognizer.view === window { return }
            uninstall()
            guard let window else { return }
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.cancelsTouchesInView = false
            pinch.delaysTouchesBegan = false
            pinch.delaysTouchesEnded = false
            pinch.delegate = self
            window.addGestureRecognizer(pinch)
            recognizer = pinch
        }

        func uninstall() {
            if let recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            reset()
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            isEnabled()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func handlePinch(_ pinch: UIPinchGestureRecognizer) {
            switch pinch.state {
            case .began:
                triggered = false
                // The recognizer begins after some movement; scale is relative to the
                // fingers' first positions, so recover that starting distance.
                let distance = Self.touchDistance(pinch)
                startDistance = pinch.scale > 0 ? distance / pinch.scale : distance
                evaluate(pinch, distance: distance)
            case .changed:
                evaluate(pinch, distance: Self.touchDistance(pinch))
            default:
                reset()
            }
        }

        private func evaluate(_ pinch: UIPinchGestureRecognizer, distance: CGFloat) {
            guard !triggered, pinch.numberOfTouches >= 2,
                  PictureInPicturePinchPolicy.shouldTrigger(startDistance: startDistance, distance: distance),
                  isEnabled() else { return }
            triggered = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onTrigger()
        }

        private func reset() {
            startDistance = 0
            triggered = false
        }

        private static func touchDistance(_ pinch: UIPinchGestureRecognizer) -> CGFloat {
            guard pinch.numberOfTouches >= 2, let view = pinch.view else { return 0 }
            let first = pinch.location(ofTouch: 0, in: view)
            let second = pinch.location(ofTouch: 1, in: view)
            return hypot(first.x - second.x, first.y - second.y)
        }
    }
}
