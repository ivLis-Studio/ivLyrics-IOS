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
        app?.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(_ surface: String = "settings", tab: String = "general", language: String = "en",
                        landscape: Bool = false, accessibilityText: Bool = false) {
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        app = XCUIApplication()
        app.launchArguments = ["--ivlyrics-ui-test"]
        app.launchEnvironment = ["IVLYRICS_UI_SURFACE": surface, "IVLYRICS_DEBUG_SETTINGS_TAB": tab,
                                 "IVLYRICS_UI_LANGUAGE": language,
                                 "IVLYRICS_UI_TEXT_SIZE": accessibilityText ? "accessibility3" : "large"]
        app.launch()
        let marker = app.descendants(matching: .any)[surface == "settings" ? "settings.search" : "lyrics.menu.close"]
        XCTAssertTrue(marker.waitForExistence(timeout: 10))
        if landscape {
            wait(NSPredicate { _, _ in self.app.windows.firstMatch.frame.width > self.app.windows.firstMatch.frame.height }, on: app.windows.firstMatch)
        }
    }

    private func wait(_ predicate: NSPredicate, on element: XCUIElement, timeout: TimeInterval = 5) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
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
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            scroll.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(element.exists && element.isHittable, "Control must be reachable by normal scrolling: \(element)")
    }

    private func assertTouchTarget(_ element: XCUIElement, contained: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(element.frame.width, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, file: file, line: line)
        XCTAssertTrue(element.isHittable, file: file, line: line)
        if contained {
            let frame = app.windows.firstMatch.frame.insetBy(dx: 1, dy: 1)
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

    func testGeneralPortraitSearchKeyboardAndSwitch() {
        launch()
        let search = app.textFields["settings.search"]
        assertTouchTarget(search)
        XCTAssertGreaterThan(search.frame.width, app.windows.firstMatch.frame.width * 0.5)
        capture("general-portrait")
        search.tap()
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
        launch(landscape: true, accessibilityText: true)
        assertTouchTarget(app.textFields["settings.search"])
        capture("general-landscape-AX3")
        let toggle = app.switches["settings.toggle.metadata"]
        reveal(toggle, scrollID: "settings.scroll")
        assertNativeToggle(toggle)
        capture("general-landscape-AX3-switch")
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
        app.buttons["lyrics.menu.close"].tap()
        XCTAssertTrue(app.staticTexts["ui.harness.closed"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["ui.harness.actions"].label, "Actions: 1")
    }

    func testLanguageLandscapeAccessibilityFooterReachable() {
        launch("language", landscape: true, accessibilityText: true)
        assertTouchTarget(app.buttons["lyrics.menu.close"])
        capture("language-popup-landscape-AX3")
        let action = app.buttons["lyrics.menu.regenerate"]
        reveal(action, scrollID: "lyrics.menu.scroll")
        assertTouchTarget(action)
        capture("language-popup-landscape-AX3-footer")
    }

    func testVideoLandscapeAccessibilityControlsReachable() {
        launch("video", landscape: true, accessibilityText: true)
        assertTouchTarget(app.buttons["lyrics.menu.close"])
        let apply = app.buttons["lyrics.menu.video.apply"]
        reveal(apply, scrollID: "lyrics.menu.scroll")
        assertTouchTarget(apply)
        capture("video-popup-landscape-AX3")
    }
}
#endif
