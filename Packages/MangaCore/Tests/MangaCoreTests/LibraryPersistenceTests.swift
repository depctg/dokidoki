import Foundation
import GRDB
import Testing
@testable import MangaCore

struct LibraryPersistenceTests {
    private let manga = ObjectKey(ruleID: "fixture", identityURL: URL(string: "https://example.test/manga")!)
    private let chapter = ObjectKey(ruleID: "fixture", identityURL: URL(string: "https://example.test/chapter")!)

    @Test func removingEntriesPreservesResumeAndReadingRestoresRecent() async throws {
        let store = try ObjectStore()
        let position = ReadingPosition(mangaKey: manga, chapterKey: chapter, sourcePageKey: .page(owner: chapter, index: 2),
            fractionalOffset: 0.4, title: "Chapter three", mangaTitle: "A story", pageNumber: 3, totalPages: 20,
            updatedAt: Date(timeIntervalSince1970: 12345))
        let repository = try ObjectRepository(store: store, rules: [])
        let object = MangaObject(key: manga, sourceURL: manga.identityURL, title: "A story")
        try await position.save(using: repository, manga: object)
        try await object.toggleStar(using: repository)
        try await object.hideFromRecent(using: repository)
        try store.clearContent()
        #expect(try store.positions(includeHidden: false).isEmpty)
        let retained = try #require(store.positions().first)
        #expect(retained.fractionalOffset == 0.4)
        #expect(retained.pageNumber == 3 && retained.totalPages == 20)
        #expect(retained.updatedAt == position.updatedAt)
        #expect(try store.savedManga().first?.isStarred == true)
        try await object.toggleStar(using: repository)
        #expect(try store.savedManga().first?.isStarred == false)
        try await object.removeFromLibrary(using: repository)
        #expect(try store.savedManga().isEmpty)
        #expect(try store.positions().first?.chapterKey == chapter)
        try await position.save(using: repository)
        #expect(try store.positions(includeHidden: false).count == 1)
    }

    @Test(arguments: [false, true], [false, true])
    func legacyDatabasesMigrateIntoDurableMangaObjects(latestLegacy: Bool, cached: Bool) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let manga = ObjectKey(ruleID: "custom|rule", identityURL: self.manga.identityURL)
        let chapter = ObjectKey(ruleID: manga.ruleID, identityURL: self.chapter.identityURL)
        let oldPosition = ReadingPosition(mangaKey: manga, chapterKey: chapter, sourcePageKey: .page(owner: chapter, index: 1), fractionalOffset: 0.25, title: "Chapter two")
        let oldManga = MangaObject(key: manga, sourceURL: manga.identityURL, title: "A story", chapterRefs: [ContentReference(key: chapter, title: "Chapter two")])
        // Build the shipped schema directly; do not construct a new store and partially undo its migrations.
        do {
            let db = try DatabaseQueue(path: path)
            try db.write { db in
                try db.execute(sql: """
                    CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
                    INSERT INTO grdb_migrations VALUES ('v1');
                    CREATE TABLE objects (key TEXT PRIMARY KEY, kind TEXT NOT NULL, payload BLOB NOT NULL, ruleVersion INTEGER NOT NULL, fetchedAt DOUBLE NOT NULL, expiresAt DOUBLE NOT NULL, ownerKey TEXT);
                    CREATE TABLE rules (id TEXT PRIMARY KEY, version INTEGER NOT NULL, payload BLOB NOT NULL);
                    CREATE TABLE readingState (mangaKey TEXT PRIMARY KEY, payload BLOB NOT NULL, updatedAt DOUBLE NOT NULL);
                    CREATE TABLE savedManga (key TEXT PRIMARY KEY, payload BLOB NOT NULL);
                    CREATE TABLE preferences (key TEXT PRIMARY KEY, payload BLOB NOT NULL);
                    """)
                var savedPayload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SavedManga(key: manga, title: "A story", isStarred: true))) as! [String: Any]
                if !latestLegacy { savedPayload.removeValue(forKey: "isStarred") }
                try db.execute(sql: "INSERT INTO savedManga VALUES (?, ?)", arguments: [manga.id, try JSONSerialization.data(withJSONObject: savedPayload)])
                try db.execute(sql: "INSERT INTO readingState VALUES (?, ?, ?)", arguments: [manga.id, try JSONEncoder().encode(oldPosition), oldPosition.updatedAt.timeIntervalSince1970])
                if cached {
                    try db.execute(sql: "INSERT INTO objects VALUES (?, 'manga', ?, 1, 0, 0, NULL)", arguments: [manga.id, try JSONEncoder().encode(ContentObject.manga(oldManga))])
                }
                if latestLegacy {
                    try db.execute(sql: """
                        ALTER TABLE objects ADD COLUMN ruleID TEXT;
                        ALTER TABLE objects RENAME COLUMN expiresAt TO accessedAt;
                        ALTER TABLE objects ADD COLUMN priority INTEGER NOT NULL DEFAULT 1;
                        ALTER TABLE readingState ADD COLUMN hidden INTEGER NOT NULL DEFAULT 1;
                        CREATE TABLE mangaReadingState (mangaKey TEXT PRIMARY KEY, payload BLOB NOT NULL);
                        INSERT INTO grdb_migrations VALUES ('v2RuleOwnership'), ('v3RecentVisibility'), ('v4ChapterReadingStatus'), ('v5PriorityCache');
                        """)
                    try db.execute(sql: "INSERT INTO mangaReadingState VALUES (?, ?)", arguments: [manga.id, try JSONEncoder().encode([chapter: ChapterReadingStatus.read])])
                }
            }
        }
        let upgraded = try ObjectStore(path: path)
        #expect(try upgraded.savedManga().first?.isStarred == latestLegacy)
        let position = try #require(upgraded.positions().first)
        #expect(position.sourcePageKey == oldPosition.sourcePageKey && position.fractionalOffset == 0.25)
        #expect(position.pageNumber == nil && position.totalPages == nil)
        #expect(try upgraded.positions(includeHidden: false).isEmpty == latestLegacy)
        let retained = try #require(upgraded.libraryObjects().first)
        #expect(retained.chapterRefs == (cached ? oldManga.chapterRefs : []))
        #expect(retained.title == "A story")
        #expect(retained.readingStatus(for: chapter) == (latestLegacy ? .read : .reading))
        try upgraded.clearContent()
        #expect(try ObjectStore(path: path).libraryObjects().first == retained)
        try upgraded.hideRecent(manga)
        #expect(try upgraded.positions(includeHidden: false).isEmpty)
    }
}
