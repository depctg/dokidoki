import SwiftUI
import MangaCore

/// One presentation above the whole app, independent of the selected tab's navigation stack.
struct ReaderPresentation: View {
    @Bindable var model: AppModel
    @State private var dragOffset = CGSize.zero
    var body: some View {
        GeometryReader { geometry in
            NavigationStack {
                Group {
                    if let reader = model.reader {
                        ReaderView(reader: reader, model: model).id(reader.id).transition(.opacity)
                    } else {
                        ProgressView("Opening chapter…")
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Collapse reader") { model.collapseReader() } } }
                    }
                }
                // This preference belongs to the persistent stack root, not a replaced chapter.
                #if os(macOS)
                .toolbarVisibility(model.readerImmersive ? .hidden : .visible, for: .windowToolbar)
                #else
                .toolbarVisibility(model.readerImmersive ? .hidden : .visible, for: .navigationBar)
                #endif
            }
            .persistentSystemOverlays(model.readerImmersive ? .hidden : .automatic)
            #if os(iOS)
            .statusBarHidden(model.readerImmersive)
            #endif
            .animation(.easeOut(duration: 0.2), value: model.reader?.id)
            .offset(dragOffset)
            .simultaneousGesture(DragGesture(minimumDistance: 20, coordinateSpace: .named("readerPresentation"))
                .onChanged { value in
                    if accepts(value, size: geometry.size) {
                        dragOffset = model.preferences.mode == .paged
                            ? CGSize(width: 0, height: max(0, value.translation.height))
                            : CGSize(width: max(0, value.translation.width), height: 0)
                    }
                }
                .onEnded { value in
                    let distance = model.preferences.mode == .paged ? dragOffset.height : dragOffset.width
                    if accepts(value, size: geometry.size), distance > 90 { model.collapseReader() }
                    else { withAnimation(.snappy) { dragOffset = .zero } }
                })
        }
        .coordinateSpace(name: "readerPresentation")
        .onAppear { dragOffset = .zero }
        .interactiveDismissDisabled()
        .accessibilityAction(named: "Collapse reader") { model.collapseReader() }
        .alert("MangaViewer", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private func accepts(_ value: DragGesture.Value, size: CGSize) -> Bool {
        switch model.preferences.mode {
        case .paged:
            // Only pulls beginning near the top collapse; horizontal page swipes stay in the pager.
            value.startLocation.y < min(180, size.height * 0.22) && value.translation.height > abs(value.translation.width) * 1.5
        case .scroll:
            // Physical left edge, independent of manga reading direction. Vertical scrolling remains free.
            value.startLocation.x < 28 && value.translation.width > abs(value.translation.height) * 1.5
        }
    }
}

struct ReaderResumeBar: View {
    let reader: ReaderModel
    let model: AppModel
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    var body: some View {
        Button { model.resumeReader() } label: {
            HStack(spacing: 12) {
                CoverImageView(key: reader.mangaCover, model: model, bounds: CGSize(width: 36, height: 36), cornerRadius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(placement == .inline ? [reader.mangaTitle, reader.chapter.title].compactMap { $0 }.joined(separator: " · ") : reader.mangaTitle ?? reader.chapter.title)
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    if placement != .inline {
                        Text([reader.mangaTitle == nil ? nil : reader.chapter.title,
                              reader.plans.isEmpty ? String(localized: "Resume reading") : String(localized: "Page \(reader.index + 1) of \(reader.plans.count)")].compactMap { $0 }.joined(separator: " · "))
                            .lineLimit(1)
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up").font(.headline)
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .frame(maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resume \([reader.mangaTitle, reader.chapter.title].compactMap { $0 }.joined(separator: ", "))")
        .accessibilityValue(reader.plans.isEmpty ? "" : String(localized: "Page \(reader.index + 1) of \(reader.plans.count)"))
        .accessibilityIdentifier("reader.resume")
        .task(id: model.loadingRevision) { await reader.loadMangaMetadata() }
    }
}

#if os(iOS)
struct ReaderTabAccessory: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: model.reader != nil && !model.readerExpanded) { accessory }
        } else if model.reader != nil {
            content.tabViewBottomAccessory { accessory }
        } else { content }
    }
    @ViewBuilder private var accessory: some View {
        if let reader = model.reader, !model.readerExpanded { ReaderResumeBar(reader: reader, model: model) }
    }
}
#endif
