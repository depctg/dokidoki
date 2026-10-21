import SwiftUI
import MangaCore

struct MangaView: View {
    let manga: MangaObject
    let model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title) private var coverWidth = 112.0
    private var readingState: MangaObject { model.personalManga[manga.key] ?? manga }
    private enum ChapterOrder { case smart, source, reversed }
    @State private var chapterOrders: [String: ChapterOrder] = [:]
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
                        model.toggleStar(manga.key, title: manga.title, manga: manga)
                    }.accessibilityIdentifier("manga.star")
                }
            }
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
                        ForEach(orderedChapters(list)) { chapter in
                            chapterRow(chapter, list: list)
                                .listRowBackground(isCurrent(chapter, list: list) ? Color.accentColor.opacity(0.15) : nil)
                        }
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
        }, highlighted: { id in
            guard let (chapter, list) = rows[id] else { return false }
            return isCurrent(chapter, list: list)
        }, reveal: reveal)
        // UIKit owns the list's safe-area insets; extend its scroll surface under
        // the system's floating navigation and tab controls.
        .ignoresSafeArea(.container, edges: .vertical)
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
    private var readingButton: some View {
        Button {
            model.resumeManga(manga.key, manga: manga)
        } label: {
            Label(position == nil ? String(localized: "Start reading") : String(localized: "Resume reading"), systemImage: "play.fill")
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(model.openingChapter || manga.chapterRefs.isEmpty && position == nil)
        .accessibilityIdentifier("manga.read")
    }
    private var emptyChapters: some View { Text("No chapters are available on this page.").foregroundStyle(.secondary) }
    private func orderedChapters(_ list: ChapterList) -> [ContentReference] {
        switch chapterOrders[list.id, default: .smart] {
        case .smart: list.chaptersByNumber
        case .source: list.chapters
        case .reversed: Array(list.chapters.reversed())
        }
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
            Menu { chapterActions(list.chapters.map(\.key), wholeList: true) } label: {
                Label("Chapter list actions", systemImage: "checklist").labelStyle(.iconOnly)
            }
            .disabled(list.chapters.isEmpty)
            .accessibilityIdentifier("manga.actions.\(list.id)")
            Menu {
                Picker("Order", selection: Binding(get: { chapterOrders[list.id, default: .smart] }, set: { chapterOrders[list.id] = $0 })) {
                    Text("Smart order").tag(ChapterOrder.smart)
                    Text("Source order").tag(ChapterOrder.source)
                    Text("Reverse order").tag(ChapterOrder.reversed)
                }
            } label: { Label("Sort chapters", systemImage: "arrow.up.arrow.down").labelStyle(.iconOnly) }
            .accessibilityIdentifier("manga.sort.\(list.id)")
        }.textCase(nil)
    }
    private func chapterRow(_ chapter: ContentReference, list: ChapterList) -> some View {
        let status = readingState.readingStatus(for: chapter.key)
        let isCurrent = isCurrent(chapter, list: list)
        let statusTitle: String = switch status {
        case .unread: String(localized: "Unread")
        case .reading: String(localized: "In progress")
        case .read: String(localized: "Read")
        case .ignored: String(localized: "Ignored")
        }
        return Button { model.openChapter(chapter.key, listID: list.id) } label: {
            HStack {
                Text(chapter.title)
                Spacer(minLength: 12)
                if status == .read { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                else if status == .reading { Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary) }
                else if status == .ignored { Image(systemName: "minus.circle").foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .id(rowID(chapter.key, list: list))
        #if !os(macOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) { chapterActions([chapter.key]) }
        #endif
        .contextMenu { chapterActions([chapter.key]) }
        .accessibilityActions { chapterActions([chapter.key]) }
        .accessibilityLabel(chapter.title)
        .accessibilityValue(isCurrent ? String(localized: "Current chapter, \(statusTitle)") : statusTitle)
    }
    @ViewBuilder private func chapterActions(_ keys: [ObjectKey], wholeList: Bool = false) -> some View {
        let status = readingState.readingStatus(for: keys)
        Button(wholeList ? (status == .read ? String(localized: "Mark all as unread") : String(localized: "Mark all as read"))
               : (status == .read ? String(localized: "Mark as unread") : String(localized: "Mark as read")),
               systemImage: status == .read ? "circle" : "checkmark") {
            setStatus(status == .read ? .unread : .read, for: keys)
        }.tint(.blue)
        Button(wholeList ? (status == .ignored ? String(localized: "Unignore all") : String(localized: "Ignore all"))
               : (status == .ignored ? String(localized: "Unignore") : String(localized: "Ignore")),
               systemImage: status == .ignored ? "plus.circle" : "minus.circle") {
            setStatus(status == .ignored ? .unread : .ignored, for: keys)
        }.tint(.orange)
    }
    private func setStatus(_ status: ChapterReadingStatus, for keys: [ObjectKey]) {
        guard let repository = model.repository else { return }
        let manga = manga
        model.persist { _ = try await manga.setReadingStatus(status, for: keys, using: repository) }
    }
    private func isCurrent(_ chapter: ContentReference, list: ChapterList) -> Bool {
        position?.chapterKey == chapter.key && manga.chapterList(containing: chapter.key, preferredID: position?.chapterListID)?.id == list.id
    }
    private func rowID(_ key: ObjectKey, list: ChapterList) -> String { "\(list.id)|\(key.id)" }
}
