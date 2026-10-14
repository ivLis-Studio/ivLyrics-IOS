#if DEBUG
import XCTest

/// Genuine native views and accessibility frames, not HTML/mock screenshots.
@MainActor
final class SettingsLayoutUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if let app, app.exists, (testRun?.failureCount ?? 0) > 0 {
            capture("failure-\(name)")
        }
        app?.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(_ surface: String = "settings", tab: String = "general", language: String = "en",
                        landscape: Bool = false, textSize: String = "large") {
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        app = XCUIApplication()
        app.launchArguments = ["--ivlyrics-ui-test"]
        app.launchEnvironment = ["IVLYRICS_UI_SURFACE": surface, "IVLYRICS_DEBUG_SETTINGS_TAB": tab,
                                 "IVLYRICS_UI_LANGUAGE": language,
                                 "IVLYRICS_UI_TEXT_SIZE": textSize]
        app.launch()
        let marker = app.descendants(matching: .any)[surface == "settings" ? "settings.search" : "lyrics.menu.close"]
        let ready = marker.waitForExistence(timeout: 10)
        if !ready { capture("launch-\(surface)-missing-marker") }
        XCTAssertTrue(ready, "Native launch marker is missing: \(marker)")
        if landscape {
            wait(NSPredicate { _, _ in self.app.windows.firstMatch.frame.width > self.app.windows.firstMatch.frame.height }, on: app.windows.firstMatch)
        }
    }

    private func wait(_ predicate: NSPredicate, on element: XCUIElement, timeout: TimeInterval = 5) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        if result != .completed { capture("native-wait-timeout") }
        XCTAssertEqual(result, .completed)
    }

    private func capture(_ name: String) {
        // Application-cropped screenshots were malformed after landscape rotation
        // in CI. Preserve the actual full native display, plus the application's AX tree.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility-tree"
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func reveal(_ element: XCUIElement, scrollID: String) {
        let scroll = app.scrollViews[scrollID]
        let scrollExists = scroll.waitForExistence(timeout: 4)
        if !scrollExists { capture("missing-scroll-\(scrollID)") }
        XCTAssertTrue(scrollExists, "Native scroll container is missing: \(scrollID)")
        for _ in 0..<24 {
            let viewport = app.windows.firstMatch.frame.insetBy(dx: 1, dy: 1).intersection(scroll.frame)
            if element.exists && element.isHittable && viewport.contains(element.frame) { return }
            let distance = Self.revealDragDistance(for: element.exists ? element.frame : nil, in: viewport)
            if distance == 0 {
                wait(NSPredicate { _, _ in element.exists && element.isHittable && viewport.contains(element.frame) }, on: element)
                return
            }
            // Match the actual overflow, not a fixed swipe fraction. Slow movement
            // and a stationary end hold prevent momentum from skipping a short control.
            let start = scroll.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: viewport.midX - scroll.frame.minX, dy: viewport.midY - scroll.frame.minY))
            let end = start.withOffset(CGVector(dx: 0, dy: distance))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.25)
        }
        capture("unreachable-in-\(scrollID)")
        XCTFail("Control must be fully visible and reachable by normal scrolling: \(element)")
    }

    private static func revealDragDistance(for frame: CGRect?, in viewport: CGRect) -> CGFloat {
        let limit = viewport.height * 0.4 // Both finger endpoints stay inside the viewport.
        guard let frame, !frame.isEmpty else { return -limit }
        // A drag of 8–10pt can remain inside UIScrollView's pan-recognition slop.
        // Include enough finger travel to scroll even a control clipped by 1–2pt.
        let recognitionTravel: CGFloat = 24
        if frame.minY < viewport.minY { return min(limit, viewport.minY - frame.minY + recognitionTravel) }
        if frame.maxY > viewport.maxY { return -min(limit, frame.maxY - viewport.maxY + recognitionTravel) }
        return 0
    }

    private func assertTouchTarget(_ element: XCUIElement, contained: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        let frame = app.windows.firstMatch.frame.insetBy(dx: 1, dy: 1)
        if !element.exists || element.frame.width < 44 || element.frame.height < 44 || !element.isHittable || (contained && !frame.contains(element.frame)) {
            capture("invalid-touch-target-\(element.exists ? element.identifier : "missing-control")")
        }
        XCTAssertGreaterThanOrEqual(element.frame.width, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, file: file, line: line)
        XCTAssertTrue(element.isHittable, file: file, line: line)
        if contained {
            XCTAssertTrue(frame.contains(element.frame), "Control extends outside the window: \(element.frame)", file: file, line: line)
        }
    }

    private func assertNativeToggle(_ toggle: XCUIElement) {
        XCTAssertTrue(toggle.isHittable)
        // AX may expose the 31pt native switch rather than its 44pt wrapper.
        let hitArea = app.otherElements["ui.hit.\(toggle.identifier)"]
        XCTAssertTrue(hitArea.exists)
        XCTAssertGreaterThanOrEqual(hitArea.frame.width, 44)
        XCTAssertGreaterThanOrEqual(hitArea.frame.height, 44)
        XCTAssertFalse(toggle.frame.isEmpty)
    }

    private func checkVideoOffsets() {
        var value = 0
        for delta in [-100, -50, -10, 10, 50, 100] {
            let button = app.buttons["lyrics.menu.offset.video.delta.\(delta)"]
            reveal(button, scrollID: "lyrics.menu.scroll")
            assertTouchTarget(button)
            button.tap()
            value += delta
            XCTAssertEqual(app.staticTexts["lyrics.menu.offset.video.value"].label,
                           value > 0 ? "+\(value)ms" : "\(value)ms")
        }
        let increment = app.buttons["lyrics.menu.offset.video.delta.100"]
        reveal(increment, scrollID: "lyrics.menu.scroll")
        increment.tap()
        let reset = app.buttons["lyrics.menu.offset.video.reset"]
        reveal(reset, scrollID: "lyrics.menu.scroll")
        assertTouchTarget(reset)
        reset.tap()
        XCTAssertEqual(app.staticTexts["lyrics.menu.offset.video.value"].label, "0ms")
        capture("video-popup-offset-buttons-and-reset")
    }

    func testGeneralPortraitSearchKeyboardAndSwitch() {
        launch()
        let search = app.textFields["settings.search"]
        assertTouchTarget(search)
        XCTAssertGreaterThan(search.frame.width, app.windows.firstMatch.frame.width * 0.5)
        capture("general-portrait")
        // The top edge of the 48pt native input must focus too, not only its text baseline.
        search.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
        search.typeText("artist")
        let result = app.buttons["settings.result.setting.metadata_translation"]
        XCTAssertTrue(result.waitForExistence(timeout: 4))
        assertTouchTarget(app.buttons["settings.search.clear"])
        capture("settings-search-keyboard")
        result.tap()
        wait(NSPredicate(format: "exists == false"), on: app.keyboards.firstMatch)
        let toggle = app.switches["settings.toggle.metadata"]
        reveal(toggle, scrollID: "settings.scroll")
        assertNativeToggle(toggle)
        let before = toggle.value as? String
        toggle.tap()
        XCTAssertNotEqual(toggle.value as? String, before, "Native toggle must actually change the isolated preference")
        capture("general-metadata-long-description")
    }

    func testAILongDescriptionsAndNativeSwitch() {
        launch(tab: "ai", language: "ko")
        let toggle = app.switches["settings.ai.toggle.local-ai"]
        reveal(toggle, scrollID: "settings.scroll")
        assertNativeToggle(toggle)
        let before = toggle.value as? String
        toggle.tap()
        XCTAssertNotEqual(toggle.value as? String, before)
        capture("ai-korean-local-ai-long-description")
        let cultural = app.switches["settings.toggle.cultural"]
        reveal(cultural, scrollID: "settings.scroll")
        assertNativeToggle(cultural)
        capture("ai-korean-cultural-long-description")
    }

    func testGeneralLandscapeAccessibilityText() {
        launch(landscape: true, textSize: "accessibility5")
        assertTouchTarget(app.textFields["settings.search"])
        capture("general-landscape-AX5")
        let toggle = app.switches["settings.toggle.metadata"]
        reveal(toggle, scrollID: "settings.scroll")
        assertNativeToggle(toggle)
        let before = toggle.value as? String
        toggle.tap()
        XCTAssertNotEqual(toggle.value as? String, before)
        capture("general-landscape-AX5-switch")
    }

    func testLanguagePopupPortraitActions() {
        launch("language", language: "ko")
        assertTouchTarget(app.buttons["lyrics.menu.close"])
        capture("language-popup-korean-portrait")
        let action = app.buttons["lyrics.menu.regenerate"]
        reveal(action, scrollID: "lyrics.menu.scroll")
        assertTouchTarget(action)
        XCTAssertFalse(action.label.contains("리서치"), "Lyrics regeneration must not be labelled research")
        capture("language-popup-lyrics-action")
        action.tap()
        XCTAssertTrue(app.staticTexts["ui.harness.closed"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["ui.harness.actions"].label, "Actions: 1")
    }

    func testVideoPopupNativeInputAndSelection() {
        launch("video")
        let field = app.textFields["lyrics.menu.video.url"]
        reveal(field, scrollID: "lyrics.menu.scroll")
        assertTouchTarget(field)
        capture("video-popup-portrait")
        field.tap()
        field.typeText("Abc123xyZ_0")
        assertTouchTarget(app.buttons["lyrics.menu.close"])
        capture("video-popup-keyboard")
        field.typeText("\n")
        let apply = app.buttons["lyrics.menu.video.apply"]
        reveal(apply, scrollID: "lyrics.menu.scroll")
        assertTouchTarget(apply)
        apply.tap()
        wait(NSPredicate(format: "isEnabled == true"), on: apply)
        capture("video-popup-offline-selection")
        checkVideoOffsets()
        app.buttons["lyrics.menu.close"].tap()
        XCTAssertTrue(app.staticTexts["ui.harness.closed"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["ui.harness.actions"].label, "Actions: 1")
    }

    func testLanguageLandscapeAccessibilityFooterReachable() {
        launch("language", landscape: true, textSize: "accessibility5")
        assertTouchTarget(app.buttons["lyrics.menu.close"])
        capture("language-popup-landscape-AX5")
        let action = app.buttons["lyrics.menu.regenerate"]
        reveal(action, scrollID: "lyrics.menu.scroll")
        assertTouchTarget(action)
        capture("language-popup-landscape-AX5-footer")
        action.tap()
        XCTAssertTrue(app.staticTexts["ui.harness.closed"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["ui.harness.actions"].label, "Actions: 1")
    }

    func testVideoLandscapeAccessibilityControlsReachable() {
        launch("video", landscape: true, textSize: "accessibility3")
        assertTouchTarget(app.buttons["lyrics.menu.close"])
        let apply = app.buttons["lyrics.menu.video.apply"]
        reveal(apply, scrollID: "lyrics.menu.scroll")
        assertTouchTarget(apply)
        capture("video-popup-landscape-AX3")
    }
}
#endif
