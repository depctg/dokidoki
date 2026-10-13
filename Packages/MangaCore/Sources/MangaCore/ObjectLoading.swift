import CoreGraphics

// Objects describe what to load; the repository owns freshness and the shared sender owns admission.
extension ObjectKey {
    public func load(using repository: ObjectRepository, hint: CacheHint = .refreshIfStale) async throws -> ContentObject {
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
    public func load(using repository: ObjectRepository, hint: CacheHint = .refreshIfStale) async throws -> ContentObject {
        try await key.load(using: repository, hint: hint)
    }
}
extension ContentObject {
    public func reload(using repository: ObjectRepository, hint: CacheHint = .forceRefresh) async throws -> ContentObject {
        try await key.load(using: repository, hint: hint)
    }
}
extension DirectoryObject {
    /// Append the next source list without changing the first page's identity/sorting.
    public func loadingNext(using repository: ObjectRepository) async throws -> DirectoryObject {
        guard let nextPage else { return self }
        guard case .directory(let next) = try await nextPage.load(using: repository) else { throw ReaderError.invalidResponse }
        try Task.checkCancellation()
        var seen = Set(mangaRefs.map(\.key))
        let additions = next.mangaRefs.filter { seen.insert($0.key).inserted }
        return DirectoryObject(key: key, sourceURL: sourceURL, title: title, mangaRefs: mangaRefs + additions,
            nextURL: next.nextURL, sortBy: sortBy, sortOrder: sortOrder, selectedSortBy: selectedSortBy, selectedSortOrder: selectedSortOrder)
    }
}
extension MangaObject {
    public func coverPage(using repository: ObjectRepository, hint: CacheHint = .refreshIfStale) async throws -> PageObject? {
        guard let coverPageRef, case .page(let page) = try await coverPageRef.load(using: repository, hint: hint) else { return nil }
        return page
    }
}
extension ChapterObject {
    public func manga(using repository: ObjectRepository) async throws -> MangaObject? {
        guard let mangaRef, case .manga(let manga) = try await mangaRef.load(using: repository) else { return nil }
        return manga
    }
    public func page(at index: Int, using repository: ObjectRepository) async throws -> PageObject? {
        guard pageRefs.indices.contains(index), case .page(let page) = try await pageRefs[index].load(using: repository) else { return nil }
        return page
    }
    public func pages(using repository: ObjectRepository) async throws -> [PageObject] {
        var pages: [PageObject] = []
        for index in pageRefs.indices { if let page = try await page(at: index, using: repository) { pages.append(page) } }
        return pages
    }
}
extension PageObject {
    public func image(using repository: ObjectRepository, refresh: Bool = false, maxPixel: Int = 1800) async throws -> CGImage {
        let page: PageObject
        if refresh {
            guard case .page(let fresh) = try await key.load(using: repository, hint: .forceRefresh) else { throw ReaderError.extraction(String(localized: "This reference does not contain a page.", bundle: .module)) }
            page = fresh
        } else { page = self }
        do {
            let rule = try await repository.rule(for: page.key)
            return try await repository.images.image(for: page, rule: rule, maxPixel: maxPixel)
        } catch {
            ErrorDiagnostics.record(error, operation: .loadImage, url: page.imageURL)
            throw error
        }
    }
}
