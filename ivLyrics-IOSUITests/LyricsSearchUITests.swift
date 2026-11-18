#if DEBUG
import XCTest

/// ivLyrics without Spotify, on the production app root: a fresh install leaves setup for lyrics
/// search, and found lyrics play on the app's own timer. It searches real lyrics providers, so it
/// runs only with TEST_RUNNER_IVLYRICS_LIVE_SEARCH_UI=1.
@MainActor
final class LyricsSearchUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IVLYRICS_LIVE_SEARCH_UI"] == "1",
                          "Searches live lyrics providers")
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    func testFreshInstallSearchesLyricsWithoutSpotify() throws {
        app = XCUIApplication()
        // Setup is shown again even if an earlier run left it.
        app.launchArguments = ["-initial_setup_dismissed", "NO"]
        app.launch()

        let withoutSpotify = app.buttons["onboarding.without-spotify"]
        XCTAssertTrue(withoutSpotify.waitForExistence(timeout: 20))
        capture("01-setup")
        withoutSpotify.tap()

        let title = app.textFields["lyrics-search.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        capture("02-search")
        title.tap()
        title.typeText(ProcessInfo.processInfo.environment["IVLYRICS_LIVE_SEARCH_TITLE"] ?? "Lemon")
        let artist = app.textFields["lyrics-search.artist"]
        artist.tap()
        artist.typeText(ProcessInfo.processInfo.environment["IVLYRICS_LIVE_SEARCH_ARTIST"] ?? "Kenshi Yonezu")
        app.buttons["lyrics-search.submit"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.buttons["main.lyrics-search"].exists, "A searched song replaces the empty-state card")

        Thread.sleep(forTimeInterval: 25)
        capture("03-playing")
        Thread.sleep(forTimeInterval: 6)
        capture("04-playing-later")
    }

    func testEmptyPlayerOffersSearchAndSpotify() throws {
        app = XCUIApplication()
        app.launchArguments = ["-initial_setup_dismissed", "YES"]
        app.launch()

        let search = app.buttons["main.lyrics-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["main.connect-spotify"].exists)
        capture("05-empty-player")
        search.tap()
        XCTAssertTrue(app.textFields["lyrics-search.title"].waitForExistence(timeout: 10))
        app.buttons["lyrics-search.close"].tap()
        XCTAssertTrue(search.waitForExistence(timeout: 10))

        app.buttons["main.connect-spotify"].tap()
        XCTAssertTrue(app.buttons["onboarding.without-spotify"].waitForExistence(timeout: 10))
        capture("06-connect-opens-setup")
    }

    private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
#endif
