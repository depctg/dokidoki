import SwiftUI
import MangaCore

struct BrowseView: View {
    @Bindable var model: AppModel
    @State private var entry: BrowseEntry?
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
                Button("Search site", systemImage: "magnifyingglass") { entry = .search }
                    .disabled(model.browseSite?.searchURLTemplate == nil)
                Menu {
                    Picker("Site", selection: Binding(get: { model.browseSite?.id ?? "" }, set: { model.browseSiteID = $0 })) {
                        ForEach(model.rules) { Text($0.name).tag($0.id) }
                    }
                } label: { Label("Switch site", systemImage: "globe") }
                .disabled(model.rules.isEmpty)
                Button("Open URL", systemImage: "link") { entry = .url }
            }
        }
        .sheet(item: $entry) { entry in BrowseEntryView(entry: entry, site: model.browseSite, model: model) }
        .onChange(of: model.openURLRequest, initial: true) { _, request in
            if request > 0 { entry = .url; model.openURLRequest = 0 }
        }
        .onChange(of: model.ruleRevision) { _, _ in entry = nil }
    }
}

private enum BrowseEntry: String, Identifiable {
    case search, url
    var id: Self { self }
}

private struct BrowseEntryView: View {
    let entry: BrowseEntry
    let site: SiteRule?
    let model: AppModel
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    private var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        NavigationStack {
            Form {
                TextField(entry == .search ? "Search titles" : "Website URL", text: $text)
                    .focused($focused).onSubmit(submit)
                    #if !os(macOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    #endif
                if entry == .search, let site { Text(site.name).foregroundStyle(.secondary) }
            }
            .navigationTitle(entry == .search ? "Search site" : "Open URL")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(entry == .search ? "Search" : "Open", action: submit).disabled(query.isEmpty) }
            }
            .onAppear { focused = true }
        }.frame(minWidth: 300, idealWidth: 480, minHeight: 220)
            .presentationDetents([.medium])
    }
    private func submit() {
        guard !query.isEmpty else { return }
        focused = false
        if entry == .search {
            guard let site, let url = site.searchURL(query: query), let canonical = try? RuleRegistry.normalize(url) else { return }
            model.paths[.browse, default: []].append(ObjectKey(ruleID: site.id, identityURL: canonical))
        } else {
            let url = query
            Task { await model.open(url) }
        }
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
            NavigationLink(value: key) {
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
                                NavigationLink(value: reference.key) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        MangaCover(reference: reference, model: model).frame(width: 148, height: 210)
                                        Text(reference.title).font(.subheadline).lineLimit(2)
                                    }.frame(width: 148, alignment: .leading)
                                }.buttonStyle(.plain)
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

/// A bounded, lazy cover load shared by Browse shelves and directory rows.
struct MangaCover: View {
    let reference: ContentReference
    let model: AppModel
    @State private var cover: PageObject?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            if let cover { PageImageView(page: cover, model: model) }
            else { Image(systemName: "book.closed").font(.title).foregroundStyle(.secondary) }
        }
        .clipShape(.rect(cornerRadius: 8)).accessibilityHidden(true)
        .task(id: "\(reference.id.id)|\(model.ruleRevision)") {
            cover = nil
            do {
                guard let repository = model.repository, case .manga(let manga) = try await reference.load(using: repository, hint: .preferCache) else { return }
                let page = try await manga.coverPage(using: repository, hint: .preferCache)
                try Task.checkCancellation(); cover = page
            } catch { /* Keep the title and a placeholder if the cover is unavailable. */ }
        }
    }
}
