import SwiftUI
import MangaCore

struct ReaderView: View {
    static let chapterSwitchThreshold = 0.2
    let reader: ReaderModel
    let model: AppModel
    private var chapter: ChapterObject { reader.chapter }
    @State private var zoom: CGFloat = 1
    @State private var zoomStart: CGFloat = 1
    @State private var pagerReady = false
    @State private var restoration: FractionalRestore?
    @State private var contentID: UUID?
    @State private var userScrolling = false
    @State private var scrollOwner: UUID?
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
    private var canRecordPosition: Bool {
        contentID == reader.id && reader.active && !model.openingChapter && !pendingRestore && restoration == nil
    }
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
            .onChange(of: reader.id) { _, _ in reader.size = geometry.size; reader.replan(restore: true) }
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
        .focusable(interactions: .activate).focusEffectDisabled().focused($focused)
        .onKeyPress(.leftArrow) { turn(rtl ? 1 : -1); return .handled }
        .onKeyPress(.rightArrow) { turn(rtl ? -1 : 1); return .handled }
        .onKeyPress(.space) { toggleChrome(); return .handled }
        .onKeyPress(.escape) { model.collapseReader(); return .handled }
        .onChange(of: model.preferences) { old, new in
            reader.save(); zoom = 1; zoomStart = 1; chapterTransition = nil; chapterPull = ScrollPull()
            // A remounted pager needs a fresh scroll request, even for the same source page.
            if old.mode == .paged, new.mode != .paged { pagerReady = false }
            reader.replan(restore: true)
        }
        .onChange(of: model.preferences.mode == .paged && canRecordPosition && reader.index == reader.plans.count - 1 && reader.finalPageReady ? reader.id : nil, initial: true) { _, chapter in
            if chapter != nil { reader.finishReading() }
        }
        .onChange(of: reader.index) { _, _ in zoom = 1; zoomStart = 1; reader.save() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { reader.save(); chapterTransition = nil; chapterPull = ScrollPull() } }
        .onChange(of: model.readerExpanded) { _, expanded in if !expanded { chapterTransition = nil; chapterPull = ScrollPull() } }
        .onChange(of: model.openingChapter) { _, opening in if !opening, model.reader?.id == reader.id { chapterTransition = nil; chapterPull = ScrollPull() } }
        .onChange(of: reader.id, initial: true) { _, _ in
            // The native scroll surfaces and chrome survive chapter replacement.
            // Preserve native geometry; a new chapter cannot inherit an outgoing
            // gesture or rubber-band return as a new user-driven scroll.
            zoom = 1; zoomStart = 1
            pendingRestore = true; restoration = nil; chapterPull = ScrollPull(); chapterTransition = nil
            userScrolling = false; scrollOwner = nil
            contentID = reader.id
            restoreRequest += 1
        }
        .onDisappear { chapterTransition = nil; reader.stop() }
        .task(id: "\(reader.id)|\(model.loadingRevision)") {
            #if os(macOS)
            focused = true
            #endif
            await reader.activate()
        }
        .task(id: "\(reader.id)|\(reader.chapterToPrefetch(.next)?.id ?? "")|\(model.loadingRevision)", priority: .utility) { await reader.preloadChapter(.next) }
        .task(id: "\(reader.id)|\(reader.chapterToPrefetch(.previous)?.id ?? "")|\(model.loadingRevision)", priority: .utility) { await reader.preloadChapter(.previous) }
        .task(id: "\(reader.id)-\(reader.revision)-\(restoreRequest)-\(pagerReady)") { restorePosition() }
    }
    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) { model.readerImmersive.toggle() }
    }
    private func turn(_ delta: Int) {
        guard !advancing, !model.openingChapter else { return }
        if delta > 0, reader.index == reader.plans.count - 1 { advanceChapter(.next); return }
        if delta < 0, reader.index == 0 { advanceChapter(.previous); return }
        scrollOwner = nil
        reader.move(delta)
        withAnimation(.easeOut(duration: 0.2)) { if let id = reader.current?.id { reader.scrollPosition.scrollTo(id: id) } }
    }
    private func paged(size: CGSize) -> some View {
        @Bindable var reader = reader
        return ZStack {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(reader.plans) { plan in
                        DisplayImageView(plan: plan, pages: reader.pages, model: model, prepared: reader.landingArtwork,
                                         onLoad: reader.preparePages)
                            .frame(width: size.width, height: size.height)
                            .contentShape(Rectangle()).onTapGesture { toggleChrome() }
                            .id(plan.id)
                    }
                }.scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
            .scrollBounceBehavior(.always, axes: .horizontal)
            .scrollPosition($reader.scrollPosition, anchor: .center)
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            .scrollDisabled(zoom > 1 || model.openingChapter)
            .opacity(zoom > 1 ? 0 : 1)
            .onScrollGeometryChange(for: Bool.self) { $0.contentSize.width > 0 && $0.containerSize.width > 0 } action: { _, ready in
                pagerReady = ready
            }
            .onChange(of: reader.scrollPosition.viewID(type: String.self)) { _, id in
                guard userScrolling, canRecordPosition, let index = reader.plans.firstIndex(where: { $0.id == id }) else { return }
                reader.record(index: index, within: 0, preserveSource: false)
            }
            .modifier(chapterOverscroll)
            if zoom > 1, let plan = reader.current {
                ScrollView([.horizontal, .vertical]) {
                    DisplayImageView(plan: plan, pages: reader.pages, model: model, prepared: reader.landingArtwork,
                                         onLoad: reader.preparePages)
                        .frame(width: size.width * zoom, height: size.height * zoom)
                        .contentShape(Rectangle()).onTapGesture { toggleChrome() }
                }.scrollIndicators(.hidden).scrollDisabled(model.openingChapter)
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
                    if abs(value.translation.width) >= size.width * Self.chapterSwitchThreshold { advanceChapter(delta > 0 ? .next : .previous) }
                } else { turn(delta) }
            })
        #endif
    }
    private func continuous(size: CGSize) -> some View {
        @Bindable var reader = reader
        return ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(reader.plans) { plan in
                    let finalReady = canRecordPosition
                        && reader.finalPageReady && plan.id == reader.plans.last?.id
                    let restoreFraction = restoration?.pageID == plan.id ? restoration?.fraction : nil
                    DisplayImageView(plan: plan, pages: reader.pages, model: model, prepared: reader.landingArtwork,
                                         onLoad: reader.preparePages)
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
                        .onGeometryChange(for: ReaderPageGeometry.self) { geometry in
                            ReaderPageGeometry(frame: geometry.frame(in: .named("readerViewport")),
                                               contentY: geometry.frame(in: .named("readerContent")).minY,
                                               restoreFraction: restoreFraction)
                        } action: { geometry in
                            updateScroll(plan: plan, geometry: geometry)
                        }
                }
            }.frame(width: size.width).scrollTargetLayout().coordinateSpace(name: "readerContent")
        }
        .accessibilityIdentifier("reader.viewport")
        .coordinateSpace(name: "readerViewport")
        .scrollBounceBehavior(.always)
        .scrollDisabled(model.openingChapter)
        .scrollPosition($reader.scrollPosition)
        .modifier(chapterOverscroll)
    }
    private var chapterOverscroll: ScrollOverpull {
        ScrollOverpull(axis: model.preferences.mode == .paged ? .horizontal : .vertical,
                         enabled: zoom == 1 && !advancing && !model.openingChapter && scenePhase == .active,
                         pull: $chapterPull, onRelease: { pull in
                             if abs(pull.fraction) >= Self.chapterSwitchThreshold { advanceChapter(pull.distance < 0 ? .previous : .next) }
                         }, onPhaseChange: scrollPhaseChanged)
    }
    private func scrollPhaseChanged(_ phase: ScrollPhase) {
        // Native callbacks may briefly idle before the same drag decelerates.
        // Retain its chapter ownership until explicit navigation/restoration.
        if phase == .tracking || phase == .interacting {
            scrollOwner = reader.id
            restoration = nil // A new native gesture supersedes an unfinished restore.
        }
        userScrolling = scrollOwner == reader.id && (phase == .tracking || phase == .interacting || phase == .decelerating)
        reader.setInteracting(userScrolling)
        if phase == .idle {
            if scrollOwner == reader.id, canRecordPosition, model.preferences.mode == .paged,
               let index = reader.plans.firstIndex(where: { $0.id == reader.scrollPosition.viewID(type: String.self) }) {
                reader.record(index: index, within: 0, preserveSource: false)
            }
            reader.save()
            if pendingRestore { restoreRequest += 1 }
        }
    }
    private func advanceChapter(_ direction: ChapterDirection) {
        guard !advancing, !model.openingChapter, let reference = reader.adjacentChapter(direction) else { return }
        let transition = ChapterTransition(direction: direction, fraction: max(Self.chapterSwitchThreshold, pullReveal))
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
    private func updateScroll(plan: DisplayPage, geometry: ReaderPageGeometry) {
        if restoration?.pageID == plan.id, let fraction = geometry.restoreFraction, !userScrolling {
            // The native target has laid out: use its real content coordinate now,
            // without a timer, guessed delay, or a second independent offset observer.
            self.restoration = nil
            reader.scrollPosition.scrollTo(y: max(0, geometry.contentY + fraction * geometry.frame.height))
            return
        }
        let frame = geometry.frame
        guard canRecordPosition, userScrolling, frame.maxY > 1, frame.minY <= 12,
              let index = reader.plans.firstIndex(where: { $0.id == plan.id }) else { return }
        reader.record(index: index, within: max(0, -frame.minY) / max(1, frame.height))
    }
    private func restorePosition() {
        guard let plan = reader.current else { return }
        guard !userScrolling else { pendingRestore = true; return }
        scrollOwner = nil
        restoration = nil
        if model.preferences.mode == .paged {
            guard pagerReady else { return }
            reader.scrollPosition.scrollTo(id: plan.id)
            pendingRestore = false
            return
        }
        pendingRestore = false
        let within = reader.withinPage
        if within >= 0.999_999, plan.id == reader.plans.last?.id {
            reader.scrollPosition.scrollTo(edge: .bottom)
        } else {
            restoration = within > 0 ? FractionalRestore(pageID: plan.id, fraction: within) : nil
            reader.scrollPosition.scrollTo(id: plan.id, anchor: .top)
        }
    }
}
private struct ChapterTransition {
    let id = UUID()
    let direction: ChapterDirection
    let fraction: Double
}
private struct ReaderPageGeometry: Equatable {
    let frame: CGRect
    let contentY: Double
    let restoreFraction: Double?
}
private struct FractionalRestore {
    let pageID: String
    let fraction: Double
}
