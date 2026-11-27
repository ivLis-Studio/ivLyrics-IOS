#if DEBUG
import XCTest

/// Opens the real motion lyrics cover over the debug fixture track and leaves it by touch,
/// the only way out an iPhone has.
@MainActor
final class MotionLyricsUITests: XCTestCase {
    private var app: XCUIApplication!
    /// The close button fades after three idle seconds in the app. A loaded CI runner has taken
    /// over 20 seconds to deliver the tap that follows a reveal, so the fixture keeps the button
    /// for this long instead.
    private let controlsSeconds: TimeInterval = 30

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
        app.launchEnvironment = ["IVLYRICS_DEBUG_FIXTURE": "1", "IVLYRICS_DEBUG_SHOW_MOTION": "1",
                                 "IVLYRICS_DEBUG_MOTION_CONTROLS_S": String(Int(controlsSeconds))]
        app.launch()
        let window = app.windows.firstMatch
        let root = app.otherElements["motion.root"]
        XCTAssertTrue(root.waitForExistence(timeout: 20), "Motion lyrics did not open")
        // A phone turns to landscape while the mode is open.
        wait("landscape") { window.frame.width > window.frame.height }
        // The button fades out when left alone but stays in the accessibility tree, so the
        // screen is driven by touch where a finger would land.
        pause(controlsSeconds + 1.5)
        capture("motion-idle")
        // Worked out before the reveal, whose tap starts the button's window.
        let close = closePoint(of: root, in: window)
        // The page itself takes no touches, so a tap anywhere must bring the button back.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(root.exists, "A tap on the page must not close the mode")
        close.tap()
        wait("closed", timeout: 12) { !root.exists && window.frame.width < window.frame.height }
        capture("motion-closed")
    }

    /// The entry people use: the button in the menu a long press on the title opens.
    func testOpensFromTheLyricsMenuOverTheLyricsPage() {
        app = XCUIApplication()
        app.launchEnvironment = ["IVLYRICS_DEBUG_FIXTURE": "1", "IVLYRICS_DEBUG_SHOW_META_MENU": "1",
                                 "IVLYRICS_DEBUG_MOTION_CONTROLS_S": String(Int(controlsSeconds))]
        app.launch()
        let window = app.windows.firstMatch
        let entry = app.buttons["lyrics.menu.motion"]
        XCTAssertTrue(entry.waitForExistence(timeout: 20), "The lyrics menu has no motion lyrics entry")
        capture("motion-menu")
        entry.tap()
        let root = app.otherElements["motion.root"]
        XCTAssertTrue(root.waitForExistence(timeout: 10), "The entry did not open motion lyrics")
        wait("landscape") { window.frame.width > window.frame.height }
        // Neither the menu nor the lyrics page it was opened over stays above the mode.
        wait("menu gone") { !entry.exists && !self.app.otherElements["lyrics.menu.root"].exists }
        capture("motion-from-menu")
        // The button shows from the moment the mode opens.
        closePoint(of: root, in: window).tap()
        wait("closed", timeout: 12) { !root.exists && window.frame.width < window.frame.height }
        pause(1)
        capture("motion-menu-closed")
    }

    /// The middle of the 40pt close button, 14pt below and 16pt inside the top trailing corner
    /// of the safe area.
    private func closePoint(of root: XCUIElement, in window: XCUIElement) -> XCUICoordinate {
        let safeArea = root.frame
        return window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: safeArea.maxX - 36, dy: safeArea.minY + 34))
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
