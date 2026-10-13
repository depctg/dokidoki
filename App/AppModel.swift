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
    var preferences = ReaderPreferences() {
        didSet {
            do { try store?.setPreference("reader", value: preferences) }
            catch { report(error, operation: .storage) }
        }
    }
    var jumpToLastChapter = true {
        didSet {
            do { try store?.setPreference("jumpToLastChapter", value: jumpToLastChapter) }
            catch { report(error, operation: .storage) }
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
            repository = try ObjectRepository(store: store, rules: rules)
            reloadLibrary()
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
    func reloadLibrary() {
        do {
            saved = try store?.savedManga() ?? []
            readingPositions = try store?.positions() ?? []
            recent = try store?.positions(includeHidden: false) ?? []
        }
        catch { report(error, operation: .storage) }
    }
    func resumeManga(_ key: ObjectKey) {
        if let position = readingPositions.first(where: { $0.mangaKey == key }) { openChapter(position.chapterKey, listID: position.chapterListID); return }
        chapterRequest?.cancel(); openingChapter = true
        chapterRequest = Task {
            defer { if !Task.isCancelled { openingChapter = false } }
            do {
                guard let repository, case .manga(let manga) = try await key.load(using: repository, hint: .preferCache),
                      let first = manga.chapterRefs.first else { throw ReaderError.extraction(String(localized: "This manga has no chapters yet.")) }
                try Task.checkCancellation()
                openChapter(first.key, listID: manga.chapterList(containing: first.key)?.id)
            } catch is CancellationError {} catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func toggleStar(_ key: ObjectKey, title: String) {
        do {
            var manga = saved.first(where: { $0.key == key }) ?? SavedManga(key: key, title: title)
            manga.isStarred.toggle()
            try store?.setSaved(manga, saved: true)
            reloadLibrary()
        } catch { report(error, operation: .storage) }
    }
    func removeLibraryItem(_ key: ObjectKey, from section: AppSection) {
        do {
            if section == .recent { try store?.hideRecent(key) }
            else if let manga = saved.first(where: { $0.key == key }) { try store?.setSaved(manga, saved: false) }
            reloadLibrary()
        } catch { report(error, operation: .storage) }
    }
}
