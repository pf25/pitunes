import XCTest

/// UI smoke tests. Need a pitunes server; pass its URL with TEST_SERVER
/// (default http://127.0.0.1:8765) when running `xcodebuild test`.
final class SmokeTests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        let server = ProcessInfo.processInfo.environment["TEST_SERVER"] ?? "http://127.0.0.1:8765"
        app.launchArguments += ["-serverURL", server]   // overrides the Settings value
        app.launch()
        return app
    }

    /// Home's first song shelf can be below the fold (speed dial, mixes come first).
    private func scrollToPlayAll(_ app: XCUIApplication) -> XCUIElement {
        let playAll = app.buttons["Play all"].firstMatch
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15))
        sleep(3)
        for _ in 0..<8 where !(playAll.exists && playAll.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(playAll.exists, "no 'Play all' on Home")
        return playAll
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testBrowseScreens() throws {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Quick picks"].waitForExistence(timeout: 15)
                      || app.scrollViews.firstMatch.waitForExistence(timeout: 1))
        sleep(3); snap(app, "1-home")
        app.tabBars.buttons["Explore"].tap()
        sleep(4); snap(app, "2-explore")
        app.buttons["Charts"].firstMatch.tap()
        sleep(4); snap(app, "3-charts")
        app.tabBars.buttons["Library"].tap()
        sleep(2); snap(app, "4-library")
    }

    func testPlaybackScreens() throws {
        let app = launch()
        let playAll = scrollToPlayAll(app)
        playAll.tap()
        let next = app.buttons["Next"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5), "mini player missing")
        sleep(14); snap(app, "5-home-playing")
        next.coordinate(withNormalizedOffset: CGVector(dx: -4, dy: 0.5)).tap()   // tap the mini player body
        XCTAssertTrue(app.staticTexts["Up Next"].waitForExistence(timeout: 5), "Now Playing didn't open")
        sleep(2); snap(app, "6-now-playing")
        // Repeat cycles off -> all -> one; the "..." menu has the sleep timer.
        let repeatButton = app.buttons["Repeat"].firstMatch
        XCTAssertEqual(repeatButton.value as? String, "Off")
        repeatButton.tap()
        XCTAssertEqual(repeatButton.value as? String, "All")
        repeatButton.tap(); repeatButton.tap()
        XCTAssertEqual(repeatButton.value as? String, "Off")
        XCTAssertTrue(app.buttons["Shuffle Up Next"].firstMatch.isEnabled)
        app.buttons["More"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Sleep Timer"].waitForExistence(timeout: 3), "menu didn't open")
        XCTAssertTrue(app.buttons["Pin to Speed Dial"].exists)
        snap(app, "6b-now-playing-menu")
        app.buttons["Pin to Speed Dial"].tap()
        sleep(1)
        app.buttons["More"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Unpin from Speed Dial"].waitForExistence(timeout: 3), "pin didn't stick")
        app.buttons["Unpin from Speed Dial"].tap()
        // Clearing Up Next leaves a way to fill it again.
        app.buttons["More"].firstMatch.tap()
        app.buttons["Clear Up Next"].tap()
        app.swipeUp()
        let refill = app.buttons["Add Similar Songs"]
        XCTAssertTrue(refill.waitForExistence(timeout: 3), "no way to refill Up Next")
        snap(app, "6c-up-next-cleared")
        refill.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "More").element(boundBy: 1).waitForExistence(timeout: 30), "similar songs didn't arrive")
        app.swipeUp()
        sleep(1); snap(app, "7-up-next")
    }

    func testFirstLaunchConnect() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-resetServer"]            // as on a fresh install
        app.launch()
        XCTAssertTrue(app.staticTexts["Connect to your server"].waitForExistence(timeout: 10))
        snap(app, "11-connect")
        let field = app.textFields["Server address"]
        field.tap()
        field.typeText("not a server\n")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "look like an address")).firstMatch
            .waitForExistence(timeout: 15), "bad address should show an error")
        snap(app, "12-connect-error")
        // Start over with a real address, typed the lazy way (no http://).
        app.terminate()
        app.launchArguments = []
        app.launch()
        let again = app.textFields["Server address"]
        XCTAssertTrue(again.waitForExistence(timeout: 10))
        again.tap()
        let server = ProcessInfo.processInfo.environment["TEST_SERVER"] ?? "127.0.0.1:8765"
        again.typeText(server.replacingOccurrences(of: "http://", with: "") + "\n")
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 15), "should land on the main screens")
    }

    func testPodcasts() throws {
        let app = launch()
        app.tabBars.buttons["Podcasts"].tap()
        XCTAssertTrue(app.staticTexts["Top shows"].waitForExistence(timeout: 30), "top shows didn't load")
        sleep(3); snap(app, "8-podcasts")
        app.swipeUp(); sleep(1); snap(app, "8b-podcast-categories"); app.swipeDown()
        app.buttons["Science"].firstMatch.tap()           // category chip
        sleep(2); snap(app, "8c-podcasts-science")
        app.buttons["Science"].firstMatch.tap()           // back to the overview
        app.buttons.matching(identifier: "show-card").firstMatch.tap()
        let latest = app.buttons["Latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 20), "show page didn't load")
        sleep(2); snap(app, "9-show")
        latest.tap()
        let fwd = app.buttons["Next"].firstMatch            // mini player
        XCTAssertTrue(fwd.waitForExistence(timeout: 5))
        sleep(10)
        fwd.coordinate(withNormalizedOffset: CGVector(dx: -4, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Forward 30 seconds"].waitForExistence(timeout: 5), "episode controls missing")
        sleep(2); snap(app, "10-episode-playing")
    }

    func testLikedSongsHasDownloadButton() throws {
        let app = launch()
        app.tabBars.buttons["Library"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Liked Songs")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Download"].waitForExistence(timeout: 5)
                      || app.buttons["Downloaded"].exists || app.buttons["Downloading"].exists,
                      "download button missing. Buttons: \(app.buttons.allElementsBoundByIndex.map(\.label))")
    }

    /// Tapping outside a text field hides the keyboard; tapping the field shows it again.
    func testSettingsKeyboardDismisses() throws {
        let app = launch()
        app.tabBars.buttons["Library"].tap()
        app.buttons["Settings"].firstMatch.tap()
        let field = app.textFields["New profile name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard didn't open")
        app.staticTexts["Profile"].firstMatch.tap()        // a blank-ish spot: the section header
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "keyboard stayed up")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard didn't reopen")
        // And with the keyboard hidden, the profile menu must still open.
        app.staticTexts["Profile"].firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let before = app.buttons.count
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Listening as")).firstMatch.tap()
        sleep(1); snap(app, "11-profile-menu")
        XCTAssertTrue(app.buttons.count > before || app.collectionViews.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Profile ")).count > 0,
            "profile menu didn't open. Buttons: \(app.buttons.allElementsBoundByIndex.map(\.label))")
    }

    /// With the mini player showing, the end of Home must scroll clear of it,
    /// and swiping the bar down closes the player.
    func testMiniPlayerDoesNotCoverContent() throws {
        let app = launch()
        let playAll = scrollToPlayAll(app)
        playAll.tap()
        let next = app.buttons["Next"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5), "mini player missing")
        for _ in 0..<12 { app.swipeUp(velocity: .fast) }
        sleep(1); snap(app, "12-home-bottom-with-player")
        app.tabBars.buttons["Library"].tap()
        sleep(1); snap(app, "13-library-with-player")
        next.coordinate(withNormalizedOffset: CGVector(dx: -4, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.tabBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertTrue(next.waitForNonExistence(timeout: 5), "mini player didn't close")
        snap(app, "14-player-closed")
    }

    /// Speed dial pages: swipe to the second page (needs 10+ played songs on the server).
    func testSpeedDialPages() throws {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Speed dial"].waitForExistence(timeout: 15), "no speed dial")
        sleep(3); snap(app, "15-speed-dial-page-1")
        let title = app.staticTexts["Speed dial"]
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 6))
            .press(forDuration: 0.05, thenDragTo: title.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 6)))
        sleep(1); snap(app, "16-speed-dial-page-2")
    }

    /// Home extras, recent searches, and following an artist.
    func testHomeSearchAndFollow() throws {
        var app = launch()
        XCTAssertTrue(app.staticTexts["Your mixes"].waitForExistence(timeout: 20), "no mixes shelf (needs plays on the server)")
        snap(app, "17-home-top")
        app.tabBars.buttons["Search"].tap()
        sleep(1); snap(app, "17b-search-empty")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no search field: \(app.debugDescription.prefix(1500))")
        field.tap(); field.typeText("coldplay\n")
        let artists = app.buttons["Artists"]
        XCTAssertTrue(artists.waitForExistence(timeout: 20))
        artists.tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Coldplay")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no artist result")
        row.tap()
        let follow = app.buttons["Follow"]
        if follow.waitForExistence(timeout: 20) { follow.tap() }   // (already followed if a run was cut short)
        XCTAssertTrue(app.buttons["Following"].waitForExistence(timeout: 5), "couldn't follow the artist")
        snap(app, "18-artist-following")
        app.navigationBars.buttons.firstMatch.tap()       // back to results
        let clear = app.buttons["Clear text"].firstMatch
        if clear.waitForExistence(timeout: 3) { clear.tap() }
        XCTAssertTrue(app.staticTexts["Recent searches"].waitForExistence(timeout: 5)
                      || app.staticTexts["RECENT SEARCHES"].exists, "no recent searches")
        snap(app, "19-recent-searches")
        XCTAssertTrue(app.buttons["Identify a song playing nearby"].exists, "no sound search button")
        app.terminate()                                   // the keyboard covers the tab bar; start clean
        app = launch()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts["Coldplay"].waitForExistence(timeout: 5), "followed artist not in Library")
        snap(app, "20-library-artists")
        // Clean up so the test can run again.
        app.staticTexts["Coldplay"].tap()
        app.buttons["Following"].tap()
    }
}
