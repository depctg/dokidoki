import SwiftUI
import MangaCore

struct RootView: View {
    @Bindable var model: AppModel
    @State private var columns: NavigationSplitViewVisibility = .automatic
    var body: some View {
        Group {
            #if os(macOS)
            NavigationSplitView(columnVisibility: $columns) {
                List(selection: Binding<AppSection?>(get: { model.section }, set: { if let section = $0 { model.section = section } })) {
                    ForEach(AppSection.allCases) { section in
                        Label(section.title, systemImage: section.symbol).tag(section)
                    }
                }
                .navigationTitle("MangaViewer")
                .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            } detail: {
                navigation(for: model.section)
                    .id(model.section)
            }
            .safeAreaInset(edge: .top) {
                if let reader = model.reader, !model.readerExpanded {
                    ReaderResumeBar(reader: reader, model: model)
                        .frame(maxWidth: 600).glassEffect(.regular, in: .capsule).padding(8)
                }
            }
            #else
            TabView(selection: $model.section) {
                ForEach(AppSection.allCases) { section in
                    Tab(section.title, systemImage: section.symbol, value: section) {
                        navigation(for: section)
                    }
                }
            }
            .tabViewStyle(.tabBarOnly)
            #if os(iOS)
            .tabBarMinimizeBehavior(.onScrollDown)
            .modifier(ReaderTabAccessory(model: model))
            #else
            .ornament(visibility: model.reader != nil && !model.readerExpanded ? .visible : .hidden,
                      attachmentAnchor: .scene(.bottom)) {
                if let reader = model.reader {
                    ReaderResumeBar(reader: reader, model: model)
                        .frame(width: 440).glassBackgroundEffect(in: Capsule())
                }
            }
            #endif
            #endif
        }
        .overlay {
            if model.openingChapter && !model.readerExpanded { ProgressView("Opening chapter…").padding(20).background(.regularMaterial, in: .rect(cornerRadius: 16)) }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $model.readerExpanded) {
            ReaderPresentation(model: model).presentationBackground(.clear)
        }
        #else
        .sheet(isPresented: $model.readerExpanded) {
            ReaderPresentation(model: model).frame(minWidth: 600, idealWidth: 1000, minHeight: 600, idealHeight: 800)
        }
        #endif
        .alert("MangaViewer", isPresented: Binding(get: { model.error != nil && !model.readerExpanded }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private func navigation(for section: AppSection) -> some View {
        NavigationStack(path: Binding(get: { model.paths[section, default: []] }, set: { model.paths[section] = $0 })) {
            Group {
                switch section {
                case .library, .recent: LibraryView(model: model, section: section)
                case .browse: BrowseView(model: model)
                case .settings: SettingsView(model: model)
                }
            }
            .navigationDestination(for: ObjectKey.self) { key in
                ObjectScreen(key: key, model: model) { chapter in
                    if model.paths[section]?.last == key { model.paths[section]?.removeLast() }
                    model.presentChapter(chapter)
                }
            }
        }
    }

}

struct ObjectScreen: View {
    let key: ObjectKey
    let model: AppModel
    let openChapter: (ChapterObject) -> Void
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
                case .chapter: ProgressView("Opening reader…")
                case .page(let page): PageImageView(page: page, model: model)
                }
            } else if loading { ProgressView("Opening content…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { ContentUnavailableView { Label("Could not open content", systemImage: "exclamationmark.triangle") } description: { Text(error ?? String(localized: "Try a supported URL.")) } actions: { Button("Retry") { Task { await load(.forceRefresh) } } } }
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
        do {
            let result = if let object { try await object.reload(using: repository, hint: hint) }
                else { try await key.load(using: repository, hint: hint) }
            try Task.checkCancellation()
            object = result; revision = UUID()
            if case .chapter(let chapter) = result { openChapter(chapter) }
        }
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
                NavigationLink(value: ref.key) {
                    MangaPreview(reference: ref, model: model)
                }.accessibilityIdentifier("manga.item.\(ref.key.id)")
            }
            if let next = directory.nextURL {
                NavigationLink("Next directory page", value: ObjectKey(ruleID: directory.key.ruleID, identityURL: next))
            }
        }
        .overlay { if references.isEmpty { ContentUnavailableView.search(text: query) } }
        .searchable(text: $query, prompt: "Filter titles")
        .navigationTitle(model.rules.first(where: { $0.id == directory.key.ruleID })?.browse?.first(where: { (try? RuleRegistry.normalize($0.url)) == directory.key.identityURL })?.title ?? directory.title)
        .toolbar { ToolbarItem { Toggle("Sort by title", systemImage: "arrow.up.arrow.down", isOn: $sorted) } }
    }
}

struct MangaView: View {
    let manga: MangaObject
    let model: AppModel
    @State private var cover: PageObject?
    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    HStack(alignment: .top, spacing: 20) {
                        if let cover { PageImageView(page: cover, model: model).frame(width: 120, height: 180).clipShape(.rect(cornerRadius: 8)) }
                        VStack(alignment: .leading, spacing: 10) {
                            Text(manga.title).font(.title2.bold())
                            if let author = manga.author { Text(author).foregroundStyle(.secondary) }
                            MangaMetadataView(manga: manga)
                            if let summary = manga.summary { Text(summary).font(.callout).lineLimit(8) }
                        }
                    }.padding(.vertical, 12)
                    if let position = model.readingPositions.first(where: { $0.mangaKey == manga.key }) {
                        Button("Resume reading", systemImage: "play.fill") { model.openChapter(position.chapterKey) }
                    } else if let first = manga.chapterRefs.first {
                        Button("Start reading", systemImage: "play.fill") { model.openChapter(first.key) }
                    }
                }
                Section("\(manga.chapterRefs.count) chapters") {
                    ForEach(manga.chapterRefs) { chapter in
                        Button(chapter.title) { model.openChapter(chapter.key) }
                            .id(chapter.key)
                            .accessibilityValue(model.reader?.chapter.key == chapter.key ? String(localized: "Current chapter") : "")
                            .listRowBackground(model.reader?.chapter.key == chapter.key ? Color.accentColor.opacity(0.15) : nil)
                    }
                    if manga.chapterRefs.isEmpty { Text("No chapters are available on this page.").foregroundStyle(.secondary) }
                }
            }.navigationTitle(manga.title)
            .toolbar { ToolbarItem { Button(model.saved.contains { $0.key == manga.key } ? String(localized: "Unsave") : String(localized: "Save"), systemImage: "bookmark") { model.toggleSaved(manga) } } }
            .task(id: manga.coverPageRef) {
                if let repository = model.repository { cover = try? await manga.coverPage(using: repository) }
            }
            .task(id: model.chapterToReveal) {
                if let key = model.chapterToReveal, manga.chapterRefs.contains(where: { $0.key == key }) {
                    await Task.yield()
                    guard !Task.isCancelled, model.chapterToReveal == key else { return }
                    proxy.scrollTo(key, anchor: .center)
                    model.chapterToReveal = nil
                }
            }
        }
    }
}
