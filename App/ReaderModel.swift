import SwiftUI
import MangaCore

@MainActor @Observable final class ReaderModel: Identifiable {
    let id = UUID()
    let chapter: ChapterObject
    unowned let app: AppModel
    var pages: [PageObject] = []
    var plans: [DisplayPage] = []
    var analysis: [ObjectKey: ImageAnalysis] = [:]
    var overrides: [ObjectKey: SpreadOverride] = [:]
    var source: ObjectKey?
    var fraction = 0.0
    var previousChapter: ContentReference?
    var nextChapter: ContentReference?
    var mangaTitle: String?
    var mangaCover: PageObject?
    var nextPreview: PageObject?
    var nextPreviewError: String?
    var error: String?
    var loading = true
    var revision = 0
    var size: CGSize = .zero
    private var interacting = false
    private var pendingReplan = false
    private var active = false
    private var metadataLoaded = false
    var index: Int { PagePipeline.index(for: source, fraction: fraction, in: plans) }
    var current: DisplayPage? { plans.indices.contains(index) ? plans[index] : nil }
    var nextChapterToPrefetch: ObjectKey? { !plans.isEmpty && index >= plans.count - 2 ? nextChapter?.key : nil }
    private var planning: Task<Void, Never>?
    private var prefetch: Task<Void, Never>?
    private var rule: SiteRule?

    init(chapter: ChapterObject, app: AppModel) {
        self.chapter = chapter; self.app = app
        mangaTitle = app.saved.first { $0.key == chapter.mangaRef }?.title
            ?? app.readingPositions.first { $0.mangaKey == chapter.mangaRef }?.mangaTitle
    }
    func activate() async {
        active = true
        if pages.isEmpty { await load() }
        else { replan(); await loadMangaMetadata() }
    }
    func load() async {
        guard let repository = app.repository else { return }
        planning?.cancel(); prefetch?.cancel()
        loading = true; error = nil
        defer { loading = false }
        do {
            rule = try await repository.rule(for: chapter.key)
            let loaded = try await chapter.pages(using: repository)
            try Task.checkCancellation(); pages = loaded
            overrides = try app.store?.preference("overrides:" + chapter.key.id, as: [ObjectKey: SpreadOverride].self) ?? [:]
            let position = try app.store?.positions().first { $0.chapterKey == chapter.key }
            source = pages.first(where: { $0.key == position?.sourcePageKey })?.key ?? pages.first?.key
            fraction = position?.fractionalOffset ?? 0
            replan()
            loading = false
            await loadMangaMetadata()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    func loadMangaMetadata() async {
        guard !metadataLoaded, let repository = app.repository else { return }
        do {
            guard let manga = try await chapter.manga(using: repository) else { return }
            try Task.checkCancellation()
            mangaTitle = manga.title
            previousChapter = manga.previousChapter(before: chapter.key)
            nextChapter = manga.nextChapter(after: chapter.key)
            mangaCover = try? await manga.coverPage(using: repository)
            try Task.checkCancellation()
            metadataLoaded = true
            if active { save() }
        } catch { /* Pages remain usable; activation retries metadata after cancellation/failure. */ }
    }
    /// Only the adjacent chapter metadata and its first image; the view owns cancellation.
    func preloadNextChapter() async {
        guard let key = nextChapterToPrefetch, nextPreview == nil, let repository = app.repository else { return }
        nextPreviewError = nil
        do {
            guard case .chapter(let next) = try await key.load(using: repository),
                  let page = try await next.page(at: 0, using: repository) else { nextPreviewError = "Preview unavailable"; return }
            _ = try await page.image(using: repository)
            try Task.checkCancellation()
            nextPreview = page
        } catch is CancellationError {} catch { if !Task.isCancelled { nextPreviewError = "Preview unavailable" } }
    }
    func openAdjacent(_ reference: ContentReference?) {
        guard let reference else { return }
        app.openChapter(reference.key, preserveImmersion: true)
    }
    func replan() {
        guard active else { return }
        guard !interacting else { pendingReplan = true; return }
        planning?.cancel()
        let context = ReaderContext(size: size, preferences: app.preferences, analysis: analysis, overrides: overrides)
        let keys = pages.map(\.key)
        let ids = rule?.processors ?? ["identity", "marginAlign", "spreadDetect", "layout"]
        planning = Task {
            guard let pipeline = try? PagePipeline(ids: ids) else { return }
            let planned = await pipeline.plan(keys, context: context)
            guard !Task.isCancelled else { return }
            guard !interacting else { pendingReplan = true; return }
            if plans != planned { plans = planned }
            // Mode/viewport changes need restoration even when the page regions stay identical.
            revision += 1
            schedulePrefetch()
        }
    }
    func setInteracting(_ value: Bool) {
        interacting = value
        if !value, pendingReplan { pendingReplan = false; replan() }
    }
    func learn(_ key: ObjectKey, image: CGImage) {
        guard analysis[key] == nil else { return }
        analysis[key] = ImageProcessing.analyze(image); replan()
    }
    func move(_ delta: Int) {
        guard !plans.isEmpty else { return }
        record(index: min(plans.count - 1, max(0, index + delta)), within: 0, preserveSource: false)
        revision += 1
    }
    func record(index: Int, within: Double, preserveSource: Bool = true) {
        guard plans.indices.contains(index) else { return }
        let keys = plans[index].sourcePageKeys
        // Physical region order may be RTL. Progress follows original chapter order.
        let key = preserveSource && source.map(keys.contains) == true ? source : pages.first(where: { keys.contains($0.key) })?.key
        guard let key else { return }
        let oldIndex = self.index
        source = key; fraction = PagePipeline.fraction(index: index, withinPage: within, source: key, in: plans)
        if oldIndex != self.index { schedulePrefetch() }
    }
    var withinPage: Double {
        guard let source else { return 0 }
        let indices = plans.indices.filter { plans[$0].sourcePageKeys.contains(source) }
        return min(0.999_999, max(0, fraction * Double(indices.count) - Double(indices.firstIndex(of: index) ?? 0)))
    }
    func setOverride(_ value: SpreadOverride) {
        guard let source else { return }; overrides[source] = value
        do { try app.store?.setPreference("overrides:" + chapter.key.id, value: overrides) }
        catch { app.error = error.localizedDescription }; replan()
    }
    func save() {
        guard let source else { return }
        do {
            try app.store?.savePosition(ReadingPosition(mangaKey: chapter.mangaRef ?? chapter.key, chapterKey: chapter.key,
                sourcePageKey: source, fractionalOffset: fraction, title: chapter.title, mangaTitle: mangaTitle,
                pageNumber: pages.firstIndex(where: { $0.key == source }).map { $0 + 1 }, totalPages: pages.count))
        }
        catch { app.error = error.localizedDescription }
    }
    func stop() {
        guard active else { return }
        save(); active = false; interacting = false; pendingReplan = false
        planning?.cancel(); prefetch?.cancel(); app.reloadLibrary()
    }
    func height(_ plan: DisplayPage, width: Double) -> Double {
        let aspect = plan.regions.reduce(0.0) { total, region in
            let ratio = analysis[region.sourcePage]?.aspectRatio ?? 0.727
            return total + ratio * Double(region.normalizedCrop.width / region.normalizedCrop.height)
        }
        return width / max(0.1, aspect)
    }
    private func schedulePrefetch() {
        prefetch?.cancel()
        guard active, let repository = app.repository, !plans.isEmpty else { return }
        let neighborIndices = [index + 1, index - 1].filter { plans.indices.contains($0) }
        var keys: [ObjectKey] = []
        for i in neighborIndices {
            for key in plans[i].sourcePageKeys where !keys.contains(key) { keys.append(key) }
        }
        // Match the pager's neighbor window, prioritizing the next page over the previous page.
        let neighbors = keys.prefix(3).compactMap { key in pages.first { $0.key == key } }
        prefetch = Task {
            var learned = false
            for page in neighbors {
                guard !Task.isCancelled else { return }
                do {
                    let image = try await page.image(using: repository)
                    try Task.checkCancellation()
                    if analysis[page.key] == nil { analysis[page.key] = ImageProcessing.analyze(image); learned = true }
                } catch is CancellationError { return } catch { /* Visible loading exposes errors and retry. */ }
            }
            // Update plans once per neighbor window; never scan/decode the full chapter.
            if !Task.isCancelled && learned { await applyPrefetchAnalysis() }
        }
    }
    private func applyPrefetchAnalysis() async {
        let context = ReaderContext(size: size, preferences: app.preferences, analysis: analysis, overrides: overrides)
        guard let pipeline = try? PagePipeline(ids: rule?.processors ?? ["identity", "marginAlign", "spreadDetect", "layout"]) else { return }
        let newPlans = await pipeline.plan(pages.map(\.key), context: context)
        guard !Task.isCancelled else { return }
        guard !interacting else { pendingReplan = true; return }
        if plans != newPlans { plans = newPlans }
        revision += 1
    }
}
