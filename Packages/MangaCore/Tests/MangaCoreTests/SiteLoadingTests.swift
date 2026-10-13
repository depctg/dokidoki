import Foundation
import Testing
@testable import MangaCore

struct SiteLoadingTests {
    private func rule() throws -> SiteRule { try #require(DemoContent.bundledRules().first { $0.id == "demo" }) }

    @Test func oneHomeBuildsListsAndMangaWithoutDetailRequestsAndPreservesFullSnapshots() async throws {
        let rule = try rule(), site = try SiteObject(rule: rule), store = try ObjectStore(), fetcher = SiteFixtureFetcher()
        let repository = try ObjectRepository(store: store, rules: [rule], sender: RequestSender(fetcher: fetcher))
        async let first = site.load(using: repository)
        async let duplicate = site.load(using: repository)
        let (lists, again) = try await (first, duplicate)
        #expect(lists.map(\.key) == again.map(\.key))
        #expect(lists.count == 2 && lists.allSatisfy { $0.isPreview == true && $0.hasMore == nil })
        #expect(lists.map { $0.mangaRefs.count } == [2, 2])
        #expect(await fetcher.requests.map(\.path) == ["/home"])
        let preview = try #require(lists.first), mangaRef = try #require(preview.mangaRefs.first)
        guard case .manga(let manga) = try await mangaRef.preview(using: repository),
              let cover = try await manga.coverPage(using: repository) else { throw ReaderError.invalidResponse }
        #expect(manga.chapters == nil && cover.sessionURL == site.browseRefs[0].key.identityURL)
        #expect(cover.refererURL == cover.sessionURL && cover.ownerRef == manga.key)
        #expect(await fetcher.requests.count == 1)
        let reopened = try ObjectRepository(store: store, rules: [rule], sender: RequestSender(fetcher: fetcher))
        #expect(try await site.load(using: reopened, hint: .offlineOnly).map(\.key) == lists.map(\.key))
        await #expect(throws: ReaderError.self) { try await preview.key.load(using: repository, hint: .offlineOnly) }
        guard case .directory(let full) = try await preview.key.load(using: repository) else { throw ReaderError.invalidResponse }
        #expect(full.isPreview != true && full.sortBy?.count == 2)
        let saved = try #require(try store.snapshot(full.key))
        _ = try await site.load(using: repository, hint: .forceRefresh)
        guard case .directory(let retained) = try #require(try store.snapshot(full.key)).object else { throw ReaderError.invalidResponse }
        #expect(retained.sortBy == full.sortBy && retained.isPreview != true)
        #expect(try store.snapshot(full.key)?.fetchedAt == saved.fetchedAt)
        #expect(await fetcher.requests.map(\.path) == ["/home", "/catalog", "/home"])
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(full)) as! [String: Any]
        legacy.removeValue(forKey: "isPreview")
        let decoded = try JSONDecoder().decode(DirectoryObject.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(ContentObject.directory(decoded).isComplete)
    }

    @Test func multipleJSONSourcesRetainOrderDeduplicateListsAndRespectNestedContext() async throws {
        var json = try JSONSerialization.jsonObject(with: rule().exported()) as! [String: Any]
        json["browse"] = [["title": "First", "url": "https://demo.mangaviewer.local/home?part=1"],
                          ["title": "Second", "url": "https://demo.mangaviewer.local/home?part=2"]]
        var extractors = json["extractors"] as! [String: Any]
        let mangaFields = ["title": ["path": "name"], "coverImage": ["path": "cover"]]
        let directoryFields: [String: Any] = ["title": ["path": "name"], "mangaLinks": ["path": "items.*", "fields": mangaFields]]
        extractors["site"] = ["format": "json", "fields": ["title": ["path": "name"], "directoryLinks": ["path": "lists.*", "fields": directoryFields]]]
        json["extractors"] = extractors
        let rule = try SiteRule.decode(JSONSerialization.data(withJSONObject: json)), site = try SiteObject(rule: rule)
        let first = #"{"name":"First","lists":[{"url":"/catalog?list=a","name":"A","items":[{"url":"/series/a","name":"Manga A","cover":"/images/1.png"}]},{"url":"/catalog?list=empty","name":"Empty","items":[]}]}"#
        let second = #"{"name":"Second","lists":[{"url":"/catalog?list=a","name":"Repeated A","items":[{"url":"/series/a","name":"Manga A","cover":"/images/1.png"}]},{"url":"/catalog?list=b","name":"B","items":[{"url":"/series/b","name":"Manga B","cover":"/images/2.png"}]}]}"#
        let fetcher = SiteFixtureFetcher(sources: ["part=1": first, "part=2": second]), store = try ObjectStore()
        let repository = try ObjectRepository(store: store, rules: [rule], sender: RequestSender(fetcher: fetcher))
        let lists = try await site.load(using: repository)
        #expect(lists.map(\.title) == ["A", "Empty", "B"])
        #expect(lists.map { $0.mangaRefs.map(\.title) } == [["Manga A"], [], ["Manga B"]])
        #expect(await fetcher.requests.count == 2)
        let ref = try #require(lists.last?.mangaRefs.first)
        guard case .manga(let manga) = try await ref.preview(using: repository), let cover = try await manga.coverPage(using: repository) else { throw ReaderError.invalidResponse }
        #expect(cover.imageURL?.lastPathComponent == "2.png" && cover.sessionURL?.query == "part=2")
        await repository.clearImages()
        #expect(try await site.load(using: repository).count == 3)
        #expect(await fetcher.requests.count == 2) // Browser disposal does not erase content knowledge.
        // Unknown linked items are different from an explicit known empty selection.
        var siteExtractor = extractors["site"] as! [String: Any]
        siteExtractor["fields"] = ["title": ["path": "name"], "directoryLinks": ["path": "lists.*", "fields": ["title": ["path": "name"]]]]
        extractors["site"] = siteExtractor; json["extractors"] = extractors
        let sparseRule = try SiteRule.decode(JSONSerialization.data(withJSONObject: json)), key = site.browseRefs[0].key
        let objects = try RuleExtractor().extract(data: Data(first.utf8), responseURL: key.identityURL, key: key, kind: .site, rule: sparseRule)
        let directory = try #require(objects.compactMap { if case .directory(let value) = $0 { value } else { nil } }.first)
        #expect(directory.items == nil && directory.hasMore == nil)
    }

    @Test func linkOnlySourcesReloadInvalidatedListsWithoutReloadingCachedSiblings() async throws {
        var json = try JSONSerialization.jsonObject(with: rule().exported()) as! [String: Any]
        var extractors = json["extractors"] as! [String: Any]
        extractors["site"] = ["format": "html", "fields": ["title": ["path": "//h1"],
            "directoryLinks": ["path": "//section/h2/a", "read": "attr:href", "fields": ["title": ["path": "."]]]]]
        json["extractors"] = extractors
        let rule = try SiteRule.decode(JSONSerialization.data(withJSONObject: json)), site = try SiteObject(rule: rule)
        let store = try ObjectStore(), fetcher = SiteFixtureFetcher()
        let repository = try ObjectRepository(store: store, rules: [rule], sender: RequestSender(fetcher: fetcher))
        let lists = try await site.load(using: repository), first = try #require(lists.first)
        #expect(lists.count == 2 && lists.allSatisfy { $0.isPreview != true })
        for hint: CacheHint in [.preferCache, .forceRefresh] {
            try store.upsert([.directory(first)], version: rule.version - 1)
            let before = await fetcher.requests
            let loaded = try await site.load(using: repository, hint: hint)
            #expect(loaded.map(\.key) == lists.map(\.key))
            let added = await fetcher.requests.dropFirst(before.count)
            #expect(added.filter { $0.path == "/catalog" } == [first.sourceURL])
            #expect(added.filter { $0.path == "/home" }.count == (hint == .forceRefresh ? 1 : 0))
            #expect(try store.snapshot(first.key)?.ruleVersion == rule.version)
        }
    }

    @Test func siteRelationshipsRejectUnknownHostsAndUnsupportedMetadataDepth() throws {
        let rule = try rule(), key = try #require(try SiteObject(rule: rule).browseRefs.first?.key)
        let data = try DemoContent.resource("home", extension: "html")
        let source = String(decoding: data, as: UTF8.self)
        for bad in [source.replacingOccurrences(of: "href=\"/catalog\"", with: "href=\"https://outside.example/catalog\""),
                    source.replacingOccurrences(of: "data-cover=\"/images/1.png\"", with: "data-cover=\"https://outside.example/image\"")] {
            #expect(throws: ReaderError.self) { try RuleExtractor().extract(data: Data(bad.utf8), responseURL: key.identityURL, key: key, kind: .site, rule: rule) }
        }
        var json = try JSONSerialization.jsonObject(with: rule.exported()) as! [String: Any]
        var extractors = json["extractors"] as! [String: Any]
        for invalid: [String: Any] in [
            ["title": ["path": ".", "script": "forbidden"]],
            ["directoryLinks": ["path": ".", "fields": ["title": ["path": "."]]]],
            ["mangaLinks": ["path": ".", "fields": ["coverImage": ["path": ".", "fields": ["title": ["path": "."]]]]]]
        ] {
            extractors["site"] = ["fields": ["title": ["path": "//h1"], "directoryLinks": ["path": "//a", "fields": invalid]]]
            json["extractors"] = extractors
            #expect(throws: ReaderError.self) { try SiteRule.decode(JSONSerialization.data(withJSONObject: json)) }
        }
    }
}

private actor SiteFixtureFetcher: SourceFetcher {
    var requests: [URL] = []
    let sources: [String: String]
    init(sources: [String: String] = [:]) { self.sources = sources }
    func fetch(_ url: URL, rule: SiteRule, kind: ContentKind, backgroundLoading: Bool) async throws -> SourceResponse {
        requests.append(url)
        try await Task.sleep(for: .milliseconds(url.query == "part=2" ? 5 : 50))
        if let source = sources[url.query ?? ""] { return SourceResponse(data: Data(source.utf8), url: url) }
        return try #require(try DemoContent.response(for: url))
    }
}
