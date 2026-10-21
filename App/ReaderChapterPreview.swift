import SwiftUI
import MangaCore

/// A persistent boundary surface. Geometry only reveals it; metadata replaces the placeholder.
struct ReaderChapterPreview: View {
    let reader: ReaderModel
    let model: AppModel
    let direction: ChapterDirection
    let size: CGSize
    let reveal: Double
    let advancing: Bool
    var body: some View {
        let paged = model.preferences.mode == .paged
        let forward = direction == .next
        let reference = reader.adjacentChapter(direction)
        let preview = reader.previews[direction]
        let ready = reveal >= ReaderView.chapterSwitchThreshold && reference != nil
        let title = reference?.title ?? (forward ? String(localized: "No next chapter") : String(localized: "No previous chapter"))
        let hint = reference == nil ? (forward ? String(localized: "End of manga") : String(localized: "Beginning of manga"))
            : (ready ? (forward ? String(localized: "Release for next chapter") : String(localized: "Release for previous chapter"))
               : String(localized: "Pull farther to continue"))
        let gap = min(paged ? size.width : size.height, (paged ? size.width : size.height) * reveal)
        let restingGap = (paged ? size.width : size.height) * ReaderView.chapterSwitchThreshold
        let left = forward == (model.preferences.direction == .rightToLeft)
        let center = paged ? CGPoint(x: left ? gap / 2 : size.width - gap / 2, y: size.height / 2)
            : CGPoint(x: size.width / 2, y: forward ? size.height - gap / 2 : gap / 2)
        let growth = min(1.15, reveal / ReaderView.chapterSwitchThreshold)
        let imageWidth = max(1, min(paged ? 260 : 240, size.width * (paged ? 0.42 : 0.34)) * growth)
        let imageHeight = max(1, size.height * (paged ? 0.4 : 0.23) * growth)
        return ZStack {
            // Fixed typography/position: the expanding gap unmasks text without reflowing it.
            VStack(spacing: 6) {
                Text(title)
                    .font(.caption.bold()).lineLimit(2).accessibilityIdentifier("reader.continuationTitle")
                Image(systemName: reference == nil ? "book.closed" : (ready ? "checkmark.circle.fill" : "arrow.down.circle"))
                    .contentTransition(.symbolEffect(.replace)).font(.title3).frame(width: 24, height: 24)
                ZStack {
                    Text("Pull farther to continue").opacity(reference != nil && !ready ? 1 : 0)
                    Text(forward ? String(localized: "Release for next chapter") : String(localized: "Release for previous chapter")).opacity(ready ? 1 : 0)
                    Text(forward ? String(localized: "End of manga") : String(localized: "Beginning of manga")).opacity(reference == nil ? 1 : 0)
                }.font(.caption2).accessibilityIdentifier("reader.continuationHint")
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(ready ? Color.accentColor : .secondary)
            .padding(.horizontal, 8)
            .frame(width: max(1, paged ? min(180, restingGap - 8) : size.width * 0.55))
            .fixedSize(horizontal: false, vertical: true)
            .position(x: paged ? (left ? restingGap / 2 : size.width - restingGap / 2) : size.width * 0.7,
                      y: paged ? size.height * 0.72 : (forward ? size.height - restingGap * 0.75 : restingGap * 0.75))
            .animation(.smooth(duration: 0.2), value: ready)
            .mask {
                Rectangle().frame(width: paged ? gap : size.width, height: paged ? size.height : gap).position(center)
            }
            if reference != nil {
                ZStack {
                    if let page = preview?.page { PageImageView(page: page, model: model).accessibilityIdentifier("reader.continuationImage") }
                    else if let error = preview?.error { Text(error).font(.caption) }
                    else { Image(systemName: "photo").foregroundStyle(.secondary) }
                }
                .frame(width: advancing ? size.width : imageWidth, height: advancing ? size.height : imageHeight)
                .position(x: advancing ? size.width / 2 : (paged ? center.x : size.width * 0.24),
                          y: advancing ? size.height / 2 : (paged ? size.height * 0.43 : center.y))
                .opacity(advancing ? 1 : min(1, reveal / 0.08))
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .opacity(reveal > 0 ? 1 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(hint)
        .accessibilityHidden(reveal == 0)
    }
}
