import SwiftUI
import MangaCore

enum ChapterDirection: CaseIterable { case previous, next }
struct ChapterPreview {
    var page: PageObject?
    var error: String?
}

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
    var previews: [ChapterDirection: ChapterPreview] = [:]
    private let startAtEnd: Bool
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
    func adjacentChapter(_ direction: ChapterDirection) -> ContentReference? {
        direction == .next ? nextChapter : previousChapter
    }
    func chapterToPrefetch(_ direction: ChapterDirection) -> ObjectKey? {
        guard !plans.isEmpty, direction == .next ? index >= plans.count - 2 : index <= 1 else { return nil }
        return adjacentChapter(direction)?.key
    }
    private var planning: Task<Void, Never>?
    private var prefetch: Task<Void, Never>?
    private var rule: SiteRule?

    init(chapter: ChapterObject, app: AppModel, startAtEnd: Bool = false) {
        self.chapter = chapter; self.app = app; self.startAtEnd = startAtEnd
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
            let position: ReadingPosition?
            do {
                overrides = try app.store?.preference("overrides:" + chapter.key.id, as: [ObjectKey: SpreadOverride].self) ?? [:]
                position = try app.store?.positions().first { $0.chapterKey == chapter.key }
            } catch { ErrorDiagnostics.record(error, operation: .storage); throw error }
            source = startAtEnd ? pages.last?.key : (pages.first(where: { $0.key == position?.sourcePageKey })?.key ?? pages.first?.key)
            fraction = startAtEnd ? 0.999_999 : (position?.fractionalOffset ?? 0)
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
    /// Only adjacent metadata and the boundary image; the view owns cancellation.
    func preloadChapter(_ direction: ChapterDirection) async {
        guard let key = chapterToPrefetch(direction), previews[direction]?.page == nil, let repository = app.repository else { return }
        previews[direction] = ChapterPreview()
        do {
            guard case .chapter(let chapter) = try await key.load(using: repository),
                  let page = try await chapter.page(at: direction == .next ? 0 : chapter.pageRefs.count - 1, using: repository) else {
                previews[direction] = ChapterPreview(error: String(localized: "Preview unavailable")); return
            }
            _ = try await page.image(using: repository)
            try Task.checkCancellation()
            previews[direction] = ChapterPreview(page: page)
        } catch is CancellationError {} catch { if !Task.isCancelled { previews[direction] = ChapterPreview(error: String(localized: "Preview unavailable")) } }
    }
    func openAdjacent(_ reference: ContentReference?, fromEnd: Bool = false) {
        guard app.reader?.id == id, let reference else { return }
        app.openChapter(reference.key, preserveImmersion: true, fromEnd: fromEnd)
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
        catch { app.report(error, operation: .storage) }; replan()
    }
    func save() {
        // An outgoing view may settle during the chapter crossfade after stop().
        guard active, app.reader?.id == id, let source else { return }
        do {
            try app.store?.savePosition(ReadingPosition(mangaKey: chapter.mangaRef ?? chapter.key, chapterKey: chapter.key,
                sourcePageKey: source, fractionalOffset: fraction, title: chapter.title, mangaTitle: mangaTitle,
                pageNumber: pages.firstIndex(where: { $0.key == source }).map { $0 + 1 }, totalPages: pages.count))
        }
        catch { app.report(error, operation: .storage) }
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
            var learned: [ObjectKey: ImageAnalysis] = [:]
            for page in neighbors {
                guard !Task.isCancelled else { return }
                do {
                    let image = try await page.image(using: repository)
                    try Task.checkCancellation()
                    if analysis[page.key] == nil { learned[page.key] = ImageProcessing.analyze(image) }
                } catch is CancellationError { return } catch { /* Visible loading exposes errors and retry. */ }
            }
            // Publish analysis and request its plan together. A superseding plan must not cancel
            // this task after it published evidence but before that evidence reached the renderer.
            if !Task.isCancelled && !learned.isEmpty {
                analysis.merge(learned) { current, _ in current }
                replan()
            }
        }
    }
}
