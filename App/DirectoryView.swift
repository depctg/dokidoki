import SwiftUI
import MangaCore

struct DirectoryView: View {
    let directory: DirectoryObject
    let model: AppModel
    var isSearchResult = false
    let changeSort: (ObjectKey) -> Void
    @State private var query = ""
    private var references: [ContentReference] {
        directory.mangaRefs.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
    }
    private var title: String {
        if isSearchResult { return String(localized: "Search results") }
        return model.rules.first(where: { $0.id == directory.key.ruleID })?.browse?
            .first(where: { (try? RuleRegistry.normalize($0.url)) == directory.key.identityURL })?.title ?? directory.title
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
            if let next = directory.nextURL {
                NavigationLink("Next directory page", value: AppRoute.object(ObjectKey(ruleID: directory.key.ruleID, identityURL: next)))
            }
        }
        .accessibilityIdentifier("directory.list")
        .overlay { if references.isEmpty { ContentUnavailableView.search(text: query) } }
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
