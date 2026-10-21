import SwiftUI

/// A signed distance beyond the logical start/end of a native scroll view.
struct ScrollPull: Equatable {
    var distance = 0.0
    var viewport = 1.0
    var fraction: Double { distance / max(1, viewport) }

    init() {}
    init(_ geometry: ScrollGeometry, axis: Axis) {
        // Horizontal geometry follows SwiftUI's logical reading direction.
        let horizontal = axis == .horizontal
        let offset = horizontal ? geometry.contentOffset.x : geometry.contentOffset.y
        let start = -(horizontal ? geometry.contentInsets.leading : geometry.contentInsets.top)
        let endInset = horizontal ? geometry.contentInsets.trailing : geometry.contentInsets.bottom
        let content = horizontal ? geometry.contentSize.width : geometry.contentSize.height
        viewport = horizontal ? geometry.containerSize.width : geometry.containerSize.height
        distance = min(0, offset - start) + max(0, offset - max(start, content - viewport + endInset))
    }
}

/// Native lifecycle for reader chapter continuation. Only a
/// finger release emits an action; inertia may shrink an existing preview only.
struct ScrollOverpull: ViewModifier {
    var axis: Axis = .vertical
    var enabled = true
    @Binding var pull: ScrollPull
    let onRelease: (ScrollPull) -> Void
    var onPhaseChange: (ScrollPhase) -> Void = { _ in }
    @State private var phase = ScrollPhase.idle

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: ScrollPull.self) { ScrollPull($0, axis: axis) } action: { _, value in
                guard enabled else { return }
                if phase == .interacting { pull = value }
                else if phase == .decelerating {
                    pull.distance = pull.distance * value.distance > 0
                        ? (pull.distance < 0 ? -1 : 1) * min(abs(pull.distance), abs(value.distance)) : 0
                }
            }
            .onScrollPhaseChange { old, new, context in
                phase = new
                if enabled {
                    let value = ScrollPull(context.geometry, axis: axis)
                    if old == .interacting, new == .decelerating || new == .idle { onRelease(value) }
                    if new == .interacting { pull = value }
                    else if new != .decelerating { pull = ScrollPull() }
                }
                onPhaseChange(new)
            }
            .onChange(of: enabled) { _, enabled in if !enabled { pull = ScrollPull() } }
    }
}
