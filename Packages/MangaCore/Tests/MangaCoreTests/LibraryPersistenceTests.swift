import Foundation
import GRDB
import Testing
@testable import MangaCore

struct LibraryPersistenceTests {
    private let manga = ObjectKey(ruleID: "fixture", identityURL: URL(string: "https://example.test/manga")!)
    private let chapter = ObjectKey(ruleID: "fixture", identityURL: URL(string: "https://example.test/chapter")!)

    @Test func removingEntriesPreservesResumeAndReadingRestoresRecent() throws {
        let store = try ObjectStore()
        let position = ReadingPosition(mangaKey: manga, chapterKey: chapter, sourcePageKey: .page(owner: chapter, index: 2),
            fractionalOffset: 0.4, title: "Chapter three", mangaTitle: "A story", pageNumber: 3, totalPages: 20,
            updatedAt: Date(timeIntervalSince1970: 12345))
        let saved = SavedManga(key: manga, title: "A story", isStarred: true)
        try store.savePosition(position)
        try store.setSaved(saved, saved: true)
        try store.hideRecent(manga)
        try store.clearContent()
        #expect(try store.positions(includeHidden: false).isEmpty)
        let retained = try #require(store.positions().first)
        #expect(retained.fractionalOffset == 0.4)
        #expect(retained.pageNumber == 3 && retained.totalPages == 20)
        #expect(retained.updatedAt == position.updatedAt)
        #expect(try store.savedManga().first?.isStarred == true)
        try store.setSaved(saved, saved: false)
        #expect(try store.savedManga().isEmpty)
        #expect(try store.positions().first?.chapterKey == chapter)
        try store.savePosition(position)
        #expect(try store.positions(includeHidden: false).count == 1)
    }

    @Test func legacyDatabaseAndPayloadsUpgradeWithoutLosingReadingState() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let oldPosition = ReadingPosition(mangaKey: manga, chapterKey: chapter, sourcePageKey: .page(owner: chapter, index: 1), fractionalOffset: 0.25, title: "Chapter two")
        let oldSaved = SavedManga(key: manga, title: "A story")
        // Reproduce the previously shipped schema and JSON payloads, without new optional fields.
        do {
            let store = try ObjectStore(path: path)
            try store.savePosition(oldPosition); try store.setSaved(oldSaved, saved: true)
            let db = try DatabaseQueue(path: path)
            try db.write { db in
                try db.execute(sql: "ALTER TABLE readingState DROP COLUMN hidden")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v3RecentVisibility'")
                var payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldSaved)) as! [String: Any]
                payload.removeValue(forKey: "isStarred")
                try db.execute(sql: "UPDATE savedManga SET payload = ?", arguments: [try JSONSerialization.data(withJSONObject: payload)])
            }
        }
        let upgraded = try ObjectStore(path: path)
        #expect(try upgraded.savedManga().first?.isStarred == false)
        let position = try #require(upgraded.positions(includeHidden: false).first)
        #expect(position.sourcePageKey == oldPosition.sourcePageKey)
        #expect(position.fractionalOffset == 0.25)
        #expect(position.pageNumber == nil && position.totalPages == nil)
        try upgraded.hideRecent(manga)
        #expect(try upgraded.positions(includeHidden: false).isEmpty)
        #expect(try upgraded.positions().count == 1)
    }
}
