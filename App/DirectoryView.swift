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
    @State private var phase = ScrollPhase.idle
    @State private var pull: CGFloat = 0
    private let threshold: CGFloat = 72
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
            ForEach(references) { ref in
                NavigationLink(value: AppRoute.object(ref.key)) { MangaPreview(reference: ref, model: model) }
                    .accessibilityIdentifier("manga.item.\(ref.key.id)")
            }
            if hasMore || loadingMore {
                HStack {
                    Spacer()
                    if loadingMore { ProgressView("Loading more…") }
                    else {
                        Button(action: requestMore) {
                            Label(pull >= threshold ? String(localized: "Release to load more") : String(localized: "Pull up to load more"), systemImage: "arrow.up")
                        }.accessibilityLabel("Load more")
                    }
                    Spacer()
                }.frame(minHeight: 44).listRowSeparator(.hidden)
                    .accessibilityIdentifier("directory.loadMore")
            } else if accumulated != nil {
                Text("No more titles").foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
        .accessibilityIdentifier("directory.list")
        .scrollBounceBehavior(.always)
        .onScrollGeometryChange(for: CGFloat.self) { distance($0) } action: { _, value in
            if phase == .interacting { pull = value }
        }
        .onScrollPhaseChange { old, new, context in
            phase = new
            if old == .interacting, new == .decelerating || new == .idle, distance(context.geometry) >= threshold { requestMore() }
            if new != .interacting { pull = 0 }
        }
        .task(id: loadRequest) {
            guard loadingMore, let repository = model.repository else { return }
            defer { loadingMore = false }
            do {
                let loaded = try await current.load(current.mangaRefs.count..<(current.mangaRefs.count + 20), using: repository)
                try Task.checkCancellation()
                accumulated = loaded
            } catch is CancellationError {} catch { if !Task.isCancelled { loadError = error.localizedDescription } }
        }
        .alert("Could not load more", isPresented: Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } })) {
            Button("Retry") { requestMore() }
            Button("Cancel", role: .cancel) {}
        } message: { Text(loadError ?? "") }
        .overlay { if references.isEmpty && !hasMore { ContentUnavailableView.search(text: query).allowsHitTesting(false) } }
    }
    private func requestMore() {
        guard hasMore, !loadingMore, model.repository != nil else { return }
        loadError = nil; loadingMore = true; loadRequest += 1
    }
    private func distance(_ geometry: ScrollGeometry) -> CGFloat {
        let end = max(-geometry.contentInsets.top, geometry.contentSize.height - geometry.containerSize.height + geometry.contentInsets.bottom)
        return max(0, geometry.contentOffset.y - end)
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
