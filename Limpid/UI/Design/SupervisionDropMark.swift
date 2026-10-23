// SupervisionDropMark.swift
// Limpid — how the supervision window marks the place a drag would land.

import SwiftUI

/// Where a dragged tab or pane would land, drawn one way across the
/// supervision window: a ring in the accent, a step thinner than the
/// keyboard's ring (`dropTargetRingWidth`), in the target's own shape, over
/// the accent's soft tone. The mark takes the language the window's other
/// marks already speak rather than macOS's default drop highlight, so a
/// drop target reads as the same kind of place as a focused one. The
/// soft tone is translucent so what the target holds (a tab's title, a
/// pane's lines) still reads under it.
struct SupervisionDropMark<S: InsettableShape>: View {
    let shape: S
    @Environment(\.limpidAccent) private var accent

    var body: some View {
        ZStack {
            shape.fill(accent.opacity(SupervisionTokens.dropTargetFillOpacity))
            shape.strokeBorder(accent, lineWidth: LimpidLayout.Supervision.dropTargetRingWidth)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A sidebar row a dragged tab would move to: the fill of the selected
/// row, since the row becomes the session the tab is in, under the same
/// ring as every other drop target of the window (`SupervisionDropMark`).
struct SupervisionRowDropMark: ViewModifier {
    let isTargeted: Bool
    let cornerRadius: CGFloat
    @Environment(\.limpidAccent) private var accent

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if isTargeted {
                    shape.fill(SupervisionTokens.selection.color)
                        .transition(.opacity)
                }
            }
            .overlay {
                if isTargeted {
                    shape.strokeBorder(accent, lineWidth: LimpidLayout.Supervision.dropTargetRingWidth)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
    }
}
