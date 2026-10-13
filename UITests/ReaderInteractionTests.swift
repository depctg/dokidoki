import XCTest

@MainActor final class ReaderInteractionTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    // Shell ownership, library action wiring, and replacing the one global reader.
    func testLibraryNavigationAndActions() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let libraryTab = app.buttons.matching(identifier: "My Library").firstMatch
        let recentTab = app.buttons.matching(identifier: "Recent").firstMatch
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 20))
        XCTAssertTrue(libraryTab.isSelected)

        app.buttons.matching(identifier: "Browse").firstMatch.tap()
        app.buttons["Switch site"].tap()
        app.buttons["Bundled reading room"].tap()
        let shelf = app.buttons["browse.list.https://demo.mangaviewer.local/catalog"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 8))
        shelf.tap()
        XCTAssertTrue(app.navigationBars["Reading room"].waitForExistence(timeout: 8))
        let listedManga = app.buttons["manga.item.demo|https://demo.mangaviewer.local/series/observatory"]
        XCTAssertTrue(listedManga.waitForExistence(timeout: 8))
        XCTAssertTrue(wait { listedManga.label.contains("9.2 / 10") && listedManga.label.contains("Finished") && listedManga.label.contains("Science fiction") })
        app.buttons["directory.sort"].tap()
        XCTAssertFalse(app.buttons["Descending"].exists, "Source order does not offer a direction")
        app.buttons["Title"].tap()
        XCTAssertTrue(app.navigationBars["Reading room · A–Z"].waitForExistence(timeout: 8))
        let aster = app.buttons["manga.item.demo|https://demo.mangaviewer.local/series/aster"]
        XCTAssertTrue(wait { aster.frame.minY < listedManga.frame.minY })
        app.buttons["directory.sort"].tap()
        app.buttons["Descending"].tap()
        XCTAssertTrue(app.navigationBars["Reading room · Z–A"].waitForExistence(timeout: 8))
        XCTAssertTrue(wait { listedManga.frame.minY < aster.frame.minY })
        app.navigationBars.buttons["Browse"].tap()
        app.buttons["Search site"].tap()
        let query = app.searchFields["Search titles"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        query.tap(); query.typeText("Observatory\n")
        XCTAssertTrue(app.navigationBars["Search results"].waitForExistence(timeout: 8))
        XCTAssertTrue(listedManga.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["directory.sort"].exists)
        listedManga.tap()
        XCTAssertTrue(app.navigationBars["The Observatory"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Rating: 9.2 / 10"].exists)
        XCTAssertTrue(app.staticTexts["Status: Finished"].exists)
        XCTAssertTrue(app.staticTexts["Tags: Science fiction, Adventure"].exists)
        app.navigationBars.buttons["Search results"].tap()
        XCTAssertTrue(listedManga.waitForExistence(timeout: 8), "Returning from a result retains the submitted search")
        XCTAssertFalse(app.staticTexts["Search this site"].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        listedManga.tap()
        app.buttons["1 · Arrival"].tap()
        let counter = app.staticTexts["reader.pageCounter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 20))
        let position = counter.label
        app.buttons["reader.collapse"].tap()
        let resume = app.buttons["reader.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 8))
        XCTAssertEqual(resume.value as? String, position)

        recentTab.tap()
        let row = app.buttons["library.item.demo|https://demo.mangaviewer.local/series/observatory"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertTrue(wait { row.label.contains("The Observatory") })
        XCTAssertTrue(row.label.contains("1 · Arrival"))
        XCTAssertTrue(row.label.contains("/ 4"))
        XCTAssertTrue(row.label.contains("Last read <1 hr ago"))
        row.swipeLeft()
        if app.buttons["Unstar"].exists { app.buttons["Unstar"].tap(); row.swipeLeft() }
        app.buttons["Star"].tap()
        libraryTab.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertTrue(row.label.contains("Starred"))
        row.swipeLeft()
        app.buttons["Unstar"].tap()
        XCTAssertTrue(wait { row.exists && !row.label.contains("Starred") }, "Unstarring keeps the saved manga")
        row.swipeLeft()
        app.buttons["Manga details"].tap()
        XCTAssertTrue(app.navigationBars["The Observatory"].waitForExistence(timeout: 8))

        app.buttons["2 · Starlight"].tap()
        XCTAssertTrue(wait { app.staticTexts["reader.chapterTitle"].label == "2 · Starlight" })
        app.buttons["Back to manga"].tap()
        XCTAssertTrue(app.navigationBars["The Observatory"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons["2 · Starlight"].value as? String, "Current chapter")
        XCTAssertTrue(app.buttons["2 · Starlight"].isHittable)
        app.buttons.matching(identifier: "Settings").firstMatch.tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertTrue(resume.isHittable)
        XCTAssertEqual(app.buttons.matching(identifier: "reader.resume").count, 1)
        XCTAssertEqual(resume.label, "Resume The Observatory, 2 · Starlight")

        // Each removal action affects its own list; the saved row still opens the latest chapter.
        recentTab.tap()
        XCTAssertTrue(wait { row.label.contains("2 · Starlight") })
        row.swipeLeft()
        app.buttons["Remove"].tap()
        XCTAssertTrue(wait { !row.exists })
        XCTAssertTrue(resume.exists)
        libraryTab.tap()
        app.navigationBars.buttons.matching(identifier: "My Library").firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(wait { app.staticTexts["reader.chapterTitle"].label == "2 · Starlight" })
        app.buttons["reader.collapse"].tap()
        XCTAssertTrue(libraryTab.isSelected)
        row.swipeLeft()
        app.buttons["Remove"].tap()
        XCTAssertTrue(wait { !row.exists })
        recentTab.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Reading makes the hidden history entry recent again")

        // Reordering site rules belongs to shell coverage; persistence is checked in core tests.
        app.buttons.matching(identifier: "Settings").firstMatch.tap()
        let demo = app.staticTexts["Bundled reading room"]
        let other = app.staticTexts["漫画柜 · Manhuagui"]
        for _ in 0..<4 where !other.isHittable { app.swipeUp() }
        XCTAssertTrue(demo.isHittable && other.isHittable)
        let lower = demo.frame.minY > other.frame.minY ? demo : other
        let upper = demo.frame.minY > other.frame.minY ? other : demo
        lower.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.8, thenDragTo: upper.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: -20)))
        XCTAssertTrue(wait { lower.frame.minY < upper.frame.minY })
        XCTAssertEqual(resume.label, "Resume The Observatory, 2 · Starlight")
        app.buttons.matching(identifier: "Browse").firstMatch.tap()
        XCTAssertEqual(app.staticTexts["browse.siteTitle"].label, lower.label)

        // Diagnostics owns error reporting; opening a failing bundled URL requires no live site.
        app.buttons["Open URL"].tap()
        let url = app.textFields["Website URL"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap(); url.typeText("https://demo.mangaviewer.local/chapter/missing?token=private-value\n")
        XCTAssertTrue(app.alerts["MangaViewer"].waitForExistence(timeout: 8))
        app.alerts.buttons["OK"].tap()
        app.buttons.matching(identifier: "Settings").firstMatch.tap()
        let reportButton = app.buttons["Error report"]
        for _ in 0..<5 where !reportButton.isHittable { app.swipeUp() }
        XCTAssertTrue(reportButton.isHittable)
        reportButton.tap()
        let report = app.staticTexts["diagnostics.report"]
        XCTAssertTrue(report.waitForExistence(timeout: 15))
        XCTAssertTrue(report.label.contains("loadContent: unsupported_url [demo.mangaviewer.local]"))
        XCTAssertFalse(report.label.contains("private-value"))
        XCTAssertFalse(report.label.contains("/chapter/missing"))
        XCTAssertTrue(app.buttons["Share report"].isHittable)
        app.buttons["Export report"].tap()
        XCTAssertTrue(app.buttons["DOCPicker.actionButton"].waitForExistence(timeout: 8))
    }

    // Reader-only gestures, chrome, and original-page/fraction restoration (including one relaunch).
    func testReaderGesturesAndPosition() {
        let app = XCUIApplication()
        app.launchArguments = ["--open-url", "https://demo.mangaviewer.local/chapter/arrival", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let counter = app.staticTexts["reader.pageCounter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 20))
        app.buttons["Reader options"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.buttons["Paged"].tap()
        dismissOptions(in: app)
        select("Right to left", in: "Direction", app: app)
        setAdjustment("Detect spreads", enabled: false, app: app)
        setAdjustment("Facing pages in wide windows", enabled: false, app: app)
        let title = app.staticTexts["reader.chapterTitle"]
        XCTAssertEqual(title.label, "1 · Arrival")

        // RTL: drag right to reveal the next source page.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        // The test is repeatable without deleting the app's reading history.
        for _ in 0..<3 where !counter.label.hasPrefix("Page 1 ") {
            end.press(forDuration: 0.05, thenDragTo: start)
        }
        XCTAssertTrue(counter.label.hasPrefix("Page 1 "))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(wait { counter.label.hasPrefix("Page 2 ") && self.visiblePage(in: app) == "Comic page 2" })
        let advanced = counter.label
        // Native one-view targeting must also bound fast flicks in either direction.
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(wait { counter.label.hasPrefix("Page 3 ") && self.visiblePage(in: app) == "Comic page 3" })
        end.press(forDuration: 0.05, thenDragTo: start, withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(wait { counter.label == advanced && self.visiblePage(in: app) == "Comic page 2" })

        // Paged mode collapses from a top pull, then resumes the actual same source image.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.13))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        let resume = app.buttons["reader.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 8))
        resume.tap()
        XCTAssertTrue(counter.waitForExistence(timeout: 8))
        XCTAssertTrue(wait { self.visiblePage(in: app) == "Comic page 2" })

        // Check actual content, since a stale counter alone would hide lost restoration.
        select("Scroll", in: "Mode", app: app)
        XCTAssertTrue(wait { self.visiblePage(in: app) == "Comic page 2" })
        checkImmersion(in: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.3)
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
        XCTAssertTrue(wait { self.visiblePage(in: app) == "Comic page 2" })

        checkImmersion(in: app)

        // The compact title does not expand when touched.
        let height = title.frame.height
        title.tap()
        XCTAssertEqual(title.frame.height, height, accuracy: 1)

        app.terminate()
        app.launch()
        XCTAssertTrue(counter.waitForExistence(timeout: 20))
        XCTAssertEqual(counter.label, advanced)
        XCTAssertTrue(wait { self.visiblePage(in: app) == "Comic page 2" })

        // Exercise the release threshold in both directions, including an immersive transition.
        for direction in ["Right to left", "Left to right"] {
            let leftward = direction == "Left to right"
            if leftward { select(direction, in: "Direction", app: app) }
            let from = leftward ? end : start, to = leftward ? start : end
            for _ in 0..<3 where !counter.label.hasPrefix("Page 4 ") { from.press(forDuration: 0.05, thenDragTo: to) }
            XCTAssertTrue(wait { counter.label.hasPrefix("Page 4 ") })
            XCTAssertEqual(title.label, "1 · Arrival", "Reaching the last page must not open the next chapter")
            from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: leftward ? 0.7 : 0.35, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.3)
            XCTAssertEqual(title.label, "1 · Arrival")
            XCTAssertTrue(wait { self.visiblePage(in: app) == "Comic page 4" })
            let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            if leftward { center.tap() }
            app.coordinate(withNormalizedOffset: CGVector(dx: leftward ? 0.9 : 0.1, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: leftward ? 0.1 : 0.9, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.3)
            XCTAssertTrue(wait { counter.value as? String == "2 · Starlight" })
            XCTAssertTrue(wait { self.visiblePage(in: app) == "Comic page 1" })
            if leftward {
                XCTAssertFalse(title.exists, "Continuing a chapter keeps immersive mode")
                center.tap()
            }
            XCTAssertTrue(wait { app.buttons["Previous chapter"].isEnabled })
            XCTAssertFalse(app.buttons["Next chapter"].isEnabled)
            to.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: leftward ? 0.35 : 0.7, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.3)
            XCTAssertEqual(title.label, "2 · Starlight", "A short backward pull must not switch chapters")
            app.coordinate(withNormalizedOffset: CGVector(dx: leftward ? 0.1 : 0.9, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: leftward ? 0.9 : 0.1, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.3)
            XCTAssertTrue(wait { title.label == "1 · Arrival" && counter.label.hasPrefix("Page 4 ") })
            XCTAssertTrue(wait { self.visiblePage(in: app) == "Comic page 4" })
        }
        select("Scroll", in: "Mode", app: app)
        let lastPage = app.images.matching(identifier: "reader.pageImage").matching(NSPredicate(format: "label == %@", "Comic page 4")).firstMatch
        for _ in 0..<8 where !lastPage.exists || lastPage.frame.maxY > app.frame.maxY + 2 {
            app.swipeUp()
            XCTAssertEqual(title.label, "1 · Arrival", "Scrolling to the bottom must not switch chapters")
        }
        XCTAssertTrue(lastPage.exists && lastPage.frame.maxY <= app.frame.maxY + 2)
        // A short flick may bounce farther after release; momentum must never arm continuation.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertEqual(title.label, "1 · Arrival")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)), withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(wait { title.label == "2 · Starlight" })
        // The matching top-edge pull returns to the previous chapter's last page/bottom.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertEqual(title.label, "2 · Starlight")
        // Start inside the first page: crossing the boundary while still dragging must
        // reveal/commit the same previous-chapter pull, without a separate arming swipe.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.3)
        let firstPage = app.images.matching(identifier: "reader.pageImage").matching(NSPredicate(format: "label == %@", "Comic page 1")).firstMatch
        XCTAssertTrue(wait { firstPage.frame.minY < -5 })
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)), withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(wait { title.label == "1 · Arrival" && counter.label.hasPrefix("Page 4 ") })
        XCTAssertTrue(wait { lastPage.exists && abs(lastPage.frame.maxY - app.frame.maxY) < 3 })
        // Missing adjacent chapters stay on the boundary even after a long pull.
        app.buttons["Next chapter"].tap()
        XCTAssertTrue(wait { title.label == "2 · Starlight" })
        select("Paged", in: "Mode", app: app)
        for _ in 0..<3 where !counter.label.hasPrefix("Page 4 ") { end.press(forDuration: 0.05, thenDragTo: start) }
        XCTAssertTrue(wait { counter.label.hasPrefix("Page 4 ") })
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 1)
        XCTAssertEqual(title.label, "2 · Starlight")
        XCTAssertTrue(counter.label.hasPrefix("Page 4 "))

        // The core's joined plan must reach the actual renderer in both modes, with an off switch.
        select("Right to left", in: "Direction", app: app)
        setAdjustment("Detect spreads", enabled: true, app: app)
        app.buttons["reader.collapse"].tap()
        app.buttons.matching(identifier: "Browse").firstMatch.tap()
        app.buttons["Open URL"].tap()
        let url = app.textFields["Website URL"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap(); url.typeText("https://demo.mangaviewer.local/chapter/rejoined\n")
        XCTAssertTrue(wait { title.label == "1 · Across the valley" })
        let joined = app.images.matching(identifier: "reader.pageImage").matching(NSPredicate(format: "label == %@", "Comic page 1, 2")).firstMatch
        XCTAssertTrue(wait { counter.label == "Page 1 of 1" && joined.exists })
        select("Scroll", in: "Mode", app: app)
        XCTAssertTrue(wait { counter.label == "Page 1 of 1" && joined.exists })
        setAdjustment("Detect spreads", enabled: false, app: app)
        XCTAssertTrue(wait { counter.label == "Page 1 of 2" && !joined.exists })
    }
    private func checkImmersion(in app: XCUIApplication) {
        let image = app.images.matching(identifier: "reader.pageImage").matching(NSPredicate(format: "label == %@", "Comic page 2")).firstMatch
        let frame = image.frame
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.tap()
        XCTAssertTrue(wait { !app.staticTexts["reader.chapterTitle"].exists && !app.buttons["Reader options"].isHittable })
        let counter = app.staticTexts["reader.pageCounter"]
        XCTAssertTrue(counter.exists)
        XCTAssertEqual(counter.value as? String, "1 · Arrival")
        XCTAssertEqual(image.frame, frame, "Hiding chrome must not move or resize the manga")
        center.tap()
        XCTAssertTrue(app.buttons["Reader options"].waitForExistence(timeout: 5))
        XCTAssertEqual(image.frame, frame, "Restoring chrome must not move or resize the manga")
    }
    private func select(_ value: String, in picker: String, app: XCUIApplication) {
        app.buttons["Reader options"].tap()
        if app.buttons[picker].exists { app.buttons[picker].tap() }
        let option = app.buttons[value]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        dismissOptions(in: app)
    }
    private func dismissOptions(in app: XCUIApplication) {
        if app.buttons["Image adjustments"].exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap() }
    }
    private func visiblePage(in app: XCUIApplication) -> String? {
        let point = CGPoint(x: app.frame.midX, y: app.frame.minY + app.frame.height * 0.35)
        return app.images.matching(identifier: "reader.pageImage").allElementsBoundByIndex
            .first { $0.frame.contains(point) }?.label
    }
    private func setAdjustment(_ label: String, enabled: Bool, app: XCUIApplication) {
        app.buttons["Reader options"].tap()
        app.buttons["Image adjustments"].tap()
        let toggle = app.buttons[label]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let selected = toggle.isSelected || ["1", "on"].contains(toggle.value as? String ?? "")
        if selected != enabled { toggle.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap() }
    }
    private func wait(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 8) == .completed
    }
}
