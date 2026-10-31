// HorizontalLayoutPlacement.swift
// Weir — placing a custom layout's subviews side by side at widths it has already decided.

import SwiftUI

/// This is the placing half of a horizontal `Layout`: it places each subview
/// from the leading edge of `bounds`, at the width given for it, centered on
/// the bounds' height, `spacing` apart. The decision bar's words, the pane strip's
/// tabs, and the title bar's place controls each decide their widths by a
/// rule of their own and then place alike here, so only the rule differs
/// between them.
enum HorizontalLayoutPlacement {
    /// Places `subviews` at `widths`, paired in order; a subview past the
    /// end of `widths` is left unplaced, as `zip` leaves it.
    static func place(_ subviews: LayoutSubviews, widths: [CGFloat], in bounds: CGRect, spacing: CGFloat) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width + spacing
        }
    }
}
