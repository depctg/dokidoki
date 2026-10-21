import SwiftUI
import MangaCore

struct DirectoryView: View {
    let directory: DirectoryObject
    let model: AppModel
    var isSearchResult = false
    let changeSort: (ObjectKey) -> Void
    @State private var query = ""
    @State private var accumulated: DirectoryObject?
    @State private var loadingMore = false
    @State private var loadRequest = 0
    @State private var loadError: String?
    @State private var loadFailed = false
    private var current: DirectoryObject { accumulated ?? directory }
    private var hasMore: Bool { current.hasMore != false }
    private var references: [ContentReference] {
        current.mangaRefs.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
    }
    private var title: String {
        if isSearchResult { return String(localized: "Search results") }
        return directory.title
    }
    var body: some View {
        Group {
            if isSearchResult { list }
            else { list.searchable(text: $query, prompt: "Filter titles") }
        }
        .navigationTitle(title)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if !(directory.sortBy ?? []).isEmpty || !(directory.sortOrder ?? []).isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if let options = directory.sortBy, !options.isEmpty {
                            sortPicker("Sort by", options: options, selected: directory.selectedSortBy)
                        }
                        if let options = directory.sortOrder, !options.isEmpty {
                            sortPicker("Order", options: options, selected: directory.selectedSortOrder)
                        }
                    } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
                    .accessibilityIdentifier("directory.sort")
                }
            }
        }
    }
    private var list: some View {
        List {
            Section {
                ForEach(references) { ref in
                    NavigationLink(value: AppRoute.object(ref.key)) {
                        MangaPreview(reference: ref, model: model)
                    }
                    .accessibilityIdentifier("manga.item.\(ref.key.id)")
                    .onAppear {
                        if current.mangaRefs.suffix(5).contains(where: { $0.key == ref.key }) { requestMore() }
                    }
                }
            } footer: {
                Group {
                    if loadFailed {
                        Button("Retry", action: retry).buttonStyle(.plain)
                    } else {
                        Text(loadingMore ? String(localized: "Loading more…") : !hasMore ? String(localized: "No more titles") : String(localized: "More titles load as you scroll."))
                    }
                }
                .font(.footnote).foregroundStyle(.secondary).textCase(nil)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .accessibilityIdentifier("directory.footer")
                .onAppear { if current.mangaRefs.isEmpty { requestMore() } }
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("directory.list")
        .task(id: loadRequest) { [request = loadRequest] in
            guard !Task.isCancelled, loadingMore, let repository = model.repository else { return }
            defer { if loadRequest == request { loadingMore = false } }
            do {
                let loaded = try await current.load(current.mangaRefs.count..<(current.mangaRefs.count + 20), using: repository)
                try Task.checkCancellation()
                accumulated = loaded
            } catch is CancellationError {} catch {
                if !Task.isCancelled { loadFailed = true; loadError = error.localizedDescription }
            }
        }
        .alert("Could not load more", isPresented: Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } })) {
            Button("Retry", action: retry)
            Button("Cancel", role: .cancel) {}
        } message: { Text(loadError ?? "") }
        .overlay { if references.isEmpty && !hasMore { ContentUnavailableView.search(text: query).allowsHitTesting(false) } }
    }
    private func requestMore() {
        guard query.isEmpty, hasMore, !loadingMore, !loadFailed, model.repository != nil else { return }
        loadError = nil; loadingMore = true; loadRequest += 1
    }
    private func retry() {
        loadFailed = false
        requestMore()
    }
    private func sortPicker(_ title: LocalizedStringKey, options: [ContentReference], selected: ObjectKey?) -> some View {
        Picker(title, selection: Binding<ObjectKey?>(get: {
            options.first(where: { $0.key == (selected ?? directory.key) })?.key
        }, set: { key in
            if let key, key != directory.key { changeSort(key) }
        })) {
            ForEach(options) { option in Text(option.title).tag(Optional(option.key)) }
        }
    }
}
