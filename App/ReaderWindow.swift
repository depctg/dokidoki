#if os(visionOS)
import SwiftUI
import UIKit
import MangaCore

/// A pushed window replaces the main window; the system restores it on dismissal.
struct ReaderWindow: View {
    let model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ReaderPresentation(model: model)
            .background(ReaderWindowScene(reader: model.reader, onDisconnect: model.collapseReader).allowsHitTesting(false))
            .onChange(of: model.readerExpanded, initial: true) { _, expanded in
                if !expanded { dismissWindow() }
            }
    }
}

/// Fit once per window, outside chapter identity. Native resizing remains unconstrained.
private struct ReaderWindowScene: UIViewRepresentable {
    let reader: ReaderModel?
    let onDisconnect: () -> Void

    func makeUIView(context: Context) -> SizingView { SizingView() }
    func updateUIView(_ view: SizingView, context: Context) {
        view.onDisconnect = onDisconnect
        guard !view.fitted else { return }
        view.prepare = nil
        guard let reader, !reader.loading, let pipeline = try? PagePipeline(ids: reader.processorIDs) else { return }
        // Capture observable inputs synchronously so image arrival retries a deferred fit.
        let sources = reader.pages.map(\.key), source = reader.source, fraction = reader.fraction
        let layout = ReaderContext(size: .zero, preferences: reader.app.preferences,
                                   analysis: reader.analysis, overrides: reader.overrides)
        view.prepare = { bounds, minimum in
            var layout = layout
            layout.size = bounds
            return await pipeline.fittedSize(sources, source: source, fraction: fraction, context: layout, minimum: minimum)
        }
    }
    static func dismantleUIView(_ view: SizingView, coordinator: ()) { view.prepare = nil }

    final class SizingView: UIView {
        var onDisconnect: (() -> Void)?
        var prepare: ((CGSize, CGSize) async -> CGSize?)? { didSet { fitIfReady() } }
        private(set) var fitted = false
        private var fitting: Task<Void, Never>?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene {
                // A unique SwiftUI Window may retain its view after closing.
                // Scene removal, unlike backgrounding, means reading has ended.
                NotificationCenter.default.removeObserver(self)
                NotificationCenter.default.addObserver(self, selector: #selector(disconnected(_:)),
                                                       name: UIScene.didDisconnectNotification, object: scene)
            }
            fitIfReady()
        }

        @objc private func disconnected(_ notification: Notification) {
            fitting?.cancel()
            onDisconnect?()
        }

        private func fitIfReady() {
            fitting?.cancel()
            guard !fitted, let prepare, let window, let scene = window.windowScene else { return }
            let bounds = window.bounds.size, minimum = scene.effectiveGeometry.minimumSize
            fitting = Task { [weak self] in
                guard let size = await prepare(bounds, minimum), !Task.isCancelled, let self else { return }
                fitted = true
                scene.requestGeometryUpdate(.Vision(size: size))
            }
        }
    }
}
#endif
