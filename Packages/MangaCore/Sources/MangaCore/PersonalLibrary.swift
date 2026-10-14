import Foundation
import GRDB

extension ObjectStore {
    /// All durable manga objects, including hidden history and removed library entries.
    /// Removal changes membership, never deletes progress.
    public func libraryObjects() throws -> [MangaObject] {
        try db.read(Self.fetchLibrary)
    }
    /// Database observation publishes both personal edits and refreshed source catalogs.
    public func libraryUpdates() -> some AsyncSequence<[MangaObject], any Error> & Sendable {
        ValueObservation.tracking(Self.fetchLibrary).removeDuplicates()
            .values(in: db, bufferingPolicy: .bufferingNewest(1))
    }
    private static func fetchLibrary(_ db: Database) throws -> [MangaObject] {
        try Data.fetchAll(db, sql: "SELECT payload FROM mangaLibrary ORDER BY mangaKey")
            .map { try JSONDecoder().decode(MangaObject.self, from: $0) }
    }
    public func positions(includeHidden: Bool = true) throws -> [ReadingPosition] {
        try libraryObjects().filter { includeHidden || $0.personalState?.isRecentHidden != true }
            .compactMap { $0.personalState?.position }.sorted { $0.updatedAt > $1.updatedAt }
    }
    public func savedManga() throws -> [SavedManga] {
        try libraryObjects().compactMap { manga in
            guard let state = manga.personalState, state.isSaved else { return nil }
            return SavedManga(key: manga.key, title: manga.title, isStarred: state.isStarred)
        }
    }
    public func savePosition(_ position: ReadingPosition, completed: Bool = false, manga known: MangaObject? = nil) throws {
        try db.write { db in
            var manga = try Self.mangaForPersonalAction(position.mangaKey, title: position.mangaTitle ?? position.title, known: known, db: db)
            if position.mangaKey == position.chapterKey, manga.chapters == nil {
                manga = Self.updatingMetadata(MangaObject(key: manga.key, sourceURL: manga.sourceURL, title: manga.title,
                    chapterRefs: [ContentReference(key: position.chapterKey, title: position.title)]), in: manga)
            }
            var state = manga.personalState ?? MangaPersonalState()
            state.position = position
            state.isRecentHidden = false
            let old = state.chapterProgress[position.chapterKey]
            let status: ChapterReadingStatus = old?.status == .ignored ? .ignored : completed || old?.status == .read ? .read : .reading
            let fraction: Double
            if status == .read { fraction = 1 }
            else if let page = position.pageNumber, let total = position.totalPages, total > 0 {
                fraction = max(old?.fraction ?? 0, min(1, max(0, (Double(page - 1) + position.fractionalOffset) / Double(total))))
            } else { fraction = old?.fraction ?? 0 }
            state.chapterProgress[position.chapterKey] = ChapterProgress(status: status, fraction: fraction)
            manga.personalState = state; manga.updateProgress()
            try Self.writePersonalManga(manga, db: db)
        }
    }
    public func hideRecent(_ key: ObjectKey) throws {
        try db.write { db in
            guard var manga = try Self.personalManga(key, db: db), var state = manga.personalState else { return }
            state.isRecentHidden = true; manga.personalState = state
            try Self.writePersonalManga(manga, db: db)
        }
    }
    public func setSaved(_ savedManga: SavedManga, saved: Bool, manga known: MangaObject? = nil) throws {
        try db.write { db in
            var manga = try Self.mangaForPersonalAction(savedManga.key, title: savedManga.title, known: known, db: db)
            var state = manga.personalState ?? MangaPersonalState()
            state.isSaved = saved; state.isStarred = saved && savedManga.isStarred
            manga.personalState = state; manga.updateProgress()
            try Self.writePersonalManga(manga, db: db)
        }
    }
    func setReadingStatus(_ status: ChapterReadingStatus, chapters: [ObjectKey], in source: MangaObject) throws -> MangaObject {
        try db.write { db in
            var manga = try Self.mangaForPersonalAction(source.key, title: source.title, known: source, db: db)
            var state = manga.personalState ?? MangaPersonalState()
            let allowed = Set(manga.chapterRefs.map(\.key))
            for key in Set(chapters).intersection(allowed) {
                state.chapterProgress[key] = ChapterProgress(status: status, fraction: status == .read ? 1 : 0)
            }
            manga.personalState = state; manga.updateProgress()
            try Self.writePersonalManga(manga, db: db)
            return manga
        }
    }
    func readingState(for manga: MangaObject) throws -> MangaObject {
        try db.read { db in
            var manga = manga
            manga.personalState = try Self.personalManga(manga.key, db: db)?.personalState
            return manga
        }
    }
    static func personalManga(_ key: ObjectKey, db: Database) throws -> MangaObject? {
        try Data.fetchOne(db, sql: "SELECT payload FROM mangaLibrary WHERE mangaKey = ?", arguments: [key.id])
            .map { try JSONDecoder().decode(MangaObject.self, from: $0) }
    }
    static func writePersonalManga(_ manga: MangaObject, db: Database) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO mangaLibrary VALUES (?, ?)", arguments: [manga.key.id, try JSONEncoder().encode(manga)])
    }
    private static func mangaForPersonalAction(_ key: ObjectKey, title: String, known: MangaObject? = nil, db: Database) throws -> MangaObject {
        let old = try personalManga(key, db: db)
        // Source upsert owns catalog replacement. A retained view/reader snapshot
        // may seed missing metadata, but cannot roll back a newer complete catalog.
        if let old, old.chapters != nil { return old }
        if let known, known.key == key { return updatingMetadata(known, in: old ?? known) }
        if let data = try Data.fetchOne(db, sql: "SELECT payload FROM objects WHERE key = ?", arguments: [key.id]),
           case .manga(let cached) = try JSONDecoder().decode(ContentObject.self, from: data) {
            return updatingMetadata(cached, in: old ?? cached)
        }
        return old ?? MangaObject(key: key, sourceURL: key.identityURL, title: title)
    }
    /// Source refresh updates durable metadata, while linked excerpts cannot erase its catalog.
    static func updatingMetadata(_ source: MangaObject, in old: MangaObject) -> MangaObject {
        if source.chapters == nil, old.chapters != nil { return old }
        var source = source
        source.personalState = old.personalState ?? MangaPersonalState(); source.updateProgress()
        return source
    }

    static func migratePersonalObjects(_ db: Database) throws {
        try db.execute(sql: "CREATE TABLE mangaLibrary (mangaKey TEXT PRIMARY KEY, payload BLOB NOT NULL)")
        var entries: [ObjectKey: MangaObject] = [:]
        func entry(_ key: ObjectKey, title: String) throws -> MangaObject {
            if let existing = entries[key] { return existing }
            return try mangaForPersonalAction(key, title: title, db: db)
        }
        for row in try Row.fetchAll(db, sql: "SELECT payload, hidden FROM readingState") {
            let position = try JSONDecoder().decode(ReadingPosition.self, from: row["payload"])
            var manga = try entry(position.mangaKey, title: position.mangaTitle ?? position.title)
            var state = MangaPersonalState()
            state.position = position
            state.isRecentHidden = (row["hidden"] as Int) != 0
            manga.personalState = state; entries[manga.key] = manga
        }
        for data in try Data.fetchAll(db, sql: "SELECT payload FROM savedManga") {
            let saved = try JSONDecoder().decode(SavedManga.self, from: data)
            var manga = try entry(saved.key, title: saved.title)
            var state = manga.personalState ?? MangaPersonalState()
            state.isSaved = true; state.isStarred = saved.isStarred
            // A legacy position may contain only the chapter title. The saved manga
            // title is authoritative when source metadata has already been evicted.
            if manga.chapters == nil, state.position?.mangaTitle == nil {
                manga = MangaObject(key: saved.key, sourceURL: manga.sourceURL, title: saved.title,
                    author: manga.author, summary: manga.summary, coverPageRef: manga.coverPageRef,
                    rating: manga.rating, status: manga.status, tags: manga.tags)
            }
            manga.personalState = state; entries[manga.key] = manga
        }
        for row in try Row.fetchAll(db, sql: "SELECT mangaKey, payload FROM mangaReadingState") {
            let id: String = row["mangaKey"]
            let statuses = try JSONDecoder().decode([ObjectKey: ChapterReadingStatus].self, from: row["payload"])
            // Recover the structured rule identity; IDs themselves may contain '|'.
            let key: ObjectKey
            if let existing = entries.keys.first(where: { $0.id == id }) { key = existing }
            else if let chapter = statuses.keys.first, id.hasPrefix(chapter.ruleID + "|"),
                    let url = URL(string: String(id.dropFirst(chapter.ruleID.count + 1))) {
                key = ObjectKey(ruleID: chapter.ruleID, identityURL: url)
            } else { throw ReaderError.invalidResponse }
            var manga = try entry(key, title: entries[key]?.title ?? key.identityURL.lastPathComponent)
            var state = manga.personalState ?? MangaPersonalState()
            for (chapter, status) in statuses {
                let position = state.position
                var fraction = status == .read ? 1.0 : 0.0
                if status != .read, let position, position.chapterKey == chapter, let total = position.totalPages, total > 0 {
                    fraction = (Double((position.pageNumber ?? 1) - 1) + position.fractionalOffset) / Double(total)
                }
                state.chapterProgress[chapter] = ChapterProgress(status: status, fraction: min(1, max(0, fraction)))
            }
            manga.personalState = state; entries[key] = manga
        }
        for var manga in entries.values {
            manga.updateProgress(); try writePersonalManga(manga, db: db)
        }
        try db.execute(sql: "DROP TABLE readingState; DROP TABLE savedManga; DROP TABLE mangaReadingState")
    }
}
