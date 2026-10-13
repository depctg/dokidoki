import SwiftUI
import MangaCore

@MainActor @Observable final class ReaderModel {
    let chapter: ChapterObject
    let app: AppModel
    var pages: [PageObject] = []
    var plans: [DisplayPage] = []
    var analysis: [ObjectKey: ImageAnalysis] = [:]
    var overrides: [ObjectKey: SpreadOverride] = [:]
    var source: ObjectKey?
    var fraction = 0.0
    var nextChapter: ContentReference?
    var error: String?
    var loading = true
    var revision = 0
    var size: CGSize = .zero
    var index: Int { PagePipeline.index(for: source, fraction: fraction, in: plans) }
    var current: DisplayPage? { plans.indices.contains(index) ? plans[index] : nil }
    private var planning: Task<Void, Never>?
    private var prefetch: Task<Void, Never>?
    private var rule: SiteRule?

    init(chapter: ChapterObject, app: AppModel) { self.chapter = chapter; self.app = app }
    func load() async {
        guard let repository = app.repository else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            rule = try await repository.rule(for: chapter.key)
            var loaded: [PageObject] = []
            for key in chapter.pageRefs { if case .page(let page) = try await repository.resolve(key) { loaded.append(page) } }
            try Task.checkCancellation(); pages = loaded
            overrides = try app.store?.preference("overrides:" + chapter.key.id, as: [ObjectKey: SpreadOverride].self) ?? [:]
            let position = try app.store?.positions().first { $0.chapterKey == chapter.key }
            source = pages.first(where: { $0.key == position?.sourcePageKey })?.key ?? pages.first?.key
            fraction = position?.fractionalOffset ?? 0
            replan()
            loading = false
            if let key = chapter.mangaRef, let object = try? await repository.resolve(key), case .manga(let manga) = object,
               let i = manga.chapterRefs.firstIndex(where: { $0.key == chapter.key }), manga.chapterRefs.indices.contains(i + 1) { nextChapter = manga.chapterRefs[i + 1] }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    func replan() {
        planning?.cancel()
        let context = ReaderContext(size: size, preferences: app.preferences, analysis: analysis, overrides: overrides)
        let keys = pages.map(\.key)
        let ids = rule?.processors ?? ["identity", "marginAlign", "spreadDetect", "layout"]
        planning = Task {
            guard let pipeline = try? PagePipeline(ids: ids) else { return }
            let planned = await pipeline.plan(keys, context: context)
            guard !Task.isCancelled else { return }
            plans = planned; revision += 1; schedulePrefetch()
        }
    }
    func learn(_ key: ObjectKey, image: CGImage) {
        guard analysis[key] == nil else { return }
        analysis[key] = ImageProcessing.analyze(image); replan()
    }
    func move(_ delta: Int) {
        guard !plans.isEmpty else { return }
        record(index: min(plans.count - 1, max(0, index + delta)), within: 0, preserveSource: false)
        revision += 1; schedulePrefetch()
    }
    func record(index: Int, within: Double, preserveSource: Bool = true) {
        guard plans.indices.contains(index) else { return }
        let keys = plans[index].sourcePageKeys
        // Physical region order may be RTL. Progress follows original chapter order.
        let key = preserveSource && source.map(keys.contains) == true ? source : pages.first(where: { keys.contains($0.key) })?.key
        guard let key else { return }
        let old = source
        source = key; fraction = PagePipeline.fraction(index: index, withinPage: within, source: key, in: plans)
        if old != source { schedulePrefetch() }
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
        do { try app.store?.savePosition(ReadingPosition(mangaKey: chapter.mangaRef ?? chapter.key, chapterKey: chapter.key, sourcePageKey: source, fractionalOffset: fraction, title: chapter.title)) }
        catch { app.error = error.localizedDescription }
    }
    func stop() { save(); planning?.cancel(); prefetch?.cancel(); app.reloadLibrary() }
    func height(_ plan: DisplayPage, width: Double) -> Double {
        let aspect = plan.regions.reduce(0.0) { total, region in
            let ratio = analysis[region.sourcePage]?.aspectRatio ?? 0.727
            return total + ratio * Double(region.normalizedCrop.width / region.normalizedCrop.height)
        }
        return width / max(0.1, aspect)
    }
    private func schedulePrefetch() {
        prefetch?.cancel()
        guard let rule, !plans.isEmpty else { return }
        let neighborIndices = [index + 1, index - 1].filter { plans.indices.contains($0) }
        let keys = Set(neighborIndices.flatMap { plans[$0].sourcePageKeys })
        let neighbors = Array(pages.filter { keys.contains($0.key) }.prefix(3))
        prefetch = Task {
            var learned = false
            for page in neighbors {
                guard !Task.isCancelled else { return }
                do {
                    let image = try await app.images.image(for: page, rule: rule)
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
        if !Task.isCancelled { plans = newPlans; revision += 1 }
    }
}
