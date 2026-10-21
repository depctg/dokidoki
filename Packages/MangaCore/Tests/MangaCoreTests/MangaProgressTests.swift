import Foundation
import Testing
@testable import MangaCore

struct MangaProgressTests {
    private let key = ObjectKey(ruleID: "fixture", identityURL: URL(string: "https://example.test/manga")!)
    private func manga(_ count: Int) -> MangaObject {
        MangaObject(key: key, sourceURL: key.identityURL, title: "Series", chapterLists: [
            ChapterList(id: "chapters", chapters: (0..<count).map { index in
                ContentReference(key: ObjectKey(ruleID: key.ruleID, identityURL: URL(string: "https://example.test/chapter/\(index)")!), title: "Chapter \(index)")
            })])
    }
    private func position(_ manga: MangaObject, chapter: Int, page: Int, fraction: Double = 0) -> ReadingPosition {
        let ref = manga.chapterRefs[chapter]
        return ReadingPosition(mangaKey: key, chapterKey: ref.key, sourcePageKey: .page(owner: ref.key, index: page - 1),
            fractionalOffset: fraction, title: ref.title, pageNumber: page, totalPages: 4)
    }
    @Test func progressExcludesIgnoredChaptersAndRefreshDiscoversNewWork() throws {
        let store = try ObjectStore(), original = manga(2)
        try store.upsert([.manga(original)], version: 1)
        try store.savePosition(position(original, chapter: 0, page: 2, fraction: 0.5))
        #expect(try store.libraryObjects().first?.personalState?.progress.fraction == 0.1875)
        var updated = try store.setReadingStatus(.ignored, chapters: [original.chapterRefs[1].key], in: original)
        #expect(updated.personalState?.progress.fraction == 0.375)
        try store.savePosition(position(original, chapter: 0, page: 4), completed: true)
        #expect(try store.libraryObjects().first?.personalState?.progress.state == .finished)
        let expanded = manga(3)
        try store.upsert([.manga(expanded)], version: 1)
        updated = try store.readingState(for: expanded)
        #expect(updated.personalState?.progress.state == .new && updated.personalState?.progress.fraction == 0.5)
        // Repeated snapshots and linked previews must not consume the new-chapters state.
        try store.upsert([.manga(expanded)], version: 1)
        try store.upsert([.manga(MangaObject(key: key, sourceURL: key.identityURL, title: "Series"))], version: 1)
        #expect(try store.libraryObjects().first?.personalState?.progress.state == .new)
        try store.savePosition(position(expanded, chapter: 2, page: 1))
        #expect(try store.libraryObjects().first?.personalState?.progress.state == .reading)
        try store.savePosition(position(expanded, chapter: 2, page: 4), completed: true)
        #expect(try store.libraryObjects().first?.personalState?.progress.state == .finished)
        // Explicit Unread reverses sticky completion, without losing the last source position.
        updated = try store.setReadingStatus(.unread, chapters: [expanded.chapterRefs[0].key], in: expanded)
        #expect(updated.personalState?.progress.state == .reading && updated.personalState?.progress.fraction == 0.5)
        #expect(updated.personalState?.position?.chapterKey == expanded.chapterRefs[2].key)
    }
    @Test(arguments: [false, true])
    func firstPersonalActionRetainsKnownMetadataWhenCacheDeclinesIt(saveToLibrary: Bool) async throws {
        let store = try ObjectStore(cacheLimit: 0), original = manga(1)
        try store.upsert([.manga(original)], version: 1)
        #expect(try store.snapshot(key) == nil)
        if saveToLibrary {
            try store.setSaved(SavedManga(key: key, title: original.title, isStarred: true), saved: true, manga: original)
        } else {
            try store.savePosition(position(original, chapter: 0, page: 4), completed: true, manga: original)
        }
        let retained = try #require(store.libraryObjects().first)
        #expect(retained.chapters == original.chapters)
        #expect(retained.personalState?.progress.fraction == (saveToLibrary ? 0 : 1))
        // Core observation publishes source changes as well as personal edits.
        var updates = store.libraryUpdates().makeAsyncIterator()
        #expect(try await updates.next()?.first == retained)
        try store.upsert([.manga(manga(2))], version: 1)
        let refreshed = try #require(try await updates.next()?.first)
        #expect(refreshed.chapters?.count == 2)
        #expect(refreshed.personalState?.progress.state == (saveToLibrary ? .reading : .new))
        #expect(try store.snapshot(key) == nil)
    }
    @Test(arguments: ["position", "saved", "status"])
    func personalActionsCannotReplaceRefreshedCatalogWithRetainedSnapshot(action: String) throws {
        let store = try ObjectStore(cacheLimit: 0), original = manga(1)
        try store.savePosition(position(original, chapter: 0, page: 4), completed: true, manga: original)
        try store.upsert([.manga(manga(2))], version: 1)
        switch action {
        case "position": try store.savePosition(position(original, chapter: 0, page: 4), completed: true, manga: original)
        case "saved": try store.setSaved(SavedManga(key: key, title: original.title), saved: true, manga: original)
        default: _ = try store.setReadingStatus(.read, chapters: original.chapterRefs.map(\.key), in: original)
        }
        let retained = try #require(store.libraryObjects().first)
        #expect(retained.chapters?.count == 2)
        #expect(retained.personalState?.progress.state == .new && retained.personalState?.progress.fraction == 0.5)
    }
    @Test func groupActionsAreAtomicDeduplicateKeysAndSurviveEviction() async throws {
        let store = try ObjectStore(cacheLimit: 0), original = manga(3)
        let repository = try ObjectRepository(store: store, rules: [])
        let keys = original.chapterRefs.map(\.key)
        let foreign = ObjectKey(ruleID: "other", identityURL: key.identityURL)
        var updated = try await original.setReadingStatus(.read, for: keys + keys + [foreign], using: repository)
        #expect(updated.readingStatus(for: keys) == .read)
        #expect(updated.chapterStatuses?.count == keys.count)
        #expect(updated.personalState?.progress.state == .finished)
        updated = try await original.setReadingStatus(.ignored, for: keys, using: repository)
        #expect(updated.readingStatus(for: keys) == .ignored && updated.personalState?.progress.state == .finished)
        try store.savePosition(position(original, chapter: 0, page: 4), completed: true)
        #expect(try await original.readingState(using: repository).readingStatus(for: keys) == .ignored)
        updated = try await original.setReadingStatus(.unread, for: keys, using: repository)
        try store.clearContent()
        #expect(try await original.readingState(using: repository).readingStatus(for: keys) == .unread)
        #expect(updated.personalState?.progress.fraction == 0)
        #expect(try JSONDecoder().decode(MangaObject.self, from: JSONEncoder().encode(updated)) == updated)
    }
}
