// SupervisionIconButtonStyle.swift
// Limpid — the supervision window's borderless glyph button, filled while hovered.

import SwiftUI

/// A glyph or a short mark with no edge (the sidebar heading's ＋): muted
/// at rest; hovered, it takes the `hover` fill and the text color, so it
/// shows it can be pressed without a border competing with the heading.
/// Pressing fills it with `selection`.
struct SupervisionIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration)
    }

    /// A view of its own, so it can hold the hover and read whether the
    /// button is enabled.
    private struct Face: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: LimpidLayout.Supervision.smallControlCornerRadius, style: .continuous)
            let isLit = isHovering && isEnabled
            configuration.label
                .foregroundStyle(isLit ? SupervisionTokens.text.color : SupervisionTokens.muted.color)
                .padding(.horizontal, LimpidLayout.Supervision.iconButtonHorizontalPadding)
                // As see-through as the ground it is on (`SurfaceGround`),
                // as the bordered buttons' fill is.
                .background(SurfaceGround { shape.fill(fill(isLit: isLit)) })
                .contentShape(shape)
                .opacity(isEnabled ? 1 : SupervisionTokens.disabledOpacity)
                .onHover { isHovering = $0 }
        }

        private func fill(isLit: Bool) -> Color {
            if configuration.isPressed {
                return SupervisionTokens.selection.color
            }
            return isLit ? SupervisionTokens.hover.color : .clear
        }
    }
}

extension ButtonStyle where Self == SupervisionIconButtonStyle {
    static var supervisionIcon: SupervisionIconButtonStyle {
        SupervisionIconButtonStyle()
    }
}
