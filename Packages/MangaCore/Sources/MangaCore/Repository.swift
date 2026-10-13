import Foundation

public enum CacheHint: Sendable { case preferCache, refreshIfStale, forceRefresh, offlineOnly }

public actor ObjectRepository {
    public let store: ObjectStore
    private var registry: RuleRegistry
    private let fetcher: any SourceFetcher
    private var inFlight: [ObjectKey: Task<ContentObject, Error>] = [:]
    private var generation = 0

    public init(store: ObjectStore, rules: [SiteRule], fetcher: any SourceFetcher = DefaultSourceFetcher()) throws {
        self.store = store; registry = try RuleRegistry(rules: rules); self.fetcher = fetcher
    }
    public func installedRules() -> [SiteRule] { registry.rules }
    public func rule(for key: ObjectKey) throws -> SiteRule {
        guard let rule = registry.rules.first(where: { $0.id == key.ruleID }) else { throw ReaderError.missingRule }; return rule
    }
    public func key(for url: URL) throws -> ObjectKey { try registry.match(url).2 }
    public func install(_ rule: SiteRule) throws {
        try rule.validate()
        if let existing = registry.rules.first(where: { $0.id == rule.id }) {
            let identical = try rule.exported() == existing.exported()
            guard rule.version > existing.version || identical else { throw ReaderError.invalidRule("Changed rules must increase their version.") }
        }
        let next = try RuleRegistry(rules: registry.rules.filter { $0.id != rule.id } + [rule])
        try store.saveRule(rule); invalidate(); registry = next
    }
    public func removeRule(_ id: String) throws {
        let next = try RuleRegistry(rules: registry.rules.filter { $0.id != id })
        try store.removeRule(id); invalidate(); registry = next
    }
    private func invalidate() { generation += 1; inFlight.values.forEach { $0.cancel() }; inFlight.removeAll() }
    public func clearContent() throws { invalidate(); try store.clearContent() }
    public func resolve(_ key: ObjectKey, hint: CacheHint = .refreshIfStale) async throws -> ContentObject {
        let rule = try rule(for: key)
        let cached = try store.snapshot(key)
        if let cached, cached.ruleVersion == rule.version,
           hint == .offlineOnly || hint == .preferCache || (hint == .refreshIfStale && cached.expiresAt > Date()) { return cached.object }
        if hint == .offlineOnly { throw ReaderError.cacheMiss }
        if let owner = key.owner {
            _ = try await resolve(owner, hint: hint == .forceRefresh ? .forceRefresh : .refreshIfStale)
            if let child = try store.snapshot(key), child.ruleVersion == rule.version { return child.object }
            // A parent can outlive an individually missing child; rebuild the complete snapshot.
            _ = try await resolve(owner, hint: .forceRefresh)
            guard let child = try store.snapshot(key) else { throw ReaderError.cacheMiss }; return child.object
        }
        if let task = inFlight[key] { return try await task.value }
        let (_, kind, canonical) = try registry.match(key.identityURL, ruleID: key.ruleID)
        guard canonical == key else { return try await resolve(canonical, hint: hint) }
        let currentGeneration = generation
        let task = Task<ContentObject, Error> { [fetcher] in
            let response = try await fetcher.fetch(key.identityURL, rule: rule, kind: kind)
            try Task.checkCancellation()
            let objects = try RuleExtractor().extract(data: response.data, responseURL: response.url, key: key, kind: kind, rule: rule)
            try Task.checkCancellation()
            guard currentGeneration == self.generation else { throw CancellationError() }
            try self.store.upsert(objects, version: rule.version, ttl: kind == .directory ? 900 : 86_400)
            guard let object = objects.first else { throw ReaderError.extraction("No content was found.") }; return object
        }
        inFlight[key] = task
        defer { if generation == currentGeneration { inFlight[key] = nil } }
        return try await task.value
    }
}
