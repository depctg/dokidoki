import XCTest

@MainActor final class ReaderInteractionTests: XCTestCase {
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

        // Check actual content, since a stale counter alone would hide lost restoration.
        select("Scroll", in: "Mode", app: app)
        XCTAssertTrue(wait { self.visiblePage(in: app) == "Comic page 2" })
        XCTAssertEqual(counter.label, advanced)
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
        center.tap()
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        XCTAssertTrue(wait { counter.label == advanced })
        XCTAssertTrue(app.buttons["Reader options"].isHittable)

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
            .first { $0.isHittable && $0.frame.contains(point) }?.label
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
