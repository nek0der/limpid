// SupervisionIconButtonStyle.swift
// Weir — the supervision window's borderless glyph button, filled while hovered.

import SwiftUI

/// A glyph with no edge (the sidebar heading's ＋): muted at rest;
/// hovered, it takes the `hover` fill and the text color, so it shows it
/// can be pressed without a border competing with the heading. Pressing
/// fills it with `selection`. The fill is a square as tall as the button,
/// centered on the glyph. The room either side of the glyph stays for the
/// click and for where the glyph stands, but a fill that wide reads as a
/// bar under a lone ＋.
struct SupervisionIconButtonStyle: ButtonStyle {
    /// The room either side of the glyph: the heading's, unless the glyphs
    /// stand in a row of their own where that room reads as gaps between
    /// them (a turn card's moves).
    var horizontalPadding = WeirLayout.Supervision.iconButtonHorizontalPadding

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, horizontalPadding: horizontalPadding)
    }

    /// A view of its own, so it can hold the hover and read whether the
    /// button is enabled.
    private struct Face: View {
        let configuration: Configuration
        let horizontalPadding: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: WeirLayout.Supervision.smallControlCornerRadius, style: .continuous)
            let isLit = isHovering && isEnabled
            configuration.label
                .foregroundStyle(isLit ? SupervisionTokens.text.color : SupervisionTokens.muted.color)
                .padding(.horizontal, horizontalPadding)
                // As see-through as the ground it is on (`SurfaceGround`),
                // as the bordered buttons' fill is.
                .background(SurfaceGround { shape.fill(fill(isLit: isLit)).aspectRatio(1, contentMode: .fit) })
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

    /// `supervisionIcon` with `horizontalPadding` either side of the glyph.
    static func supervisionIcon(horizontalPadding: CGFloat) -> SupervisionIconButtonStyle {
        SupervisionIconButtonStyle(horizontalPadding: horizontalPadding)
    }
}
