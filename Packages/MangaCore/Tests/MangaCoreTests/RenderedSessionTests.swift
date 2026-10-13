import Foundation
import Testing
@testable import MangaCore
#if os(macOS)
import AppKit
#endif

@Suite(.serialized) @MainActor struct RenderedSessionTests {
    private func rule(mode: String = "scroll", target: String = "//*[@id='end']") throws -> SiteRule {
        #if os(macOS)
        NSApplication.shared.setActivationPolicy(.prohibited)
        #endif
        var json = try JSONSerialization.jsonObject(with: DemoContent.bundledRules().first { $0.id == "demo" }!.exported()) as! [String: Any]
        var extractors = json["extractors"] as! [String: [String: Any]]
        var fields: [String: Any] = ["title": ["path": "//h1"], "totalCount": ["path": "//*[@id='total']"],
                                   "pageImages": ["path": "//*[@id='pages']/img", "read": "attr:data-src"]]
        if mode == "page" { fields["pageNumber"] = ["path": "//*[@id='current']"] }
        extractors["chapter"] = ["fields": fields, "session": ["mode": mode, "actionXPath": target],
                                 "rendering": ["readyXPath": "//*[@id='pages']/img"]]
        json["extractors"] = extractors
        return try SiteRule.decode(JSONSerialization.data(withJSONObject: json))
    }
    private func key(_ name: String) -> ObjectKey {
        ObjectKey(ruleID: "demo", identityURL: DemoContent.directoryURL.deletingLastPathComponent().appendingPathComponent("chapter/" + name))
    }
    private func pages(_ response: SourceResponse, key: ObjectKey, rule: SiteRule) throws -> [PageObject] {
        try RuleExtractor().extract(data: response.data, responseURL: response.url, key: key, kind: .chapter, rule: rule)
            .compactMap { if case .page(let page) = $0 { page } else { nil } }
    }

    @Test func lazyChapterKeepsDescriptorsAndCachesResolvedRanges() async throws {
        let rule = try rule(), store = try ObjectStore(), sender = RequestSender(fetcher: RenderedSourceFetcher())
        let repository = try ObjectRepository(store: store, rules: [rule], sender: sender)
        let key = key("lazy")
        guard case .chapter(let chapter) = try await key.load(using: repository) else { throw ReaderError.invalidResponse }
        #expect(chapter.pageRefs.count == 4)
        let descriptors = try await chapter.pages(using: repository)
        #expect(descriptors.count == 4 && descriptors[0].imageURL != nil && descriptors[3].imageURL == nil)
        let resolved = try await chapter.load(2..<4, using: repository)
        #expect(resolved.map(\.sourceIndex) == [2, 3])
        #expect(resolved.map { $0.imageURL?.lastPathComponent } == ["3.png", "4.png"])
        let prepared = try await descriptors[3].prepare(using: repository)
        await sender.invalidateResources()
        let image = try await descriptors[3].image(using: repository)
        #expect(image.width == prepared.width && image.height == prepared.height)
        // Resolved page URLs survive browser disposal and process-style reopening.
        let reopened = try ObjectRepository(store: store, rules: [rule])
        for page in chapter.pageRefs {
            guard case .page(let page) = try await page.load(using: reopened, hint: .offlineOnly) else { throw ReaderError.cacheMiss }
            #expect(page.imageURL != nil)
        }
    }

    @Test func pageSelectionReusesURLSessionsAndRefreshResetsThem() async throws {
        let rule = try rule(mode: "page", target: "//select/option[@value='{index}']")
        #expect(rule.extractors["chapter"]?.format == .renderedHTML)
        let sender = RequestSender(fetcher: RenderedSourceFetcher()), key = key("paged")
        func load(_ range: Range<Int>? = nil, refresh: Bool = false, url: ObjectKey? = nil) async throws -> [PageObject] {
            let key = url ?? key
            let response = try await sender.send(.source(key, kind: .chapter, rule: rule, load: SourceLoad(range: range, refresh: refresh)))
            return try pages(response, key: key, rule: rule)
        }
        #expect(try await load(3..<4).first?.sourceIndex == 3)
        let second = ObjectKey(ruleID: key.ruleID, identityURL: URL(string: key.identityURL.absoluteString + "?other=1")!)
        #expect(try await load(1..<2, url: second).first?.sourceIndex == 1)
        #expect(try await load().first?.sourceIndex == 3) // First URL kept its selected page.
        #expect(try await load(0..<1).first?.sourceIndex == 0)
        #expect(try await load(2..<3).first?.sourceIndex == 2)
        #expect(try await load(refresh: true).first?.sourceIndex == 0)
        await sender.invalidateResources()
        #expect(try await load().first?.sourceIndex == 0)
        await sender.invalidateResources()
    }

    @Test func sequentialPageControlsCanSeekBackAndCancelStalledActions() async throws {
        let rule = try rule(mode: "page", target: "//*[@id='next']"), key = key("paged")
        let sender = RequestSender(fetcher: RenderedSourceFetcher())
        func read(_ range: Range<Int>) async throws -> [PageObject] {
            let response = try await sender.send(.source(key, kind: .chapter, rule: rule, load: SourceLoad(range: range)))
            return try pages(response, key: key, rule: rule)
        }
        #expect(try await read(3..<4).first?.sourceIndex == 3)
        #expect(try await read(1..<2).first?.sourceIndex == 1)
        // A multi-page range cannot coexist in this replacing DOM. Cancellation
        // must stop an unsatisfied action loop and allow a subsequent request.
        let stalled = Task { try await read(0..<4) }
        try await Task.sleep(for: .milliseconds(150))
        stalled.cancel()
        await #expect(throws: CancellationError.self) { try await stalled.value }
        #expect(try await read(0..<1).first?.sourceIndex == 0)
        let invalidated = Task { try await read(0..<4) }
        try await Task.sleep(for: .milliseconds(150))
        let start = ContinuousClock.now
        await sender.invalidateResources()
        await #expect(throws: CancellationError.self) { try await invalidated.value }
        #expect(start.duration(to: .now) < .seconds(2))
    }

    @Test func namedExtractorConfigurationIsIsolatedWithinALogicalURL() async throws {
        var json = try JSONSerialization.jsonObject(with: rule(mode: "page", target: "//*[@id='next']").exported()) as! [String: Any]
        var matchers = json["matchers"] as! [[String: Any]]
        matchers.append(["kind": "chapter", "pattern": "^https://demo\\.mangaviewer\\.local/chapter/capture$", "priority": 1, "extractor": "capture"])
        json["matchers"] = matchers
        var extractors = json["extractors"] as! [String: [String: Any]]
        extractors["capture"] = ["format": "renderedJSON", "rendering": ["captureFunction": "fixturePublish", "readyImageXPath": "//*[@id='page']", "loadAds": false],
                                  "fields": ["title": ["path": "data.title"], "pageImages": ["path": "data.pages.*"]]]
        json["extractors"] = extractors
        let rule = try SiteRule.decode(JSONSerialization.data(withJSONObject: json)), sender = RequestSender(fetcher: RenderedSourceFetcher())
        let first = key("paged"), second = key("capture")
        _ = try await sender.send(.source(first, kind: .chapter, rule: rule, load: SourceLoad(range: 2..<3)))
        let response = try await sender.send(.source(second, kind: .chapter, rule: rule, load: SourceLoad(sessionURL: first.identityURL)))
        #expect(try pages(response, key: second, rule: rule).count == 1)
        let resumed = try await sender.send(.source(first, kind: .chapter, rule: rule))
        #expect(try pages(resumed, key: first, rule: rule).first?.sourceIndex == 2)
        await sender.invalidateResources()
    }

    @Test func replacingDirectoryResumesAfterBrowserDisposalAndStopsAtDeclaredTotal() async throws {
        var json = try JSONSerialization.jsonObject(with: rule().exported()) as! [String: Any]
        var extractors = json["extractors"] as! [String: [String: Any]]
        extractors["directory"] = ["fields": ["title": ["path": "//h1"], "totalCount": ["path": "//*[@id='total']"],
                                               "mangaLinks": ["path": "//a[@class='manga']", "read": "attr:href"]],
                                   "session": ["mode": "page", "actionXPath": "//*[@id='next']"],
                                   "rendering": ["readyXPath": "//a[@class='manga']"]]
        json["extractors"] = extractors
        let rule = try SiteRule.decode(JSONSerialization.data(withJSONObject: json)), store = try ObjectStore()
        let sender = RequestSender(fetcher: RenderedSourceFetcher())
        let repository = try ObjectRepository(store: store, rules: [rule], sender: sender)
        let key = ObjectKey(ruleID: rule.id, identityURL: URL(string: DemoContent.directoryURL.absoluteString + "?browser=page")!)
        let directory = DirectoryObject(key: key, sourceURL: key.identityURL, title: "Unknown")
        let first = try await directory.load(0..<6, using: repository)
        #expect(first.mangaRefs.count == 6 && first.hasMore == true)
        await sender.invalidateResources()
        let final = try await first.load(6..<12, using: repository)
        #expect(final.mangaRefs.map(\.title) == (1...8).map { "Item \($0)" })
        for ref in final.mangaRefs {
            guard case .manga(let preview) = try #require(try store.snapshot(ref.key)).object else { throw ReaderError.cacheMiss }
            #expect(preview.title == ref.title && preview.chapters == nil)
        }
        #expect(final.hasMore == false && final.totalCount == 8)
        #expect(try JSONDecoder().decode(DirectoryObject.self, from: JSONEncoder().encode(final)).hasMore == false)
        await sender.invalidateResources()
    }

    @Test func declaredCountsAndSessionRulesRejectMalformedValues() throws {
        let rule = try rule(mode: "page", target: "//select/option[@value='{index}']"), key = key("paged")
        for (total, current) in [("0", "1"), ("four", "1"), ("4", "-1"), ("4", "9223372036854775807")] {
            let data = Data("<h1>Fixture</h1><span id='total'>\(total)</span><span id='current'>\(current)</span><div id='pages'><img data-src='/images/1.png'></div>".utf8)
            #expect(throws: ReaderError.self) { try RuleExtractor().extract(data: data, responseURL: key.identityURL, key: key, kind: .chapter, rule: rule) }
        }
        var json = try JSONSerialization.jsonObject(with: rule.exported()) as! [String: Any]
        var extractors = json["extractors"] as! [String: [String: Any]]
        extractors["chapter"]!["session"] = ["mode": "scroll", "actionXPath": "//*[", "script": "fetch('/secret')"]
        json["extractors"] = extractors
        #expect(throws: ReaderError.self) { try SiteRule.decode(JSONSerialization.data(withJSONObject: json)) }
    }
}
