import SwiftUI
import MangaCore

/// A cover is decorative artwork at its original ratio, bounded by the available
/// space. The decoded object image comes from core's shared cache, with no page pipeline.
struct CoverImageView: View {
    let key: ObjectKey?
    let model: AppModel
    let bounds: CGSize
    var hint: CacheHint = .preferCache
    var cornerRadius = 8.0
    @State private var image: CGImage?
    @State private var active = false
    private var requestID: String {
        "\(key?.id ?? "")|\(hint)|\(model.loadingRevision)|\(active)"
    }
    var body: some View {
        ZStack {
            if let image {
                let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
                Image(decorative: image, scale: 1).resizable()
                    .frame(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                    .clipShape(.rect(cornerRadius: cornerRadius))
            } else {
                Image(systemName: "book.closed").foregroundStyle(.secondary)
                    .frame(width: bounds.width, height: min(bounds.height, bounds.width * 1.5))
            }
        }
        .accessibilityHidden(true)
        .onAppear { active = true }
        .onDisappear { active = false; image = nil }
        .task(id: requestID) {
            guard active else { return }
            image = nil
            guard let key, let repository = model.repository else { return }
            do {
                guard case .page(let page) = try await key.load(using: repository, hint: hint) else { return }
                let decoded = try await page.image(using: repository, maxPixel: 768)
                try Task.checkCancellation()
                guard active else { return }
                image = decoded
            } catch { /* Core records image errors; the decorative placeholder stays available. */ }
        }
    }
}
