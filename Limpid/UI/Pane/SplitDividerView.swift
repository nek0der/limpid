// SplitDividerView.swift
// Limpid — visual-only divider handle. Drag gesture is owned by
// SplitContainerView (absolute-position approach) so this view
// only provides the hit target and hover highlight.

import SwiftUI

struct SplitDividerView: View {
    enum Axis { case horizontal, vertical }
    let direction: Axis

    @State private var isHovering: Bool = false

    var body: some View {
        Rectangle()
            .fill(isHovering ? LimpidColor.accent.opacity(0.35) : Color.primary.opacity(0.08))
            .frame(
                width: direction == .horizontal ? 6 : nil,
                height: direction == .vertical ? 6 : nil
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    (direction == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}
