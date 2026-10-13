import Foundation
import GRDB
import Testing
@testable import MangaCore

struct ObjectCacheTests {
    private func manga(_ index: Int) -> ContentObject {
        let key = ObjectKey(ruleID: "fixture", identityURL: URL(string: "https://cache.example/manga/\(index)")!)
        return .manga(MangaObject(key: key, sourceURL: key.identityURL, title: "Title \(index)",
            summary: String(repeating: "x", count: 2000), chapterRefs: []))
    }

    @Test func cacheOwnsAdmissionPriorityAndRecencyWithoutAffectingReadingState() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = manga(1), second = manga(2), third = manga(3)
        let budget = try JSONEncoder().encode(first).count + JSONEncoder().encode(second).count
        let path = folder.appendingPathComponent("cache.sqlite").path
        let store = try ObjectStore(path: path, cacheLimit: budget)
        try store.upsert([first, second], version: 1)
        let db = try DatabaseQueue(path: path)
        try db.write { try $0.execute(sql: "UPDATE objects SET accessedAt = 0") }
        _ = try store.snapshot(first.key) // Access protects this one among equal priorities.
        try store.savePosition(ReadingPosition(mangaKey: second.key, chapterKey: second.key,
            sourcePageKey: .page(owner: second.key, index: 0), title: "Reading", updatedAt: .distantPast), completed: true)
        try store.setSaved(SavedManga(key: second.key, title: "Saved"), saved: true)
        try store.upsert([third], version: 1)
        #expect(try store.snapshot(first.key) != nil && store.snapshot(third.key) != nil)
        #expect(try store.snapshot(second.key) == nil)
        let directory = DirectoryObject(key: second.key, sourceURL: second.key.identityURL, title: "List", mangaRefs: [])
        // A newly requested lower-priority object may be declined even though it is newest.
        try store.upsert([.directory(directory)], version: 1)
        #expect(try store.snapshot(second.key) == nil)
        #expect(try store.snapshot(first.key) != nil && store.snapshot(third.key) != nil)
        #expect(try store.positions().first?.mangaKey == second.key)
        #expect(try store.savedManga().first?.key == second.key)
        let bytes = try db.read { try Int.fetchOne($0, sql: "SELECT SUM(length(payload)) FROM objects") }
        #expect(try #require(bytes) <= budget)

        // Simulate the previously shipped expiry schema, then migrate without clearing data.
        try db.write {
            try $0.execute(sql: "ALTER TABLE objects RENAME COLUMN accessedAt TO expiresAt")
            try $0.execute(sql: "ALTER TABLE objects DROP COLUMN priority")
            try $0.execute(sql: "UPDATE objects SET expiresAt = 0, fetchedAt = 0")
            try $0.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v5PriorityCache'")
        }
        let reopened = try ObjectStore(path: path, cacheLimit: budget)
        #expect(try reopened.cachedObject(first.key, version: 1) != nil)
        #expect(try reopened.cachedObject(first.key, version: 2) == nil)
        #expect(try reopened.positions().first?.mangaKey == second.key)
    }

    @Test func fetchedObjectsStillReturnWhenCacheDeclinesStorage() async throws {
        let store = try ObjectStore(cacheLimit: 0)
        let repository = try ObjectRepository(store: store, rules: DemoContent.bundledRules())
        let key = ObjectKey(ruleID: "demo", identityURL: DemoContent.directoryURL)
        guard case .directory(let directory) = try await key.load(using: repository) else { throw ReaderError.invalidResponse }
        #expect(!directory.mangaRefs.isEmpty)
        #expect(try store.snapshot(key) == nil)
        let ref = try #require(directory.mangaRefs.first)
        guard case .manga(let manga) = try await ref.load(using: repository),
              let cover = try await manga.coverPage(using: repository) else { throw ReaderError.invalidResponse }
        #expect(cover.imageURL != nil && cover.ownerRef == manga.key)
        #expect(try store.snapshot(cover.key) == nil)
        let chapterRef = try #require(manga.chapterRefs.first)
        guard case .chapter(let chapter) = try await chapterRef.load(using: repository),
              let pageKey = chapter.pageRefs.first,
              case .page(let page) = try await pageKey.load(using: repository) else { throw ReaderError.invalidResponse }
        #expect(page.imageURL != nil && page.ownerRef == chapter.key)
    }
}
