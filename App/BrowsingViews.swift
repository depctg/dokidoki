import SwiftUI
import MangaCore

struct RootView: View {
    @Bindable var model: AppModel
    @State private var urlText = "https://www.manhuagui.com/"
    @FocusState private var urlFocused: Bool
    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.section }, set: { model.path = []; model.section = $0 })) {
                Label("Browse", systemImage: "safari").tag("Browse")
                Label("My Library", systemImage: "books.vertical").tag("My Library")
                Label("Settings", systemImage: "gear").tag("Settings")
            }
            .navigationTitle("MangaViewer")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            NavigationStack(path: $model.path) {
                Group {
                    if model.section == "Settings" { SettingsView(model: model) }
                    else if model.section == "My Library" { LibraryView(model: model) }
                    else { browse }
                }
                .navigationDestination(for: ObjectKey.self) { ObjectScreen(key: $0, model: model) }
            }
        }
        .alert("MangaViewer", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onChange(of: model.openURLRequest) { _, _ in urlFocused = true }
    }
    private var browse: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "book.pages").font(.system(size: 52)).foregroundStyle(.tint)
                Text("Your next chapter").font(.largeTitle.bold())
                Text("Open a supported URL, or explore the bundled reading room.").foregroundStyle(.secondary)
                HStack {
                    TextField("Website URL", text: $urlText).textFieldStyle(.roundedBorder)
                        .focused($urlFocused)
                        .onSubmit { Task { await model.open(urlText) } }
                    Button("Open", systemImage: "arrow.right") { Task { await model.open(urlText) } }.buttonStyle(.borderedProminent)
                }
                Button { Task { await model.open(DemoContent.directoryURL.absoluteString) } } label: {
                    Label("Open the reading room", systemImage: "sparkles").padding(.vertical, 8)
                }.buttonStyle(.bordered)
                ForEach(model.rules.filter { $0.id != "demo" }) { rule in
                    VStack(alignment: .leading) {
                        Text(rule.name).font(.headline)
                        Text(rule.allowedHosts.first ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(32).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }.navigationTitle("Browse")
    }
}

struct ObjectScreen: View {
    let key: ObjectKey
    let model: AppModel
    @State private var object: ContentObject?
    @State private var error: String?
    @State private var loading = false
    @State private var revision = UUID()
    var body: some View {
        Group {
            if let object {
                switch object {
                case .directory(let directory): DirectoryView(directory: directory, model: model)
                case .manga(let manga): MangaView(manga: manga, model: model)
                case .chapter(let chapter): ReaderView(chapter: chapter, model: model)
                case .page(let page): PageImageView(page: page, model: model)
                }
            } else if loading { ProgressView("Opening content…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { ContentUnavailableView { Label("Could not open content", systemImage: "exclamationmark.triangle") } description: { Text(error ?? "Try a supported URL.") } actions: { Button("Retry") { Task { await load(.forceRefresh) } } } }
        }
        .id(revision)
        .task(id: "\(key.id)|\(model.ruleRevision)") { object = nil; await load(.refreshIfStale) }
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load(.forceRefresh) } }.disabled(loading)
            }
            ToolbarItem { Link(destination: key.identityURL) { Label("Source website", systemImage: "safari") } }
        }
        .alert("Refresh failed", isPresented: Binding(get: { error != nil && object != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
    private func load(_ hint: CacheHint) async {
        guard let repository = model.repository else { return }
        loading = true; error = nil; defer { loading = false }
        do { let result = try await repository.resolve(key, hint: hint); try Task.checkCancellation(); object = result; revision = UUID() }
        catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

struct DirectoryView: View {
    let directory: DirectoryObject
    let model: AppModel
    @State private var query = ""
    @State private var sorted = false
    private var references: [ContentReference] {
        let refs = directory.mangaRefs.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
        return sorted ? refs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } : refs
    }
    var body: some View {
        List {
            ForEach(references) { ref in
                NavigationLink(value: ref.key) { Label(ref.title, systemImage: "book.closed").padding(.vertical, 5) }
            }
            if let next = directory.nextURL {
                Button("Next directory page") { Task { await model.open(next.absoluteString) } }
            }
            if !query.isEmpty, let rule = model.rules.first(where: { $0.id == directory.key.ruleID }), let search = rule.searchURL(query: query) {
                Button("Search \(rule.name) for “\(query)”") { Task { await model.open(search.absoluteString) } }
            }
        }
        .overlay { if references.isEmpty { ContentUnavailableView.search(text: query) } }
        .searchable(text: $query, prompt: "Filter titles")
        .navigationTitle(directory.title)
        .toolbar { ToolbarItem { Toggle("Sort by title", systemImage: "arrow.up.arrow.down", isOn: $sorted) } }
    }
}

struct MangaView: View {
    let manga: MangaObject
    let model: AppModel
    @State private var cover: PageObject?
    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 20) {
                    if let cover { PageImageView(page: cover, model: model).frame(width: 120, height: 180).clipShape(.rect(cornerRadius: 8)) }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(manga.title).font(.title2.bold())
                        if let author = manga.author { Text(author).foregroundStyle(.secondary) }
                        if let summary = manga.summary { Text(summary).font(.callout).lineLimit(8) }
                    }
                }.padding(.vertical, 12)
                if let position = model.recent.first(where: { $0.mangaKey == manga.key }) {
                    NavigationLink(value: position.chapterKey) { Label("Resume reading", systemImage: "play.fill") }
                } else if let first = manga.chapterRefs.first {
                    NavigationLink(value: first.key) { Label("Start reading", systemImage: "play.fill") }
                }
            }
            Section("\(manga.chapterRefs.count) chapters") {
                ForEach(manga.chapterRefs) { chapter in NavigationLink(chapter.title, value: chapter.key) }
                if manga.chapterRefs.isEmpty { Text("No chapters are available on this page.").foregroundStyle(.secondary) }
            }
        }.navigationTitle(manga.title)
        .toolbar { ToolbarItem { Button(model.saved.contains { $0.key == manga.key } ? "Unsave" : "Save", systemImage: "bookmark") { model.toggleSaved(manga) } } }
        .task(id: manga.coverPageRef) {
            if let key = manga.coverPageRef, let object = try? await model.repository?.resolve(key), case .page(let page) = object { cover = page }
        }
    }
}

struct LibraryView: View {
    let model: AppModel
    var body: some View {
        List {
            Section("Saved manga") { ForEach(model.saved) { NavigationLink($0.title, value: $0.key) } }
            Section("Recent reading") {
                ForEach(model.recent, id: \.mangaKey) { position in
                    NavigationLink(value: position.chapterKey) { VStack(alignment: .leading) { Text(position.title); Text(position.updatedAt, style: .relative).font(.caption).foregroundStyle(.secondary) } }
                }
            }
        }.navigationTitle("My Library")
            .overlay { if model.saved.isEmpty && model.recent.isEmpty { ContentUnavailableView("Make room for a story", systemImage: "books.vertical", description: Text("Saved titles and your reading history appear here.")) } }
            .onAppear { model.reloadLibrary() }
    }
}
