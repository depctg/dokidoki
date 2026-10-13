import SwiftUI
import MangaCore

struct ReaderView: View {
    let chapter: ChapterObject
    let model: AppModel
    @State private var reader: ReaderModel
    @State private var zoom: CGFloat = 1
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    @State private var frames: [String: CGRect] = [:]
    @State private var scrollOffset = 0.0
    @State private var restoring = false
    @State private var userScrolling = false
    @State private var pendingRestore = false
    @State private var restoreRequest = 0
    @FocusState private var focused: Bool
    @Environment(\.scenePhase) private var scenePhase

    init(chapter: ChapterObject, model: AppModel) {
        self.chapter = chapter; self.model = model
        _reader = State(initialValue: ReaderModel(chapter: chapter, app: model))
    }
    private var rtl: Bool { model.preferences.direction == .rightToLeft }
    var body: some View {
        @Bindable var app = model
        VStack(spacing: 0) {
            GeometryReader { geometry in
                Group {
                    if reader.loading { ProgressView("Preparing chapter…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else if let error = reader.error {
                        ContentUnavailableView { Label("Could not load pages", systemImage: "exclamationmark.triangle") } description: { Text(error) } actions: { Button("Retry") { Task { await reader.load() } } }
                    } else if reader.plans.isEmpty {
                        ContentUnavailableView("No pages", systemImage: "book.closed", description: Text("Refresh or open the source website to check chapter availability."))
                    } else if model.preferences.mode == .paged, let plan = reader.current {
                        ScrollView([.horizontal, .vertical]) {
                            DisplayImageView(plan: plan, pages: reader.pages, model: model, onImage: reader.learn)
                                .frame(width: geometry.size.width * zoom, height: geometry.size.height * zoom)
                                .gesture(MagnifyGesture().onChanged { zoom = min(3, max(1, $0.magnification)) })
                                .onTapGesture(count: 2) { zoom = zoom > 1 ? 1 : 2 }
                                .onTapGesture { point in
                                    guard zoom == 1 else { return }
                                    let left = point.x < geometry.size.width * 0.35
                                    let right = point.x > geometry.size.width * 0.65
                                    if left { reader.move(rtl ? 1 : -1) }
                                    if right { reader.move(rtl ? -1 : 1) }
                                }
                        }.id(reader.index)
                    } else { continuous(width: geometry.size.width) }
                }
                .onChange(of: geometry.size, initial: true) { _, size in reader.size = size; reader.replan() }
            }
            HStack(spacing: 12) {
                Button("Previous page", systemImage: rtl ? "chevron.right" : "chevron.left") { reader.move(-1) }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).disabled(reader.index == 0)
                Text(reader.plans.isEmpty ? "0 / 0" : "\(reader.index + 1) / \(reader.plans.count)").monospacedDigit().accessibilityLabel("Display page \(reader.index + 1) of \(reader.plans.count)")
                Button("Next page", systemImage: rtl ? "chevron.left" : "chevron.right") { reader.move(1) }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).disabled(reader.index >= reader.plans.count - 1)
                if reader.index == reader.plans.count - 1 {
                    if let next = reader.nextChapter { NavigationLink("Next chapter", value: next.key) }
                    else { Text("End").font(.caption).foregroundStyle(.secondary) }
                }
            }.padding(.horizontal).frame(maxWidth: .infinity).background(.bar)
        }
        .background(Color(white: 0.08)).preferredColorScheme(.dark)
        .focusable().focusEffectDisabled().focused($focused)
        .navigationTitle(chapter.title)
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Mode", selection: $app.preferences.mode) { ForEach(ReadingMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Picker("Direction", selection: $app.preferences.direction) { ForEach(ReadingDirection.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Toggle("Trim blank margins", isOn: $app.preferences.trimMargins)
                    Toggle("Detect spreads", isOn: $app.preferences.detectSpreads)
                    Toggle("Facing pages in wide windows", isOn: $app.preferences.facingPages)
                    Divider()
                    Picker("Current source page", selection: Binding(get: { reader.source.flatMap { reader.overrides[$0] } ?? .automatic }, set: reader.setOverride)) {
                        ForEach(SpreadOverride.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.disabled(reader.source == nil)
                } label: { Label("Reader options", systemImage: "slider.horizontal.3") }
            }
        }
        .onKeyPress(.leftArrow) { reader.move(rtl ? 1 : -1); return .handled }
        .onKeyPress(.rightArrow) { reader.move(rtl ? -1 : 1); return .handled }
        .onChange(of: model.preferences) { _, _ in reader.save(); zoom = 1; reader.replan() }
        .onChange(of: reader.source) { _, _ in reader.save() }
        .onChange(of: reader.index) { _, _ in zoom = 1 }
        .onChange(of: scenePhase) { _, phase in if phase != .active { reader.save() } }
        .onDisappear { reader.stop() }
        .task { await reader.load(); focused = true }
        .task(id: "\(reader.revision)-\(restoreRequest)") { await restoreScroll() }
    }
    private func continuous(width: Double) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(reader.plans) { plan in
                    DisplayImageView(plan: plan, pages: reader.pages, model: model, onImage: reader.learn)
                        .frame(height: reader.height(plan, width: max(1, width - 24)))
                        .id(plan.id)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: ReaderFrames.self, value: [plan.id: geometry.frame(in: .named("readerViewport"))])
                        })
                }
            }.padding(.horizontal, 12).scrollTargetLayout()
        }
        .coordinateSpace(name: "readerViewport")
        .scrollPosition($scrollPosition)
        .onPreferenceChange(ReaderFrames.self) { frames = $0; recordScroll() }
        .onScrollGeometryChange(for: Double.self) { $0.contentOffset.y } action: { _, offset in scrollOffset = offset; recordScroll() }
        .onScrollPhaseChange { _, phase in
            userScrolling = phase == .interacting || phase == .decelerating
            if phase == .idle {
                reader.save()
                if pendingRestore { pendingRestore = false; restoreRequest += 1 }
            }
        }
    }
    private func recordScroll() {
        guard !restoring, userScrolling else { return }
        let visible = frames.filter { $0.value.maxY > 1 }.min { $0.value.minY < $1.value.minY }
        guard let (id, rect) = visible, let index = reader.plans.firstIndex(where: { $0.id == id }) else { return }
        reader.record(index: index, within: max(0, -rect.minY) / max(1, rect.height))
    }
    private func restoreScroll() async {
        guard model.preferences.mode == .scroll, let plan = reader.current else { return }
        guard !userScrolling else { pendingRestore = true; return }
        restoring = true
        defer { restoring = false }
        let within = reader.withinPage
        scrollPosition.scrollTo(id: plan.id, anchor: .top)
        do { try await Task.sleep(for: .milliseconds(100)); try Task.checkCancellation() } catch { return }
        guard !userScrolling else { pendingRestore = true; return }
        if let rect = frames[plan.id] { scrollPosition.scrollTo(y: max(0, scrollOffset + rect.minY + within * rect.height)) }
    }
}
private struct ReaderFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

struct DisplayImageView: View {
    let plan: DisplayPage
    let pages: [PageObject]
    let model: AppModel
    var onImage: (ObjectKey, CGImage) -> Void = { _, _ in }
    @State private var image: CGImage?
    @State private var originalImages: [CGImage] = []
    @State private var error: String?
    @State private var attempt = 0
    @State private var active = false
    private var resources: [PageObject] { pages.filter { plan.sourcePageKeys.contains($0.key) } }
    private var requestID: String { plan.id + resources.map { $0.imageURL.absoluteString + ($0.refererURL?.absoluteString ?? "") }.joined() + "-\(attempt)" }
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit().accessibilityLabel("Comic page") }
            else if !originalImages.isEmpty {
                HStack(spacing: 0) { ForEach(originalImages.indices, id: \.self) { Image(decorative: originalImages[$0], scale: 1).resizable().scaledToFit() } }
            }
            else if let error {
                VStack(spacing: 12) { Image(systemName: "photo.badge.exclamationmark"); Text(error).font(.caption); Button("Retry image") { attempt += 1 } }.padding().foregroundStyle(.secondary)
            } else { ProgressView("Loading image…").padding(30) }
        }
        .onAppear { active = true }
        .onDisappear { active = false; image = nil; originalImages = [] }
        .task(id: requestID + "-\(active)") {
            guard active else { return }
            error = nil; image = nil; originalImages = []
            do {
                guard let repository = model.repository else { return }
                var loaded: [ObjectKey: CGImage] = [:]
                for original in resources {
                    var page = original
                    if attempt > 0, case .page(let fresh) = try await repository.resolve(page.key, hint: .forceRefresh) { page = fresh }
                    let rule = try await repository.rule(for: page.key)
                    let decoded = try await model.images.image(for: page, rule: rule)
                    try Task.checkCancellation(); loaded[page.key] = decoded; onImage(page.key, decoded)
                }
                let images = loaded
                let rendered = await Task.detached(priority: .userInitiated) { ImageProcessing.render(plan, images: images) }.value
                try Task.checkCancellation()
                guard active else { return }
                if let rendered { image = rendered }
                else { originalImages = plan.sourcePageKeys.compactMap { loaded[$0] } }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
struct PageImageView: View {
    let page: PageObject
    let model: AppModel
    var body: some View { DisplayImageView(plan: DisplayPage(regions: [PageRegion(sourcePage: page.key)]), pages: [page], model: model) }
}
