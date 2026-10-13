import SwiftUI

/// Both reader modes use the same native scroll lifecycle. A drag can reveal either
/// boundary whenever it reaches it; only the distance at finger release can commit.
struct ReaderOverscroll: ViewModifier {
    let axis: Axis
    let enabled: Bool
    @Binding var pull: Double
    let onRelease: (ChapterDirection) -> Void
    let onPhaseChange: (ScrollPhase) -> Void
    @State private var phase = ScrollPhase.idle

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Double.self) { fraction($0) } action: { _, fraction in
                guard enabled else { return }
                if phase == .interacting { pull = fraction }
                else if phase == .decelerating {
                    // Rubber-band return may shrink the revealed gap, but inertia cannot
                    // create a preview, change its direction, or increase its readiness.
                    pull = pull * fraction > 0 ? (pull < 0 ? -1 : 1) * min(abs(pull), abs(fraction)) : 0
                }
            }
            .onScrollPhaseChange { old, new, context in
                phase = new
                if enabled {
                    let released = fraction(context.geometry)
                    if old == .interacting, new == .decelerating || new == .idle, abs(released) >= 0.25 {
                        onRelease(released < 0 ? .previous : .next)
                    }
                    if new == .interacting { pull = released }
                    else if new != .decelerating { pull = 0 }
                }
                onPhaseChange(new)
            }
            .onChange(of: enabled) { _, enabled in if !enabled { pull = 0 } }
    }

    private func fraction(_ geometry: ScrollGeometry) -> Double {
        // SwiftUI reports horizontal geometry in logical (reading-order) coordinates.
        let horizontal = axis == .horizontal
        let offset = horizontal ? geometry.contentOffset.x : geometry.contentOffset.y
        let startInset = horizontal ? geometry.contentInsets.leading : geometry.contentInsets.top
        let endInset = horizontal ? geometry.contentInsets.trailing : geometry.contentInsets.bottom
        let content = horizontal ? geometry.contentSize.width : geometry.contentSize.height
        let viewport = horizontal ? geometry.containerSize.width : geometry.containerSize.height
        let start = -startInset
        let end = max(start, content - viewport + endInset)
        return (min(0, offset - start) + max(0, offset - end)) / max(1, viewport)
    }
}
