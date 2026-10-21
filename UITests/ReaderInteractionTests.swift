import XCTest

@MainActor final class ReaderInteractionTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    // Shell ownership, library action wiring, and replacing the one global reader.
    func testLibraryNavigationAndActions() {
        let app = launch()
        let libraryTab = app.buttons.matching(identifier: "My Library").firstMatch
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 20))
        XCTAssertTrue(libraryTab.isSelected)

        selectSection("Browse", in: app)
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
        goBack(in: app)
        app.buttons["Search site"].tap()
        let query = app.searchFields["Search titles"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        query.tap(); query.typeText("story\n")
        XCTAssertTrue(app.navigationBars["Search results"].waitForExistence(timeout: 8))
        XCTAssertTrue(listedManga.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["directory.sort"].exists)
        // Native row appearance loads the next range without a footer tap.
        let footer = app.staticTexts["directory.footer"]
        XCTAssertTrue(aster.waitForExistence(timeout: 8))
        XCTAssertTrue(wait { footer.label == "No more titles" })
        listedManga.tap()
        XCTAssertTrue(app.navigationBars["The Observatory"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Rating: 9.2 / 10"].exists)
        XCTAssertGreaterThan(app.staticTexts["Rating: 9.2 / 10"].frame.width, 50, "Rating text must remain visible beside its icon")
        XCTAssertTrue(app.staticTexts["Status: Finished"].exists)
        XCTAssertTrue(app.staticTexts["Tags: Science fiction, Adventure"].exists)
        goBack(in: app)
        XCTAssertTrue(listedManga.waitForExistence(timeout: 8), "Returning from a result retains the submitted search")
        XCTAssertTrue(aster.exists && footer.label == "No more titles", "Returning retains the loaded directory range")
        XCTAssertFalse(app.staticTexts["Search this site"].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        listedManga.tap()
        // The reading action must work with the first tap in a newly hosted list.
        let read = app.buttons["manga.read"]
        for _ in 0..<3 where !read.isHittable { app.windows.firstMatch.swipeUp() }
        XCTAssertTrue(read.isHittable)
        read.tap()
        XCTAssertTrue(app.staticTexts["reader.pageCounter"].waitForExistence(timeout: 20))
        app.buttons["reader.collapse"].tap()
        // Each chapter group has its own presentation sort, without changing core adjacency.
        let arrival = app.buttons["1 · Arrival"], starlight = app.buttons["2 · Starlight"]
        for _ in 0..<3 where !app.buttons["manga.sort.chapters"].isHittable { app.windows.firstMatch.swipeUp() }
        app.buttons["manga.sort.chapters"].tap()
        app.buttons["Reverse order"].tap()
        XCTAssertTrue(wait { starlight.frame.minY < arrival.frame.minY })
        app.buttons["manga.sort.chapters"].tap()
        app.buttons["Source order"].tap()
        for _ in 0..<3 where !app.buttons["Extra · Sketches"].isHittable { app.windows.firstMatch.swipeUp() }
        XCTAssertTrue(app.buttons["manga.sort.books"].exists && app.buttons["manga.sort.extras"].exists)
        XCTAssertTrue(app.buttons["Book one"].exists && app.buttons["Extra · Sketches"].exists)
        // SwiftUI swipe actions bridge into native hosted cells; group actions share the same core API.
        let book = app.buttons["Book one"]
        book.swipeLeft(); app.buttons["Mark as read"].tap()
        XCTAssertTrue((book.value as? String)?.hasSuffix("Read") == true)
        book.swipeLeft(); app.buttons["Ignore"].tap()
        XCTAssertTrue((book.value as? String)?.hasSuffix("Ignored") == true)
        setChapterGroup("chapters", action: "Mark all as read", opposite: "Mark all as unread", in: app)
        XCTAssertTrue((starlight.value as? String)?.hasSuffix("Read") == true)
        setChapterGroup("chapters", action: "Mark all as unread", opposite: "Mark all as read", in: app)
        XCTAssertTrue((starlight.value as? String)?.hasSuffix("Unread") == true)
        setChapterGroup("extras", action: "Ignore all", opposite: "Unignore all", in: app)
        XCTAssertTrue((app.buttons["Extra · Sketches"].value as? String)?.hasSuffix("Ignored") == true)
        setChapterGroup("extras", action: "Unignore all", opposite: "Ignore all", in: app)
        XCTAssertTrue((app.buttons["Extra · Sketches"].value as? String)?.hasSuffix("Unread") == true)
        for _ in 0..<3 where !arrival.isHittable { app.windows.firstMatch.swipeDown() }
        arrival.tap()
        let counter = app.staticTexts["reader.pageCounter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 20))
        let position = counter.label
        app.buttons["reader.collapse"].tap()
        let resume = app.buttons["reader.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 8))
        XCTAssertEqual(resume.value as? String, position)

        selectSection("Recent", in: app)
        let row = app.buttons["library.item.demo|https://demo.mangaviewer.local/series/observatory"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertTrue(wait { row.label.contains("The Observatory") })
        XCTAssertTrue(row.label.contains("1 · Arrival"))
        XCTAssertTrue(row.label.contains("Reading ("))
        XCTAssertFalse(row.label.contains("/ 4"), "Library progress summarizes the manga, not source page counts")
        XCTAssertTrue(row.label.contains("<1 hr ago"))
        row.swipeLeft()
        if app.buttons["Unstar"].exists { app.buttons["Unstar"].tap(); row.swipeLeft() }
        app.buttons["Star"].tap()
        selectSection("My Library", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertTrue(row.label.contains("Starred"))
        row.swipeLeft()
        XCTAssertTrue(app.buttons["Remove"].exists)
        XCTAssertFalse(app.buttons["Unstar"].exists || app.buttons["Star"].exists, "Library swipe only removes")
        row.swipeRight()
        row.tap()
        XCTAssertTrue(app.navigationBars["The Observatory"].waitForExistence(timeout: 8))
        XCTAssertFalse(counter.exists, "The main row opens details")
        app.buttons["manga.star"].tap()
        XCTAssertEqual(app.buttons["manga.star"].label, "Star")
        app.buttons["manga.star"].tap()
        XCTAssertEqual(app.buttons["manga.star"].label, "Unstar")
        app.buttons["2 · Starlight"].tap()
        XCTAssertTrue(wait { app.descendants(matching: .any)["reader.chapterTitle"].firstMatch.label == "2 · Starlight" })
        app.buttons["Back to manga"].tap()
        XCTAssertTrue(app.navigationBars["The Observatory"].waitForExistence(timeout: 8))
        XCTAssertTrue((app.buttons["2 · Starlight"].value as? String)?.hasPrefix("Current chapter,") == true)
        XCTAssertTrue(wait { !counter.exists })
        let currentRow = app.buttons["2 · Starlight"]
        XCTAssertTrue(app.windows.firstMatch.frame.contains(currentRow.frame), "Back to manga reveals the current chapter")
        currentRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(counter.waitForExistence(timeout: 8), "The revealed chapter remains interactive")
        app.buttons["reader.collapse"].tap()
        selectSection("Settings", in: app)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertTrue(resume.isHittable)
        XCTAssertEqual(app.buttons.matching(identifier: "reader.resume").count, 1)
        XCTAssertEqual(resume.label, "Resume The Observatory, 2 · Starlight")

        // Each removal affects its own list; the separate Resume button opens the latest chapter.
        selectSection("Recent", in: app)
        XCTAssertTrue(wait { row.label.contains("2 · Starlight") })
        row.swipeLeft()
        app.buttons["Remove"].tap()
        XCTAssertTrue(wait { !row.exists })
        XCTAssertTrue(resume.exists)
        selectSection("My Library", in: app)
        goBack(in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        app.buttons["library.resume.demo|https://demo.mangaviewer.local/series/observatory"].tap()
        XCTAssertTrue(wait { app.descendants(matching: .any)["reader.chapterTitle"].firstMatch.label == "2 · Starlight" })
        app.buttons["reader.collapse"].tap()
        XCTAssertTrue(libraryTab.isSelected)
        row.swipeLeft()
        app.buttons["Remove"].tap()
        XCTAssertTrue(wait { !row.exists })
        selectSection("Recent", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Reading makes the hidden history entry recent again")

        // Reordering site rules belongs to shell coverage; persistence is checked in core tests.
        selectSection("Settings", in: app)
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 8))
        let demo = app.staticTexts["Bundled reading room"]
        let other = app.staticTexts["拷貝漫畫 · MangaCopy"]
        for _ in 0..<6 where !demo.isHittable || !other.isHittable {
            let downward = demo.exists && demo.frame.minY < app.navigationBars.firstMatch.frame.maxY
            app.collectionViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
                .press(forDuration: 0.05, thenDragTo: app.collectionViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: downward ? 0.8 : 0.5)), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(demo.isHittable && other.isHittable)
        let lower = demo.frame.minY > other.frame.minY ? demo : other
        let upper = demo.frame.minY > other.frame.minY ? other : demo
        lower.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.8, thenDragTo: upper.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: -20)))
        XCTAssertTrue(wait { lower.frame.minY < upper.frame.minY })
        XCTAssertEqual(resume.label, "Resume The Observatory, 2 · Starlight")
        selectSection("Browse", in: app)
        XCTAssertEqual(app.staticTexts["browse.siteTitle"].label, lower.label)

        // Diagnostics owns error reporting; opening a failing bundled URL requires no live site.
        app.buttons["Open URL"].tap()
        let url = app.textFields["Website URL"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap(); url.typeText("https://demo.mangaviewer.local/chapter/missing?token=private-value\n")
        XCTAssertTrue(app.alerts.buttons["OK"].waitForExistence(timeout: 8))
        app.alerts.buttons["OK"].tap()
        selectSection("Settings", in: app)
        let background = app.switches["Background resource loading"]
        for _ in 0..<5 where !background.isHittable { app.windows.firstMatch.swipeUp() }
        XCTAssertTrue(background.isHittable)
        let original = background.value as? String
        background.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(wait { background.value as? String != original })
        background.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(wait { background.value as? String == original })
        XCTAssertTrue(resume.exists)
        let reportButton = app.buttons["Error report"]
        for _ in 0..<5 where !reportButton.isHittable { app.windows.firstMatch.swipeUp() }
        XCTAssertTrue(reportButton.isHittable)
        reportButton.tap()
        let report = app.staticTexts["diagnostics.report"]
        XCTAssertTrue(report.waitForExistence(timeout: 15))
        XCTAssertTrue(report.label.contains("loadContent: unsupported_url")) // Redaction/format details belong to core.
        XCTAssertTrue(app.buttons["Share report"].isHittable)
        app.buttons["Export report"].tap()
        XCTAssertTrue(app.buttons["DOCPicker.actionButton"].waitForExistence(timeout: 8))
    }

    // Reader-only gestures, chrome, and original-page/fraction restoration (including one relaunch).
    func testReaderGesturesAndPosition() {
        let app = launch(chapter: "arrival")
        let counter = app.staticTexts["reader.pageCounter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 20))
        app.buttons["Reader options"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.buttons["Paged"].tap()
        dismissOptions(in: app)
        select("Right to left", in: "Direction", app: app)
        setAdjustment("Detect spreads", enabled: false, app: app)
        setAdjustment("Facing pages in wide windows", enabled: false, app: app)
        let title = app.descendants(matching: .any)["reader.chapterTitle"].firstMatch
        XCTAssertEqual(title.label, "1 · Arrival")

        // RTL: drag right to reveal the next source page.
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        let end = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
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
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.13))
            .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        let resume = app.buttons["reader.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 8))
        resume.tap()
        XCTAssertTrue(counter.waitForExistence(timeout: 8))
        let resumedPage = wait { self.visiblePage(in: app) == "Comic page 2" }
        if !resumedPage {
            let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            capture.name = "Resume restoration failure"; add(capture)
        }
        XCTAssertTrue(resumedPage, "Resume: \(counter.label); images: \(app.images.matching(identifier: "reader.pageImage").allElementsBoundByIndex.map { "\($0.label): \($0.frame)" })")

        // Check actual content, since a stale counter alone would hide lost restoration.
        select("Scroll", in: "Mode", app: app)
        XCTAssertTrue(wait { self.visiblePage(in: app) == "Comic page 2" })
        checkCenteredPages(in: app)
        checkImmersion(in: app)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.3)
        let scrolledPage = pageImage(2, in: app)
        let verticalPosition = scrolledPage.frame.minY
        // Vertical reading uses a physical left-edge back swipe, never a vertical page drag.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)))
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

        // One boundary contract covers both horizontal directions and vertical scrolling.
        for (mode, direction, axis) in [("Paged", "Right to left", CGVector(dx: 1, dy: 0)),
                                        ("Paged", "Left to right", CGVector(dx: -1, dy: 0)),
                                        ("Scroll", "Left to right", CGVector(dx: 0, dy: -1))] {
            XCTContext.runActivity(named: "Chapter overpull: \(mode), \(direction)") { _ in
                select(mode, in: "Mode", app: app)
                select(direction, in: "Direction", app: app)
                let last = pageImage(4, in: app)
                for _ in 0..<8 {
                    if mode == "Paged" ? counter.label.hasPrefix("Page 4 ") : last.exists && last.frame.maxY <= app.windows.firstMatch.frame.maxY + 2 { break }
                    pull(in: app, axis: axis, from: -0.3, to: 0.3)
                    XCTAssertEqual(title.label, "1 · Arrival", "Reaching the end must not open the next chapter")
                }
                XCTAssertTrue(wait { counter.label.hasPrefix("Page 4 ") })
                if mode == "Scroll" { XCTAssertTrue(last.exists && last.frame.maxY <= app.windows.firstMatch.frame.maxY + 2) }
                checkChapterBoundary(in: app, axis: axis)
            }
        }
        // Missing adjacent chapters stay on the boundary even after a long pull.
        app.buttons["Next chapter"].tap()
        XCTAssertTrue(wait { title.label == "2 · Starlight" })
        XCTAssertTrue(wait { self.visiblePage(in: app) == "Comic page 1" })
        checkCenteredPages(in: app)
        select("Paged", in: "Mode", app: app)
        for _ in 0..<3 where !counter.label.hasPrefix("Page 4 ") { end.press(forDuration: 0.05, thenDragTo: start) }
        XCTAssertTrue(wait { counter.label.hasPrefix("Page 4 ") })
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 1)
        XCTAssertEqual(counter.value as? String, "2 · Starlight")
        XCTAssertTrue(counter.label.hasPrefix("Page 4 "))
        XCTAssertFalse(title.exists)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        app.buttons["Back to manga"].tap()
        XCTAssertTrue(app.buttons["2 · Starlight"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons["2 · Starlight"].value as? String, "Current chapter, Read")
        XCTAssertEqual(app.buttons["1 · Arrival"].value as? String, "Read")
        app.buttons["reader.resume"].tap()
        XCTAssertTrue(counter.waitForExistence(timeout: 8))

        // The core's joined plan must reach the actual renderer in both modes, with an off switch.
        select("Right to left", in: "Direction", app: app)
        setAdjustment("Detect spreads", enabled: true, app: app)
        app.buttons["reader.collapse"].tap()
        selectSection("Browse", in: app)
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
    private func setChapterGroup(_ id: String, action: String, opposite: String, in app: XCUIApplication) {
        let menu = app.buttons["manga.actions." + id]
        menu.tap()
        // Exercise the requested action even when a previous test left its state set.
        if !app.buttons[action].exists { app.buttons[opposite].tap(); menu.tap() }
        app.buttons[action].tap()
    }
    private func selectSection(_ title: String, in app: XCUIApplication) {
        // Native iPad tabs do not expose a TabBar container. Match their public
        // labels, excluding navigation back buttons with the same title.
        let tabs = app.buttons.matching(NSPredicate(format: "label IN %@ AND identifier != 'BackButton'", ["My Library", "Browse", "Recent", "Settings"]))
        let target = tabs.matching(identifier: title).firstMatch
        if !target.isHittable {
            // A native minimized tab bar exposes only its selected tab; tap to expand.
            tabs.matching(NSPredicate(format: "isSelected == true")).firstMatch.tap()
        }
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()
        XCTAssertTrue(wait { target.isSelected })
    }
    private func goBack(in app: XCUIApplication) {
        app.descendants(matching: .any).matching(identifier: "BackButton").firstMatch.tap()
    }
    // Coordinate gestures use a native window, including its display identity on Duo.
    private func launch(chapter: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if let chapter { app.launchArguments += ["--open-url", "https://demo.mangaviewer.local/chapter/" + chapter] }
        app.launch()
        return app
    }
    private func pageImage(_ number: Int, in app: XCUIApplication) -> XCUIElement {
        app.images.matching(identifier: "reader.pageImage")
            .matching(NSPredicate(format: "label == %@", "Comic page \(number)")).firstMatch
    }
    /// Scalar positions along the chosen reading axis, centered in the viewport.
    private func pull(in app: XCUIApplication, axis: CGVector, from: Double, to: Double, fast: Bool = false) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5 + axis.dx * from, dy: 0.5 + axis.dy * from))
            .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5 + axis.dx * to, dy: 0.5 + axis.dy * to)),
                   withVelocity: fast ? .fast : .slow, thenHoldForDuration: fast ? 0 : 0.3)
    }
    private func checkChapterBoundary(in app: XCUIApplication, axis: CGVector) {
        let title = app.descendants(matching: .any)["reader.chapterTitle"].firstMatch, counter = app.staticTexts["reader.pageCounter"]
        pull(in: app, axis: axis, from: -0.25, to: -0.15, fast: true)
        XCTAssertEqual(title.label, "1 · Arrival", "Short pulls and momentum cannot switch chapters")
        let center = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.tap()
        XCTAssertTrue(wait { !app.buttons["Reader options"].isHittable })
        pull(in: app, axis: axis, from: -0.25, to: 0.45)
        let switched = wait { counter.value as? String == "2 · Starlight" && self.visiblePage(in: app) == "Comic page 1" }
        if !switched {
            let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            capture.name = "Chapter replacement failure"; add(capture)
        }
        XCTAssertTrue(switched, "Forward landing: \(counter.value ?? "unknown"), \(counter.label); images: \(app.images.matching(identifier: "reader.pageImage").allElementsBoundByIndex.map { "\($0.label): \($0.frame)" })")
        XCTAssertFalse(title.exists, "Chapter switching retains immersion")
        center.tap()
        XCTAssertTrue(wait { app.buttons["Previous chapter"].isEnabled })
        XCTAssertFalse(app.buttons["Next chapter"].isEnabled)
        pull(in: app, axis: axis, from: 0.15, to: 0.05, fast: true)
        XCTAssertEqual(title.label, "2 · Starlight", "A short backward pull cannot switch chapters")
        if axis.dy != 0 {
            // Cross the top boundary during one drag, without a separate arming swipe.
            pull(in: app, axis: axis, from: -0.1, to: 0)
            XCTAssertTrue(wait { self.pageImage(1, in: app).frame.minY < -5 })
        }
        // Boundary pulls target unobstructed artwork, including native vertical toolbars.
        // Verify backward chapter changes retain immersion just like forward changes.
        center.tap()
        XCTAssertTrue(wait { !app.buttons["Reader options"].isHittable })
        pull(in: app, axis: axis, from: 0.25, to: -0.45)
        XCTAssertTrue(wait { counter.value as? String == "1 · Arrival" && counter.label.hasPrefix("Page 4 ") }, "Backward landing: \(counter.value ?? "unknown"), \(counter.label)")
        XCTAssertFalse(title.exists)
        center.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        if axis.dy == 0 { XCTAssertTrue(wait { self.visiblePage(in: app) == "Comic page 4" }) }
        else { XCTAssertTrue(wait { abs(self.pageImage(4, in: app).frame.maxY - app.windows.firstMatch.frame.maxY) < 3 }) }
    }
    private func checkCenteredPages(in app: XCUIApplication) {
        let visible = app.images.matching(identifier: "reader.pageImage").allElementsBoundByIndex.filter { $0.frame.intersects(app.windows.firstMatch.frame) }
        XCTAssertFalse(visible.isEmpty)
        for image in visible {
            XCTAssertEqual(image.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 1, "Loading pages must not change the reader's horizontal layout")
            XCTAssertLessThanOrEqual(image.frame.width, app.windows.firstMatch.frame.width)
        }
    }
    private func checkImmersion(in app: XCUIApplication) {
        let image = pageImage(2, in: app)
        let frame = image.frame
        let center = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.tap()
        XCTAssertTrue(wait { !app.descendants(matching: .any)["reader.chapterTitle"].firstMatch.exists && !app.buttons["Reader options"].isHittable })
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
        if app.buttons["Image adjustments"].exists { app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap() }
    }
    private func visiblePage(in app: XCUIApplication) -> String? {
        let point = CGPoint(x: app.windows.firstMatch.frame.midX, y: app.windows.firstMatch.frame.minY + app.windows.firstMatch.frame.height * 0.35)
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
        else { app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap() }
    }
    private func wait(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 8) == .completed
    }
}
