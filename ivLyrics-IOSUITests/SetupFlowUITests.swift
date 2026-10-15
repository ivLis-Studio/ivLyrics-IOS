#if DEBUG
import XCTest

/// Runs the production SwiftUI setup/prompt and real AppSettings persistence, without accounts.
@MainActor
final class SetupFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        if let app, app.exists, (testRun?.failureCount ?? 0) > 0 { capture("setup-failure") }
        app?.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(_ surface: String, language: String = "en", theme: String = "dark",
                        landscape: Bool = false, textSize: String = "large", keyless: Bool = false,
                        suite: String = UUID().uuidString, staleTrack: Bool = false, closed: Bool = false,
                        configuredLanguage: Bool = false, forcePrompt: Bool = false, savedSecret: Bool = false) {
        app?.terminate()
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        app = XCUIApplication()
        app.launchArguments = ["--ivlyrics-ui-test"]
        app.launchEnvironment = ["IVLYRICS_UI_SURFACE": surface, "IVLYRICS_UI_LANGUAGE": language,
                                 "IVLYRICS_UI_THEME": theme, "IVLYRICS_UI_TEXT_SIZE": textSize,
                                 "IVLYRICS_UI_DEFAULTS_ID": suite,
                                 "IVLYRICS_UI_TRANSLATION_PROVIDER": keyless ? "keyless" : "none",
                                 "IVLYRICS_UI_STALE_TRACK": staleTrack ? "1" : "0",
                                 "IVLYRICS_UI_CONFIGURED_LANGUAGE": configuredLanguage ? "1" : "0",
                                 "IVLYRICS_UI_FORCE_PROMPT": forcePrompt ? "1" : "0",
                                 "IVLYRICS_UI_SAVED_SECRET": savedSecret ? "1" : "0"]
        app.launch()
        let marker = closed ? "ui.harness.closed" : (surface == "onboarding" ? "onboarding.title" : "first-language.title")
        XCTAssertTrue(app.descendants(matching: .any)[marker].waitForExistence(timeout: 10))
        if landscape {
            wait { self.app.windows.firstMatch.frame.width > self.app.windows.firstMatch.frame.height }
        }
    }

    private func wait(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: app)],
                                     timeout: timeout), .completed)
    }

    private func capture(_ name: String) {
        // Native button/theme compositing can trail AX idle by one short transition.
        // Capture the settled page, rather than an intermediate old/new label blend.
        let composed = expectation(description: "Native page composed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { composed.fulfill() }
        wait(for: [composed], timeout: 2)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility-tree"
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func reveal(_ element: XCUIElement, scrollID: String = "onboarding.scroll") {
        let scroll = app.scrollViews[scrollID]
        for _ in 0..<32 {
            let window = app.windows.firstMatch.frame.insetBy(dx: 1, dy: 1)
            let viewport = scroll.exists ? window.intersection(scroll.frame) : window
            if element.exists && element.isHittable && viewport.contains(element.frame) { return }
            guard scroll.exists else { break }
            let frame = element.exists ? element.frame : .zero
            let limit = viewport.height * 0.4
            let distance: CGFloat = frame.isEmpty ? -limit : (frame.minY < viewport.minY
                ? min(limit, viewport.minY - frame.minY + 24) : -min(limit, frame.maxY - viewport.maxY + 24))
            let start = scroll.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: viewport.midX - scroll.frame.minX, dy: viewport.midY - scroll.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                        withVelocity: .slow, thenHoldForDuration: 0.25)
        }
        capture("setup-unreachable-\(element.identifier)")
        XCTFail("Control must be fully reachable by scrolling: \(element)")
    }

    private func touchTarget(_ element: XCUIElement) {
        XCTAssertTrue(element.exists && element.isHittable)
        // AX can serialize 44pt as 43.99999999999994; allow only floating-point roundoff.
        XCTAssertGreaterThanOrEqual(element.frame.width + 0.000001, 44)
        XCTAssertGreaterThanOrEqual(element.frame.height + 0.000001, 44)
        XCTAssertTrue(app.windows.firstMatch.frame.insetBy(dx: 1, dy: 1).contains(element.frame))
    }

    private func nativeToggle(_ id: String, scrollID: String = "onboarding.scroll") -> XCUIElement {
        let row = app.switches[id]
        let toggle = row.switches.firstMatch.exists ? row.switches.firstMatch : row
        reveal(toggle, scrollID: scrollID)
        let hitArea = app.otherElements["ui.hit.\(id)"]
        XCTAssertTrue(hitArea.exists)
        XCTAssertGreaterThanOrEqual(hitArea.frame.width, 44)
        XCTAssertGreaterThanOrEqual(hitArea.frame.height, 44)
        return toggle
    }

    private func next() {
        let button = app.buttons["onboarding.next"]
        reveal(button)
        touchTarget(button)
        assertNavigationSpacing()
        button.tap()
    }

    private func assertNavigationSpacing() {
        let next = app.buttons["onboarding.next"]
        let back = app.buttons["onboarding.back"]
        if back.exists {
            XCTAssertGreaterThanOrEqual(back.frame.minY - next.frame.maxY + 0.000001, 8,
                                       "The next/back hit areas must retain their full spacing")
        }
        let help = app.buttons["onboarding.help"]
        if help.exists {
            XCTAssertGreaterThanOrEqual(next.frame.minY - help.frame.maxY + 0.000001, 8,
                                       "The setup guide and primary action must not overlap")
        }
    }

    private func credentials() { next(); next() }
    private var preferences: String { app.staticTexts["ui.harness.preferences"].label }

    private func enterID() {
        let field = app.textFields["onboarding.client-id"]
        reveal(field)
        touchTarget(field)
        // Tap close to the native input's top edge, not just its text baseline.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
        field.typeText("fixture-client\n")
        wait { !self.app.keyboards.firstMatch.exists }
    }

    func testOnboardingLanguageThemeDraftsAndValidationRetry() {
        launch("onboarding", language: "ko")
        capture("onboarding-ko-dark-display")
        touchTarget(app.buttons["onboarding.language"])
        app.buttons["onboarding.language"].tap()
        app.buttons["English"].tap()
        XCTAssertEqual(app.staticTexts["onboarding.title"].label, "Make it yours")
        app.buttons["onboarding.theme.light"].tap()
        XCTAssertTrue(app.buttons["onboarding.theme.light"].isSelected)
        capture("onboarding-en-light-display")
        next()
        let webAPI = nativeToggle("onboarding.web-api")
        XCTAssertEqual(webAPI.value as? String, "0")
        webAPI.tap()
        XCTAssertEqual(webAPI.value as? String, "1")
        webAPI.tap()
        XCTAssertEqual(webAPI.value as? String, "0")
        capture("onboarding-en-light-connection")
        next()
        XCTAssertFalse(app.buttons["onboarding.next"].isEnabled)
        enterID()
        reveal(app.buttons["onboarding.metadata"])
        app.buttons["onboarding.metadata"].tap()
        let secret = app.secureTextFields.firstMatch
        reveal(secret)
        touchTarget(secret)
        secret.tap()
        secret.typeText("fixture-secret\n")
        wait { !self.app.keyboards.firstMatch.exists }
        next()
        wait { self.app.buttons["onboarding.next"].label == "Try again" }
        XCTAssertTrue(app.staticTexts["onboarding.status"].exists)
        capture("onboarding-validation-failure-retry")
        let back = app.buttons["onboarding.back"]
        reveal(back)
        back.tap()
        next()
        XCTAssertEqual(app.textFields["onboarding.client-id"].value as? String, "fixture-client")
        reveal(app.buttons["Show"])
        app.buttons["Show"].tap()
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == %@", "fixture-secret")).firstMatch.exists)
        app.buttons["Hide"].tap()
        next()
        wait { self.app.buttons["onboarding.next"].label == "Try again" }
        capture("onboarding-drafts-retained-second-failure")
    }

    func testClientIDOnlyRequestsConnectionWithoutClaimingAuthentication() {
        launch("onboarding")
        credentials()
        enterID()
        next()
        XCTAssertTrue(app.staticTexts["ui.harness.closed"].waitForExistence(timeout: 4))
        XCTAssertEqual(app.staticTexts["ui.harness.actions"].label, "Actions: 1")
        XCTAssertTrue(preferences.contains("webAPI=false;ai=false;auth=false"))
        capture("onboarding-id-only-auth-handoff")
    }

    func testInvalidSavedSecretDoesNotBlockAppRemoteWhenWebAPIIsOff() {
        launch("onboarding", savedSecret: true)
        next()
        XCTAssertEqual(app.switches["onboarding.web-api"].value as? String, "0")
        next()
        XCTAssertFalse(app.secureTextFields.firstMatch.exists)
        enterID()
        capture("onboarding-old-secret-optional-and-inactive")
        next()
        XCTAssertTrue(app.staticTexts["ui.harness.closed"].waitForExistence(timeout: 4))
        XCTAssertEqual(app.staticTexts["ui.harness.actions"].label, "Actions: 1", "Only the connection action, no secret validation")
        XCTAssertTrue(preferences.contains("webAPI=false;ai=false;auth=false"))
        XCTAssertTrue(preferences.contains("secretRetained=true"))
        capture("onboarding-old-secret-app-remote-handoff")
    }

    func testIndependentSwitchesProviderHintAndRememberedLanguage() {
        let suite = UUID().uuidString
        launch("first-language", keyless: true, suite: suite)
        let panel = app.otherElements["ui.hit.first-language.panel"]
        XCTAssertLessThan(panel.frame.height, 520, "Standard prompt should remain compact")
        let title = app.staticTexts["first-language.title"]
        XCTAssertLessThan(title.frame.minX - panel.frame.minX, 24)
        XCTAssertFalse(app.staticTexts["first-language.provider-hint"].exists)
        capture("first-language-en-dark-compact")
        let translation = nativeToggle("first-language.translation", scrollID: "first-language.scroll")
        let pronunciation = nativeToggle("first-language.pronunciation", scrollID: "first-language.scroll")
        XCTAssertEqual(translation.value as? String, "0")
        XCTAssertEqual(pronunciation.value as? String, "0")
        translation.tap()
        XCTAssertEqual(pronunciation.value as? String, "0")
        XCTAssertFalse(app.staticTexts["first-language.provider-hint"].exists, "Keyless translation needs no AI hint")
        pronunciation.tap()
        XCTAssertTrue(app.staticTexts["first-language.provider-hint"].waitForExistence(timeout: 3))
        capture("first-language-keyless-pronunciation-hint")
        touchTarget(app.buttons["first-language.apply"])
        touchTarget(app.buttons["first-language.not-now"])
        app.buttons["first-language.apply"].tap()
        XCTAssertTrue(app.staticTexts["ui.harness.closed"].waitForExistence(timeout: 4))
        XCTAssertTrue(preferences.contains("translation=true;pronunciation=true;prompt=false;rule=true"))
        XCTAssertTrue(preferences.contains("ai=false;auth=false"))
        XCTAssertEqual(app.staticTexts["ui.harness.actions"].label, "Actions: 1")
        launch("first-language", keyless: true, suite: suite, closed: true)
        XCTAssertTrue(preferences.contains("translation=true;pronunciation=true;prompt=false;rule=true"))
        capture("first-language-persisted-without-reprompt")
    }

    func testNotNowOriginalOnlyAndChangedTrackSafeguard() {
        launch("first-language")
        app.buttons["first-language.not-now"].tap()
        XCTAssertTrue(app.staticTexts["ui.harness.closed"].waitForExistence(timeout: 4))
        XCTAssertTrue(preferences.contains("prompt=false;rule=false"))
        launch("first-language")
        XCTAssertEqual(app.buttons["first-language.apply"].label, "Original only")
        app.buttons["first-language.apply"].tap()
        XCTAssertTrue(app.staticTexts["ui.harness.closed"].waitForExistence(timeout: 4))
        XCTAssertTrue(preferences.contains("translation=false;pronunciation=false;prompt=false;rule=true"))
        launch("first-language", staleTrack: true)
        nativeToggle("first-language.translation", scrollID: "first-language.scroll").tap()
        XCTAssertTrue(app.staticTexts["first-language.provider-hint"].exists)
        capture("first-language-no-provider-hint")
        app.buttons["first-language.apply"].tap()
        XCTAssertTrue(app.staticTexts["ui.harness.closed"].waitForExistence(timeout: 4))
        XCTAssertTrue(preferences.contains("translation=true;pronunciation=false"))
        XCTAssertEqual(app.staticTexts["ui.harness.actions"].label, "Actions: 0", "Never reload a replacement track")
    }

    func testCurrentConfigurationAndReopenPreserveIndependentChoices() {
        let suite = UUID().uuidString
        launch("first-language", suite: suite, configuredLanguage: true)
        XCTAssertEqual(app.switches["first-language.translation"].value as? String, "1")
        XCTAssertEqual(app.switches["first-language.pronunciation"].value as? String, "1")
        XCTAssertTrue(app.staticTexts["first-language.provider-hint"].exists)
        XCTAssertTrue(app.staticTexts["first-language.provider-hint"].label.contains("Enable a translation provider in Settings"))
        XCTAssertTrue(app.staticTexts["first-language.provider-hint"].label.contains("Set up an AI provider in Settings"))
        let pronunciation = nativeToggle("first-language.pronunciation", scrollID: "first-language.scroll")
        pronunciation.tap()
        XCTAssertEqual(pronunciation.value as? String, "0")
        XCTAssertEqual(app.switches["first-language.translation"].value as? String, "1")
        wait { self.app.staticTexts["first-language.provider-hint"].label == "Enable a translation provider in Settings to generate translations." }
        app.buttons["first-language.apply"].tap()
        XCTAssertTrue(app.staticTexts["ui.harness.closed"].waitForExistence(timeout: 4))
        launch("first-language", suite: suite, forcePrompt: true)
        XCTAssertEqual(app.switches["first-language.translation"].value as? String, "1")
        XCTAssertEqual(app.switches["first-language.pronunciation"].value as? String, "0")
        capture("first-language-current-configuration-on-reopen")
    }

    func testLandscapeAX5ControlsRemainReachable() {
        launch("onboarding", language: "de", theme: "light", landscape: true, textSize: "accessibility5")
        capture("onboarding-de-light-landscape-AX5-display")
        reveal(app.buttons["onboarding.language"])
        touchTarget(app.buttons["onboarding.language"])
        next()
        let toggle = nativeToggle("onboarding.web-api")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        capture("onboarding-de-light-landscape-AX5-connection")
        next()
        reveal(app.textFields["onboarding.client-id"])
        capture("onboarding-de-light-landscape-AX5-credentials")
        reveal(app.buttons["onboarding.back"])
        touchTarget(app.buttons["onboarding.back"])
        launch("first-language", language: "de", theme: "light", landscape: true, textSize: "accessibility5")
        capture("first-language-de-light-landscape-AX5-title")
        let pronunciation = nativeToggle("first-language.pronunciation", scrollID: "first-language.scroll")
        pronunciation.tap()
        XCTAssertEqual(pronunciation.value as? String, "1")
        let apply = app.buttons["first-language.apply"]
        reveal(apply, scrollID: "first-language.scroll")
        touchTarget(apply)
        capture("first-language-de-light-landscape-AX5-apply")
        apply.tap()
        XCTAssertTrue(app.staticTexts["ui.harness.closed"].waitForExistence(timeout: 4))
        XCTAssertTrue(preferences.contains("translation=false;pronunciation=true"))
    }

    func testSetupAndPromptScreenshotMatrixAndGuide() {
        for theme in ["dark", "light"] {
            launch("onboarding", language: "ko", theme: theme)
            capture("matrix-onboarding-ko-\(theme)-display")
            next()
            assertNavigationSpacing()
            capture("matrix-onboarding-ko-\(theme)-connection")
            next()
            assertNavigationSpacing()
            capture("matrix-onboarding-ko-\(theme)-credentials")
            let help = app.buttons["onboarding.help"]
            reveal(help)
            touchTarget(help)
            help.tap()
            for _ in 0..<3 {
                let next = app.buttons["spotify.setup.next"]
                reveal(next)
                touchTarget(next)
                next.tap()
            }
            let uri = app.staticTexts["musicplayer-auth://callback"]
            reveal(uri)
            XCTAssertTrue(uri.exists)
            capture("matrix-onboarding-ko-\(theme)-redirect-guide")
            launch("first-language", language: "ko", theme: theme)
            capture("matrix-first-language-ko-\(theme)")
        }
        for language in ["ar", "de", "th"] {
            launch("first-language", language: language, theme: "light")
            capture("matrix-first-language-\(language)-light")
        }
    }
}
#endif
