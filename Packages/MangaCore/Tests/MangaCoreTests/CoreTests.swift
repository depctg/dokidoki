import Foundation
import Testing
@testable import MangaCore

struct CoreTests {
    @Test func mangaOwnsNavigationInDeclaredOrder() {
        let key = ObjectKey(ruleID: "test", identityURL: URL(string: "https://reader.example/series")!)
        let refs = [3, 1, 2].map { number in
            ContentReference(key: ObjectKey(ruleID: key.ruleID, identityURL: URL(string: "https://reader.example/chapter/\(number)")!), title: "Chapter \(number)")
        }
        let manga = MangaObject(key: key, sourceURL: key.identityURL, title: "Series", author: nil, summary: nil, coverPageRef: nil, chapterRefs: refs)
        #expect(manga.nextChapter(after: refs[0].key) == refs[1])
        #expect(manga.nextChapter(after: refs[1].key) == refs[2])
        #expect(manga.previousChapter(before: refs[1].key) == refs[0])
        #expect(manga.previousChapter(before: refs[0].key) == nil)
        #expect(manga.nextChapter(after: refs[2].key) == nil)
        let foreign = ObjectKey(ruleID: "other", identityURL: refs[1].key.identityURL)
        #expect(manga.nextChapter(after: foreign) == nil)
        #expect(manga.previousChapter(before: foreign) == nil)
        let empty = MangaObject(key: key, sourceURL: key.identityURL, title: "Empty", author: nil, summary: nil, coverPageRef: nil, chapterRefs: [])
        #expect(empty.nextChapter(after: refs[0].key) == nil)
        #expect(empty.previousChapter(before: refs[0].key) == nil)
    }
    @Test func fixtureImageDecodesWithBoundedSize() async throws {
        let rule = try DemoContent.bundledRules().first { $0.id == "demo" }!
        let owner = ObjectKey(ruleID: rule.id, identityURL: URL(string: "https://demo.mangaviewer.local/chapter/arrival")!)
        let page = PageObject(key: .page(owner: owner, index: 0), ownerRef: owner, sourceIndex: 0, imageURL: URL(string: "https://demo.mangaviewer.local/images/1.png")!, refererURL: owner.identityURL)
        let repository = try ObjectRepository(store: ObjectStore(), rules: [rule])
        let image = try await page.image(using: repository, maxPixel: 512)
        #expect(max(image.width, image.height) == 512)
        #expect(image.height > image.width)
    }
    @Test func matchingAndRuleRoundTrip() throws {
        let rules = try DemoContent.bundledRules()
        let registry = try RuleRegistry(rules: rules)
        #expect(try registry.match(DemoContent.directoryURL).1 == .directory)
        let normalized = try RuleRegistry.normalize(URL(string: "HTTPS://EXAMPLE.COM:443/a?q=2#fragment")!)
        #expect(normalized.absoluteString == "https://example.com/a?q=2")
        #expect(throws: ReaderError.self) { try registry.match(URL(string: "https://evil.test/catalog")!) }
        #expect(throws: ReaderError.self) { try RuleRegistry(rules: [rules[0], rules[0]]) }
        for rule in rules { #expect(try SiteRule.decode(rule.exported()).exported() == rule.exported()) }
        var json = try JSONSerialization.jsonObject(with: rules[0].exported()) as! [String: Any]
        json["headers"] = ["Cookie": "secret"]
        #expect(throws: ReaderError.self) { try SiteRule.decode(JSONSerialization.data(withJSONObject: json)) }
    }

    @Test func fullGraphPersistsAndProgressSurvivesEviction() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let rules = try DemoContent.bundledRules()
        let store = try ObjectStore(path: path)
        let repository = try ObjectRepository(store: store, rules: rules)
        let key = try await repository.key(for: DemoContent.directoryURL)
        guard case .directory(let directory) = try await key.load(using: repository),
              case .manga(let manga) = try await directory.mangaRefs[0].load(using: repository),
              case .chapter(let chapter) = try await manga.chapterRefs[0].load(using: repository),
              let page = try await chapter.page(at: 0, using: repository) else { Issue.record("Unexpected graph"); return }
        #expect(try await chapter.manga(using: repository)?.key == manga.key)
        #expect(try await chapter.pages(using: repository).map(\.key) == chapter.pageRefs)
        #expect(try await manga.coverPage(using: repository)?.role == .cover)
        #expect(try await chapter.page(at: -1, using: repository) == nil)
        #expect(chapter.pageRefs.count == 4)
        #expect(page.imageURL.absoluteString == "https://demo.mangaviewer.local/images/1.png")
        #expect(page.key.owner == chapter.key)
        #expect(chapter.mangaRef == manga.key)
        try store.savePosition(ReadingPosition(mangaKey: manga.key, chapterKey: chapter.key, sourcePageKey: page.key, fractionalOffset: 0.4, title: manga.title))
        try store.setSaved(SavedManga(key: manga.key, title: manga.title), saved: true)
        let reopened = try ObjectStore(path: path)
        #expect(try reopened.snapshot(chapter.key)?.object.key == chapter.key)
        try await repository.clearContent()
        #expect(try reopened.positions().first?.fractionalOffset == 0.4)
        #expect(try reopened.savedManga().count == 1)
        #expect(try reopened.snapshot(chapter.key) == nil)
        // Synthetic page resolution rebuilds its owner after eviction, never requests reader://.
        #expect(try await repository.resolve(page.key).key == page.key)
    }

    @Test func htmlFallbackRelativeLinksAndHostEnforcement() throws {
        let rule = try DemoContent.bundledRules().first { $0.id == "demo" }!
        let key = ObjectKey(ruleID: rule.id, identityURL: URL(string: "https://demo.mangaviewer.local/series/test")!)
        let html = Data("<h1>Test &amp; title</h1><img src='../images/1.png'><a href='../chapter/arrival'>One</a><a href='../chapter/arrival'>Duplicate</a>".utf8)
        let objects = try RuleExtractor().extract(data: html, responseURL: key.identityURL, key: key, kind: .manga, rule: rule)
        guard case .manga(let manga) = objects[0], case .page(let cover) = objects[1] else { Issue.record("Missing manga"); return }
        #expect(manga.title == "Test & title"); #expect(manga.chapterRefs.count == 1)
        #expect(cover.imageURL.path == "/images/1.png")
        #expect(throws: ReaderError.self) { try RuleExtractor().extract(data: Data("<h1>T</h1><img src='https://evil.test/a.jpg'>".utf8), responseURL: key.identityURL, key: key, kind: .manga, rule: rule) }
    }

    @Test func deduplicationAndVersionInvalidation() async throws {
        let rule = try DemoContent.bundledRules().first { $0.id == "demo" }!
        let fetcher = CountingFetcher()
        let store = try ObjectStore()
        let repository = try ObjectRepository(store: store, rules: [rule], sender: RequestSender(fetcher: fetcher))
        let key = try await repository.key(for: DemoContent.directoryURL)
        async let a = repository.resolve(key)
        async let b = repository.resolve(key)
        _ = try await (a, b)
        #expect(await fetcher.count == 1)
        _ = try await repository.resolve(key)
        #expect(await fetcher.count == 1)
        var json = try JSONSerialization.jsonObject(with: rule.exported()) as! [String: Any]; json["version"] = rule.version + 1
        let v2 = try SiteRule.decode(JSONSerialization.data(withJSONObject: json))
        try await repository.install(v2)
        await #expect(throws: ReaderError.self) { try await repository.resolve(key, hint: .offlineOnly) }
        _ = try await repository.resolve(key)
        #expect(await fetcher.count == 2)
        #expect(try store.snapshot(key)?.ruleVersion == rule.version + 1)
    }

    @Test func refreshingParentRemovesObsoleteChildren() async throws {
        let rules = try DemoContent.bundledRules(); let store = try ObjectStore()
        let repository = try ObjectRepository(store: store, rules: rules)
        let key = ObjectKey(ruleID: "demo", identityURL: URL(string: "https://demo.mangaviewer.local/chapter/arrival")!)
        guard case .chapter(let chapter) = try await repository.resolve(key) else { Issue.record("Missing chapter"); return }
        let replacement = ChapterObject(key: key, sourceURL: key.identityURL, title: "Now empty", mangaRef: chapter.mangaRef, pageRefs: [])
        try store.upsert([.chapter(replacement)], version: 1, ttl: 3600)
        #expect(try store.snapshot(chapter.pageRefs[0]) == nil)
    }

    @Test func abandonedResolutionCancelsTransportAndCanRetry() async throws {
        let rules = try DemoContent.bundledRules()
        let store = try ObjectStore()
        let fetcher = SlowFetcher()
        let repository = try ObjectRepository(store: store, rules: rules, sender: RequestSender(fetcher: fetcher))
        let key = try await repository.key(for: DemoContent.directoryURL)
        let request = Task { try await repository.resolve(key) }
        while await fetcher.count == 0 { await Task.yield() }
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        let deadline = ContinuousClock.now + .seconds(1)
        while await fetcher.cancellations == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await fetcher.cancellations == 1)
        #expect(try store.snapshot(key) == nil)
        _ = try await repository.resolve(key)
        #expect(await fetcher.count == 2)
    }

    @Test func cancellationAndIdenticalImportPreserveSharedConsumers() async throws {
        let rules = try DemoContent.bundledRules()
        let fetcher = SlowFetcher()
        let repository = try ObjectRepository(store: ObjectStore(), rules: rules, sender: RequestSender(fetcher: fetcher))
        let key = try await repository.key(for: DemoContent.directoryURL)
        let first = Task { try await repository.resolve(key) }
        let second = Task { try await repository.resolve(key) }
        // Leave both callers waiting on the delayed transport before cancelling one.
        try await Task.sleep(for: .milliseconds(50))
        try await repository.install(rules[0])
        first.cancel()
        _ = try await second.value
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await fetcher.count == 1)
        #expect(await fetcher.cancellations == 0)
    }

    @Test func backgroundLoadingDefaultsOnPersistsAndCancelsOldPolicy() async throws {
        let rules = try DemoContent.bundledRules(), store = try ObjectStore(), fetcher = SlowFetcher()
        let repository = try ObjectRepository(store: store, rules: rules, sender: RequestSender(fetcher: fetcher))
        let key = try await repository.key(for: DemoContent.directoryURL)
        let old = Task { try await key.load(using: repository) }
        while await fetcher.count == 0 { await Task.yield() }
        #expect(await fetcher.backgroundPolicies == [true])
        try await repository.setBackgroundLoading(false)
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(try store.snapshot(key) == nil)
        #expect(try store.preference("backgroundLoading", as: Bool.self) == false)
        let reopened = try ObjectRepository(store: store, rules: rules, sender: RequestSender(fetcher: fetcher))
        _ = try await key.load(using: reopened)
        #expect(await fetcher.backgroundPolicies == [true, false])
        try await reopened.setBackgroundLoading(true)
        _ = try await key.load(using: reopened, hint: .forceRefresh)
        #expect(await fetcher.backgroundPolicies == [true, false, true])
    }
}
private actor SlowFetcher: SourceFetcher {
    var count = 0
    var cancellations = 0
    var backgroundPolicies: [Bool] = []
    func fetch(_ url: URL, rule: SiteRule, kind: ContentKind, backgroundLoading: Bool) async throws -> SourceResponse {
        count += 1
        backgroundPolicies.append(backgroundLoading)
        do { try await Task.sleep(for: .milliseconds(250)) }
        catch { cancellations += 1; throw error }
        return try DemoContent.response(for: url)!
    }
}
private actor CountingFetcher: SourceFetcher {
    var count = 0
    func fetch(_ url: URL, rule: SiteRule, kind: ContentKind, backgroundLoading: Bool) async throws -> SourceResponse {
        count += 1; try await Task.sleep(for: .milliseconds(40)); return try DemoContent.response(for: url)!
    }
}
