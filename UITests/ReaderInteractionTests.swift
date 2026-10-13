import XCTest

@MainActor final class ReaderInteractionTests: XCTestCase {
    func testLibraryLandingAndGlobalReader() {
        let app = XCUIApplication()
        app.launch()
        let libraryTab = app.buttons.matching(identifier: "My Library").firstMatch
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons.matching(identifier: "My Library").firstMatch.isSelected)
        XCTAssertTrue(app.navigationBars["My Library"].exists)

        app.buttons.matching(identifier: "Browse").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Browse"].waitForExistence(timeout: 5))
        let url = app.textFields["Website URL"]
        url.tap()
        url.typeText("https://demo.mangaviewer.local/chapter/arrival")
        app.buttons["Open"].tap()
        let counter = app.staticTexts["reader.pageCounter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 20))
        let position = counter.label
        XCTAssertFalse(libraryTab.isHittable)
        app.buttons["reader.collapse"].tap()
        let resume = app.buttons["reader.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 8))
        XCTAssertEqual(resume.value as? String, position)
        let collapsed = XCTAttachment(screenshot: app.screenshot())
        collapsed.name = "Global reader resume accessory"
        collapsed.lifetime = .keepAlways
        add(collapsed)

        app.buttons.matching(identifier: "Settings").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(resume.isHittable)
        app.buttons.matching(identifier: "My Library").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["My Library"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 · Arrival"].exists)
        resume.tap()
        XCTAssertTrue(counter.waitForExistence(timeout: 20))
        XCTAssertTrue(wait { counter.label == position })
        XCTAssertEqual(app.staticTexts["reader.chapterTitle"].label, "1 · Arrival")
        app.buttons["reader.collapse"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "My Library").firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons.matching(identifier: "My Library").firstMatch.isSelected)

        // Opening a different chapter replaces the one global session, without a second mini reader.
        app.buttons.matching(identifier: "Browse").firstMatch.tap()
        app.buttons["Open the reading room"].tap()
        let manga = app.buttons["The Observatory"]
        XCTAssertTrue(manga.waitForExistence(timeout: 10))
        manga.tap()
        let chapter = app.buttons["2 · Starlight"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 10))
        chapter.tap()
        XCTAssertTrue(wait { app.staticTexts["reader.chapterTitle"].label == "2 · Starlight" })
        app.buttons["reader.collapse"].tap()
        XCTAssertTrue(resume.waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons.matching(identifier: "reader.resume").count, 1)
        XCTAssertEqual(resume.label, "Resume 2 · Starlight")
        app.buttons.matching(identifier: "My Library").firstMatch.tap()
        resume.tap()
        XCTAssertTrue(wait { app.staticTexts["reader.chapterTitle"].label == "2 · Starlight" })

        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["My Library"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons.matching(identifier: "My Library").firstMatch.isSelected)
    }

    func testSwipeImmersionAndResume() {
        let app = XCUIApplication()
        app.launchArguments = ["--open-url", "https://demo.mangaviewer.local/chapter/arrival"]
        app.launch()
        let counter = app.staticTexts["reader.pageCounter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 20))
        select("Paged", in: "Mode", app: app)
        select("Right to left", in: "Direction", app: app)
        disable("Detect spreads", app: app)
        disable("Facing pages in wide windows", app: app)
        XCTAssertFalse(app.buttons["Next page"].exists)
        XCTAssertFalse(app.buttons["Previous page"].exists)
        XCTAssertEqual(app.staticTexts["reader.chapterTitle"].label, "1 · Arrival")

        // RTL: drag right to reveal the next source page.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        // The test is repeatable without deleting the app's reading history.
        for _ in 0..<8 where !counter.label.hasPrefix("Page 1 ") {
            end.press(forDuration: 0.05, thenDragTo: start)
        }
        XCTAssertTrue(counter.label.hasPrefix("Page 1 "))
        let initial = counter.label
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(wait { counter.exists && counter.label != initial })
        XCTAssertTrue(wait { self.visiblePage(in: app) == "Comic page 2" })
        let advanced = counter.label

        // Paged mode collapses from a top pull, then resumes the actual same source image.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.13))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        let resume = app.buttons["reader.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 8))
        XCTAssertEqual(resume.value as? String, advanced)
        resume.tap()
        XCTAssertTrue(counter.waitForExistence(timeout: 8))
        XCTAssertTrue(wait { self.visiblePage(in: app) == "Comic page 2" })

        // Check actual content, since a stale counter alone would hide lost restoration.
        select("Scroll", in: "Mode", app: app)
        XCTAssertTrue(wait { self.visiblePage(in: app) == "Comic page 2" })
        XCTAssertEqual(counter.label, advanced)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        let scrolledPage = app.images.matching(identifier: "reader.pageImage").matching(NSPredicate(format: "label == %@", "Comic page 2")).firstMatch
        let verticalPosition = scrolledPage.frame.minY
        // Vertical reading uses a physical left-edge back swipe, never a vertical page drag.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)))
        XCTAssertTrue(resume.waitForExistence(timeout: 8))
        resume.tap()
        XCTAssertTrue(counter.waitForExistence(timeout: 8))
        XCTAssertTrue(wait { self.visiblePage(in: app) == "Comic page 2" })
        XCTAssertTrue(wait { abs(scrolledPage.frame.minY - verticalPosition) < 3 }, "Before: \(verticalPosition), resumed: \(scrolledPage.frame.minY)")
        select("Paged", in: "Mode", app: app)
        let restored = wait { self.visiblePage(in: app) == "Comic page 2" }
        if !restored {
            print(app.debugDescription)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertTrue(restored)
        XCTAssertEqual(counter.label, advanced)

        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.tap()
        XCTAssertTrue(wait { !counter.exists && !app.buttons["Reader options"].isHittable })
        XCTAssertFalse(app.buttons.matching(identifier: "My Library").firstMatch.isHittable)
        center.tap()
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        XCTAssertTrue(wait { counter.label == advanced })
        XCTAssertTrue(app.buttons["Reader options"].isHittable)
        XCTAssertFalse(app.buttons.matching(identifier: "My Library").firstMatch.isHittable)

        // The compact title does not expand when touched.
        let title = app.staticTexts["reader.chapterTitle"]
        let height = title.frame.height
        title.tap()
        XCTAssertEqual(title.frame.height, height, accuracy: 1)
        XCTAssertTrue(wait { counter.label == advanced })

        app.terminate()
        app.launch()
        XCTAssertTrue(counter.waitForExistence(timeout: 20))
        XCTAssertEqual(counter.label, advanced)
        XCTAssertTrue(wait { self.visiblePage(in: app) == "Comic page 2" })
    }
    private func select(_ value: String, in picker: String, app: XCUIApplication) {
        app.buttons["Reader options"].tap()
        if app.buttons[picker].exists { app.buttons[picker].tap() }
        let option = app.buttons[value]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
    }
    private func visiblePage(in app: XCUIApplication) -> String? {
        let point = CGPoint(x: app.frame.midX, y: app.frame.minY + app.frame.height * 0.35)
        return app.images.matching(identifier: "reader.pageImage").allElementsBoundByIndex
            .first { $0.frame.contains(point) && $0.isHittable }?.label
    }
    private func disable(_ label: String, app: XCUIApplication) {
        app.buttons["Reader options"].tap()
        let toggle = app.buttons[label]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if toggle.isSelected || ["1", "on"].contains(toggle.value as? String ?? "") { toggle.tap() }
        else { app.buttons["Paged"].tap() }
    }
    private func wait(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 8) == .completed
    }
}
