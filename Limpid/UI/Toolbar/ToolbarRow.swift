// ToolbarRow.swift
// Limpid — shared wrapper that vertically positions toolbar content
// (action capsule / container title) so every column's toolbar lands
// at the same window-y as the AppKit traffic-light row.
//
// Why a wrapper instead of dropping `.padding(.top, X)` ad-hoc:
//   * one place to tweak the alignment when the traffic-light
//     reposition origin changes
//   * caller stays declarative — `ToolbarRow(.container) { … }` vs.
//     wrestling with `.frame(height:alignment:) + padding`

import SwiftUI

struct ToolbarRow<Content: View>: View {
    enum Position { case container, tab, terminal }

    let position: Position
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topInset)
            content()
                .frame(height: LimpidLayout.toolbarContentHeight)
            Spacer(minLength: 0)
        }
        .frame(height: LimpidLayout.topStripHeight)
    }

    private var topInset: CGFloat {
        // Container column sits inside a slab that's already offset by `containerColumnInsetV`
        // from the window top, so it needs *less* inner top inset to
        // reach the same window-y as tab / terminal column.
        switch position {
        case .container: LimpidLayout.toolbarContentTopInsetContainer
        case .tab, .terminal: LimpidLayout.toolbarContentTopInset
        }
    }
}
