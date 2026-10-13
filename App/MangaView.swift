import SwiftUI
import MangaCore

struct MangaView: View {
    let manga: MangaObject
    let model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title) private var coverWidth = 112.0
    @State private var readingState: MangaObject?
    @State private var reversedLists: Set<String> = []
    @State private var reveal: ChapterListReveal?
    private var starred: Bool { model.saved.contains { $0.key == manga.key && $0.isStarred } }
    private var position: ReadingPosition? { model.readingPositions.first { $0.mangaKey == manga.key } }

    var body: some View {
        chapterList
            .navigationTitle(manga.title)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(starred ? String(localized: "Unstar") : String(localized: "Star"), systemImage: starred ? "star.fill" : "star") {
                        model.toggleStar(manga.key, title: manga.title)
                    }.accessibilityIdentifier("manga.star")
                }
            }
            .onAppear { refreshReadingState() }
            .onChange(of: position?.updatedAt) { _, _ in refreshReadingState() }
            .task { revealChapter(includeLastRead: true) }
            .onChange(of: model.chapterToReveal) { _, key in
                if key != nil { revealChapter(includeLastRead: false) }
            }
    }
    @ViewBuilder private var chapterList: some View {
        #if os(macOS)
        ScrollViewReader { proxy in
            List {
                Section { details; readingButton }
                ForEach(manga.chapterLists) { list in
                    Section {
                        ForEach(orderedChapters(list)) { chapterRow($0, list: list) }
                        if list.chapters.isEmpty { emptyChapters }
                    }
                        header: { chapterHeader(list) }
                }
            }
            .scrollIndicators(.visible)
            .onChange(of: reveal?.id) { _, _ in
                if let reveal { proxy.scrollTo(reveal.row, anchor: .center) }
            }
        }
        #else
        let chapters = manga.chapterLists.flatMap { list in
            orderedChapters(list).map { (id: rowID($0.key, list: list), chapter: $0, list: list) }
        }
        let rows = Dictionary(uniqueKeysWithValues: chapters.map { ($0.id, ($0.chapter, $0.list)) })
        IndexedChapterList(sections: [
            .init(id: "details", indexTitle: "↑", header: nil, rows: ["details", "reading"])
        ] + manga.chapterLists.enumerated().map { offset, list in
            .init(id: "group|\(list.id)", indexTitle: list.indexTitle.map { String($0.prefix(2)) } ?? String(offset + 1),
                  header: AnyView(chapterHeader(list)), rows: list.chapters.isEmpty ? ["empty|\(list.id)"] : orderedChapters(list).map { rowID($0.key, list: list) })
        }, row: { id in
            if id == "details" { return AnyView(details) }
            if id == "reading" { return AnyView(readingButton) }
            if let (chapter, list) = rows[id] { return AnyView(chapterRow(chapter, list: list)) }
            return AnyView(emptyChapters)
        }, reveal: reveal)
        #endif
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
            layout {
                CoverImageView(key: manga.coverPageRef, model: model, bounds: CGSize(width: min(170, coverWidth), height: 260))
                VStack(alignment: .leading, spacing: 10) {
                    Text(manga.title).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    if let author = manga.author { Text(author).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    MangaMetadataView(manga: manga)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let summary = manga.summary {
                Text(summary).font(.callout).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("manga.summary")
            }
        }.padding(.vertical, 12)
    }
    @ViewBuilder private var readingButton: some View {
        if position != nil {
            Button("Resume reading", systemImage: "play.fill") { model.resumeManga(manga.key) }
        } else if let first = manga.chapterRefs.first {
            Button("Start reading", systemImage: "play.fill") {
                model.openChapter(first.key, listID: manga.chapterList(containing: first.key)?.id)
            }
        } else { emptyChapters }
    }
    private var emptyChapters: some View { Text("No chapters are available on this page.").foregroundStyle(.secondary) }
    private func orderedChapters(_ list: ChapterList) -> [ContentReference] {
        reversedLists.contains(list.id) ? Array(list.chapters.reversed()) : list.chapters
    }
    private func revealChapter(includeLastRead: Bool) {
        let explicit = model.chapterToReveal.flatMap { key in manga.chapterRefs.contains { $0.key == key } ? key : nil }
        let target = explicit ?? (includeLastRead && model.jumpToLastChapter ? position?.chapterKey : nil)
        let listID = explicit != nil ? model.reader?.chapterListID : position?.chapterListID
        if let key = target, let list = manga.chapterList(containing: key, preferredID: listID) {
            reveal = ChapterListReveal(row: rowID(key, list: list))
            if explicit != nil { model.chapterToReveal = nil }
        }
    }
    private func chapterHeader(_ list: ChapterList) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                if let title = list.title { Text(title).font(.headline) }
                Text("\(list.chapters.count) chapters")
            }
            Spacer()
            Menu {
                Picker("Order", selection: Binding(get: { reversedLists.contains(list.id) }, set: { reversed in
                    if reversed { reversedLists.insert(list.id) } else { reversedLists.remove(list.id) }
                })) {
                    Text("Source order").tag(false)
                    Text("Reverse order").tag(true)
                }
            } label: { Label("Sort chapters", systemImage: "arrow.up.arrow.down").labelStyle(.iconOnly) }
            .accessibilityIdentifier("manga.sort.\(list.id)")
        }.textCase(nil)
    }
    private func chapterRow(_ chapter: ContentReference, list: ChapterList) -> some View {
        let status = (readingState ?? manga).readingStatus(for: chapter.key)
        let isCurrent = model.reader?.chapter.key == chapter.key && model.reader?.chapterListID == list.id
        let statusTitle: String = switch status {
        case .unread: String(localized: "Unread")
        case .reading: String(localized: "In progress")
        case .read: String(localized: "Read")
        }
        return Button { model.openChapter(chapter.key, listID: list.id) } label: {
            HStack {
                Text(chapter.title)
                Spacer(minLength: 12)
                if status == .read { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                else if status == .reading { Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary) }
            }
        }
        .id(rowID(chapter.key, list: list))
        .accessibilityLabel(chapter.title)
        .accessibilityValue(isCurrent ? String(localized: "Current chapter, \(statusTitle)") : statusTitle)
        .background(isCurrent ? Color.accentColor.opacity(0.15) : nil)
    }
    private func rowID(_ key: ObjectKey, list: ChapterList) -> String { "\(list.id)|\(key.id)" }
    private func refreshReadingState() {
        guard let repository = model.repository else { return }
        do { readingState = try manga.readingState(using: repository) }
        catch { model.report(error, operation: .storage) }
    }
}
