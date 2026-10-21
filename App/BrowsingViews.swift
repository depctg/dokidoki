import SwiftUI
import MangaCore

struct RootView: View {
    @Bindable var model: AppModel
    @State private var columns: NavigationSplitViewVisibility = .automatic
    #if os(visionOS)
    @Environment(\.pushWindow) private var pushWindow
    #endif
    var body: some View {
        Group {
            #if os(macOS)
            NavigationSplitView(columnVisibility: $columns) {
                List(selection: Binding<AppSection?>(get: { model.section }, set: { if let section = $0 { model.section = section } })) {
                    ForEach(AppSection.allCases) { section in
                        Label(section.title, systemImage: section.symbol).tag(section)
                    }
                }
                .navigationTitle(Text(verbatim: AppInfo.name))
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
        #elseif os(macOS)
        .sheet(isPresented: $model.readerExpanded) {
            ReaderPresentation(model: model).frame(minWidth: 600, idealWidth: 1000, minHeight: 600, idealHeight: 800)
        }
        #elseif os(visionOS)
        .onChange(of: model.readerExpanded) { _, expanded in
            if expanded { pushWindow(id: "reader") }
        }
        #endif
        .alert(Text(verbatim: AppInfo.name), isPresented: Binding(get: { model.error != nil && !model.readerExpanded }, set: { if !$0 { model.error = nil } })) {
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
            .toolbarTitleDisplayMode(.inlineLarge)
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .object(let key):
                    ObjectScreen(key: key, model: model, openChapter: { chapter in
                        if model.paths[section]?.last == .object(key) { model.paths[section]?.removeLast() }
                        model.presentChapter(chapter)
                    }, changeDirectory: { target in
                        if let index = model.paths[section]?.lastIndex(of: .object(key)) {
                            model.paths[section]?[index] = .object(target)
                        }
                    })
                case .search(let ruleID):
                    if let site = model.sites.first(where: { $0.id == ruleID }) { SiteSearchView(site: site, model: model) }
                    else { ContentUnavailableView("Site unavailable", systemImage: "globe") }
                }
            }
        }
    }

}

struct ObjectScreen: View {
    let key: ObjectKey
    let model: AppModel
    let openChapter: (ChapterObject) -> Void
    var isSearchResult = false
    let changeDirectory: (ObjectKey) -> Void
    @State private var object: ContentObject?
    @State private var error: String?
    @State private var loading = false
    @State private var refresh = 0
    private struct LoadIdentity: Hashable {
        let key: ObjectKey
        let revision: Int
        let refresh: Int
    }
    @State private var loadedIdentity: LoadIdentity?
    private var identity: LoadIdentity { LoadIdentity(key: key, revision: model.loadingRevision, refresh: refresh) }
    var body: some View {
        Group {
            if let object {
                switch object {
                case .site(let page):
                    ScrollView {
                        BrowseLists(model: model) { repository, hint in try await page.lists(using: repository, hint: hint) }
                            .padding(.vertical, 16)
                    }.navigationTitle(page.title)
                case .directory(let directory):
                    DirectoryView(directory: directory, model: model, isSearchResult: isSearchResult, changeSort: changeDirectory)
                case .manga(let manga): MangaView(manga: manga, model: model)
                case .chapter: ProgressView("Opening reader…")
                case .page(let page): PageImageView(page: page, model: model)
                }
            } else if loading { ProgressView("Opening content…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { ContentUnavailableView { Label("Could not open content", systemImage: "exclamationmark.triangle") } description: { Text(error ?? String(localized: "Try a supported URL.")) } actions: { Button("Retry") { refresh += 1 } } }
        }
        .id(loadedIdentity)
        .task(id: identity) {
            guard loadedIdentity != identity else { return }
            let sameContent = loadedIdentity?.key == key && loadedIdentity?.revision == model.loadingRevision
            if !sameContent { object = nil }
            await load(sameContent ? .forceRefresh : .preferCache)
        }
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { refresh += 1 }.disabled(loading)
                Link(destination: key.identityURL) { Label("Source website", systemImage: "safari") }
            }
        }
        .alert("Refresh failed", isPresented: Binding(get: { error != nil && object != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
    private func load(_ hint: CacheHint) async {
        guard let repository = model.repository else { return }
        let requestedIdentity = identity
        loading = true; error = nil
        defer { if !Task.isCancelled { loading = false } }
        do {
            let result = try await key.load(using: repository, hint: hint)
            try Task.checkCancellation()
            object = result; loadedIdentity = requestedIdentity
            if case .chapter(let chapter) = result { openChapter(chapter) }
        } catch is CancellationError {} catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}
