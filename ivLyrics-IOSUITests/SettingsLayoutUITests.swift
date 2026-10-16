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
        // Reset a changed orientation while the tested app is still active.
        // Repeated portrait assignments after termination can stall CI's AX
        // active-application lookup even when no rotation is needed.
        if XCUIDevice.shared.orientation != .portrait {
            XCUIDevice.shared.orientation = .portrait
        }
        app?.terminate()
    }

    /// Settings open on the home list (menus + search); `tab` opens one menu page directly.
    private func launch(_ surface: String = "settings", tab: String = "home", language: String = "en",
                        landscape: Bool = false, textSize: String = "large", theme: String = "dark") {
        if XCUIDevice.shared.orientation != .portrait {
            XCUIDevice.shared.orientation = .portrait
        }
        app = XCUIApplication()
        app.launchArguments = ["--ivlyrics-ui-test"]
        app.launchEnvironment = ["IVLYRICS_UI_SURFACE": surface, "IVLYRICS_DEBUG_SETTINGS_TAB": tab,
                                 "IVLYRICS_UI_LANGUAGE": language,
                                 "IVLYRICS_UI_TEXT_SIZE": textSize,
                                 "IVLYRICS_UI_THEME": theme]
        app.launch()
        let settingsMarker = tab == "home" ? "settings.search" : "settings.scroll"
        let marker = app.descendants(matching: .any)[surface == "settings" ? settingsMarker : "lyrics.menu.close"]
        let ready = marker.waitForExistence(timeout: 10)
        if !ready { capture("launch-\(surface)-missing-marker") }
        XCTAssertTrue(ready, "Native launch marker is missing: \(marker)")
        if landscape {
            // Rotate the mounted full-screen cover, rather than racing its launch presentation.
            XCUIDevice.shared.orientation = .landscapeLeft
            wait(NSPredicate { _, _ in self.app.windows.firstMatch.frame.width > self.app.windows.firstMatch.frame.height }, on: app.windows.firstMatch, timeout: 15)
        }
    }

    private func wait(_ predicate: NSPredicate, on element: XCUIElement, timeout: TimeInterval = 5) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        if result != .completed { capture("native-wait-timeout") }
        XCTAssertEqual(result, .completed)
    }

    private func waitForSettingsPage() {
        // A completed tap/idle wait does not guarantee a fresh SwiftUI navigation
        // AX tree on a loaded CI Simulator. Run 38743069235 timed out in reveal's
        // 4s container check, yet its failure tree already showed General open.
        // Observe the destination after the single native tap; never tap again.
        let scroll = app.scrollViews["settings.scroll"]
        wait(NSPredicate { _, _ in
            scroll.exists && scroll.isHittable && !self.app.scrollViews["settings.home"].exists
        }, on: scroll, timeout: 30)
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
            // Move a clipped control toward the visible center. A tiny edge-only
            // correction can stay below the native pan threshold indefinitely.
            // Slow movement and an end hold prevent momentum from skipping it.
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
        // Aim for the center, rather than adding a guessed recognition margin.
        // In CI a 31.3pt gesture left a 44pt field clipped by 7.3pt on every
        // attempt. Centering gives short controls enough real finger travel,
        // while the cap keeps both endpoints inside the viewport.
        if frame.minY < viewport.minY || frame.maxY > viewport.maxY {
            return max(-limit, min(limit, viewport.midY - frame.midY))
        }
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

    private func assertBadgeCentered(_ identifier: String, size: CGFloat, fixed: Bool = false) {
        let badge = app.otherElements["ui.badge.\(identifier).frame"]
        reveal(badge, scrollID: "settings.scroll")
        let text = app.otherElements["ui.badge.\(identifier).text"]
        XCTAssertTrue(text.waitForExistence(timeout: 4))
        capture("centered-\(identifier)")
        XCTAssertFalse(text.frame.isEmpty)
        XCTAssertGreaterThanOrEqual(badge.frame.width, size)
        XCTAssertGreaterThanOrEqual(badge.frame.height, size)
        XCTAssertEqual(text.frame.midX, badge.frame.midX, accuracy: 0.5)
        XCTAssertEqual(text.frame.midY, badge.frame.midY, accuracy: 0.5)
        if fixed {
            XCTAssertEqual(badge.frame.width, size, accuracy: 0.5)
            XCTAssertEqual(badge.frame.height, size, accuracy: 0.5)
            XCTAssertLessThan(text.frame.width, badge.frame.width, "Measure the text separately from its square")
        }
    }

    private func checkAIProviderBadges() {
        for rank in [1, 10] { assertBadgeCentered("rank.\(rank)", size: 22) }
        // Production initials are GG, OC and PA (Pollinations.ai), respectively.
        for provider in ["gemini", "chatgpt", "pollinations"] {
            assertBadgeCentered("connection.\(provider)", size: 30, fixed: true)
        }
    }

    func testProviderBadgeCenters() {
        launch(tab: "ai")
        checkAIProviderBadges()
        app.terminate()
        // Lyrics providers reuse the very same rank badge.
        launch(tab: "providers")
        assertBadgeCentered("rank.1", size: 22)
    }

    func testAIProviderBadgeCentersWithAccessibilityText() {
        launch(tab: "ai", language: "ko", textSize: "accessibility5", theme: "light")
        checkAIProviderBadges()
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

    private func assertHomeWordmark(file: StaticString = #filePath, line: UInt = #line) {
        let wordmark = app.staticTexts["settings.wordmark"]
        XCTAssertTrue(wordmark.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(wordmark.label, "ivLyrics", file: file, line: line)
        let fonts = wordmark.value as? String ?? ""
        XCTAssertTrue(fonts.contains("iv=800;Lyrics=250;"), fonts, file: file, line: line)
        XCTAssertTrue(fonts.contains("ivFont=PretendardVariable"), fonts, file: file, line: line)
        XCTAssertTrue(fonts.contains("lyricsFont=PretendardVariable"), fonts, file: file, line: line)
        XCTAssertTrue(app.windows.firstMatch.frame.insetBy(dx: 1, dy: 1).contains(wordmark.frame), file: file, line: line)
        XCTAssertLessThanOrEqual(wordmark.frame.maxY, app.textFields["settings.search"].frame.minY, file: file, line: line)
    }

    func testHomeWordmarkExactWeightsAndLocalizedNavigation() {
        for (language, theme, title) in [("en", "dark", "General"), ("ko", "light", "일반")] {
            launch(language: language, theme: theme)
            assertHomeWordmark()
            assertTouchTarget(app.textFields["settings.search"])
            assertTouchTarget(app.buttons["settings.close"])
            assertTouchTarget(app.buttons["settings.theme.light"])
            capture("wordmark-\(language)-\(theme)-portrait")
            let general = app.buttons["settings.menu.general"]
            reveal(general, scrollID: "settings.home")
            assertTouchTarget(general)
            general.tap()
            waitForSettingsPage()
            XCTAssertTrue(app.navigationBars[title].exists, "Category title must remain localized")
            let back = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertFalse(back.label.isEmpty, "The native Back control must retain an accessibility label")
            assertTouchTarget(back)
            back.tap()
            XCTAssertTrue(app.scrollViews["settings.home"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["settings.wordmark"].label, "ivLyrics")
            app.terminate()
        }
    }

    func testHomeWordmarkLandscapeAccessibilityText() {
        launch(language: "ko", landscape: true, textSize: "accessibility5", theme: "light")
        assertHomeWordmark()
        assertTouchTarget(app.textFields["settings.search"])
        assertTouchTarget(app.buttons["settings.close"])
        capture("wordmark-ko-light-landscape-AX5")
    }


    func testGeneralPortraitSearchKeyboardAndSwitch() {
        launch()
        let search = app.textFields["settings.search"]
        assertTouchTarget(search)
        XCTAssertGreaterThan(search.frame.width, app.windows.firstMatch.frame.width * 0.5)
        capture("home-portrait")
        // The top edge of the 48pt native input must focus too, not only its text baseline.
        search.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
        search.typeText("artist")
        let result = app.buttons["settings.result.setting.metadata_translation"]
        XCTAssertTrue(result.waitForExistence(timeout: 4))
        assertTouchTarget(app.buttons["settings.search.clear"])
        capture("settings-search-keyboard")
        // A result opens its menu and scrolls to the row.
        result.tap()
        waitForSettingsPage()
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
        capture("home-landscape-AX5")
        let general = app.buttons["settings.menu.general"]
        reveal(general, scrollID: "settings.home")
        assertTouchTarget(general)
        general.tap()
        waitForSettingsPage()
        capture("general-landscape-AX5-opened")
        let toggle = app.switches["settings.toggle.metadata"]
        reveal(toggle, scrollID: "settings.scroll")
        assertNativeToggle(toggle)
        let before = toggle.value as? String
        toggle.tap()
        XCTAssertNotEqual(toggle.value as? String, before)
        capture("general-landscape-AX5-switch")
    }

    func testThemeSwitchAndMenuNavigation() {
        launch()
        let light = app.buttons["settings.theme.light"]
        assertTouchTarget(light)
        light.tap()
        wait(NSPredicate(format: "isSelected == true"), on: light)
        capture("home-light")
        let providers = app.buttons["settings.menu.providers"]
        reveal(providers, scrollID: "settings.home")
        assertTouchTarget(providers)
        providers.tap()
        waitForSettingsPage()
        let toggle = app.switches["settings.lyrics.toggle.lrclib"]
        reveal(toggle, scrollID: "settings.scroll")
        assertNativeToggle(toggle)
        capture("providers-light")
    }

    func testLrclibEndpointValidationPersistenceAndClear() {
        launch()
        let providers = app.buttons["settings.menu.providers"]
        reveal(providers, scrollID: "settings.home")
        providers.tap()
        waitForSettingsPage()
        let field = app.textFields["settings.lrclib.endpoint"]
        reveal(field, scrollID: "settings.scroll")
        assertTouchTarget(field)
        field.tap()
        let invalid = "http://mirror.example/api"
        field.typeText(invalid + "\n")
        let error = app.descendants(matching: .any)["settings.lrclib.endpoint.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        let endpoint = "https://mirror.example/api"
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: invalid.count) + endpoint + "/\n")
        wait(NSPredicate { _, _ in (field.value as? String) == endpoint && !error.exists }, on: field)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.scrollViews["settings.home"].waitForExistence(timeout: 5))
        reveal(providers, scrollID: "settings.home")
        providers.tap()
        waitForSettingsPage()
        reveal(field, scrollID: "settings.scroll")
        XCTAssertEqual(field.value as? String, endpoint, "Reopening settings reads the saved endpoint")
        field.tap()
        field.press(forDuration: 1.1)
        let selectAll = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Select All", "전체 선택", "모두 선택"])).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5), "Clear the entire saved URL using the native text selection menu")
        selectAll.tap()
        field.typeText(XCUIKeyboardKey.delete.rawValue + "\n")
        wait(NSPredicate { _, _ in (field.value as? String) == "https://lrclib.net/api" && !error.exists }, on: field)
        capture("lrclib-endpoint-cleared")
    }

    func testLrclibEndpointLargeTextLayout() {
        launch(tab: "providers", language: "ko", landscape: true, textSize: "accessibility5", theme: "light")
        let field = app.textFields["settings.lrclib.endpoint"]
        reveal(field, scrollID: "settings.scroll")
        assertTouchTarget(field)
        let save = app.buttons["settings.lrclib.endpoint.save"]
        reveal(save, scrollID: "settings.scroll")
        assertTouchTarget(save)
        capture("lrclib-endpoint-landscape-accessibility")
    }

    /// Exercise the reported home -> category route rather than seeding the destination path.
    /// Also run this test with Release optimization and opaque type erasure disabled: Debug's
    /// implicit AnyView wrapping can hide oversized SwiftUI navigation destinations.
    func testEverySettingsCategoryOpensFromHomeAndReturns() {
        for menu in ["current_track", "general", "providers", "ai", "appearance", "lyrics", "player", "system"] {
            launch(language: "ko")
            assertHomeWordmark()
            let row = app.buttons["settings.menu.\(menu)"]
            reveal(row, scrollID: "settings.home")
            row.tap()
            waitForSettingsPage()
            XCTAssertEqual(app.state, .runningForeground, "Opening \(menu) must not terminate the app")
            capture("navigation-\(menu)-opened")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.scrollViews["settings.home"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.textFields["settings.search"].exists)
            app.buttons["settings.close"].tap()
            let size = app.staticTexts["ui.harness.navigation-content-bytes"]
            XCTAssertTrue(size.waitForExistence(timeout: 5))
            XCTAssertLessThanOrEqual(Int(size.label) ?? Int.max, 64,
                                    "Navigation must not copy a union as large as every settings page")
            app.terminate()
        }
    }

    /// The pinned live preview keeps its natural height, so the first settings of the page stay in view.
    func testPinnedPreviewLeavesRoomForSettings() {
        launch(tab: "appearance")
        let toggle = app.buttons["settings.preview.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let header = app.staticTexts.matching(identifier: "Layout").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch.frame
        capture("appearance-pinned-preview")
        XCTAssertLessThan(header.frame.maxY, window.minY + window.height * 0.8,
                          "The pinned preview must leave the first section of the page on screen")
    }

    /// Screenshot matrix of every settings menu in both themes, plus large-text landscape pages.
    /// Evidence for review only: each capture follows a real launch of the native page.
    func testSettingsMenusScreenshotMatrix() {
        let menus = ["general", "providers", "ai", "appearance", "lyrics", "player", "system"]
        for theme in ["dark", "light"] {
            launch(language: "ko", theme: theme)
            capture("matrix-\(theme)-home")
            app.terminate()
            for menu in menus {
                launch(tab: menu, language: "ko", theme: theme)
                capture("matrix-\(theme)-\(menu)-1")
                let scroll = app.scrollViews["settings.scroll"]
                for page in 2...3 {
                    // Start low: an expanded live preview can be pinned over the top of the scroll view.
                    let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88))
                    let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
                    capture("matrix-\(theme)-\(menu)-\(page)")
                }
                app.terminate()
            }
        }
        for menu in ["appearance", "ai", "system"] {
            launch(tab: menu, landscape: true, textSize: "accessibility5")
            capture("matrix-landscape-AX5-\(menu)")
            app.terminate()
        }
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
