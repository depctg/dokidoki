import SwiftUI
import MangaCore

struct BrowseView: View {
    @Bindable var model: AppModel
    @State private var openingURL = false
    var body: some View {
        ScrollView {
            if model.section != .browse { Color.clear }
            else if let site = model.browseSite {
                LazyVStack(alignment: .leading, spacing: 28) {
                    Text(site.name).font(.title2.bold()).padding(.horizontal, 20)
                        .accessibilityIdentifier("browse.siteTitle")
                    if let lists = site.browse, !lists.isEmpty {
                        ForEach(lists) { list in BrowseShelf(list: list, ruleID: site.id, model: model) }
                    } else {
                        ContentUnavailableView("No browse lists", systemImage: "books.vertical", description: Text("This site rule has no browse lists. Search the site or open a supported URL."))
                    }
                }.padding(.vertical, 16).id("\(site.id)|\(site.version)")
            } else {
                ContentUnavailableView("No sites installed", systemImage: "globe", description: Text("Import or restore a site rule in Settings."))
            }
        }
        .navigationTitle("Browse")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Search site", systemImage: "magnifyingglass") {
                    if let site = model.browseSite { model.paths[.browse, default: []].append(.search(site.id)) }
                }
                    .disabled(model.browseSite?.searchURLTemplate == nil)
                Menu {
                    Picker("Site", selection: Binding(get: { model.browseSite?.id ?? "" }, set: { model.browseSiteID = $0 })) {
                        ForEach(model.rules) { Text($0.name).tag($0.id) }
                    }
                } label: { Label("Switch site", systemImage: "globe") }
                .disabled(model.rules.isEmpty)
                Button("Open URL", systemImage: "link") { openingURL = true }
            }
        }
        .sheet(isPresented: $openingURL) { OpenURLView(model: model) }
        .onChange(of: model.openURLRequest, initial: true) { _, request in
            if request > 0 { openingURL = true; model.openURLRequest = 0 }
        }
        .onChange(of: model.ruleRevision) { _, _ in openingURL = false }
    }
}

struct SiteSearchView: View {
    let site: SiteRule
    let model: AppModel
    @State private var searchPresented = false
    private var resultKey: ObjectKey? { model.searches[site.id]?.resultKey }
    private var query: Binding<String> {
        Binding(get: { model.searches[site.id]?.query ?? "" }, set: { model.searches[site.id, default: SiteSearchState()].query = $0 })
    }
    var body: some View {
        Group {
            if let resultKey {
                ObjectScreen(key: resultKey, model: model, openChapter: { model.presentChapter($0) }, isSearchResult: true,
                             changeDirectory: { model.searches[site.id, default: SiteSearchState()].resultKey = $0 })
                    .id(resultKey)
            } else {
                ContentUnavailableView("Search this site", systemImage: "magnifyingglass", description: Text(site.name))
            }
        }
        .navigationTitle("Search results")
        .searchable(text: query, isPresented: $searchPresented, prompt: "Search titles")
        .onAppear { if resultKey == nil { searchPresented = true } }
        .onSubmit(of: .search) {
            let text = query.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let url = site.searchURL(query: text), let canonical = try? RuleRegistry.normalize(url) else { return }
            model.searches[site.id, default: SiteSearchState()].resultKey = ObjectKey(ruleID: site.id, identityURL: canonical)
            searchPresented = false
        }
    }
}

private struct OpenURLView: View {
    let model: AppModel
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    private var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Website URL", text: $text)
                    .focused($focused).onSubmit(submit)
                    #if !os(macOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    #endif
            }
            .navigationTitle("Open URL")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Open", action: submit).disabled(query.isEmpty) }
            }
            .onAppear { focused = true }
        }.frame(minWidth: 300, idealWidth: 480, minHeight: 220)
            .presentationDetents([.medium])
    }
    private func submit() {
        guard !query.isEmpty else { return }
        focused = false
        let url = query
        Task { await model.open(url) }
        dismiss()
    }
}

private struct BrowseShelf: View {
    let list: BrowseList
    let ruleID: String
    let model: AppModel
    @State private var directory: DirectoryObject?
    @State private var error: String?
    @State private var attempt = 0
    private var key: ObjectKey { ObjectKey(ruleID: ruleID, identityURL: list.url) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: AppRoute.object(key)) {
                HStack(spacing: 6) {
                    Text(list.title).font(.title2.bold())
                    Image(systemName: "chevron.right").font(.headline).foregroundStyle(.secondary)
                }.foregroundStyle(.primary)
            }.buttonStyle(.plain).padding(.horizontal, 20)
                .accessibilityIdentifier("browse.list.\(list.url.absoluteString)")
            if let directory {
                if directory.mangaRefs.isEmpty {
                    Text("No titles in this list.").foregroundStyle(.secondary).padding(.horizontal, 20)
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 16) {
                            ForEach(Array(directory.mangaRefs.prefix(8))) { reference in
                                NavigationLink(value: AppRoute.object(reference.key)) {
                                    MangaPreview(reference: reference, model: model, shelf: true)
                                }.buttonStyle(.plain).accessibilityIdentifier("manga.item.\(reference.key.id)")
                            }
                        }.scrollTargetLayout()
                    }
                    .contentMargins(.horizontal, 20, for: .scrollContent)
                    .scrollIndicators(.hidden).scrollTargetBehavior(.viewAligned)
                }
            } else if let error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.callout).foregroundStyle(.secondary)
                    Button("Retry") { attempt += 1 }
                }.padding(.horizontal, 20)
            } else { ProgressView("Loading titles…").padding(20) }
        }
        .task(id: "\(attempt)|\(model.ruleRevision)") {
            error = nil
            do {
                guard let repository = model.repository, case .directory(let loaded) = try await key.load(using: repository, hint: attempt > 0 ? .forceRefresh : .refreshIfStale) else { return }
                try Task.checkCancellation(); directory = loaded
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

/// One lazy object load supplies the cover and metadata in shelves and directory rows.
struct MangaPreview: View {
    let reference: ContentReference
    let model: AppModel
    var shelf = false
    @State private var manga: MangaObject?
    @State private var cover: PageObject?
    var body: some View {
        Group {
            if shelf {
                VStack(alignment: .leading, spacing: 8) {
                    artwork.frame(width: 148, height: 210)
                    details
                }.frame(width: 148, alignment: .leading)
            } else {
                HStack(spacing: 14) {
                    artwork.frame(width: 52, height: 76)
                    details
                }.padding(.vertical, 4)
            }
        }
        .task(id: "\(reference.id.id)|\(model.ruleRevision)") {
            manga = nil; cover = nil
            do {
                guard let repository = model.repository, case .manga(let loaded) = try await reference.load(using: repository, hint: .preferCache) else { return }
                try Task.checkCancellation(); manga = loaded
                let page = try await loaded.coverPage(using: repository, hint: .preferCache)
                try Task.checkCancellation(); cover = page
            } catch { /* Keep the title and available metadata if the source or cover is unavailable. */ }
        }
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(manga?.title ?? reference.title).font(shelf ? .subheadline : .headline).lineLimit(2)
            if let manga { MangaMetadataView(manga: manga, compact: true) }
        }
    }
    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            if let cover { PageImageView(page: cover, model: model) }
            else { Image(systemName: "book.closed").font(.title).foregroundStyle(.secondary) }
        }
        .clipShape(.rect(cornerRadius: 8)).accessibilityHidden(true)
    }
}
