import Foundation
import GRDB

public struct ObjectSnapshot: Sendable {
    public let object: ContentObject
    public let ruleVersion: Int
    public let expiresAt: Date
}
public struct ReadingPosition: Codable, Sendable {
    public let mangaKey: ObjectKey
    public let chapterKey: ObjectKey
    public let sourcePageKey: ObjectKey
    public let fractionalOffset: Double
    public let title: String
    public let updatedAt: Date
    public init(mangaKey: ObjectKey, chapterKey: ObjectKey, sourcePageKey: ObjectKey, fractionalOffset: Double = 0, title: String) {
        self.mangaKey = mangaKey; self.chapterKey = chapterKey; self.sourcePageKey = sourcePageKey
        self.fractionalOffset = min(1, max(0, fractionalOffset.isFinite ? fractionalOffset : 0)); self.title = title; updatedAt = Date()
    }
}
public struct SavedManga: Codable, Sendable, Identifiable {
    public let key: ObjectKey
    public let title: String
    public var id: ObjectKey { key }
    public init(key: ObjectKey, title: String) { self.key = key; self.title = title }
}

/// GRDB serializes access. Parent/child snapshots are always written in one transaction.
public final class ObjectStore: Sendable {
    private let db: DatabaseQueue
    public init(path: String = ":memory:") throws {
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
        try migration.migrate(db)
    }
    public func snapshot(_ key: ObjectKey) throws -> ObjectSnapshot? {
        try db.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM objects WHERE key = ?", arguments: [key.id]) else { return nil }
            return ObjectSnapshot(object: try JSONDecoder().decode(ContentObject.self, from: row["payload"]), ruleVersion: row["ruleVersion"], expiresAt: Date(timeIntervalSince1970: row["expiresAt"]))
        }
    }
    public func upsert(_ objects: [ContentObject], version: Int, ttl: TimeInterval) throws {
        try db.write { db in
            if let root = objects.first, root.kind != .page {
                try db.execute(sql: "DELETE FROM objects WHERE ownerKey = ?", arguments: [root.key.id])
            }
            for object in objects {
                let owner: String? = if case .page(let page) = object { page.ownerRef?.id } else { nil }
                try db.execute(sql: "INSERT OR REPLACE INTO objects VALUES (?, ?, ?, ?, ?, ?, ?, ?)", arguments: [object.key.id, object.kind.rawValue, try JSONEncoder().encode(object), version, Date().timeIntervalSince1970, Date().addingTimeInterval(ttl).timeIntervalSince1970, owner, object.key.ruleID])
            }
        }
    }
    public func rules() throws -> [SiteRule] {
        try db.read { db in try Data.fetchAll(db, sql: "SELECT payload FROM rules ORDER BY id").map(SiteRule.decode) }
    }
    public func saveRule(_ rule: SiteRule) throws {
        let data = try rule.exported()
        try db.write { try $0.execute(sql: "INSERT OR REPLACE INTO rules VALUES (?, ?, ?)", arguments: [rule.id, rule.version, data]) }
    }
    public func removeRule(_ id: String) throws {
        try db.write {
            try $0.execute(sql: "DELETE FROM objects WHERE ruleID = ?", arguments: [id])
            try $0.execute(sql: "DELETE FROM rules WHERE id = ?", arguments: [id])
        }
    }
    public func clearContent() throws { try db.write { try $0.execute(sql: "DELETE FROM objects") } }
    public func savePosition(_ position: ReadingPosition) throws {
        try db.write { try $0.execute(sql: "INSERT OR REPLACE INTO readingState VALUES (?, ?, ?)", arguments: [position.mangaKey.id, try JSONEncoder().encode(position), position.updatedAt.timeIntervalSince1970]) }
    }
    public func positions() throws -> [ReadingPosition] {
        try db.read { try Data.fetchAll($0, sql: "SELECT payload FROM readingState ORDER BY updatedAt DESC").map { try JSONDecoder().decode(ReadingPosition.self, from: $0) } }
    }
    public func savedManga() throws -> [SavedManga] {
        try db.read { try Data.fetchAll($0, sql: "SELECT payload FROM savedManga ORDER BY key").map { try JSONDecoder().decode(SavedManga.self, from: $0) } }
    }
    public func setSaved(_ manga: SavedManga, saved: Bool) throws {
        try db.write { db in
            if saved { try db.execute(sql: "INSERT OR REPLACE INTO savedManga VALUES (?, ?)", arguments: [manga.key.id, try JSONEncoder().encode(manga)]) }
            else { try db.execute(sql: "DELETE FROM savedManga WHERE key = ?", arguments: [manga.key.id]) }
        }
    }
    public func preference<T: Decodable>(_ key: String, as: T.Type) throws -> T? {
        try db.read { db in try Data.fetchOne(db, sql: "SELECT payload FROM preferences WHERE key = ?", arguments: [key]).map { try JSONDecoder().decode(T.self, from: $0) } }
    }
    public func setPreference<T: Encodable>(_ key: String, value: T) throws {
        let data = try JSONEncoder().encode(value)
        try db.write { try $0.execute(sql: "INSERT OR REPLACE INTO preferences VALUES (?, ?)", arguments: [key, data]) }
    }
}
