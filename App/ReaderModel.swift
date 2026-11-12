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
    @ObservationIgnored var fraction = 0.0
    var scrollPosition = ScrollPosition(idType: String.self)
    var landingArtwork: PageArtwork?
    private var manga: MangaObject?
    var previousChapter: ContentReference? { manga?.previousChapter(before: chapter.key, in: chapterListID) }
    var nextChapter: ContentReference? { manga?.nextChapter(after: chapter.key, in: chapterListID) }
    private(set) var chapterListID: String?
    private var completed = false
    var finalPageReady: Bool {
        plans.last.map { $0.sourcePageKeys.allSatisfy { analysis[$0] != nil } } ?? false
    }
    var mangaTitle: String? { manga?.title ?? app.saved.first { $0.key == chapter.mangaRef }?.title
        ?? app.readingPositions.first { $0.mangaKey == chapter.mangaRef }?.mangaTitle }
    var mangaCover: ObjectKey? { manga?.coverPageRef }
    var previews: [ChapterDirection: ChapterPreview] = [:]
    private let entry: ChapterEntry
    var error: String?
    var loading = true
    var revision = 0
    var size: CGSize = .zero
    private var interacting = false
    private var pendingReplan = false
    private var pendingRestore = false
    private var learned: [ObjectKey: ImageAnalysis] = [:]
    private(set) var active = false
    private var metadataLoaded = false
    private(set) var index = 0
    var current: DisplayPage? { plans.indices.contains(index) ? plans[index] : nil }
    func adjacentChapter(_ direction: ChapterDirection) -> ContentReference? {
        direction == .next ? nextChapter : previousChapter
    }
    func chapterToPrefetch(_ direction: ChapterDirection, revealed: Bool = false) -> ObjectKey? {
        let distance = app.prefetchDistance.rawValue
        guard !plans.isEmpty, revealed || (distance > 0 && (direction == .next ? index >= plans.count - distance : index < distance)) else { return nil }
        return adjacentChapter(direction)?.key
    }
    private var planning: Task<Void, Never>?
    private var prefetch: [ObjectKey: Task<Void, Never>] = [:]
    private var rule: SiteRule?

    init(chapter: ChapterObject, app: AppModel, entry: ChapterEntry = .resume, listID: String? = nil) {
        self.chapter = chapter; self.app = app; self.entry = entry
        chapterListID = listID ?? app.readingPositions.first { $0.chapterKey == chapter.key }?.chapterListID
    }
    func activate() async {
        active = true
        if plans.isEmpty { await load() }
        else { replan(restore: true); preparePages(); save(); await loadMangaMetadata() }
    }
    func load() async {
        guard let repository = app.repository else { return }
        planning?.cancel(); cancelPrefetch()
        loading = true; error = nil
        defer { loading = false }
        do {
            rule = try await repository.rule(for: chapter.key)
            let loaded = try await chapter.pages(using: repository)
            try Task.checkCancellation(); pages = loaded
            let position: ReadingPosition?
            do {
                await app.finishPersistence()
                try Task.checkCancellation()
                let state = try await chapter.readingState(using: repository)
                try Task.checkCancellation()
                overrides = state.overrides; position = state.position
            } catch { ErrorDiagnostics.record(error, operation: .storage); throw error }
            // Navigation chooses its boundary before preparing any incoming artwork
            // or native scroll target. Only an ordinary resume consults history.
            let target = chapter.entryPosition(entry, saved: position)
            source = target.source; fraction = target.fraction
            // Establish the target's real dimensions before its first layout, including
            // cold fractional resumes, manual pairs and backward chapter entry.
            let pipeline = try PagePipeline(ids: processorIDs)
            let initial = await pipeline.plan(pages.map(\.key), context: ReaderContext(
                size: size, preferences: app.preferences, analysis: analysis, overrides: overrides))
            if !initial.isEmpty {
                let target = initial[PagePipeline.index(for: source, fraction: fraction, in: initial)]
                for page in pages where target.sourcePageKeys.contains(page.key) && analysis[page.key] == nil {
                    if let prepared = try? await page.prepare(using: repository) { analysis[page.key] = prepared }
                    try Task.checkCancellation()
                }
            }
            // Publish an initial complete plan even when preparing an incoming
            // chapter before it becomes the active reader.
            let planned = await pipeline.plan(pages.map(\.key), context: ReaderContext(
                size: size, preferences: app.preferences, analysis: analysis, overrides: overrides))
            try Task.checkCancellation()
            plans = planned; updateIndex(); revision += 1
            if let current {
                // Content, native target and its composed artwork are prepared together
                // before AppModel publishes an incoming chapter to the persistent view.
                scrollPosition = ScrollPosition(id: current.id, anchor: app.preferences.mode == .paged ? .center : (entry == .end ? .bottom : .top))
                landingArtwork = try? await PageArtwork.load(plan: current, pages: pages,
                    using: repository, revision: app.loadingRevision)
                try Task.checkCancellation()
            }
            preparePages()
            loading = false
            await loadMangaMetadata()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    func loadMangaMetadata() async {
        guard !metadataLoaded, let repository = app.repository else { return }
        do {
            guard let manga = try await chapter.manga(using: repository) else { return }
            try Task.checkCancellation()
            self.manga = manga
            chapterListID = manga.chapterList(containing: chapter.key, preferredID: chapterListID)?.id
            try Task.checkCancellation()
            metadataLoaded = true
            if active { save() }
        } catch { /* Pages remain usable; activation retries metadata after cancellation/failure. */ }
    }
    /// Only adjacent metadata and the boundary image; the view owns cancellation.
    func preloadChapter(_ direction: ChapterDirection, revealed: Bool = false) async {
        guard let key = chapterToPrefetch(direction, revealed: revealed), previews[direction]?.page == nil, let repository = app.repository else { return }
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
    func openAdjacent(_ direction: ChapterDirection) {
        guard app.reader?.id == id, let reference = adjacentChapter(direction) else { return }
        app.openChapter(reference.key, preserveImmersion: true, entry: direction == .next ? .start : .end, listID: chapterListID)
    }
    func replan(restore: Bool = false) {
        guard active else { return }
        pendingRestore = pendingRestore || restore
        guard !interacting else { pendingReplan = true; return }
        planning?.cancel()
        let context = ReaderContext(size: size, preferences: app.preferences,
                                    analysis: analysis.merging(learned) { current, _ in current }, overrides: overrides)
        let keys = pages.map(\.key)
        let ids = processorIDs
        planning = Task {
            guard let pipeline = try? PagePipeline(ids: ids) else { return }
            let planned = await pipeline.plan(keys, context: context)
            guard !Task.isCancelled else { return }
            guard !interacting else { pendingReplan = true; return }
            // Native lazy stacks preserve visible IDs as neighboring rows change.
            // Only explicit navigation/layout changes or replacing the current region
            // require restoring its source position, never an ordinary image arrival.
            let replacedCurrent = current.map { current in !planned.contains { $0.id == current.id } } ?? true
            analysis = context.analysis
            learned = learned.filter { context.analysis[$0.key] == nil }
            if plans != planned { plans = planned; updateIndex() }
            if pendingRestore || replacedCurrent { revision += 1 }
            pendingRestore = false
            preparePages()
        }
    }
    var processorIDs: [String] { rule?.processors ?? ["identity", "marginAlign", "spreadDetect", "layout"] }
    func setInteracting(_ value: Bool) {
        interacting = value
        if !value, pendingReplan { pendingReplan = false; replan() }
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
        updateIndex()
        if oldIndex != self.index { landingArtwork = nil; preparePages() }
    }
    private func updateIndex() {
        index = PagePipeline.index(for: source, fraction: fraction, in: plans)
    }
    var withinPage: Double {
        guard let source else { return 0 }
        let indices = plans.indices.filter { plans[$0].sourcePageKeys.contains(source) }
        return min(0.999_999, max(0, fraction * Double(indices.count) - Double(indices.firstIndex(of: index) ?? 0)))
    }
    func setOverride(_ value: SpreadOverride) {
        guard let source else { return }; overrides[source] = value
        if let repository = app.repository {
            let chapter = chapter, overrides = overrides
            app.persist { try await chapter.saveOverrides(overrides, using: repository) }
        }
        replan(restore: true)
    }
    func finishReading() {
        guard active, app.reader?.id == id, !completed, finalPageReady else { return }
        completed = true
        save()
    }
    func save() {
        // An outgoing view may settle during the chapter crossfade after stop().
        guard active, app.reader?.id == id, let source, let repository = app.repository else { return }
        let position = ReadingPosition(mangaKey: chapter.mangaRef ?? chapter.key, chapterKey: chapter.key,
                sourcePageKey: source, fractionalOffset: fraction, title: chapter.title, mangaTitle: mangaTitle,
                pageNumber: pages.firstIndex(where: { $0.key == source }).map { $0 + 1 }, totalPages: pages.count, chapterListID: chapterListID)
        let completed = completed, manga = manga
        app.persist {
            try await position.save(using: repository, completed: completed, manga: manga)
        }
    }
    func stop() {
        guard active else { return }
        save(); active = false; interacting = false; pendingReplan = false
        landingArtwork = nil
        planning?.cancel(); cancelPrefetch()
    }
    func height(_ plan: DisplayPage, width: Double) -> Double {
        width / max(0.1, plan.aspectRatio(analysis: analysis))
    }
    func preparePages() {
        guard active, let repository = app.repository, !plans.isEmpty else { return }
        // Visible preparation and speculative work consume the same core cache.
        let neighbors = app.prefetchDistance.sources(in: plans, at: index).compactMap { key in pages.first { $0.key == key } }
        let wanted = Set(neighbors.map(\.key))
        for key in prefetch.keys where !wanted.contains(key) { prefetch.removeValue(forKey: key)?.cancel() }
        for page in neighbors where prefetch[page.key] == nil {
            prefetch[page.key] = Task(priority: .utility) {
                do {
                    if analysis[page.key] != nil || learned[page.key] != nil {
                        _ = try await page.image(using: repository)
                        return
                    }
                    let result = try await page.prepare(using: repository)
                    try Task.checkCancellation()
                    learned[page.key] = result; replan()
                } catch {
                    // A successful visible retry can warm this page again.
                    if !Task.isCancelled { prefetch[page.key] = nil }
                }
            }
        }
    }
    private func cancelPrefetch() {
        prefetch.values.forEach { $0.cancel() }; prefetch.removeAll()
    }
}
