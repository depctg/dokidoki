import SwiftUI
import MangaCore

struct LibraryView: View {
    let model: AppModel
    let section: AppSection
    private var keys: [ObjectKey] {
        if section == .recent { return model.recent.map(\.mangaKey) }
        return model.saved.sorted {
            if $0.isStarred != $1.isStarred { return $0.isStarred }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }.map(\.key)
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            List(keys, id: \.self) { key in
                LibraryRow(key: key, model: model, section: section, now: timeline.date)
            }
            .overlay {
                if keys.isEmpty {
                    ContentUnavailableView(section == .recent ? String(localized: "Your next chapter awaits") : String(localized: "Make room for a story"),
                        systemImage: section.symbol,
                        description: Text(section == .recent ? String(localized: "Manga you read appears here.") : String(localized: "Save manga while browsing, or star a title in Recent to add it here.")))
                }
            }
        }
        .navigationTitle(section.title)
        .onAppear { model.reloadLibrary() }
    }
}

private struct LibraryRow: View {
    let key: ObjectKey
    let model: AppModel
    let section: AppSection
    let now: Date
    @State private var manga: MangaObject?
    @State private var cover: PageObject?
    @State private var cachedChapter: ChapterObject?
    private var saved: SavedManga? { model.saved.first { $0.key == key } }
    private var position: ReadingPosition? { model.readingPositions.first { $0.mangaKey == key } }
    private var title: String { manga?.title ?? saved?.title ?? position?.mangaTitle ?? position?.title ?? String(localized: "Untitled manga") }
    private var starred: Bool { saved?.isStarred == true }
    private var chapterTitle: String { position?.title ?? manga?.chapterRefs.first?.title ?? String(localized: "Not started") }
    private var pageNumber: Int? {
        guard let position else { return 0 }
        return position.pageNumber ?? cachedChapter?.pageRefs.firstIndex(of: position.sourcePageKey).map { $0 + 1 }
    }
    private var totalPages: Int? { position?.totalPages ?? cachedChapter?.pageRefs.count }
    private var progress: String { String(localized: "Page \(pageNumber.map { $0.formatted() } ?? "—") / \(totalPages.map { $0.formatted() } ?? "—")") }
    private var lastRead: String {
        guard let date = position?.updatedAt else { return String(localized: "Not read yet") }
        let hours = max(0, Int(now.timeIntervalSince(date) / 3600))
        if hours < 1 { return String(localized: "Last read <1 hr ago") }
        if hours < 24 { return String(localized: "Last read \(hours) hr ago") }
        let days = hours / 24
        return String(localized: "Last read \(days) days ago", comment: "Whole days since the last reading session; varies by plural.")
    }
    var body: some View {
        Button { model.resumeManga(key) } label: {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    if let cover { PageImageView(page: cover, model: model) }
                    else { Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary) }
                }
                .frame(width: 76, height: 108).clipShape(.rect(cornerRadius: 8))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title).font(.headline).lineLimit(2)
                        if starred { Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Starred") }
                    }
                    Text(chapterTitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    Text(progress).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(lastRead).font(.caption).foregroundStyle(.secondary)
                    if let manga { MangaMetadataView(manga: manga, compact: true) }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.item.\(key.id)")
        .accessibilityHint(position == nil ? String(localized: "Start reading") : String(localized: "Resume reading"))
        #if os(iOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) { actions }
        #endif
        .contextMenu { actions }
        .accessibilityAction(named: starred ? String(localized: "Unstar") : String(localized: "Star")) { model.toggleStar(key, title: title) }
        .accessibilityAction(named: "Remove") { model.removeLibraryItem(key, from: section) }
        .accessibilityAction(named: "Manga details") { model.paths[section, default: []].append(.object(key)) }
        .task(id: "\(key.id)|\(model.loadingRevision)") { await loadDetails() }
        .onChange(of: position?.chapterKey) { _, _ in loadCachedChapter() }
    }
    @ViewBuilder private var actions: some View {
        Button("Remove", systemImage: "trash", role: .destructive) { model.removeLibraryItem(key, from: section) }
        Button(starred ? String(localized: "Unstar") : String(localized: "Star"), systemImage: starred ? "star.slash" : "star") { model.toggleStar(key, title: title) }
            .tint(.orange)
        Button("Manga details", systemImage: "book.closed") { model.paths[section, default: []].append(.object(key)) }
            .tint(.blue)
    }
    private func loadDetails() async {
        manga = nil; cover = nil; loadCachedChapter()
        guard let repository else { return }
        do {
            // No chapter extraction just to draw history: standalone chapters use a cached page.
            if key == position?.chapterKey {
                if let pageKey = cachedChapter?.pageRefs.first,
                   case .page(let page) = try model.store?.snapshot(pageKey)?.object { cover = page }
                return
            }
            guard case .manga(let loaded) = try await key.load(using: repository, hint: .preferCache) else { return }
            try Task.checkCancellation(); manga = loaded
            if let page = try await loaded.coverPage(using: repository, hint: .preferCache) {
                try Task.checkCancellation(); cover = page
            }
            loadCachedChapter()
        } catch { /* Keep the durable title/progress and a cover placeholder when unavailable. */ }
    }
    private var repository: ObjectRepository? { model.repository }
    private func loadCachedChapter() {
        cachedChapter = nil
        if let chapterKey = position?.chapterKey ?? manga?.chapterRefs.first?.key,
           let snapshot = try? model.store?.snapshot(chapterKey), case .chapter(let chapter) = snapshot.object { cachedChapter = chapter }
    }
}
