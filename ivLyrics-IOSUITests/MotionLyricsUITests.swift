#if DEBUG
import XCTest

/// Opens the real motion lyrics cover over the debug fixture track and leaves it by touch,
/// the only way out an iPhone has.
@MainActor
final class MotionLyricsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws { continueAfterFailure = false }

    override func tearDownWithError() throws {
        if let app, app.exists, (testRun?.failureCount ?? 0) > 0 {
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "motion-failure"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "motion-failure-accessibility-tree"
            tree.lifetime = .keepAlways
            add(tree)
        }
        app?.terminate()
    }

    func testCloseButtonReturnsAfterAutoHideAndRestoresPortrait() {
        app = XCUIApplication()
        app.launchEnvironment = ["IVLYRICS_DEBUG_FIXTURE": "1", "IVLYRICS_DEBUG_SHOW_MOTION": "1"]
        app.launch()
        let window = app.windows.firstMatch
        let root = app.otherElements["motion.root"]
        XCTAssertTrue(root.waitForExistence(timeout: 20), "Motion lyrics did not open")
        // A phone turns to landscape while the mode is open.
        wait("landscape") { window.frame.width > window.frame.height }
        // The button fades out after three idle seconds but stays in the accessibility tree,
        // so the screen is driven by touch where a finger would land.
        pause(5)
        capture("motion-idle")
        // 40pt button, 14pt below and 16pt inside the top trailing corner of the safe area.
        let safeArea = root.frame
        let closePoint = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: safeArea.maxX - 36, dy: safeArea.minY + 34))
        // The page itself takes no touches, so a tap anywhere must bring the button back.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        pause(0.6)
        XCTAssertTrue(root.exists, "A tap on the page must not close the mode")
        capture("motion-controls")
        closePoint.tap()
        // A loaded runner can use up the button's three visible seconds before this tap lands;
        // the tap then only brings the button back, and the next one presses it.
        if !settles(within: 3, { !root.exists }) {
            closePoint.tap()
        }
        wait("closed", timeout: 12) { !root.exists && window.frame.width < window.frame.height }
        capture("motion-closed")
    }

    private func pause(_ seconds: TimeInterval) {
        let elapsed = expectation(description: "pause")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { elapsed.fulfill() }
        wait(for: [elapsed], timeout: seconds + 5)
    }

    private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func wait(_ step: String, timeout: TimeInterval = 8, _ condition: @escaping () -> Bool) {
        XCTAssertTrue(settles(within: timeout, condition), "Timed out at: \(step)")
    }

    private func settles(within timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: app)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
#endif
