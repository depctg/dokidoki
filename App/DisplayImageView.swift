import SwiftUI
import MangaCore

/// One composed display page, shared by preparation and visible-row loading.
/// Retain one landing page through native target layout; release on page change/collapse.
nonisolated struct PageArtwork: Sendable {
    let id: String
    let revision: Int
    let image: CGImage?
    let originals: [CGImage]

    static func identity(plan: DisplayPage, pages: [PageObject]) -> String {
        plan.id + pages.filter { plan.sourcePageKeys.contains($0.key) }.map {
            ($0.imageURL?.absoluteString ?? $0.key.id) + ($0.refererURL?.absoluteString ?? "")
        }.joined()
    }

    static func load(plan: DisplayPage, pages: [PageObject], using repository: ObjectRepository,
                                revision: Int, refresh: Bool = false) async throws -> PageArtwork {
        let artwork = try await plan.image(pages: pages, using: repository, refresh: refresh)
        return PageArtwork(id: identity(plan: plan, pages: pages), revision: revision,
                           image: artwork.image, originals: artwork.originals)
    }
}

struct DisplayImageView: View {
    let plan: DisplayPage
    let pages: [PageObject]
    let model: AppModel
    var prepared: PageArtwork?
    var onLoad: () -> Void = {}
    @State private var artwork: PageArtwork?
    @State private var error: String?
    @State private var attempt = 0
    private var identity: String { PageArtwork.identity(plan: plan, pages: pages) }
    private var preparedArtwork: PageArtwork? {
        guard attempt == 0, prepared?.id == identity, prepared?.revision == model.loadingRevision else { return nil }
        return prepared
    }
    private var visibleArtwork: PageArtwork? {
        if artwork?.id == identity, artwork?.revision == model.loadingRevision { return artwork }
        return preparedArtwork
    }
    private var imageLabel: String {
        let numbers = pages.filter { plan.sourcePageKeys.contains($0.key) }.compactMap { $0.sourceIndex.map { String($0 + 1) } }
        return numbers.isEmpty ? String(localized: "Comic page") : String(localized: "Comic page \(numbers.joined(separator: ", "))")
    }
    var body: some View {
        ZStack {
            if let image = visibleArtwork?.image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .accessibilityLabel(imageLabel).accessibilityIdentifier("reader.pageImage")
            } else if let originals = visibleArtwork?.originals, !originals.isEmpty {
                HStack(spacing: 0) { ForEach(originals.indices, id: \.self) { Image(decorative: originals[$0], scale: 1).resizable().scaledToFit() } }
            } else if let error {
                VStack(spacing: 12) { Image(systemName: "photo.badge.exclamationmark"); Text(error).font(.caption); Button("Retry image") { attempt += 1 } }.padding().foregroundStyle(.secondary)
            } else { ProgressView("Loading image…").padding(30) }
        }
        .onDisappear { artwork = nil }
        .task(id: "\(identity)|\(model.loadingRevision)|\(attempt)") {
            guard !Task.isCancelled else { return }
            error = nil
            if let preparedArtwork {
                artwork = preparedArtwork
                onLoad()
                return
            }
            artwork = nil
            do {
                guard let repository = model.repository else { return }
                let loaded = try await PageArtwork.load(plan: plan, pages: pages, using: repository,
                                                       revision: model.loadingRevision, refresh: attempt > 0)
                try Task.checkCancellation()
                artwork = loaded
                onLoad()
            } catch is CancellationError {} catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

struct PageImageView: View {
    let page: PageObject
    let model: AppModel
    var body: some View { DisplayImageView(plan: DisplayPage(regions: [PageRegion(sourcePage: page.key)]), pages: [page], model: model) }
}
