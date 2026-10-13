import Foundation
import Testing
@testable import MangaCore

struct KnownMetadataTests {
    private func rule(fields: [String: Any], format: String = "html") throws -> SiteRule {
        var json = try JSONSerialization.jsonObject(with: DemoContent.bundledRules().first { $0.id == "demo" }!.exported()) as! [String: Any]
        var extractors = json["extractors"] as! [String: Any]
        extractors["directory"] = ["format": format, "fields": fields]
        json["extractors"] = extractors
        return try SiteRule.decode(JSONSerialization.data(withJSONObject: json))
    }
    private let url = DemoContent.directoryURL
    private var key: ObjectKey { ObjectKey(ruleID: "demo", identityURL: url) }

    @Test func relativeMetadataStaysWithEachLinkAndUsesTheSameMangaMapping() throws {
        let fields: [String: Any] = ["title": ["path": "//h1"], "mangaLinks": ["path": "//article/a", "read": "attr:href", "fields": [
            "title": ["path": "../h2"], "coverImage": ["path": "../img", "read": "attr:data-src", "fallback": "attr:src"],
            "rating": ["path": "../span", "regex": "score: (.*)", "group": 1], "tags": ["path": "../i"]]]]
        let rule = try rule(fields: fields)
        let html = """
        <h1>List</h1><article><a href='/series/a'>Fallback</a><h2>Known title</h2><span>score: 4 / 5</span><i> Space </i><i>Space</i></article>
        <article><a href='/series/b'>Second</a><img src='/images/2.png'></article>
        <article><a href='/series/c'>Third</a><img data-src='/images/3.png'></article>
        """
        let session = url.appending(queryItems: [URLQueryItem(name: "sort", value: "title")])
        let objects = try RuleExtractor().extract(data: Data(html.utf8), responseURL: url, key: key, kind: .directory, rule: rule, sessionURL: session)
        guard case .directory(let list) = objects[0] else { throw ReaderError.invalidResponse }
        let manga = objects.compactMap { if case .manga(let value) = $0 { value } else { nil } }
        let pages = objects.compactMap { if case .page(let value) = $0 { value } else { nil } }
        #expect(list.mangaRefs.map(\.title) == ["Known title", "Second", "Third"])
        #expect(manga.map(\.title) == list.mangaRefs.map(\.title))
        #expect(manga.allSatisfy { $0.chapters == nil })
        #expect(manga[0].coverPageRef == nil && manga[0].rating == "4 / 5" && manga[0].tags == ["Space"])
        #expect(pages.map { $0.imageURL?.lastPathComponent } == ["2.png", "3.png"])
        #expect(pages.map(\.ownerRef) == [manga[1].key, manga[2].key])
        #expect(pages.allSatisfy { $0.refererURL == url && $0.sessionURL == session })
        let blocked = html.replacingOccurrences(of: "/images/3.png", with: "https://unknown.example/3.png")
        #expect(throws: ReaderError.self) { try RuleExtractor().extract(data: Data(blocked.utf8), responseURL: url, key: key, kind: .directory, rule: rule) }
    }

    @Test func jsonKnownMetadataAndValidationUseExistingFieldLanguage() throws {
        let metadata: [String: Any] = ["title": ["path": "name"], "coverImage": ["path": "cover", "urlTemplate": "https://demo.mangaviewer.local/{value}"],
            "status": ["path": "state"], "tags": ["path": "tags.*.name"]]
        let fields: [String: Any] = ["title": ["path": "title"], "mangaLinks": ["path": "items.*", "read": "attr:slug",
            "urlTemplate": "https://demo.mangaviewer.local/series/{value}", "fields": metadata]]
        let rule = try rule(fields: fields, format: "json")
        let input = #"{"title":"List","items":[{"slug":"a","name":"Known","cover":"images/1.png","state":" Ongoing ","tags":[{"name":"Space"},{"name":"Space"}]},{"slug":"b","title":"Legacy label"}]}"#
        let objects = try RuleExtractor().extract(data: Data(input.utf8), responseURL: url, key: key, kind: .directory, rule: rule)
        let manga = objects.compactMap { if case .manga(let value) = $0 { value } else { nil } }
        #expect(manga.map(\.title) == ["Known", "Legacy label"])
        #expect(manga[0].status == "Ongoing" && manga[0].tags == ["Space"])
        #expect(manga[1].coverPageRef == nil && manga[1].chapters == nil)
        for child in [["path": "cover", "script": "forbidden"], ["path": "cover", "fields": ["title": ["path": "x"]]]] as [[String: Any]] {
            var bad = fields; bad["mangaLinks"] = ["path": "items.*", "fields": ["coverImage": child]]
            #expect(throws: ReaderError.self) { try self.rule(fields: bad, format: "json") }
        }
        var bad = fields; bad["mangaLinks"] = ["path": "items.*", "fields": ["unknown": ["path": "x"]]]
        #expect(throws: ReaderError.self) { try self.rule(fields: bad, format: "json") }
    }

    @Test func previewsSkipDetailRequestsThenPromoteWithoutDirectoryDowngrade() async throws {
        let rules = try DemoContent.bundledRules(), rule = try #require(rules.first { $0.id == "demo" })
        let fetcher = MetadataFixtureFetcher(), store = try ObjectStore()
        let repository = try ObjectRepository(store: store, rules: rules, sender: RequestSender(fetcher: fetcher))
        guard case .directory(let list) = try await key.load(using: repository) else { throw ReaderError.invalidResponse }
        for ref in list.mangaRefs {
            guard case .manga(let preview) = try await ref.preview(using: repository) else { throw ReaderError.invalidResponse }
            #expect(preview.chapters == nil && preview.coverPageRef != nil)
            let cover = try #require(try await preview.coverPage(using: repository))
            #expect(cover.sessionURL == list.key.identityURL && cover.ownerRef == preview.key)
        }
        #expect(await fetcher.kinds == [.directory]) // Neither card needs its detail document.
        let ref = try #require(list.mangaRefs.first)
        await #expect(throws: ReaderError.self) { try await ref.load(using: repository, hint: .offlineOnly) }
        guard case .manga(let full) = try await ref.load(using: repository) else { throw ReaderError.invalidResponse }
        #expect(full.chapters?.count == 2 && full.tags == ["Science fiction", "Adventure"])
        #expect(await fetcher.kinds == [.directory, .manga])
        let before = try #require(try store.snapshot(full.key))
        let originalCover = try #require(try await full.coverPage(using: repository))
        _ = try await key.load(using: repository, hint: .forceRefresh)
        guard case .manga(let kept) = try await ref.load(using: repository, hint: .offlineOnly) else { throw ReaderError.invalidResponse }
        #expect(kept.chapters?.count == 2 && kept.tags == full.tags)
        #expect(try store.snapshot(full.key)?.expiresAt == before.expiresAt)
        let keptCover = try #require(try await kept.coverPage(using: repository))
        #expect(keptCover.refererURL == originalCover.refererURL && keptCover.sessionURL == originalCover.sessionURL)
        // A fresh repository/process sees the same complete snapshot, including old serialized chapterRefs.
        let reopened = try ObjectRepository(store: store, rules: rules)
        guard case .manga(let reopenedManga) = try await ref.preview(using: reopened) else { throw ReaderError.invalidResponse }
        #expect(reopenedManga.chapters?.count == 2)
        let decoded = try JSONDecoder().decode(MangaObject.self, from: JSONEncoder().encode(full))
        #expect(decoded.chapters?.count == 2)
        // Partial updates merge optional knowledge, but a changed rule cannot inherit old metadata.
        let partialKey = list.mangaRefs[1].key
        let empty = MangaObject(key: partialKey, sourceURL: partialKey.identityURL, title: "Updated label")
        try store.upsert([.manga(empty)], version: rule.version, ttl: 60)
        guard case .manga(let merged) = try #require(try store.snapshot(partialKey)).object else { throw ReaderError.invalidResponse }
        #expect(merged.coverPageRef != nil && merged.chapters == nil && merged.title == "Updated label")
        try store.upsert([.manga(empty)], version: rule.version + 1, ttl: 60)
        guard case .manga(let changed) = try #require(try store.snapshot(partialKey)).object else { throw ReaderError.invalidResponse }
        #expect(changed.coverPageRef == nil)
    }
}

private actor MetadataFixtureFetcher: SourceFetcher {
    var kinds: [ContentKind] = []
    func fetch(_ url: URL, rule: SiteRule, kind: ContentKind, backgroundLoading: Bool) async throws -> SourceResponse {
        kinds.append(kind)
        return try #require(try DemoContent.response(for: url))
    }
}
