import XCTest

/// Runs against the demo library from `scripts/seed-simulator.sh`.
final class OfflineMusicUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-OfflineMusicCloudSyncDisabled", "YES"]
        app.launch()
        XCTAssertTrue(app.textFields["Search tracks in playlist"].waitForExistence(timeout: 10))
    }

    func testTappingASearchResultQueuesTheResultsThenTheRestOfTheAlbum() {
        turnShuffleOff()
        search("night")

        // Results in playlist order: Night Bus to Nowhere, Night Swim,
        // Midnight Arcade, Night Shift Lullaby. Tap the second one.
        row("Night Swim").tap()
        XCTAssertTrue(app.buttons["Now playing: Night Swim, Mira Vale"].waitForExistence(timeout: 5))

        XCTAssertEqual(queueTitles(), ["Midnight Arcade", "Night Shift Lullaby", "Sugar Cloud"])
    }

    func testWithoutSearchTheQueueIsTheAlbumOrder() {
        turnShuffleOff()
        row("Night Swim").tap()
        XCTAssertEqual(queueTitles(), [
            "Concrete Bloom", "Afterglow Drive", "Midnight Arcade",
            "Northern Kite", "Night Shift Lullaby", "Sugar Cloud",
        ])
    }

    func testShuffleSurvivesRelaunchAndQueuesEveryOtherTrack() {
        let shuffle = app.buttons["Shuffle"].firstMatch
        if shuffle.value as? String != "On" { shuffle.tap() }
        row("Glass Garden").tap()
        // Only the rows on screen are listed; none may repeat or be the current track.
        let queued = queueTitles()
        XCTAssertGreaterThanOrEqual(queued.count, 6)
        XCTAssertEqual(Set(queued).count, queued.count)
        XCTAssertFalse(queued.contains("Glass Garden"))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Now playing: Glass Garden, Lumen Drift"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["Shuffle"].firstMatch.value as? String, "On")
    }

    func testScreenshots() {
        turnShuffleOff()
        row("Neon Harbor").tap()
        sleep(4)
        app.swipeDown()
        attach("1-library")

        app.buttons["Now playing: Neon Harbor, Lumen Drift"].tap()
        sleep(2)
        attach("2-now-playing")
        app.buttons["Back"].tap()

        search("night")
        row("Night Swim").tap()
        // Scroll so the search field sits at the top with its results below.
        let field = app.textFields["Search tracks in playlist"]
        let start = field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)))
        sleep(2)
        attach("3-search")

        app.buttons["Up next"].tap()
        sleep(1)
        attach("4-queue")
    }

    // MARK: Helpers

    private func turnShuffleOff() {
        let shuffle = app.buttons["Shuffle"].firstMatch
        if shuffle.value as? String == "On" { shuffle.tap() }
    }

    private func search(_ text: String) {
        let field = app.textFields["Search tracks in playlist"]
        field.tap()
        field.typeText(text + "\n")
    }

    private func row(_ title: String) -> XCUIElement {
        let element = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), "row \(title)")
        return element
    }

    private func queueTitles() -> [String] {
        app.buttons["Up next"].tap()
        let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play '"))
        _ = rows.firstMatch.waitForExistence(timeout: 5)
        let titles = rows.allElementsBoundByIndex.map { String($0.label.dropFirst(5)) }
        app.buttons["Done"].tap()
        return titles
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

