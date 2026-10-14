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
                        description: Text(section == .recent ? String(localized: "Manga you read appears here.") : String(localized: "Star a manga to add it to your library.")))
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
    @State private var cachedChapter: ChapterObject?
    @ScaledMetric(relativeTo: .body) private var resumeButtonSize = 44.0
    private var saved: SavedManga? { model.saved.first { $0.key == key } }
    private var position: ReadingPosition? { model.readingPositions.first { $0.mangaKey == key } }
    private var title: String { manga?.title ?? saved?.title ?? position?.mangaTitle ?? position?.title ?? String(localized: "Untitled manga") }
    private var starred: Bool { saved?.isStarred == true }
    private var chapterTitle: String { position?.title ?? manga?.chapterRefs.first?.title ?? String(localized: "Not started") }
    private var readingProgress: MangaProgress? { model.personalManga[key]?.personalState?.progress ?? manga?.personalState?.progress }
    private var progress: String {
        let progress = readingProgress
        guard let progress, let fraction = progress.fraction else { return String(localized: "Reading") }
        let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
        return switch progress.state {
        case .reading: String(localized: "Reading (\(percent))")
        case .finished: String(localized: "Finished")
        case .new: String(localized: "New (\(percent))")
        }
    }
    private var progressIcon: String {
        switch readingProgress?.state ?? .reading {
        case .reading: "book"
        case .finished: "checkmark.circle"
        case .new: "sparkles"
        }
    }
    private var lastRead: String {
        guard let date = position?.updatedAt else { return String(localized: "Not read yet") }
        let hours = max(0, Int(now.timeIntervalSince(date) / 3600))
        if hours < 1 { return String(localized: "<1 hr ago") }
        if hours < 24 { return String(localized: "\(hours) hr ago") }
        let days = hours / 24
        return String(localized: "\(days) days ago", comment: "Whole days since the last reading session; varies by plural.")
    }
    var body: some View {
        NavigationLink(value: AppRoute.object(key)) {
                HStack(alignment: .center, spacing: 8) {
                    CoverImageView(key: manga?.coverPageRef ?? (key == position?.chapterKey ? cachedChapter?.pageRefs.first : nil), model: model, bounds: CGSize(width: 64, height: 128), hint: manga == nil ? .offlineOnly : .preferCache)
                        .frame(width: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                        Text(chapterTitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Label(progress, systemImage: progressIcon).font(.caption).foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                        HStack(spacing: 6) {
                            if starred { Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Starred") }
                            Text(lastRead).foregroundStyle(.secondary)
                        }.font(.caption)
                        if let manga { MangaMetadataView(manga: manga, compact: true) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.resumeManga(key) } label: {
                        Label(position == nil ? String(localized: "Start reading") : String(localized: "Resume reading"), systemImage: "play.fill")
                            .labelStyle(.iconOnly)
                            .font(.title3)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .buttonSizing(.flexible)
                    .frame(width: resumeButtonSize, height: resumeButtonSize)
                    .accessibilityIdentifier("library.resume.\(key.id)")
                }
                .padding(.vertical, 6).contentShape(Rectangle())
        }
        .accessibilityIdentifier("library.item.\(key.id)")
        .accessibilityHint("Manga details")
        #if os(iOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) { actions }
        #endif
        .contextMenu { actions }
        .accessibilityActions {
            if section == .recent {
                Button(starred ? String(localized: "Unstar") : String(localized: "Star")) { model.toggleStar(key, title: title, manga: manga) }
            }
        }
        .accessibilityAction(named: "Remove") { model.removeLibraryItem(key, from: section) }
        .accessibilityAction(named: "Manga details") { model.paths[section, default: []].append(.object(key)) }
        .task(id: "\(key.id)|\(model.loadingRevision)") { await loadDetails() }
        .onChange(of: position?.chapterKey) { _, _ in loadCachedChapter() }
    }
    @ViewBuilder private var actions: some View {
        Button("Remove", systemImage: "trash", role: .destructive) { model.removeLibraryItem(key, from: section) }
        if section == .recent {
            Button(starred ? String(localized: "Unstar") : String(localized: "Star"), systemImage: starred ? "star.slash" : "star") { model.toggleStar(key, title: title, manga: manga) }
                .tint(.orange)
        }
    }
    private func loadDetails() async {
        manga = nil; loadCachedChapter()
        guard let repository else { return }
        do {
            // No chapter extraction just to draw history: standalone chapters use a cached page.
            if key == position?.chapterKey { return }
            let reference = ContentReference(key: key, title: title)
            guard case .manga(let loaded) = try await reference.preview(using: repository) else { return }
            try Task.checkCancellation(); manga = loaded
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
