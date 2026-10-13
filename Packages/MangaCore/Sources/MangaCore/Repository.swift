import Foundation

public enum CacheHint: Sendable { case preferCache, refreshIfStale, forceRefresh, offlineOnly }

public actor ObjectRepository {
    public let store: ObjectStore
    private var registry: RuleRegistry
    private let sender: RequestSender
    nonisolated let images: ImageLoader
    private struct Request {
        let id = UUID()
        let task: Task<ContentObject, Error>
        var consumers: [UUID: CheckedContinuation<ContentObject, Error>] = [:]
    }
    private var inFlight: [ObjectKey: Request] = [:]
    private var directoryFlights: [ObjectKey: Request] = [:]
    private var generation = 0
    private var backgroundLoading: Bool

    public init(store: ObjectStore, rules: [SiteRule], sender: RequestSender = RequestSender(fetcher: RenderedSourceFetcher())) throws {
        self.store = store; registry = try RuleRegistry(rules: rules); self.sender = sender
        images = ImageLoader(sender: sender)
        backgroundLoading = try store.preference("backgroundLoading", as: Bool.self) ?? true
    }
    public func clearImages() async { await images.clear(); await sender.invalidateResources() }
    public func imageCacheUsage() async -> Int { await images.diskUsage() }
    public func setBackgroundLoading(_ enabled: Bool) async throws {
        try store.setPreference("backgroundLoading", value: enabled)
        guard backgroundLoading != enabled else { return }
        backgroundLoading = enabled; await invalidate()
    }
    public func installedRules() -> [SiteRule] { registry.rules }
    public func rule(for key: ObjectKey) throws -> SiteRule {
        guard let rule = registry.rules.first(where: { $0.id == key.ruleID }) else { throw ReaderError.missingRule }; return rule
    }
    public func match(_ url: URL) throws -> (key: ObjectKey, kind: ContentKind) {
        let (_, kind, key) = try registry.match(url)
        return (key, kind)
    }
    public func key(for url: URL) throws -> ObjectKey { try match(url).key }
    public func install(_ rule: SiteRule) async throws {
        try rule.validate()
        if let existing = registry.rules.first(where: { $0.id == rule.id }) {
            let identical = try rule.exported() == existing.exported()
            if identical { return }
            guard rule.version > existing.version else { throw ReaderError.invalidRule(String(localized: "Changed rules must increase their version.", bundle: .module)) }
        }
        let next = try RuleRegistry(rules: registry.rules.filter { $0.id != rule.id } + [rule])
        try store.saveRule(rule); registry = next; await invalidate()
    }
    public func removeRule(_ id: String) async throws {
        let next = try RuleRegistry(rules: registry.rules.filter { $0.id != id })
        try store.removeRule(id); registry = next; await invalidate()
    }
    private func invalidate() async {
        generation += 1; inFlight.values.forEach { $0.task.cancel(); $0.consumers.values.forEach { $0.resume(throwing: CancellationError()) } }; inFlight.removeAll()
        directoryFlights.values.forEach { $0.task.cancel(); $0.consumers.values.forEach { $0.resume(throwing: CancellationError()) } }; directoryFlights.removeAll()
        await sender.invalidateResources()
    }
    public func clearContent() async throws { await invalidate(); try store.clearContent() }
    public func resolve(_ key: ObjectKey, hint: CacheHint = .refreshIfStale, sessionURL: URL? = nil, preview: Bool = false) async throws -> ContentObject {
        try Task.checkCancellation()
        if hint == .forceRefresh, let old = directoryFlights.removeValue(forKey: key) { old.task.cancel(); old.consumers.values.forEach { $0.resume(throwing: CancellationError()) } }
        let rule = try rule(for: key)
        let cached = try store.snapshot(key)
        if let cached, cached.ruleVersion == rule.version, (cached.object.isComplete || (preview && cached.object.hasPreview)),
           hint == .offlineOnly || hint == .preferCache || (hint == .refreshIfStale && cached.expiresAt > Date()) { return cached.object }
        if hint == .offlineOnly { throw ReaderError.cacheMiss }
        if let owner = key.owner {
            let parent = try await resolve(owner, hint: hint == .forceRefresh ? .forceRefresh : .refreshIfStale)
            if let child = try store.snapshot(key), child.ruleVersion == rule.version, child.expiresAt > Date() { return child.object }
            // A rendered chapter can declare all page identities before their URLs exist.
            if case .chapter(let chapter) = parent {
                guard let index = Int(key.identityURL.lastPathComponent), chapter.pageRefs.indices.contains(index), chapter.pageRefs[index] == key else { throw ReaderError.cacheMiss }
                let epoch = generation
                let response = try await sender.send(.source(owner, kind: .chapter, rule: rule, backgroundLoading: backgroundLoading,
                    load: SourceLoad(range: index..<(index + 1), refresh: hint == .forceRefresh)))
                try Task.checkCancellation()
                guard epoch == generation else { throw CancellationError() }
                let objects = try RuleExtractor().extract(data: response.data, responseURL: response.url, key: owner, kind: .chapter, rule: rule)
                try store.upsert(objects, version: rule.version, replacingChildren: false)
            } else { _ = try await resolve(owner, hint: .forceRefresh) }
            guard let child = try store.snapshot(key), child.ruleVersion == rule.version else { throw ReaderError.cacheMiss }; return child.object
        }
        if let request = inFlight[key] { return try await consume(request, key: key) }
        let (_, kind, canonical) = try registry.match(key.identityURL, ruleID: key.ruleID)
        guard canonical == key else { return try await resolve(canonical, hint: hint, sessionURL: sessionURL, preview: preview) }
        let currentGeneration = generation, backgroundLoading = backgroundLoading
        let task = Task<ContentObject, Error> { [sender] in
            let response = try await sender.send(.source(key, kind: kind, rule: rule, backgroundLoading: backgroundLoading, load: SourceLoad(refresh: hint == .forceRefresh, sessionURL: sessionURL)))
            try Task.checkCancellation()
            let objects = try RuleExtractor().extract(data: response.data, responseURL: response.url, key: key, kind: kind, rule: rule, sessionURL: sessionURL)
            try Task.checkCancellation()
            guard currentGeneration == self.generation else { throw CancellationError() }
            try self.store.upsert(objects, version: rule.version)
            guard let object = try self.store.snapshot(key)?.object else { throw ReaderError.extraction(String(localized: "No content was found.", bundle: .module)) }; return object
        }
        let request = Request(task: task)
        inFlight[key] = request
        return try await consume(request, key: key)
    }
    /// Site orchestration is core work: each source may return one list or a page of lists.
    func directories(from sources: [ContentReference], hint: CacheHint) async throws -> [DirectoryObject] {
        let epoch = generation
        let batches = try await withThrowingTaskGroup(of: (Int, [ContentReference]).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    switch try await self.resolve(source.key, hint: hint) {
                    case .site(let page): return (index, page.directoryRefs)
                    case .directory: return (index, [source])
                    default: throw ReaderError.invalidResponse
                    }
                }
            }
            var result: [(Int, [ContentReference])] = []
            for try await batch in group { result.append(batch) }
            return result.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
        var seen: Set<ObjectKey> = []
        let references = batches.filter { seen.insert($0.key).inserted }
        // Freshly seeded excerpts need no second request. Linked full lists retain
        // their own expiry, including when refreshing a source with only links.
        let result = try await directoryPreviews(references, hint: hint == .forceRefresh ? .refreshIfStale : hint)
        try Task.checkCancellation()
        guard generation == epoch else { throw CancellationError() }
        return result
    }
    func directoryPreviews(_ references: [ContentReference], hint: CacheHint) async throws -> [DirectoryObject] {
        let epoch = generation
        var result: [DirectoryObject] = []
        for reference in references {
            guard case .directory(var directory) = try await resolve(reference.key, hint: hint, preview: true) else { throw ReaderError.invalidResponse }
            // The source's section label describes this shelf, even when a full list is cached.
            directory.title = reference.title; result.append(directory)
        }
        try Task.checkCancellation()
        guard generation == epoch else { throw CancellationError() }
        return result
    }
    func pageDescriptors(for chapter: ChapterObject) throws -> [PageObject] {
        let rule = try rule(for: chapter.key)
        return try chapter.pageRefs.enumerated().map { index, key in
            if let cached = try store.snapshot(key), cached.ruleVersion == rule.version, cached.expiresAt > Date(), case .page(let page) = cached.object { return page }
            return PageObject(key: key, ownerRef: chapter.key, sourceIndex: index, imageURL: nil, refererURL: chapter.sourceURL)
        }
    }
    /// Range assembly is session state, never view/object mutation. Overlapping callers
    /// share one advancing job; a larger caller resumes after the smaller range completes.
    public func directory(_ key: ObjectKey, range: Range<Int>) async throws -> DirectoryObject {
        guard range.lowerBound >= 0, range.upperBound <= 100_000 else { throw ReaderError.invalidResponse }
        if let flight = directoryFlights[key] {
            _ = try await consume(flight, key: key, directory: true)
            return try await directory(key, range: range)
        }
        guard case .directory(let initial) = try await resolve(key) else { throw ReaderError.invalidResponse }
        if directoryFlights[key] != nil { return try await directory(key, range: range) }
        guard initial.mangaRefs.count < range.upperBound, initial.hasMore != false else { return initial }
        let epoch = generation
        let task = Task<ContentObject, Error> {
            var current = initial, visited: Set<ObjectKey> = [key], stalled = 0, batches = 0
            while current.mangaRefs.count < range.upperBound, current.hasMore != false {
                guard batches < 100 else { throw ReaderError.invalidResponse }; batches += 1
                let batch: DirectoryObject
                if let next = current.nextPage {
                    guard visited.count < 100, visited.insert(next.key).inserted else { throw ReaderError.invalidResponse }
                    guard case .directory(let result) = try await self.resolve(next.key, sessionURL: key.identityURL) else { throw ReaderError.invalidResponse }
                    batch = result
                } else {
                    let rule = try self.rule(for: key)
                    let response = try await self.sender.send(.source(key, kind: .directory, rule: rule, backgroundLoading: self.backgroundLoading,
                        load: SourceLoad(range: current.mangaRefs.count..<range.upperBound, knownItems: Set(current.mangaRefs.map(\.key)))))
                    let objects = try RuleExtractor().extract(data: response.data, responseURL: response.url, key: key, kind: .directory, rule: rule)
                    guard case .directory(let result) = objects.first else { throw ReaderError.invalidResponse }
                    try Task.checkCancellation()
                    guard epoch == self.generation else { throw CancellationError() }
                    try self.store.upsert(Array(objects.dropFirst()), version: rule.version, replacingChildren: false)
                    batch = result
                }
                try Task.checkCancellation()
                guard epoch == self.generation else { throw CancellationError() }
                let previousCount = current.mangaRefs.count
                var seen = Set(current.mangaRefs.map(\.key))
                current = DirectoryObject(key: key, sourceURL: initial.sourceURL, title: initial.title,
                    mangaRefs: current.mangaRefs + batch.mangaRefs.filter { seen.insert($0.key).inserted }, nextURL: batch.nextURL, endReached: batch.endReached, totalCount: batch.totalCount ?? current.totalCount,
                    sortBy: initial.sortBy, sortOrder: initial.sortOrder, selectedSortBy: initial.selectedSortBy, selectedSortOrder: initial.selectedSortOrder)
                stalled = current.mangaRefs.count == previousCount ? stalled + 1 : 0
                guard stalled < 3 else { throw ReaderError.invalidResponse }
                let rule = try self.rule(for: key)
                try self.store.upsert([.directory(current)], version: rule.version)
            }
            return .directory(current)
        }
        let request = Request(task: task); directoryFlights[key] = request
        guard case .directory(let result) = try await consume(request, key: key, directory: true) else { throw ReaderError.invalidResponse }
        return result
    }
    private func consume(_ request: Request, key: ObjectKey, directory: Bool = false) async throws -> ContentObject {
        let consumer = UUID()
        let value: ContentObject = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    let current = directory ? directoryFlights[key] : inFlight[key]
                    if let current, current.id == request.id, current.consumers.isEmpty {
                        current.task.cancel()
                        if directory { directoryFlights[key] = nil } else { inFlight[key] = nil }
                    }
                    continuation.resume(throwing: CancellationError()); return
                }
                guard var current = directory ? directoryFlights[key] : inFlight[key], current.id == request.id else {
                    continuation.resume(throwing: CancellationError()); return
                }
                current.consumers[consumer] = continuation
                if directory { directoryFlights[key] = current } else { inFlight[key] = current }
                if current.consumers.count == 1 {
                    Task {
                        let result: Result<ContentObject, Error>
                        do { result = .success(try await request.task.value) } catch { result = .failure(error) }
                        self.finish(request, key: key, directory: directory, result: result)
                    }
                }
            }
        } onCancel: {
            Task { await self.release(key, requestID: request.id, consumer: consumer, directory: directory) }
        }
        try Task.checkCancellation(); return value
    }
    private func finish(_ request: Request, key: ObjectKey, directory: Bool, result: Result<ContentObject, Error>) {
        guard let current = directory ? directoryFlights[key] : inFlight[key], current.id == request.id else { return }
        if directory { directoryFlights[key] = nil } else { inFlight[key] = nil }
        for waiter in current.consumers.values { waiter.resume(with: result) }
    }
    private func release(_ key: ObjectKey, requestID: UUID, consumer: UUID, directory: Bool = false) {
        guard var request = directory ? directoryFlights[key] : inFlight[key], request.id == requestID,
              let waiter = request.consumers.removeValue(forKey: consumer) else { return }
        waiter.resume(throwing: CancellationError())
        if request.consumers.isEmpty {
            request.task.cancel()
            if directory { directoryFlights[key] = nil } else { inFlight[key] = nil }
        } else if directory { directoryFlights[key] = request } else { inFlight[key] = request }
    }
}
