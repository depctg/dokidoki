import SwiftUI
import MangaCore

/// Chrome depends on chapter/app state, never the reader's per-frame pull geometry.
struct ReaderToolbar: ToolbarContent {
    let reader: ReaderModel
    let model: AppModel
    private var chapter: ChapterObject { reader.chapter }
    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Collapse reader", systemImage: model.preferences.mode == .paged ? "chevron.down" : "chevron.left") { model.collapseReader() }
                .accessibilityIdentifier("reader.collapse")
        }
        ToolbarItem(placement: .principal) {
            Text(chapter.title).font(.headline).lineLimit(1)
                .allowsHitTesting(false).accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("reader.chapterTitle")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Back to manga", systemImage: "book.closed") { model.showReaderManga() }
                .disabled(chapter.mangaRef == nil)
            Button("Previous chapter", systemImage: "backward.end") { reader.openAdjacent(reader.previousChapter) }
                .disabled(reader.previousChapter == nil || model.openingChapter)
            Button("Next chapter", systemImage: "forward.end") { reader.openAdjacent(reader.nextChapter) }
                .disabled(reader.nextChapter == nil || model.openingChapter)
            options
                .disabled(model.openingChapter)
        }
    }
    private var options: some View {
        @Bindable var app = model
        return Menu {
            Picker("Mode", selection: $app.preferences.mode) {
                Label("Paged", systemImage: "rectangle.portrait").tag(ReadingMode.paged)
                Label("Scroll", systemImage: "arrow.up.arrow.down").tag(ReadingMode.scroll)
            }.pickerStyle(.palette).menuActionDismissBehavior(.enabled)
            Picker("Direction", selection: $app.preferences.direction) {
                Label("Right to left", systemImage: "arrow.left").tag(ReadingDirection.rightToLeft)
                Label("Left to right", systemImage: "arrow.right").tag(ReadingDirection.leftToRight)
            }.pickerStyle(.palette).menuActionDismissBehavior(.enabled)
            Menu("Image adjustments", systemImage: "photo") {
                Toggle("Trim blank margins", isOn: $app.preferences.trimMargins)
                Toggle("Detect spreads", isOn: $app.preferences.detectSpreads)
                Toggle("Facing pages in wide windows", isOn: $app.preferences.facingPages)
                Picker("Current source page", selection: Binding(get: { reader.source.flatMap { reader.overrides[$0] } ?? .automatic }, set: reader.setOverride)) {
                    ForEach(SpreadOverride.allCases, id: \.self) { Text($0.title).tag($0) }
                }.disabled(reader.source == nil)
            }
            Divider()
            Button("Refresh", systemImage: "arrow.clockwise") { model.openChapter(chapter.key, hint: .forceRefresh, preserveImmersion: true, listID: reader.chapterListID) }
            Link(destination: chapter.sourceURL) { Label("Source website", systemImage: "safari") }
        } label: { Label("Reader options", systemImage: "gearshape") }
    }
}
