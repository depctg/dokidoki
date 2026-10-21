import SwiftUI
import MangaCore

enum AppRoute: Hashable {
    case object(ObjectKey)
    case search(String)
}
struct SiteSearchState {
    var query = ""
    var resultKey: ObjectKey?
}

enum AppSection: String, CaseIterable, Identifiable {
    case library = "My Library", browse = "Browse", recent = "Recent", settings = "Settings"
    var id: Self { self }
    var title: String {
        switch self {
        case .library: String(localized: "My Library")
        case .browse: String(localized: "Browse")
        case .recent: String(localized: "Recent")
        case .settings: String(localized: "Settings")
        }
    }
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
    var rules: [SiteRule] = [] {
        didSet {
            do { sites = try rules.map { try SiteObject(rule: $0) } }
            catch { report(error, operation: .storage) }
            // Reordering is a browsing preference, not a recipe change or reader refresh.
            if Dictionary(uniqueKeysWithValues: oldValue.map { ($0.id, $0.version) }) != Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0.version) }) { ruleRevision += 1 }
            if !rules.contains(where: { $0.id == browseSiteID }) { browseSiteID = nil }
        }
    }
    private(set) var sites: [SiteObject] = []
    var browseSiteID: String?
    var browseSite: SiteObject? { sites.first(where: { $0.id == browseSiteID }) ?? sites.first }
    var ruleRevision = 0 { didSet { loadingRevision += 1; invalidateReader() } }
    var loadingRevision = 0
    var paths: [AppSection: [AppRoute]] = [:]
    var searches: [String: SiteSearchState] = [:]
    var path: [AppRoute] {
        get { paths[section, default: []] }
        set { paths[section] = newValue }
    }
    var error: String?
    var saved: [SavedManga] = []
    var recent: [ReadingPosition] = []
    var readingPositions: [ReadingPosition] = []
    private(set) var personalManga: [ObjectKey: MangaObject] = [:]
    private(set) var libraryRevision = 0
    var preferences = ReaderPreferences() {
        didSet {
            guard let repository else { return }
            let preferences = preferences
            persist { try await repository.setPreference("reader", value: preferences) }
        }
    }
    var jumpToLastChapter = true {
        didSet {
            guard let repository else { return }
            let enabled = jumpToLastChapter
            persist { try await repository.setPreference("jumpToLastChapter", value: enabled) }
        }
    }
    var section: AppSection = .library
    private(set) var backgroundLoading = true
    var openURLRequest = 0
    var chapterToReveal: ObjectKey?
    var readerImmersive = false
    var reader: ReaderModel?
    var readerExpanded = false
    var openingChapter = false
    private var chapterRequest: Task<Void, Never>?
    private var libraryObservation: Task<Void, Never>?
    private var persistence: Task<Void, Never>?
    private var started = false

    func start() async {
        guard !started else { return }; started = true
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("MangaViewer", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let store = try ObjectStore(path: support.appendingPathComponent("library.sqlite").path)
            try store.applyBundledRules(DemoContent.bundledRules())
            rules = try store.rules(); self.store = store
            backgroundLoading = try store.preference("backgroundLoading", as: Bool.self) ?? true
            jumpToLastChapter = try store.preference("jumpToLastChapter", as: Bool.self) ?? true
            preferences = try store.preference("reader", as: ReaderPreferences.self) ?? ReaderPreferences()
            let repository = try ObjectRepository(store: store, rules: rules)
            self.repository = repository
            applyLibrary(try await repository.personalLibrary())
            libraryObservation = Task { [weak self] in
                do {
                    for try await manga in store.libraryUpdates() { self?.applyLibrary(manga) }
                } catch is CancellationError {} catch { self?.report(error, operation: .storage) }
            }
            if let index = CommandLine.arguments.firstIndex(of: "--open-url"), CommandLine.arguments.indices.contains(index + 1) {
                await open(CommandLine.arguments[index + 1])
            }
        } catch { report(error, operation: .startup) }
    }
    func open(_ text: String) async {
        guard let repository, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { error = String(localized: "Enter a supported HTTP or HTTPS URL."); return }
        do {
            let (key, kind) = try await repository.match(url)
            if kind == .chapter { openChapter(key) }
            else { browseSiteID = key.ruleID; section = .browse; path = [.object(key)] }
        }
        catch { report(error, operation: .openURL, url: url) }
    }
    func report(_ error: any Error, operation: ErrorDiagnostics.Operation, url: URL? = nil) {
        ErrorDiagnostics.record(error, operation: operation, url: url)
        self.error = error.localizedDescription
    }
    func setBackgroundLoading(_ enabled: Bool) async {
        guard backgroundLoading != enabled else { return }
        let previous = backgroundLoading
        backgroundLoading = enabled
        do {
            try await repository?.setBackgroundLoading(enabled)
            loadingRevision += 1 // Retry canceled metadata without discarding the loaded reader.
        } catch { backgroundLoading = previous; report(error, operation: .storage) }
    }
    func moveRules(from offsets: IndexSet, to destination: Int) {
        var reordered = rules; reordered.move(fromOffsets: offsets, toOffset: destination)
        do {
            try store?.setRuleOrder(reordered.map(\.id)); rules = reordered
            browseSiteID = nil; paths[.browse] = []
        } catch { report(error, operation: .storage) }
    }
    func openChapter(_ key: ObjectKey, hint: CacheHint = .preferCache, expand: Bool = true, preserveImmersion: Bool = false, fromEnd: Bool = false, listID: String? = nil) {
        chapterRequest?.cancel()
        if reader?.chapter.key == key, hint != .forceRefresh, listID == nil || reader?.chapterListID == listID {
            openingChapter = false
            if expand { resumeReader() }
            return
        }
        openingChapter = true
        chapterRequest = Task {
            defer { if !Task.isCancelled { openingChapter = false } }
            do {
                guard let repository else { return }
                var loaded: ContentObject?
                repeat {
                    let policy = backgroundLoading
                    do { loaded = try await key.load(using: repository, hint: hint) }
                    catch is CancellationError {
                        try Task.checkCancellation()
                        guard policy != backgroundLoading else { throw CancellationError() }
                    }
                } while loaded == nil
                guard case .chapter(let chapter) = loaded else { throw ReaderError.extraction(String(localized: "This link does not contain a chapter.")) }
                try Task.checkCancellation()
                presentChapter(chapter, expand: expand, preserveImmersion: preserveImmersion, fromEnd: fromEnd, listID: listID)
            } catch is CancellationError {} catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    func presentChapter(_ chapter: ChapterObject, expand: Bool = true, preserveImmersion: Bool = false, fromEnd: Bool = false, listID: String? = nil) {
        chapterRequest?.cancel(); chapterRequest = nil; openingChapter = false
        reader?.stop()
        reader = ReaderModel(chapter: chapter, app: self, startAtEnd: fromEnd, listID: listID)
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
        browseSiteID = manga.ruleID
        section = .browse
        if let index = paths[.browse]?.firstIndex(of: .object(manga)) { paths[.browse] = Array(paths[.browse, default: []].prefix(index + 1)) }
        else { paths[.browse] = [.object(manga)] }
    }
    private func invalidateReader() {
        chapterRequest?.cancel(); openingChapter = false
        guard let reader else { return }
        let key = reader.chapter.key
        reader.stop(); self.reader = nil
        guard rules.contains(where: { $0.id == key.ruleID }) else { readerExpanded = false; return }
        openChapter(key, hint: .forceRefresh, expand: readerExpanded, listID: reader.chapterListID)
    }
    /// Preserve action order across chapter replacement; disappearing reader tasks
    /// must not cancel the final durable position write.
    func persist(_ operation: @escaping @Sendable () async throws -> Void) {
        let previous = persistence
        persistence = Task {
            await previous?.value
            do { try await operation() }
            catch { report(error, operation: .storage) }
        }
    }
    func finishPersistence() async { await persistence?.value }
    private func applyLibrary(_ manga: [MangaObject]) {
        let updated = Dictionary(uniqueKeysWithValues: manga.map { ($0.key, $0) })
        guard updated != personalManga else { return }
        personalManga = updated
        saved = manga.compactMap { item in
            guard let state = item.personalState, state.isSaved else { return nil }
            return SavedManga(key: item.key, title: item.title, isStarred: state.isStarred)
        }
        readingPositions = manga.compactMap { $0.personalState?.position }.sorted { $0.updatedAt > $1.updatedAt }
        recent = readingPositions.filter { personalManga[$0.mangaKey]?.personalState?.isRecentHidden != true }
        libraryRevision += 1
    }
    func resumeManga(_ key: ObjectKey, manga known: MangaObject? = nil) {
        if reader?.chapter.mangaRef == key { resumeReader(); return }
        chapterRequest?.cancel(); openingChapter = true
        chapterRequest = Task {
            defer { if !Task.isCancelled { openingChapter = false } }
            do {
                guard let repository else { return }
                await finishPersistence()
                try Task.checkCancellation()
                let snapshot = known ?? personalManga[key] ?? MangaObject(key: key, sourceURL: key.identityURL, title: "")
                let local: MangaObject
                do { local = try await snapshot.readingState(using: repository) }
                catch { ErrorDiagnostics.record(error, operation: .storage); throw error }
                try Task.checkCancellation()
                if let position = local.personalState?.position {
                    openChapter(position.chapterKey, listID: position.chapterListID); return
                }
                guard case .manga(let manga) = try await key.load(using: repository, hint: .preferCache),
                      let first = manga.chapterRefs.first else { throw ReaderError.extraction(String(localized: "This manga has no chapters yet.")) }
                try Task.checkCancellation()
                openChapter(first.key, listID: manga.chapterList(containing: first.key)?.id)
            } catch is CancellationError {} catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func toggleStar(_ key: ObjectKey, title: String, manga known: MangaObject? = nil) {
        guard let repository else { return }
        let manga = known ?? personalManga[key] ?? MangaObject(key: key, sourceURL: key.identityURL, title: title)
        persist { try await manga.toggleStar(using: repository) }
    }
    func removeLibraryItem(_ key: ObjectKey, from section: AppSection) {
        guard let repository, let manga = personalManga[key] else { return }
        persist {
            if section == .recent { try await manga.hideFromRecent(using: repository) }
            else { try await manga.removeFromLibrary(using: repository) }
        }
    }
}
