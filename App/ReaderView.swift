import SwiftUI
import MangaCore

struct ReaderView: View {
    let reader: ReaderModel
    let model: AppModel
    private var chapter: ChapterObject { reader.chapter }
    @State private var zoom: CGFloat = 1
    @State private var zoomStart: CGFloat = 1
    @State private var pagedID: String?
    @State private var pagerReady = false
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    @State private var frames: [String: CGRect] = [:]
    @State private var scrollOffset = 0.0
    @State private var restoring = false
    @State private var userScrolling = false
    @State private var pendingRestore = false
    @State private var restoreRequest = 0
    @FocusState private var focused: Bool
    @Environment(\.scenePhase) private var scenePhase

    private var rtl: Bool { model.preferences.direction == .rightToLeft }
    var body: some View {
        GeometryReader { geometry in
            Group {
                if reader.loading { ProgressView("Preparing chapter…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error = reader.error {
                    ContentUnavailableView { Label("Could not load pages", systemImage: "exclamationmark.triangle") } description: { Text(error) } actions: { Button("Retry") { Task { await reader.load() } } }
                } else if reader.plans.isEmpty {
                    ContentUnavailableView("No pages", systemImage: "book.closed", description: Text("Refresh or open the source website to check chapter availability."))
                } else if model.preferences.mode == .paged { paged(size: geometry.size) }
                else { continuous(width: geometry.size.width) }
            }
            .onChange(of: geometry.size, initial: true) { _, size in reader.size = size; reader.replan() }
        }
        .background(Color(white: 0.08)).preferredColorScheme(.dark)
        .overlay(alignment: .bottomTrailing) {
            if !model.readerImmersive && !reader.plans.isEmpty {
                Text("\(reader.index + 1) / \(reader.plans.count)")
                    .font(.caption.monospacedDigit()).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(12).allowsHitTesting(false)
                    .accessibilityLabel("Page \(reader.index + 1) of \(reader.plans.count)")
                    .accessibilityIdentifier("reader.pageCounter")
            }
        }
        .ignoresSafeArea(.container, edges: model.readerImmersive ? .all : [])
        .persistentSystemOverlays(model.readerImmersive ? .hidden : .automatic)
        #if os(iOS)
        .statusBarHidden(model.readerImmersive)
        #endif
        .focusable().focusEffectDisabled().focused($focused)
        .navigationTitle(chapter.title)
        .toolbarTitleDisplayMode(.inline)
        #if os(macOS)
        .toolbarVisibility(model.readerImmersive ? .hidden : .automatic, for: .windowToolbar)
        #else
        .toolbarVisibility(model.readerImmersive ? .hidden : .automatic, for: .navigationBar, .tabBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Collapse reader", systemImage: model.preferences.mode == .paged ? "chevron.down" : "chevron.left") { model.collapseReader() }
                    .accessibilityIdentifier("reader.collapse")
            }
            ToolbarItem(placement: .principal) {
                Text(chapter.title).font(.headline).lineLimit(1)
                    .allowsHitTesting(false).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("reader.chapterTitle")
            }
            ToolbarItem { options }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { model.openChapter(chapter.key, hint: .forceRefresh) }
                    .disabled(model.openingChapter)
            }
            ToolbarItem { Link(destination: chapter.sourceURL) { Label("Source website", systemImage: "safari") } }
        }
        .onKeyPress(.leftArrow) { turn(rtl ? 1 : -1); return .handled }
        .onKeyPress(.rightArrow) { turn(rtl ? -1 : 1); return .handled }
        .onKeyPress(.space) { toggleChrome(); return .handled }
        .onKeyPress(.escape) { model.collapseReader(); return .handled }
        .onChange(of: model.preferences) { old, new in
            reader.save(); zoom = 1; zoomStart = 1
            // A remounted pager needs a fresh scroll request, even for the same source page.
            if old.mode == .paged, new.mode != .paged { pagedID = nil; pagerReady = false }
            reader.replan()
        }
        .onChange(of: reader.index) { _, _ in zoom = 1; zoomStart = 1; reader.save() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { reader.save() } }
        .onDisappear { reader.stop(); model.readerImmersive = false }
        .task { await reader.activate(); focused = true }
        .task(id: "\(reader.revision)-\(restoreRequest)-\(pagerReady)") { await restorePosition() }
    }
    private var options: some View {
        @Bindable var app = model
        return Menu {
            Picker("Mode", selection: $app.preferences.mode) { ForEach(ReadingMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            Picker("Direction", selection: $app.preferences.direction) { ForEach(ReadingDirection.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            Toggle("Trim blank margins", isOn: $app.preferences.trimMargins)
            Toggle("Detect spreads", isOn: $app.preferences.detectSpreads)
            Toggle("Facing pages in wide windows", isOn: $app.preferences.facingPages)
            Divider()
            Picker("Current source page", selection: Binding(get: { reader.source.flatMap { reader.overrides[$0] } ?? .automatic }, set: reader.setOverride)) {
                ForEach(SpreadOverride.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.disabled(reader.source == nil)
            Button("Hide controls", systemImage: "arrow.up.left.and.arrow.down.right") { toggleChrome() }
            if let next = reader.nextChapter { Button("Next chapter") { model.openChapter(next.key) } }
        } label: { Label("Reader options", systemImage: "slider.horizontal.3") }
    }
    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) { model.readerImmersive.toggle() }
    }
    private func turn(_ delta: Int) {
        reader.move(delta)
        withAnimation(.easeOut(duration: 0.2)) { pagedID = reader.current?.id }
    }
    private func paged(size: CGSize) -> some View {
        ZStack {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(reader.plans) { plan in
                        DisplayImageView(plan: plan, pages: reader.pages, model: model, onImage: reader.learn)
                            .frame(width: size.width, height: size.height)
                            .contentShape(Rectangle()).onTapGesture { toggleChrome() }
                            .id(plan.id)
                    }
                }.scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $pagedID)
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            .scrollDisabled(zoom > 1)
            .opacity(zoom > 1 ? 0 : 1)
            .onScrollGeometryChange(for: Bool.self) { $0.contentSize.width > 0 && $0.containerSize.width > 0 } action: { _, ready in
                pagerReady = ready
            }
            .onChange(of: pagedID) { _, id in
                guard userScrolling, let index = reader.plans.firstIndex(where: { $0.id == id }) else { return }
                reader.record(index: index, within: 0, preserveSource: false)
            }
            .onScrollPhaseChange { _, phase in
                userScrolling = phase != .idle
                reader.setInteracting(userScrolling)
                if phase == .idle {
                    if let index = reader.plans.firstIndex(where: { $0.id == pagedID }) {
                        reader.record(index: index, within: 0, preserveSource: false)
                    }
                    reader.save()
                    if pendingRestore { pendingRestore = false; restoreRequest += 1 }
                }
            }
            if zoom > 1, let plan = reader.current {
                ScrollView([.horizontal, .vertical]) {
                    DisplayImageView(plan: plan, pages: reader.pages, model: model, onImage: reader.learn)
                        .frame(width: size.width * zoom, height: size.height * zoom)
                        .contentShape(Rectangle()).onTapGesture { toggleChrome() }
                }.scrollIndicators(.hidden)
            }
        }
        .accessibilityIdentifier("reader.viewport")
        .simultaneousGesture(MagnifyGesture()
            .onChanged { zoom = min(3, max(1, zoomStart * $0.magnification)) }
            .onEnded { _ in zoomStart = zoom })
        #if os(macOS)
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
            guard zoom == 1, abs(value.translation.width) > abs(value.translation.height) else { return }
            turn((value.translation.width > 0 ? 1 : -1) * (rtl ? 1 : -1))
        })
        #endif
    }
    private func continuous(width: Double) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(reader.plans) { plan in
                    DisplayImageView(plan: plan, pages: reader.pages, model: model, onImage: reader.learn)
                        .frame(height: reader.height(plan, width: max(1, width - 24)))
                        .contentShape(Rectangle()).onTapGesture { toggleChrome() }
                        .id(plan.id)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: ReaderFrames.self, value: [plan.id: geometry.frame(in: .named("readerViewport"))])
                        })
                }
            }.padding(.horizontal, 12).scrollTargetLayout()
        }
        .accessibilityIdentifier("reader.viewport")
        .coordinateSpace(name: "readerViewport")
        .scrollPosition($scrollPosition)
        .onPreferenceChange(ReaderFrames.self) { frames = $0; recordScroll() }
        // ScrollPosition's y coordinate starts after the top inset, unlike contentOffset.
        .onScrollGeometryChange(for: Double.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in scrollOffset = offset; recordScroll() }
        .onScrollPhaseChange { _, phase in
            userScrolling = phase == .interacting || phase == .decelerating
            reader.setInteracting(userScrolling)
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
    private func restorePosition() async {
        guard let plan = reader.current else { return }
        guard !userScrolling else { pendingRestore = true; return }
        if model.preferences.mode == .paged {
            guard pagerReady else { return }
            pagedID = plan.id
            return
        }
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
    private var imageLabel: String {
        let numbers = resources.compactMap { $0.sourceIndex.map { String($0 + 1) } }
        return numbers.isEmpty ? "Comic page" : "Comic page " + numbers.joined(separator: ", ")
    }
    private var requestID: String { plan.id + resources.map { $0.imageURL.absoluteString + ($0.refererURL?.absoluteString ?? "") }.joined() + "-\(attempt)" }
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit().accessibilityLabel(imageLabel).accessibilityIdentifier("reader.pageImage") }
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
