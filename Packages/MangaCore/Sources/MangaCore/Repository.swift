import Foundation

public enum CacheHint: Sendable { case preferCache, refreshIfStale, forceRefresh, offlineOnly }

public actor ObjectRepository {
    public let store: ObjectStore
    private var registry: RuleRegistry
    public nonisolated let sender: RequestSender
    nonisolated let images: ImageLoader
    private struct Request {
        let id = UUID()
        let task: Task<ContentObject, Error>
        var consumers: Set<UUID> = []
    }
    private var inFlight: [ObjectKey: Request] = [:]
    private var generation = 0

    public init(store: ObjectStore, rules: [SiteRule], sender: RequestSender = RequestSender()) throws {
        self.store = store; registry = try RuleRegistry(rules: rules); self.sender = sender
        images = ImageLoader(sender: sender)
    }
    public func clearImages() async { await images.clear() }
    public func imageCacheUsage() async -> Int { await images.diskUsage() }
    public func installedRules() -> [SiteRule] { registry.rules }
    public func rule(for key: ObjectKey) throws -> SiteRule {
        guard let rule = registry.rules.first(where: { $0.id == key.ruleID }) else { throw ReaderError.missingRule }; return rule
    }
    public func key(for url: URL) throws -> ObjectKey { try registry.match(url).2 }
    public func install(_ rule: SiteRule) throws {
        try rule.validate()
        if let existing = registry.rules.first(where: { $0.id == rule.id }) {
            let identical = try rule.exported() == existing.exported()
            if identical { return }
            guard rule.version > existing.version else { throw ReaderError.invalidRule(String(localized: "Changed rules must increase their version.", bundle: .module)) }
        }
        let next = try RuleRegistry(rules: registry.rules.filter { $0.id != rule.id } + [rule])
        try store.saveRule(rule); invalidate(); registry = next
    }
    public func removeRule(_ id: String) throws {
        let next = try RuleRegistry(rules: registry.rules.filter { $0.id != id })
        try store.removeRule(id); invalidate(); registry = next
    }
    private func invalidate() { generation += 1; inFlight.values.forEach { $0.task.cancel() }; inFlight.removeAll() }
    public func clearContent() throws { invalidate(); try store.clearContent() }
    public func resolve(_ key: ObjectKey, hint: CacheHint = .refreshIfStale) async throws -> ContentObject {
        try Task.checkCancellation()
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
        if let request = inFlight[key] { return try await consume(request, key: key) }
        let (_, kind, canonical) = try registry.match(key.identityURL, ruleID: key.ruleID)
        guard canonical == key else { return try await resolve(canonical, hint: hint) }
        let currentGeneration = generation
        let task = Task<ContentObject, Error> { [sender] in
            let response = try await sender.send(.source(key, kind: kind, rule: rule))
            try Task.checkCancellation()
            let objects = try RuleExtractor().extract(data: response.data, responseURL: response.url, key: key, kind: kind, rule: rule)
            try Task.checkCancellation()
            guard currentGeneration == self.generation else { throw CancellationError() }
            try self.store.upsert(objects, version: rule.version, ttl: kind == .directory ? 900 : 86_400)
            guard let object = objects.first else { throw ReaderError.extraction(String(localized: "No content was found.", bundle: .module)) }; return object
        }
        let request = Request(task: task)
        inFlight[key] = request
        return try await consume(request, key: key)
    }
    private func consume(_ request: Request, key: ObjectKey) async throws -> ContentObject {
        let consumer = UUID()
        inFlight[key]?.consumers.insert(consumer)
        return try await withTaskCancellationHandler {
            defer { release(key, requestID: request.id, consumer: consumer) }
            let object = try await request.task.value
            try Task.checkCancellation()
            return object
        } onCancel: {
            Task { await self.release(key, requestID: request.id, consumer: consumer) }
        }
    }
    private func release(_ key: ObjectKey, requestID: UUID, consumer: UUID) {
        guard var request = inFlight[key], request.id == requestID else { return }
        request.consumers.remove(consumer)
        if request.consumers.isEmpty {
            // Keep shared resolutions alive only while at least one caller still needs them.
            request.task.cancel(); inFlight[key] = nil
        } else { inFlight[key] = request }
    }
}
