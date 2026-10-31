// SupervisionFootBar.swift
// Weir — the 32pt row at the foot of each of the supervision window's columns, its rule drawn inside its height.

import SwiftUI

/// The row at the foot of a column of the supervision window: the
/// sidebar's scratch row, the decision bar and the review's band under the
/// session, and the changes panel's primary action. Each column ends with
/// one, flush with its surface's bottom, so the rules along their tops sit
/// on one line across the window and the buttons in them share one center
/// line.
///
/// The height is fixed whatever the content asks for, and the rule is laid
/// over the row's top rather than stacked above it: a rule that added its
/// width, or content that grew the row, moved one column's line off the
/// others'. A column draws one only while it has a row to hold: a shell pane
/// has no decision bar, and the changes panel with no move has no foot bar
/// (`CommitAndPRFootBar`); the sidebar always holds its scratch row.
struct SupervisionFootBar<Content: View>: View {
    /// The row's ground: the soft fill of what the decision bar is on, or
    /// clear where the row stands on its surface's own fill.
    var fill: Color = .clear
    /// The rule's color: `line`, or the color of what waits.
    var rule: Color = SupervisionTokens.line.color
    var leadingInset: CGFloat = WeirLayout.Supervision.footBarLeadingInset
    var trailingInset: CGFloat = WeirLayout.Supervision.footBarTrailingInset
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
            .frame(height: WeirLayout.Supervision.footBarHeight)
            // As wide as the column, and never wider: a row whose narrowest
            // fit still asks for more is cut at the column's edge rather
            // than widening what stands above it, and the clip cuts it at
            // the bar's top and bottom too. The clip only cuts what is
            // drawn, not where a press lands, so each row's fits are what
            // keep its controls inside (`SupervisionFootBarTests`); this is
            // the backstop.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            .background(fill)
            .overlay(alignment: .top) {
                rule
                    .frame(height: WeirLayout.Supervision.footBarRuleWidth)
                    .accessibilityHidden(true)
            }
    }
}
