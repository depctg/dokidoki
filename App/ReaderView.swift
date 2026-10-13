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
    @State private var chapterPull = ScrollPull()
    @State private var chapterTransition: ChapterTransition?
    @GestureState private var mousePull = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @Environment(\.scenePhase) private var scenePhase

    private var signedPull: Double { mousePull == 0 ? chapterPull.fraction : mousePull }
    private var pullReveal: Double { chapterTransition?.fraction ?? abs(signedPull) }
    private var advancing: Bool { chapterTransition != nil }
    private var previewDirection: ChapterDirection? {
        chapterTransition?.direction ?? (signedPull == 0 ? nil : (signedPull > 0 ? .next : .previous))
    }
    private var rtl: Bool { model.preferences.direction == .rightToLeft }
    private var preloadHint: String? {
        guard reader.chapterToPrefetch(.next) != nil else { return nil }
        if reader.previews[.next]?.page != nil { return nil }
        return reader.previews[.next]?.error ?? String(localized: "Preloading next chapter…")
    }
    var body: some View {
        GeometryReader { geometry in
            Group {
                if reader.loading { ProgressView("Preparing chapter…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error = reader.error {
                    ContentUnavailableView { Label("Could not load pages", systemImage: "exclamationmark.triangle") } description: { Text(error) } actions: { Button("Retry") { Task { await reader.load() } } }
                } else if reader.plans.isEmpty {
                    ContentUnavailableView("No pages", systemImage: "book.closed", description: Text("Refresh or open the source website to check chapter availability."))
                } else if model.preferences.mode == .paged { paged(size: geometry.size) }
                else { continuous(size: geometry.size) }
            }
            .overlay {
                // Keep both boundaries mounted; overscroll reveals their already-laid-out content.
                ForEach(ChapterDirection.allCases, id: \.self) { direction in
                    ReaderChapterPreview(reader: reader, model: model, direction: direction, size: geometry.size,
                                         reveal: previewDirection == direction ? pullReveal : 0,
                                         advancing: advancing && previewDirection == direction)
                }.allowsHitTesting(false)
                    .clipped()
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onChange(of: geometry.size, initial: true) { _, size in reader.size = size; reader.replan(restore: true) }
        }
        .background(Color(white: 0.08)).preferredColorScheme(.dark)
        .overlay(alignment: .bottomTrailing) {
            if !reader.plans.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(chapter.title).lineLimit(1)
                        Text("\(reader.index + 1) / \(reader.plans.count)").monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Page \(reader.index + 1) of \(reader.plans.count)")
                    .accessibilityValue(chapter.title)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityIdentifier("reader.pageCounter")
                    if let preloadHint {
                        Text(preloadHint).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            .accessibilityIdentifier("reader.preloadHint")
                    }
                }
                    .font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
                    #if os(visionOS)
                    .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 10))
                    #else
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
                    #endif
                    .frame(maxWidth: 220, alignment: .trailing)
                    .padding(16).padding(.bottom, 16).allowsHitTesting(false)
            }
        }
        // Toolbars overlay the same full-size reading surface in either chrome state.
        .ignoresSafeArea(.container)
        .persistentSystemOverlays(model.readerImmersive ? .hidden : .automatic)
        #if os(iOS)
        .statusBarHidden(model.readerImmersive)
        #endif
        .focusable(interactions: .activate).focusEffectDisabled().focused($focused)
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
        .onKeyPress(.leftArrow) { turn(rtl ? 1 : -1); return .handled }
        .onKeyPress(.rightArrow) { turn(rtl ? -1 : 1); return .handled }
        .onKeyPress(.space) { toggleChrome(); return .handled }
        .onKeyPress(.escape) { model.collapseReader(); return .handled }
        .onChange(of: model.preferences) { old, new in
            reader.save(); zoom = 1; zoomStart = 1; chapterTransition = nil; chapterPull = ScrollPull()
            // A remounted pager needs a fresh scroll request, even for the same source page.
            if old.mode == .paged, new.mode != .paged { pagedID = nil; pagerReady = false }
            reader.replan(restore: true)
        }
        .onChange(of: model.preferences.mode == .paged && reader.index == reader.plans.count - 1 && reader.finalPageReady, initial: true) { _, finished in
            if finished { reader.finishReading() }
        }
        .onChange(of: reader.index) { _, _ in zoom = 1; zoomStart = 1; reader.save() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { reader.save(); chapterTransition = nil; chapterPull = ScrollPull() } }
        .onChange(of: model.readerExpanded) { _, expanded in if !expanded { chapterTransition = nil; chapterPull = ScrollPull() } }
        .onChange(of: model.openingChapter) { _, opening in if !opening, model.reader?.id == reader.id { chapterTransition = nil; chapterPull = ScrollPull() } }
        .overlay { if model.openingChapter { ProgressView("Opening chapter…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) } }
        .onDisappear { chapterTransition = nil; reader.stop() }
        .task(id: model.loadingRevision) {
            #if os(macOS)
            focused = true
            #endif
            await reader.activate()
        }
        .task(id: "\(reader.chapterToPrefetch(.next)?.id ?? "")|\(model.loadingRevision)") { await reader.preloadChapter(.next) }
        .task(id: "\(reader.chapterToPrefetch(.previous)?.id ?? "")|\(model.loadingRevision)") { await reader.preloadChapter(.previous) }
        .task(id: "\(reader.revision)-\(restoreRequest)-\(pagerReady)") { await restorePosition() }
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
    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) { model.readerImmersive.toggle() }
    }
    private func turn(_ delta: Int) {
        guard !advancing, !model.openingChapter else { return }
        if delta > 0, reader.index == reader.plans.count - 1 { advanceChapter(.next); return }
        if delta < 0, reader.index == 0 { advanceChapter(.previous); return }
        reader.move(delta)
        withAnimation(.easeOut(duration: 0.2)) { pagedID = reader.current?.id }
    }
    private func paged(size: CGSize) -> some View {
        ZStack {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(reader.plans) { plan in
                        DisplayImageView(plan: plan, pages: reader.pages, model: model, onLoad: reader.preparePages)
                            .frame(width: size.width, height: size.height)
                            .contentShape(Rectangle()).onTapGesture { toggleChrome() }
                            .id(plan.id)
                    }
                }.scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
            .scrollBounceBehavior(.always, axes: .horizontal)
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
            .modifier(chapterOverscroll)
            if zoom > 1, let plan = reader.current {
                ScrollView([.horizontal, .vertical]) {
                    DisplayImageView(plan: plan, pages: reader.pages, model: model, onLoad: reader.preparePages)
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
        .simultaneousGesture(DragGesture(minimumDistance: 30)
            .updating($mousePull) { value, pull, _ in
                pull = 0
                guard !advancing, zoom == 1, abs(value.translation.width) > abs(value.translation.height) else { return }
                let fraction = value.translation.width * (rtl ? 1 : -1) / size.width
                if (fraction > 0 && reader.index == reader.plans.count - 1) || (fraction < 0 && reader.index == 0) { pull = fraction }
            }
            .onEnded { value in
                guard zoom == 1, abs(value.translation.width) > abs(value.translation.height) else { return }
                let delta = (value.translation.width > 0 ? 1 : -1) * (rtl ? 1 : -1)
                if (delta > 0 && reader.index == reader.plans.count - 1) || (delta < 0 && reader.index == 0) {
                    if abs(value.translation.width) >= size.width * 0.25 { advanceChapter(delta > 0 ? .next : .previous) }
                } else { turn(delta) }
            })
        #endif
    }
    private func continuous(size: CGSize) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(reader.plans) { plan in
                    let finalReady = reader.finalPageReady && plan.id == reader.plans.last?.id
                    DisplayImageView(plan: plan, pages: reader.pages, model: model, onLoad: reader.preparePages)
                        .frame(width: max(1, size.width - 24), height: reader.height(plan, width: max(1, size.width - 24)))
                        // The scroll target occupies the whole viewport; artwork insets
                        // belong inside it so native ID restoration cannot pan sideways.
                        .frame(width: size.width)
                        .contentShape(Rectangle()).onTapGesture { toggleChrome() }
                        .id(plan.id)
                        // Completion uses the final row's laid-out bottom, after its image
                        // dimensions are known, rather than a stale placeholder offset.
                        .onGeometryChange(for: Bool.self) { geometry in
                            let bottom = geometry.frame(in: .named("readerViewport")).maxY
                            return finalReady && bottom > 0 && bottom <= size.height + 1
                        } action: { finished in if finished { reader.finishReading() } }
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: ReaderFrames.self, value: [plan.id: geometry.frame(in: .named("readerViewport"))])
                        })
                }
            }.frame(width: size.width).scrollTargetLayout()
        }
        .accessibilityIdentifier("reader.viewport")
        .coordinateSpace(name: "readerViewport")
        .scrollBounceBehavior(.always)
        .scrollPosition($scrollPosition)
        .onPreferenceChange(ReaderFrames.self) { frames = $0; recordScroll() }
        // ScrollPosition's y coordinate starts after the top inset, unlike contentOffset.
        .onScrollGeometryChange(for: Double.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in scrollOffset = offset; recordScroll() }
        .modifier(chapterOverscroll)
    }
    private var chapterOverscroll: ScrollOverpull {
        ScrollOverpull(axis: model.preferences.mode == .paged ? .horizontal : .vertical,
                         enabled: zoom == 1 && !advancing && !model.openingChapter && scenePhase == .active,
                         pull: $chapterPull, onRelease: { pull in
                             if abs(pull.fraction) >= 0.25 { advanceChapter(pull.distance < 0 ? .previous : .next) }
                         }, onPhaseChange: scrollPhaseChanged)
    }
    private func scrollPhaseChanged(_ phase: ScrollPhase) {
        userScrolling = phase != .idle
        reader.setInteracting(userScrolling)
        if phase == .idle {
            if model.preferences.mode == .paged, let index = reader.plans.firstIndex(where: { $0.id == pagedID }) {
                reader.record(index: index, within: 0, preserveSource: false)
            }
            reader.save()
            if pendingRestore { pendingRestore = false; restoreRequest += 1 }
        }
    }
    private func advanceChapter(_ direction: ChapterDirection) {
        guard !advancing, !model.openingChapter, let reference = reader.adjacentChapter(direction) else { return }
        let transition = ChapterTransition(direction: direction, fraction: max(0.25, pullReveal))
        // Complete the native enlargement after release, before replacing the reader.
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
            chapterTransition = transition
        } completion: {
            guard chapterTransition?.id == transition.id else { return }
            guard model.reader?.id == reader.id, model.readerExpanded, !model.openingChapter else {
                chapterTransition = nil; chapterPull = ScrollPull(); return
            }
            reader.openAdjacent(reference, fromEnd: direction == .previous)
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
private struct ChapterTransition {
    let id = UUID()
    let direction: ChapterDirection
    let fraction: Double
}
private struct ReaderFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

struct DisplayImageView: View {
    let plan: DisplayPage
    let pages: [PageObject]
    let model: AppModel
    var onLoad: () -> Void = {}
    @State private var image: CGImage?
    @State private var originalImages: [CGImage] = []
    @State private var error: String?
    @State private var attempt = 0
    @State private var active = false
    private var resources: [PageObject] { pages.filter { plan.sourcePageKeys.contains($0.key) } }
    private var imageLabel: String {
        let numbers = resources.compactMap { $0.sourceIndex.map { String($0 + 1) } }
        return numbers.isEmpty ? String(localized: "Comic page") : String(localized: "Comic page \(numbers.joined(separator: ", "))")
    }
    private var requestID: String { plan.id + resources.map { ($0.imageURL?.absoluteString ?? $0.key.id) + ($0.refererURL?.absoluteString ?? "") }.joined() + "-\(attempt)" }
    var body: some View {
        ZStack {
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
                for page in resources {
                    let decoded = try await page.image(using: repository, refresh: attempt > 0)
                    try Task.checkCancellation(); loaded[page.key] = decoded
                }
                onLoad()
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
