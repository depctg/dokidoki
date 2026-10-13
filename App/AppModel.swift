import SwiftUI
import MangaCore

enum AppSection: String, CaseIterable, Identifiable {
    case library = "My Library", browse = "Browse", settings = "Settings"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .library: "books.vertical"
        case .browse: "safari"
        case .settings: "gear"
        }
    }
}

@MainActor @Observable final class AppModel {
    var repository: ObjectRepository?
    var store: ObjectStore?
    let images = ImageLoader()
    var rules: [SiteRule] = [] { didSet { ruleRevision += 1 } }
    var ruleRevision = 0
    var paths: [AppSection: [ObjectKey]] = [:]
    var path: [ObjectKey] {
        get { paths[section, default: []] }
        set { paths[section] = newValue }
    }
    var error: String?
    var saved: [SavedManga] = []
    var recent: [ReadingPosition] = []
    var preferences = ReaderPreferences() {
        didSet {
            do { try store?.setPreference("reader", value: preferences) }
            catch { self.error = error.localizedDescription }
        }
    }
    var section: AppSection = .library
    var openURLRequest = 0
    var readerImmersive = false
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
        do { let key = try await repository.key(for: url); section = .browse; path = [key] }
        catch { self.error = error.localizedDescription }
    }
    func reloadLibrary() {
        do { saved = try store?.savedManga() ?? []; recent = try store?.positions() ?? [] }
        catch { self.error = error.localizedDescription }
    }
    func toggleSaved(_ manga: MangaObject) {
        do {
            try store?.setSaved(SavedManga(key: manga.key, title: manga.title), saved: !saved.contains { $0.key == manga.key })
            reloadLibrary()
        } catch { self.error = error.localizedDescription }
    }
}
