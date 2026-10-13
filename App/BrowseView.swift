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
                    BrowseLists(model: model) { repository, hint in try await site.load(using: repository, hint: hint) }
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
                    .disabled(model.browseSite?.supportsSearch != true)
                Menu {
                    Picker("Site", selection: Binding(get: { model.browseSite?.id ?? "" }, set: { model.browseSiteID = $0 })) {
                        ForEach(model.sites) { Text($0.name).tag($0.id) }
                    }
                } label: { Label("Switch site", systemImage: "globe") }
                .disabled(model.sites.isEmpty)
                Button("Open URL", systemImage: "link") { openingURL = true }
            }
        }
        .sheet(isPresented: $openingURL) { OpenURLView(model: model) }
        .onChange(of: model.openURLRequest, initial: true) { _, request in
            if request > 0 { openingURL = true; model.openURLRequest = 0 }
        }
        .onChange(of: model.loadingRevision) { _, _ in openingURL = false }
    }
}

struct SiteSearchView: View {
    let site: SiteObject
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
            do {
                guard let reference = try site.search(query.wrappedValue) else { return }
                model.searches[site.id, default: SiteSearchState()].resultKey = reference.key
                searchPresented = false
            } catch { model.report(error, operation: .openURL) }
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

/// View state is presentation only; the object/core layer assembles the site's lists.
struct BrowseLists: View {
    let model: AppModel
    let load: (ObjectRepository, CacheHint) async throws -> [DirectoryObject]
    @State private var directories: [DirectoryObject]?
    @State private var error: String?
    @State private var attempt = 0
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            if let directories {
                if directories.isEmpty {
                    ContentUnavailableView("No browse lists", systemImage: "books.vertical", description: Text("This site rule has no browse lists. Search the site or open a supported URL."))
                } else {
                    ForEach(directories) { BrowseShelf(directory: $0, model: model) }
                }
            } else if let error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.callout).foregroundStyle(.secondary)
                    Button("Retry") { attempt += 1 }
                }.padding(.horizontal, 20)
            } else { ProgressView("Loading titles…").padding(20) }
        }
        .task(id: "\(attempt)|\(model.loadingRevision)") {
            directories = nil; error = nil
            do {
                guard let repository = model.repository else { return }
                let loaded = try await load(repository, attempt > 0 ? .forceRefresh : .preferCache)
                try Task.checkCancellation(); directories = loaded
            } catch is CancellationError {} catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

private struct BrowseShelf: View {
    let directory: DirectoryObject
    let model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: AppRoute.object(directory.key)) {
                HStack(spacing: 6) {
                    Text(directory.title).font(.title2.bold())
                    Image(systemName: "chevron.right").font(.headline).foregroundStyle(.secondary)
                }.foregroundStyle(.primary)
            }.buttonStyle(.plain).padding(.horizontal, 20)
                .accessibilityIdentifier("browse.list.\(directory.key.identityURL.absoluteString)")
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
        }
    }
}

/// One lazy object load supplies the cover and metadata in shelves and directory rows.
struct MangaPreview: View {
    let reference: ContentReference
    let model: AppModel
    var shelf = false
    @State private var manga: MangaObject?
    var body: some View {
        Group {
            if shelf {
                VStack(alignment: .leading, spacing: 8) {
                    artwork.frame(width: 148, height: 210, alignment: .bottomLeading)
                    details
                }.frame(width: 148, alignment: .leading)
            } else {
                HStack(spacing: 14) {
                    artwork.frame(width: 52)
                    details
                }.padding(.vertical, 4)
            }
        }
        .task(id: "\(reference.id.id)|\(model.loadingRevision)") {
            manga = nil
            do {
                guard let repository = model.repository else { return }
                guard case .manga(let loaded) = try await reference.preview(using: repository) else { return }
                try Task.checkCancellation(); manga = loaded
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
        CoverImageView(key: manga?.coverPageRef, model: model, bounds: shelf ? CGSize(width: 148, height: 210) : CGSize(width: 52, height: 90))
    }
}
