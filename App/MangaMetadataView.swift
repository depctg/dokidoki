import SwiftUI
import MangaCore

/// Display only rule-extracted values; status wording and rating scales belong to the source.
struct MangaMetadataView: View {
    let manga: MangaObject
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if manga.rating != nil || manga.status != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { rating; status }.fixedSize()
                    VStack(alignment: .leading, spacing: 4) { rating; status }
                }
            }
            if let tags = manga.tags, !tags.isEmpty {
                Text(tags.joined(separator: " · "))
                    .lineLimit(compact ? 2 : nil)
                    .accessibilityLabel("Tags: \(tags.joined(separator: ", "))")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .font(.caption).foregroundStyle(.secondary)
    }
    @ViewBuilder private var rating: some View {
        if let rating = manga.rating {
            Label(rating, systemImage: "star.fill").labelStyle(.titleAndIcon)
                .accessibilityLabel("Rating: \(rating)")
        }
    }
    @ViewBuilder private var status: some View {
        if let status = manga.status { Text(status).accessibilityLabel("Status: \(status)") }
    }
}
