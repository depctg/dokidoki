import CoreGraphics

// Objects describe what to load; the core cache owns retention and the shared sender owns admission.
extension ObjectKey {
    public func load(using repository: ObjectRepository, hint: CacheHint = .preferCache) async throws -> ContentObject {
        do { return try await repository.resolve(self, hint: hint) }
        catch {
            // A deliberate offline cache probe is normal, not a failed load.
            if case ReaderError.cacheMiss = error, hint == .offlineOnly { throw error }
            ErrorDiagnostics.record(error, operation: .loadContent, url: owner?.identityURL ?? identityURL)
            throw error
        }
    }
}
extension ContentReference {
    /// Accept known linked metadata; normal load still resolves the object's full details.
    public func preview(using repository: ObjectRepository, hint: CacheHint = .preferCache) async throws -> ContentObject {
        do { return try await repository.resolve(key, hint: hint, preview: true) }
        catch {
            if case ReaderError.cacheMiss = error, hint == .offlineOnly { throw error }
            ErrorDiagnostics.record(error, operation: .loadContent, url: key.identityURL); throw error
        }
    }
    public func load(using repository: ObjectRepository, hint: CacheHint = .preferCache) async throws -> ContentObject {
        try await key.load(using: repository, hint: hint)
    }
}
extension ContentObject {
    public func reload(using repository: ObjectRepository, hint: CacheHint = .forceRefresh) async throws -> ContentObject {
        try await key.load(using: repository, hint: hint)
    }
}
extension DirectoryObject {
    /// Returns the known prefix covering the requested zero-based range, or the source end.
    /// All continuation and duplicate/cycle handling belongs to the shared core context.
    public func load(_ range: Range<Int>, using repository: ObjectRepository) async throws -> DirectoryObject {
        do { return try await repository.directory(key, range: range) }
        catch { ErrorDiagnostics.record(error, operation: .loadContent, url: sourceURL); throw error }
    }
}

extension MangaObject {
    @concurrent public func toggleStar(using repository: ObjectRepository) async throws {
        let current = try repository.store.readingState(for: self)
        let saved = SavedManga(key: key, title: title, isStarred: current.personalState?.isStarred != true)
        try repository.store.setSaved(saved, saved: true, manga: self)
    }
    @concurrent public func removeFromLibrary(using repository: ObjectRepository) async throws {
        try repository.store.setSaved(SavedManga(key: key, title: title), saved: false, manga: self)
    }
    @concurrent public func hideFromRecent(using repository: ObjectRepository) async throws {
        try repository.store.hideRecent(key)
    }
    @concurrent public func setReadingStatus(_ status: ChapterReadingStatus, for chapters: [ObjectKey], using repository: ObjectRepository) async throws -> MangaObject {
        try repository.store.setReadingStatus(status, chapters: chapters, in: self)
    }

    /// Refresh local chapter status without a document request or changing the cached source snapshot.
    @concurrent public func readingState(using repository: ObjectRepository) async throws -> MangaObject {
        try repository.store.readingState(for: self)
    }
    public func coverPage(using repository: ObjectRepository, hint: CacheHint = .preferCache) async throws -> PageObject? {
        guard let coverPageRef, case .page(let page) = try await coverPageRef.load(using: repository, hint: hint) else { return nil }
        return page
    }
}
extension ChapterObject {
    /// Local state is independent of evictable content and never requires a source request.
    @concurrent public func readingState(using repository: ObjectRepository) async throws -> (position: ReadingPosition?, overrides: [ObjectKey: SpreadOverride]) {
        let position = try repository.store.readingPosition(for: mangaRef ?? key)
        let overrides = try repository.store.preference("overrides:" + key.id, as: [ObjectKey: SpreadOverride].self) ?? [:]
        return (position?.chapterKey == key ? position : nil, overrides)
    }
    @concurrent public func saveOverrides(_ overrides: [ObjectKey: SpreadOverride], using repository: ObjectRepository) async throws {
        try repository.store.setPreference("overrides:" + key.id, value: overrides)
    }
    public func manga(using repository: ObjectRepository) async throws -> MangaObject? {
        guard let mangaRef, case .manga(let manga) = try await mangaRef.load(using: repository) else { return nil }
        return manga
    }
    public func page(at index: Int, using repository: ObjectRepository) async throws -> PageObject? {
        guard pageRefs.indices.contains(index), case .page(let page) = try await pageRefs[index].load(using: repository) else { return nil }
        return page
    }
    public func load(_ range: Range<Int>, using repository: ObjectRepository) async throws -> [PageObject] {
        guard range.lowerBound >= 0 else { throw ReaderError.invalidResponse }
        var result: [PageObject] = []
        for index in range.clamped(to: 0..<pageRefs.count) { if let page = try await page(at: index, using: repository) { result.append(page) } }
        return result
    }
    /// Cached descriptors preserve all source identities without eagerly resolving URLs.
    public func pages(using repository: ObjectRepository) async throws -> [PageObject] {
        try await repository.pageDescriptors(for: self)
    }
}
extension ReadingPosition {
    @concurrent public func save(using repository: ObjectRepository, completed: Bool = false, manga: MangaObject? = nil) async throws {
        try repository.store.savePosition(self, completed: completed, manga: manga)
    }
}
extension PageObject {
    /// Warm the same image cache used by later display requests. Analysis runs off
    /// the UI executor; neither the page snapshot nor a view owns the cached bytes.
    public func prepare(using repository: ObjectRepository) async throws -> ImageAnalysis {
        let image = try await image(using: repository)
        try Task.checkCancellation()
        let result = await Task.detached(priority: .utility) { ImageProcessing.analyze(image) }.value
        try Task.checkCancellation()
        return result
    }
    public func image(using repository: ObjectRepository, refresh: Bool = false, maxPixel: Int = 1800) async throws -> CGImage {
        let page: PageObject
        if refresh || imageURL == nil {
            guard case .page(let fresh) = try await key.load(using: repository, hint: refresh ? .forceRefresh : .preferCache) else { throw ReaderError.extraction(String(localized: "This reference does not contain a page.", bundle: .module)) }
            page = fresh
        } else { page = self }
        do {
            let rule = try await repository.rule(for: page.key)
            return try await repository.images.image(for: page, rule: rule, maxPixel: maxPixel, refresh: refresh)
        } catch {
            ErrorDiagnostics.record(error, operation: .loadImage, url: page.imageURL)
            throw error
        }
    }
}
