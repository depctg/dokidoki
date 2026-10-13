import SwiftUI
import MangaCore

enum AppSection: String, CaseIterable, Identifiable {
    case library = "My Library", browse = "Browse", recent = "Recent", settings = "Settings"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .library: "books.vertical"
        case .browse: "safari"
        case .recent: "clock"
        case .settings: "gear"
        }
    }
}

@MainActor @Observable final class AppModel {
    var repository: ObjectRepository?
    var store: ObjectStore?
    let images = ImageLoader()
    var rules: [SiteRule] = [] { didSet { ruleRevision += 1 } }
    var ruleRevision = 0 { didSet { invalidateReader() } }
    var paths: [AppSection: [ObjectKey]] = [:]
    var path: [ObjectKey] {
        get { paths[section, default: []] }
        set { paths[section] = newValue }
    }
    var error: String?
    var saved: [SavedManga] = []
    var recent: [ReadingPosition] = []
    var readingPositions: [ReadingPosition] = []
    var preferences = ReaderPreferences() {
        didSet {
            do { try store?.setPreference("reader", value: preferences) }
            catch { self.error = error.localizedDescription }
        }
    }
    var section: AppSection = .library
    var openURLRequest = 0
    var chapterToReveal: ObjectKey?
    var readerImmersive = false
    var reader: ReaderModel?
    var readerExpanded = false
    var openingChapter = false
    private var chapterRequest: Task<Void, Never>?
    private var started = false

    func start() async {
        guard !started else { return }; started = true
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("MangaViewer", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let store = try ObjectStore(path: support.appendingPathComponent("library.sqlite").path)
            if try store.preference("seeded", as: Bool.self) != true {
                for rule in try DemoContent.bundledRules() { try store.saveRule(rule) }
                try store.setPreference("seeded", value: true)
            }
            for bundled in try DemoContent.bundledRules() {
                if let installed = try store.rules().first(where: { $0.id == bundled.id }), installed.version < bundled.version { try store.saveRule(bundled) }
            }
            rules = try store.rules(); self.store = store
            preferences = try store.preference("reader", as: ReaderPreferences.self) ?? ReaderPreferences()
            repository = try ObjectRepository(store: store, rules: rules, fetcher: RenderedSourceFetcher())
            reloadLibrary()
            if let index = CommandLine.arguments.firstIndex(of: "--open-url"), CommandLine.arguments.indices.contains(index + 1) {
                await open(CommandLine.arguments[index + 1])
            }
        } catch { self.error = error.localizedDescription }
    }
    func open(_ text: String) async {
        guard let repository, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { error = "Enter a supported HTTP or HTTPS URL."; return }
        do {
            let key = try await repository.key(for: url)
            if try RuleRegistry(rules: rules).match(url).1 == .chapter { openChapter(key) }
            else { section = .browse; path = [key] }
        }
        catch { self.error = error.localizedDescription }
    }
    func openChapter(_ key: ObjectKey, hint: CacheHint = .refreshIfStale, expand: Bool = true, preserveImmersion: Bool = false) {
        chapterRequest?.cancel()
        if reader?.chapter.key == key, hint != .forceRefresh {
            openingChapter = false
            if expand { resumeReader() }
            return
        }
        openingChapter = true
        chapterRequest = Task {
            defer { if !Task.isCancelled { openingChapter = false } }
            do {
                guard let repository, case .chapter(let chapter) = try await repository.resolve(key, hint: hint) else { throw ReaderError.extraction("This link does not contain a chapter.") }
                try Task.checkCancellation()
                presentChapter(chapter, expand: expand, preserveImmersion: preserveImmersion)
            } catch is CancellationError {} catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    func presentChapter(_ chapter: ChapterObject, expand: Bool = true, preserveImmersion: Bool = false) {
        chapterRequest?.cancel(); chapterRequest = nil; openingChapter = false
        reader?.stop()
        reader = ReaderModel(chapter: chapter, app: self)
        if !preserveImmersion { readerImmersive = false }
        readerExpanded = expand
    }
    func resumeReader() {
        guard reader != nil else { return }
        chapterRequest?.cancel(); chapterRequest = nil; openingChapter = false
        readerImmersive = false; readerExpanded = true
    }
    func collapseReader() {
        chapterRequest?.cancel(); openingChapter = false
        reader?.stop(); readerExpanded = false; readerImmersive = false
    }
    func showReaderManga() {
        guard let reader, let manga = reader.chapter.mangaRef else { return }
        collapseReader()
        chapterToReveal = reader.chapter.key
        section = .browse
        if let index = paths[.browse]?.firstIndex(of: manga) { paths[.browse] = Array(paths[.browse, default: []].prefix(index + 1)) }
        else { paths[.browse] = [manga] }
    }
    private func invalidateReader() {
        chapterRequest?.cancel(); openingChapter = false
        guard let reader else { return }
        let key = reader.chapter.key
        reader.stop(); self.reader = nil
        guard rules.contains(where: { $0.id == key.ruleID }) else { readerExpanded = false; return }
        openChapter(key, hint: .forceRefresh, expand: readerExpanded)
    }
    func reloadLibrary() {
        do {
            saved = try store?.savedManga() ?? []
            readingPositions = try store?.positions() ?? []
            recent = try store?.positions(includeHidden: false) ?? []
        }
        catch { self.error = error.localizedDescription }
    }
    func resumeManga(_ key: ObjectKey) {
        if let position = readingPositions.first(where: { $0.mangaKey == key }) { openChapter(position.chapterKey); return }
        chapterRequest?.cancel(); openingChapter = true
        chapterRequest = Task {
            defer { if !Task.isCancelled { openingChapter = false } }
            do {
                guard let repository, case .manga(let manga) = try await repository.resolve(key, hint: .preferCache),
                      let first = manga.chapterRefs.first else { throw ReaderError.extraction("This manga has no chapters yet.") }
                try Task.checkCancellation()
                openChapter(first.key)
            } catch is CancellationError {} catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func toggleStar(_ key: ObjectKey, title: String) {
        do {
            var manga = saved.first(where: { $0.key == key }) ?? SavedManga(key: key, title: title)
            manga.isStarred.toggle()
            try store?.setSaved(manga, saved: true)
            reloadLibrary()
        } catch { self.error = error.localizedDescription }
    }
    func removeLibraryItem(_ key: ObjectKey, from section: AppSection) {
        do {
            if section == .recent { try store?.hideRecent(key) }
            else if let manga = saved.first(where: { $0.key == key }) { try store?.setSaved(manga, saved: false) }
            reloadLibrary()
        } catch { self.error = error.localizedDescription }
    }
    func toggleSaved(_ manga: MangaObject) {
        do {
            try store?.setSaved(SavedManga(key: manga.key, title: manga.title), saved: !saved.contains { $0.key == manga.key })
            reloadLibrary()
        } catch { self.error = error.localizedDescription }
    }
}
