import Foundation
import GRDB

public struct ObjectSnapshot: Sendable {
    public let object: ContentObject
    public let ruleVersion: Int
    public let fetchedAt: Date
}
public struct ReadingPosition: Codable, Sendable, Equatable {
    public let mangaKey: ObjectKey
    public let chapterKey: ObjectKey
    public let sourcePageKey: ObjectKey
    public let fractionalOffset: Double
    public let title: String
    public let updatedAt: Date
    public let mangaTitle: String?
    public let pageNumber: Int?
    public let totalPages: Int?
    public let chapterListID: String?
    public init(mangaKey: ObjectKey, chapterKey: ObjectKey, sourcePageKey: ObjectKey, fractionalOffset: Double = 0, title: String,
                mangaTitle: String? = nil, pageNumber: Int? = nil, totalPages: Int? = nil, chapterListID: String? = nil, updatedAt: Date = Date()) {
        self.mangaKey = mangaKey; self.chapterKey = chapterKey; self.sourcePageKey = sourcePageKey
        self.fractionalOffset = min(1, max(0, fractionalOffset.isFinite ? fractionalOffset : 0)); self.title = title; self.updatedAt = updatedAt
        self.mangaTitle = mangaTitle; self.pageNumber = pageNumber; self.totalPages = totalPages
        self.chapterListID = chapterListID
    }
}
public struct SavedManga: Codable, Sendable, Equatable, Identifiable {
    public let key: ObjectKey
    public let title: String
    public var isStarred: Bool
    public var id: ObjectKey { key }
    public init(key: ObjectKey, title: String, isStarred: Bool = false) { self.key = key; self.title = title; self.isStarred = isStarred }
    private enum CodingKeys: String, CodingKey { case key, title, isStarred }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(ObjectKey.self, forKey: .key)
        title = try values.decode(String.self, forKey: .title)
        isStarred = try values.decodeIfPresent(Bool.self, forKey: .isStarred) ?? false
    }
}

/// GRDB serializes access. Parent/child snapshots are always written in one transaction.
public final class ObjectStore: Sendable {
    let db: DatabaseQueue
    private let cacheLimit: Int
    public init(path: String = ":memory:", cacheLimit: Int? = nil) throws {
        self.cacheLimit = max(0, cacheLimit ?? CachePolicy.metadataBytes)
        db = try DatabaseQueue(path: path)
        var migration = DatabaseMigrator()
        migration.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE objects (key TEXT PRIMARY KEY, kind TEXT NOT NULL, payload BLOB NOT NULL, ruleVersion INTEGER NOT NULL, fetchedAt DOUBLE NOT NULL, expiresAt DOUBLE NOT NULL, ownerKey TEXT);
                CREATE TABLE rules (id TEXT PRIMARY KEY, version INTEGER NOT NULL, payload BLOB NOT NULL);
                CREATE TABLE readingState (mangaKey TEXT PRIMARY KEY, payload BLOB NOT NULL, updatedAt DOUBLE NOT NULL);
                CREATE TABLE savedManga (key TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE TABLE preferences (key TEXT PRIMARY KEY, payload BLOB NOT NULL);
                """)
        }
        migration.registerMigration("v2RuleOwnership") { db in
            try db.execute(sql: "ALTER TABLE objects ADD COLUMN ruleID TEXT")
            for row in try Row.fetchAll(db, sql: "SELECT key, payload FROM objects") {
                let object = try JSONDecoder().decode(ContentObject.self, from: row["payload"])
                try db.execute(sql: "UPDATE objects SET ruleID = ? WHERE key = ?", arguments: [object.key.ruleID, row["key"] as String])
            }
        }
        migration.registerMigration("v3RecentVisibility") { db in
            try db.execute(sql: "ALTER TABLE readingState ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0")
        }
        migration.registerMigration("v4ChapterReadingStatus") { db in
            try db.execute(sql: "CREATE TABLE mangaReadingState (mangaKey TEXT PRIMARY KEY, payload BLOB NOT NULL)")
            for data in try Data.fetchAll(db, sql: "SELECT payload FROM readingState") {
                let position = try JSONDecoder().decode(ReadingPosition.self, from: data)
                let statuses = [position.chapterKey: ChapterReadingStatus.reading]
                try db.execute(sql: "INSERT INTO mangaReadingState VALUES (?, ?)", arguments: [position.mangaKey.id, try JSONEncoder().encode(statuses)])
            }
        }
        migration.registerMigration("v5PriorityCache") { db in
            try db.execute(sql: "ALTER TABLE objects RENAME COLUMN expiresAt TO accessedAt")
            try db.execute(sql: "UPDATE objects SET accessedAt = fetchedAt")
            try db.execute(sql: "ALTER TABLE objects ADD COLUMN priority INTEGER NOT NULL DEFAULT 1")
            for row in try Row.fetchAll(db, sql: "SELECT key, payload FROM objects") {
                let object = try JSONDecoder().decode(ContentObject.self, from: row["payload"])
                try db.execute(sql: "UPDATE objects SET priority = ? WHERE key = ?", arguments: [CachePolicy.priority(object), row["key"] as String])
            }
        }
        migration.registerMigration("v6MangaPersonalObjects") { try Self.migratePersonalObjects($0) }
        try migration.migrate(db)
        try db.write { try trimCache($0) }
    }
    public func snapshot(_ key: ObjectKey) throws -> ObjectSnapshot? {
        try snapshots([key])[key]
    }
    private func snapshots(_ keys: [ObjectKey]) throws -> [ObjectKey: ObjectSnapshot] {
        try db.write { db in
            var result: [ObjectKey: ObjectSnapshot] = [:]
            // One transaction per lookup batch; bound SQL parameters for long chapters.
            for start in stride(from: 0, to: keys.count, by: 500) {
                let ids = keys[start..<min(start + 500, keys.count)].map(\.id)
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                for row in try Row.fetchAll(db, sql: "SELECT * FROM objects WHERE key IN (\(placeholders))", arguments: StatementArguments(ids)) {
                    var object = try JSONDecoder().decode(ContentObject.self, from: row["payload"])
                    if case .manga(var manga) = object { manga.personalState = try Self.personalManga(manga.key, db: db)?.personalState; object = .manga(manga) }
                    result[object.key] = ObjectSnapshot(object: object, ruleVersion: row["ruleVersion"], fetchedAt: Date(timeIntervalSince1970: row["fetchedAt"]))
                }
                var arguments = StatementArguments([Date().timeIntervalSince1970]); arguments += StatementArguments(ids)
                try db.execute(sql: "UPDATE objects SET accessedAt = ? WHERE key IN (\(placeholders))", arguments: arguments)
            }
            return result
        }
    }
    /// The cache, rather than callers or objects, decides whether retained metadata
    /// satisfies a request. Incomplete known metadata remains usable for previews.
    func cachedObject(_ key: ObjectKey, version: Int, preview: Bool = false) throws -> ContentObject? {
        try cachedObjects([key], version: version, preview: preview)[key]
    }
    func cachedObjects(_ keys: [ObjectKey], version: Int, preview: Bool = false) throws -> [ObjectKey: ContentObject] {
        try snapshots(keys).compactMapValues { cached in
            guard cached.ruleVersion == version, cached.object.isComplete || (preview && cached.object.hasPreview) else { return nil }
            return cached.object
        }
    }
    public func upsert(_ objects: [ContentObject], version: Int, replacingChildren: Bool = true) throws {
        try db.write { db in
            let partialKeys = Set(objects.filter { !$0.isComplete }.map(\.key))
            if replacingChildren, let root = objects.first, root.kind != .page, !partialKeys.contains(root.key) {
                try db.execute(sql: "DELETE FROM objects WHERE ownerKey = ?", arguments: [root.key.id])
            }
            var preserved: Set<ObjectKey> = []
            for incoming in objects {
                if case .manga(let manga) = incoming, let old = try Self.personalManga(manga.key, db: db) {
                    let updated = Self.updatingMetadata(manga, in: old)
                    if updated != old { try Self.writePersonalManga(updated, db: db) }
                }
                var object = incoming
                if !incoming.isComplete,
                   let row = try Row.fetchOne(db, sql: "SELECT payload FROM objects WHERE key = ? AND ruleVersion = ?", arguments: [incoming.key.id, version]) {
                    let existing = try JSONDecoder().decode(ContentObject.self, from: row["payload"])
                    // Linked knowledge cannot erase a complete snapshot or change its fetch date.
                    if existing.isComplete { preserved.insert(incoming.key); continue }
                    switch (incoming, existing) {
                    case (.manga(let manga), .manga(let old)):
                        object = .manga(MangaObject(key: manga.key, sourceURL: manga.sourceURL, title: manga.title,
                            author: manga.author ?? old.author, summary: manga.summary ?? old.summary,
                            coverPageRef: manga.coverPageRef ?? old.coverPageRef,
                            rating: manga.rating ?? old.rating, status: manga.status ?? old.status, tags: manga.tags ?? old.tags))
                    case (.directory(let directory), .directory(let old)):
                        object = .directory(DirectoryObject(key: directory.key, sourceURL: directory.sourceURL, title: directory.title,
                            mangaRefs: directory.items ?? old.items, isPreview: true))
                    default: break
                    }
                }
                if case .page(let page) = object, let owner = page.ownerRef, preserved.contains(owner) { continue }
                let owner: String? = if case .page(let page) = object { page.ownerRef?.id } else { nil }
                let now = Date().timeIntervalSince1970
                try db.execute(sql: "INSERT OR REPLACE INTO objects VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [object.key.id, object.kind.rawValue, try JSONEncoder().encode(object), version, now, now, owner, object.key.ruleID, CachePolicy.priority(object)])
            }
            try trimCache(db)
        }
    }
    private func trimCache(_ db: Database) throws {
        var bytes = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(length(payload)), 0) FROM objects") ?? 0
        guard bytes > cacheLimit else { return }
        let entries = try Row.fetchAll(db, sql: "SELECT key, length(payload) AS bytes FROM objects ORDER BY priority, accessedAt, key")
        for row in entries where bytes > cacheLimit {
            try db.execute(sql: "DELETE FROM objects WHERE key = ?", arguments: [row["key"] as String])
            bytes -= row["bytes"] as Int
        }
    }

    public func rules() throws -> [SiteRule] {
        let rules = try db.read { db in try Data.fetchAll(db, sql: "SELECT payload FROM rules ORDER BY id").map(SiteRule.decode) }
        let order = try preference("ruleOrder", as: [String].self) ?? []
        return rules.sorted { (order.firstIndex(of: $0.id) ?? Int.max) < (order.firstIndex(of: $1.id) ?? Int.max) }
    }
    /// The first bundled file is the shipped default. Adopt a new default once;
    /// subsequent user ordering/removal survives launches and recipe updates.
    public func applyBundledRules(_ bundled: [SiteRule]) throws {
        if try preference("seeded", as: Bool.self) != true {
            for rule in bundled { try saveRule(rule) }
            try setRuleOrder(bundled.map(\.id))
            try setPreference("seeded", value: true)
        }
        for rule in bundled {
            if let installed = try rules().first(where: { $0.id == rule.id }), installed.version < rule.version { try saveRule(rule) }
        }
        if let first = bundled.first, try preference("bundledDefaultID", as: String.self) != first.id {
            if !((try rules()).contains { $0.id == first.id }) { try saveRule(first) }
            try setRuleOrder([first.id] + rules().map(\.id).filter { $0 != first.id })
            try setPreference("bundledDefaultID", value: first.id)
        }
    }
    public func setRuleOrder(_ ids: [String]) throws {
        let installed = try rules().map(\.id)
        guard ids.count == installed.count, Set(ids) == Set(installed) else { throw ReaderError.invalidRule(String(localized: "Rule order must contain each installed rule exactly once.", bundle: .module)) }
        try setPreference("ruleOrder", value: ids)
    }
    public func saveRule(_ rule: SiteRule) throws {
        let data = try rule.exported()
        try db.write { db in
            // New imports append once; recipe replacement preserves their position.
            let orderData = try Data.fetchOne(db, sql: "SELECT payload FROM preferences WHERE key = 'ruleOrder'")
            let preferred = try orderData.map { try JSONDecoder().decode([String].self, from: $0) } ?? []
            var order = try String.fetchAll(db, sql: "SELECT id FROM rules ORDER BY id").sorted {
                (preferred.firstIndex(of: $0) ?? Int.max) < (preferred.firstIndex(of: $1) ?? Int.max)
            }
            if !order.contains(rule.id) { order.append(rule.id) }
            try db.execute(sql: "INSERT OR REPLACE INTO rules VALUES (?, ?, ?)", arguments: [rule.id, rule.version, data])
            try db.execute(sql: "INSERT OR REPLACE INTO preferences VALUES ('ruleOrder', ?)", arguments: [try JSONEncoder().encode(order)])
        }
    }
    public func removeRule(_ id: String) throws {
        try db.write {
            try $0.execute(sql: "DELETE FROM objects WHERE ruleID = ?", arguments: [id])
            try $0.execute(sql: "DELETE FROM rules WHERE id = ?", arguments: [id])
            if let data = try Data.fetchOne($0, sql: "SELECT payload FROM preferences WHERE key = 'ruleOrder'") {
                let order = try JSONDecoder().decode([String].self, from: data).filter { $0 != id }
                try $0.execute(sql: "UPDATE preferences SET payload = ? WHERE key = 'ruleOrder'", arguments: [try JSONEncoder().encode(order)])
            }
        }
    }
    public func clearContent() throws { try db.write { try $0.execute(sql: "DELETE FROM objects") } }
    public func preference<T: Decodable>(_ key: String, as: T.Type) throws -> T? {
        try db.read { db in try Data.fetchOne(db, sql: "SELECT payload FROM preferences WHERE key = ?", arguments: [key]).map { try JSONDecoder().decode(T.self, from: $0) } }
    }
    public func setPreference<T: Encodable>(_ key: String, value: T) throws {
        let data = try JSONEncoder().encode(value)
        try db.write { try $0.execute(sql: "INSERT OR REPLACE INTO preferences VALUES (?, ?)", arguments: [key, data]) }
    }
}
