import SwiftUI
import MangaCore

struct MangaView: View {
    let manga: MangaObject
    let model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title) private var coverWidth = 112.0
    @State private var cover: PageObject?
    @State private var readingState: MangaObject?
    @State private var reversedLists: Set<String> = []
    private var starred: Bool { model.saved.contains { $0.key == manga.key && $0.isStarred } }
    private var position: ReadingPosition? { model.readingPositions.first { $0.mangaKey == manga.key } }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                        layout {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                                if let cover { PageImageView(page: cover, model: model) }
                                else { Image(systemName: "book.closed").foregroundStyle(.secondary) }
                            }
                            .frame(width: min(170, coverWidth), height: min(170, coverWidth) * 1.5)
                            .clipShape(.rect(cornerRadius: 8)).accessibilityHidden(true)
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
                    if position != nil {
                        Button("Resume reading", systemImage: "play.fill") { model.resumeManga(manga.key) }
                    } else if let first = manga.chapterRefs.first {
                        Button("Start reading", systemImage: "play.fill") {
                            model.openChapter(first.key, listID: manga.chapterList(containing: first.key)?.id)
                        }
                    }
                }
                .sectionIndexLabel(Text(verbatim: "↑"))
                ForEach(Array(manga.chapterLists.enumerated()), id: \.element.id) { offset, list in
                    chapterSections(list, offset: offset)
                }
                if manga.chapterLists.isEmpty { Text("No chapters are available on this page.").foregroundStyle(.secondary) }
            }
            #if !os(macOS)
            .listSectionIndexVisibility(.visible)
            #endif
            .scrollIndicators(.visible)
            .navigationTitle(manga.title)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(starred ? String(localized: "Unstar") : String(localized: "Star"), systemImage: starred ? "star.fill" : "star") {
                        model.toggleStar(manga.key, title: manga.title)
                    }.accessibilityIdentifier("manga.star")
                }
            }
            .task(id: manga.coverPageRef) {
                if let repository = model.repository { cover = try? await manga.coverPage(using: repository) }
            }
            .onAppear { refreshReadingState() }
            .onChange(of: position?.updatedAt) { _, _ in refreshReadingState() }
            .task(id: model.chapterToReveal) {
                let explicit = model.chapterToReveal.flatMap { key in manga.chapterRefs.contains { $0.key == key } ? key : nil }
                let target = explicit ?? (model.jumpToLastChapter ? position?.chapterKey : nil)
                let listID = explicit != nil ? model.reader?.chapterListID : position?.chapterListID
                if let key = target, let list = manga.chapterList(containing: key, preferredID: listID) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(rowID(key, list: list), anchor: .center)
                    if explicit != nil { model.chapterToReveal = nil }
                }
            }
        }
    }
    @ViewBuilder private func chapterSections(_ list: ChapterList, offset: Int) -> some View {
        let chapters = reversedLists.contains(list.id) ? Array(list.chapters.reversed()) : list.chapters
        #if os(macOS)
        let parts = 1 // The native scrollbar supports continuous scrubbing.
        #else
        let parts = chapters.count >= 100 ? 4 : 1
        #endif
        ForEach(0..<parts, id: \.self) { part in
            Section {
                ForEach(chapters[(part * chapters.count / parts)..<((part + 1) * chapters.count / parts)]) { chapter in
                    chapterRow(chapter, list: list)
                }
                if chapters.isEmpty { Text("No chapters are available on this page.").foregroundStyle(.secondary) }
            } header: {
                if part == 0 { chapterHeader(list) }
            }
            .sectionIndexLabel(part == 0
                ? (list.indexTitle.map { String($0.prefix(2)) } ?? String(offset + 1))
                : ["¼", "½", "¾"][part - 1])
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
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.15) : nil)
    }
    private func rowID(_ key: ObjectKey, list: ChapterList) -> String { "\(list.id)|\(key.id)" }
    private func refreshReadingState() {
        guard let repository = model.repository else { return }
        do { readingState = try manga.readingState(using: repository) }
        catch { model.report(error, operation: .storage) }
    }
}
