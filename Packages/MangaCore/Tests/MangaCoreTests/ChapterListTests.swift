import Foundation
import GRDB
import Testing
@testable import MangaCore

struct ChapterListTests {
    private func demo() throws -> SiteRule { try #require(DemoContent.bundledRules().first { $0.id == "demo" }) }
    private var mangaKey: ObjectKey { ObjectKey(ruleID: "demo", identityURL: URL(string: "https://demo.mangaviewer.local/series/observatory")!) }

    @Test(arguments: [false, true])
    func adjacencyUsesSelectedListOrderAndStopsAtItsBoundaries(grouped: Bool) {
        let refs = [3, 1, 2].map { number in
            ContentReference(key: ObjectKey(ruleID: mangaKey.ruleID,
                identityURL: URL(string: "https://demo.mangaviewer.local/chapter/\(number)")!), title: "Chapter \(number)")
        }
        let manga = MangaObject(key: mangaKey, sourceURL: mangaKey.identityURL, title: "Series",
            chapterRefs: grouped ? nil : refs, chapterLists: grouped ? [
                ChapterList(id: "main", chapters: Array(refs.prefix(2))),
                ChapterList(id: "books", chapters: [refs[0], refs[2]]),
                ChapterList(id: "empty", chapters: [])] : nil)
        for list in manga.chapterLists {
            for (index, ref) in list.chapters.enumerated() {
                #expect(manga.previousChapter(before: ref.key, in: list.id) == (index > 0 ? list.chapters[index - 1] : nil))
                #expect(manga.nextChapter(after: ref.key, in: list.id) == (index + 1 < list.chapters.count ? list.chapters[index + 1] : nil))
            }
            let foreign = ObjectKey(ruleID: "other", identityURL: refs[0].key.identityURL)
            #expect(manga.nextChapter(after: foreign, in: list.id) == nil)
            #expect(manga.previousChapter(before: foreign, in: list.id) == nil)
        }
        #expect(manga.nextChapter(after: refs[0].key) == refs[1]) // Default chooses the first containing list.
        let empty = MangaObject(key: mangaKey, sourceURL: mangaKey.identityURL, title: "Empty", chapterRefs: [])
        #expect(empty.nextChapter(after: refs[0].key) == nil && empty.previousChapter(before: refs[0].key) == nil)
    }

    @Test func htmlGroupsKeepHeadingsAndReverseEachListIndependently() throws {
        let rule = try #require(DemoContent.bundledRules().first { $0.id == "manhuagui" })
        let key = ObjectKey(ruleID: rule.id, identityURL: URL(string: "https://www.manhuagui.com/comic/123/")!)
        // Original markup matching the source's grouping; repeated DOM IDs are legal input.
        let html = "<h1>Series</h1><h4><span>单话</span></h4><div class='chapter-list cf' id='chapter-list-0'><a href='/comic/123/2.html'>Two</a><a href='/comic/123/1.html'>One</a></div><h4><span>番外篇</span></h4><div class='chapter-list cf' id='chapter-list-0'><a href='/comic/123/3.html'>Extra</a></div>"
        guard case .manga(let manga) = try RuleExtractor().extract(data: Data(html.utf8), responseURL: key.identityURL, key: key, kind: .manga, rule: rule)[0] else { throw ReaderError.invalidResponse }
        #expect(manga.chapterLists.map(\.title) == ["单话", "番外篇"])
        #expect(manga.chapterLists.map(\.indexTitle) == ["单", "番"])
        #expect(manga.chapterRefs.map(\.title) == ["One", "Two", "Extra"])
        #expect(manga.nextChapter(after: manga.chapterRefs[1].key) == nil)
    }

    @Test func oldSnapshotsPreserveFlatChapterOrder() async throws {
        let rule = try demo(), store = try ObjectStore()
        let repository = try ObjectRepository(store: store, rules: [rule], sender: RequestSender(fetcher: DefaultSourceFetcher()))
        guard case .manga(let manga) = try await mangaKey.load(using: repository) else { throw ReaderError.invalidResponse }
        #expect(manga.chapterLists.map(\.title) == ["Chapters", "Books", "Extras"])
        #expect(manga.chapterLists.map(\.indexTitle) == ["C", "B", "E"])
        #expect(manga.chapterLists.map { $0.chapters.count } == [2, 1, 1])
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manga)) as! [String: Any]
        old.removeValue(forKey: "chapterLists"); old.removeValue(forKey: "chapterStatuses")
        let decoded = try JSONDecoder().decode(MangaObject.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.chapterLists.count == 1)
        #expect(decoded.chapterRefs == manga.chapterRefs)
        #expect(decoded.nextChapter(after: manga.chapterRefs[1].key)?.key == manga.chapterRefs[2].key)
        #expect(decoded.readingStatus(for: manga.chapterRefs[0].key) == .unread)

    }

    @Test func jsonGroupsUseRelativeFieldsAndRejectInvalidRulesAndHosts() throws {
        var json = try JSONSerialization.jsonObject(with: demo().exported()) as! [String: Any]
        var extractors = json["extractors"] as! [String: Any]
        var fields: [String: Any] = ["title": ["path": "title"], "chapterLists": ["path": "groups.*", "fields": [
            "id": ["path": "key"], "title": ["path": "label"], "chapterLinks": ["path": "chapters.*", "read": "attr:href", "reverse": true]]]]
        func changed() throws -> SiteRule {
            extractors["manga"] = ["format": "json", "fields": fields]; json["extractors"] = extractors
            return try SiteRule.decode(JSONSerialization.data(withJSONObject: json))
        }
        let rule = try changed()
        let input = #"{"title":"Series","groups":[{"key":"main","label":" Chapters ","chapters":[{"href":"/chapter/starlight","title":"Two"},{"href":"/chapter/arrival","title":"One"},{"href":"/chapter/arrival","title":"Duplicate"}]},{"key":"extra","label":"Extras","chapters":[]}]}"#
        func extract(_ input: String) throws -> MangaObject {
            guard case .manga(let manga) = try RuleExtractor().extract(data: Data(input.utf8), responseURL: mangaKey.identityURL, key: mangaKey, kind: .manga, rule: rule)[0] else { throw ReaderError.invalidResponse }
            return manga
        }
        let manga = try extract(input)
        #expect(manga.chapterLists.map(\.title) == ["Chapters", "Extras"])
        #expect(manga.chapterLists[0].chapters.map { $0.key.identityURL.lastPathComponent } == ["arrival", "starlight"])
        #expect(manga.chapterLists[1].chapters.isEmpty)
        #expect(throws: ReaderError.self) { try extract(input.replacingOccurrences(of: "/chapter/arrival", with: "https://outside.test/chapter")) }
        #expect(throws: ReaderError.self) { try extract(input.replacingOccurrences(of: "\"extra\"", with: "\"main\"")) }
        fields["chapterLinks"] = ["path": "chapters.*"]
        #expect(throws: ReaderError.self) { try changed() }
        fields.removeValue(forKey: "chapterLinks")
        fields["chapterLists"] = ["path": "groups.*", "fields": ["title": ["path": "label"]]]
        #expect(throws: ReaderError.self) { try changed() }
        fields["chapterLists"] = ["path": "groups.*", "fields": ["chapterLinks": ["path": "chapters.*", "fields": ["title": ["path": "title"]]]]]
        #expect(throws: ReaderError.self) { try changed() }
    }

    @Test func readStatusSurvivesRefreshCacheEvictionAndReopening() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let rule = try demo(), store = try ObjectStore(path: path)
        let repository = try ObjectRepository(store: store, rules: [rule], sender: RequestSender(fetcher: DefaultSourceFetcher()))
        guard case .manga(let original) = try await mangaKey.load(using: repository) else { throw ReaderError.invalidResponse }
        func position(_ index: Int) -> ReadingPosition {
            let ref = original.chapterRefs[index]
            return ReadingPosition(mangaKey: mangaKey, chapterKey: ref.key, sourcePageKey: .page(owner: ref.key, index: 0), title: ref.title)
        }
        try store.savePosition(position(0), completed: true)
        try store.savePosition(position(0)) // Rereading must not erase completion.
        try store.savePosition(position(2))
        let local = try original.readingState(using: repository)
        #expect(local.readingStatus(for: original.chapterRefs[0].key) == .read)
        #expect(local.readingStatus(for: original.chapterRefs[2].key) == .reading)
        try store.hideRecent(mangaKey); try store.clearContent()
        guard case .manga(let refreshed) = try await mangaKey.load(using: repository, hint: .forceRefresh) else { throw ReaderError.invalidResponse }
        #expect(refreshed.chapterStatuses == local.chapterStatuses)
        try store.removeRule(rule.id)
        let reopened = try ObjectRepository(store: ObjectStore(path: path), rules: [rule], sender: RequestSender(fetcher: DefaultSourceFetcher()))
        guard case .manga(let loaded) = try await mangaKey.load(using: reopened) else { throw ReaderError.invalidResponse }
        #expect(loaded.chapterStatuses == local.chapterStatuses)
        let decoded = try JSONDecoder().decode(MangaObject.self, from: JSONEncoder().encode(loaded))
        #expect(decoded.chapterStatuses == loaded.chapterStatuses)
    }

    @Test func oldReadingPositionsMigrateWithoutInventingCompletions() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let chapter = ObjectKey(ruleID: "demo", identityURL: URL(string: "https://demo.mangaviewer.local/chapter/arrival")!)
        do {
            let store = try ObjectStore(path: path)
            try store.savePosition(ReadingPosition(mangaKey: mangaKey, chapterKey: chapter, sourcePageKey: .page(owner: chapter, index: 0), title: "One"))
            let db = try DatabaseQueue(path: path)
            try db.write {
                try $0.execute(sql: "DROP TABLE mangaReadingState")
                try $0.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v4ChapterReadingStatus'")
            }
        }
        let store = try ObjectStore(path: path)
        let manga = MangaObject(key: mangaKey, sourceURL: mangaKey.identityURL, title: "Series")
        #expect(try store.readingState(for: manga).readingStatus(for: chapter) == .reading)
    }
}
