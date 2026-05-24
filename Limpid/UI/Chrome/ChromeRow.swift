// ChromeRow.swift
// Limpid — shared wrapper that vertically positions chrome content
// (action capsule / container title) so every column's chrome lands
// at the same window-y as the AppKit traffic-light row.
//
// Why a wrapper instead of dropping `.padding(.top, X)` ad-hoc:
//   * one place to tweak the alignment when the traffic-light
//     reposition origin changes
//   * caller stays declarative — `ChromeRow(.l1) { … }` vs.
//     wrestling with `.frame(height:alignment:) + padding`

import SwiftUI

struct ChromeRow<Content: View>: View {
    enum Position { case l1, l2, l3 }

    let position: Position
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topInset)
            content()
                .frame(height: LimpidLayout.chromeContentHeight)
            Spacer(minLength: 0)
        }
        .frame(height: LimpidLayout.topStripHeight)
    }

    private var topInset: CGFloat {
        // L1 sits inside a slab that's already offset by `l1InsetV`
        // from the window top, so it needs *less* inner top inset to
        // reach the same window-y as L2 / L3.
        switch position {
        case .l1: LimpidLayout.chromeContentTopInsetL1
        case .l2, .l3: LimpidLayout.chromeContentTopInset
        }
    }
}
