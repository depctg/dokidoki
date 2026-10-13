import SwiftUI
import MangaCore

enum ReadingMode: String, CaseIterable { case paged = "Paged", scroll = "Scroll" }

struct ReaderView: View {
    let chapter: ChapterObject
    let model: AppModel
    @State private var pages: [PageObject] = []
    @State private var source: ObjectKey?
    @State private var mode = ReadingMode.paged
    @State private var rtl = true
    @State private var nextChapter: ContentReference?
    @State private var error: String?
    @State private var zoom: CGFloat = 1
    @FocusState private var readerFocused: Bool
    private var index: Int { pages.firstIndex { $0.key == source } ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            if let error {
                ContentUnavailableView("Could not load pages", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if pages.isEmpty {
                ContentUnavailableView("No pages", systemImage: "book.closed", description: Text("This chapter has no readable images. Refresh or open the source website."))
            } else if mode == .paged {
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        PageImageView(page: pages[index], model: model)
                            .frame(width: geometry.size.width * zoom, height: geometry.size.height * zoom)
                            .gesture(MagnifyGesture().onChanged { zoom = min(3, max(1, $0.magnification)) })
                            .onTapGesture(count: 2) { zoom = zoom > 1 ? 1 : 2 }
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(pages) { page in
                            PageImageView(page: page, model: model).frame(minHeight: 300).id(page.key)
                        }
                    }.scrollTargetLayout()
                }.scrollPosition(id: $source, anchor: .top)
            }
            HStack(spacing: 16) {
                Button("Previous", systemImage: rtl ? "chevron.right" : "chevron.left") { move(-1) }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).disabled(index == 0)
                Text(pages.isEmpty ? "0 / 0" : "\(index + 1) / \(pages.count)").monospacedDigit()
                Button("Next", systemImage: rtl ? "chevron.left" : "chevron.right") { move(1) }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).disabled(index >= pages.count - 1)
                if index == pages.count - 1, let nextChapter { NavigationLink("Next chapter", value: nextChapter.key) }
            }.padding().frame(maxWidth: .infinity).background(.bar)
        }
        .background(.black.opacity(0.92))
        .focusable().focusEffectDisabled().focused($readerFocused)
        .navigationTitle(chapter.title)
        .toolbar {
            ToolbarItem { Picker("Mode", selection: $mode) { ForEach(ReadingMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu) }
            ToolbarItem { Toggle("Right to left", isOn: $rtl) }
        }
        .onKeyPress(.leftArrow) { move(rtl ? 1 : -1); return .handled }
        .onKeyPress(.rightArrow) { move(rtl ? -1 : 1); return .handled }
        .onChange(of: source) { _, _ in savePosition() }
        .onDisappear { savePosition(); model.reloadLibrary() }
        .task(id: chapter.key) { await load() }
    }
    private func move(_ delta: Int) {
        guard !pages.isEmpty else { return }; source = pages[min(pages.count - 1, max(0, index + delta))].key; zoom = 1
    }
    private func load() async {
        guard let repository = model.repository else { return }
        error = nil; nextChapter = nil
        do {
            var loaded: [PageObject] = []
            for key in chapter.pageRefs { if case .page(let page) = try await repository.resolve(key) { loaded.append(page) } }
            try Task.checkCancellation(); pages = loaded
            let position = model.recent.first { $0.chapterKey == chapter.key }
            source = pages.first(where: { $0.key == position?.sourcePageKey })?.key ?? pages.first?.key
            readerFocused = true
            if let key = chapter.mangaRef, let object = try? await repository.resolve(key), case .manga(let manga) = object,
               let index = manga.chapterRefs.firstIndex(where: { $0.key == chapter.key }), manga.chapterRefs.indices.contains(index + 1) { nextChapter = manga.chapterRefs[index + 1] }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func savePosition() {
        guard let source else { return }
        do {
            try model.store?.savePosition(ReadingPosition(mangaKey: chapter.mangaRef ?? chapter.key, chapterKey: chapter.key, sourcePageKey: source, title: chapter.title))
        } catch { model.error = error.localizedDescription }
    }
}

struct PageImageView: View {
    let page: PageObject
    let model: AppModel
    @State private var image: CGImage?
    @State private var error: String?
    @State private var attempt = 0
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit().accessibilityLabel("Page \((page.sourceIndex ?? 0) + 1)") }
            else if let error {
                VStack(spacing: 12) { Image(systemName: "photo.badge.exclamationmark"); Text(error).font(.caption); Button("Retry image") { attempt += 1 } }.padding().foregroundStyle(.secondary)
            } else { ProgressView("Loading image…").padding(40) }
        }
        .task(id: "\(page.key.id)-\(page.imageURL)-\(page.refererURL?.absoluteString ?? "")-\(attempt)") {
            error = nil; image = nil
            do {
                guard let repository = model.repository else { return }
                let rule = try await repository.rule(for: page.key)
                let result = try await model.images.image(for: page, rule: rule)
                try Task.checkCancellation(); image = result
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
