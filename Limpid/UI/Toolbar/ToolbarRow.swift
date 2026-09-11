// ToolbarRow.swift
// Limpid — shared wrapper that vertically positions toolbar content
// (toolbar controls / container title) so every column's toolbar lands
// at the same window-y as the AppKit traffic-light row.
//
// Why a wrapper instead of dropping `.padding(.top, X)` ad-hoc:
//   * one place to tweak the alignment when the traffic-light
//     reposition origin changes
//   * caller stays declarative — `ToolbarRow { … }` vs. wrestling
//     with `.frame(height:alignment:) + padding`
//
// Every column starts at the window top, so all three share one inset.
// The container column needed a smaller one only while its content sat
// inside a slab inset from the window edge.

import SwiftUI

struct ToolbarRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: LimpidLayout.toolbarContentTopInset)
            content()
                .frame(height: LimpidLayout.toolbarContentHeight)
            Spacer(minLength: 0)
        }
        .frame(height: LimpidLayout.topStripHeight)
    }
}
