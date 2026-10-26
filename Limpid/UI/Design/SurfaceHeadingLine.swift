// SurfaceHeadingLine.swift
// Limpid — a surface's first line: its heading and a glyph button, centered on the line the rails share.

import SwiftUI

/// The first line of a surface whose heading has a glyph button at its end
/// (the sidebar's "Projects" and ＋), on the surfaces' heading line:
/// `surfaceHeadingLineHeight` tall, so its center sits where the rails'
/// first icons are centered; the heading stands a surface heading's inset
/// in from the leading edge, and the button's glyph as far in from the
/// other edge
/// (`surfaceHeadingButtonTrailingInset`).
struct SurfaceHeadingLine<Title: View, Trailing: View>: View {
    @ViewBuilder var title: () -> Title
    @ViewBuilder var trailing: () -> Trailing

    private typealias Layout = LimpidLayout.Supervision

    var body: some View {
        HStack(spacing: 0) {
            title()
                .font(LimpidFont.Supervision.surfaceHeading)
                .foregroundStyle(SupervisionTokens.text.color)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Layout.spaceXS)
            trailing()
        }
        .padding(Layout.sidebarHeadingInsets)
        .frame(height: Layout.surfaceHeadingLineHeight)
    }
}
