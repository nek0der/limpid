// PaneStripTabWidths.swift
// Limpid — how the pane strip's tabs share its width: the longest titles are cut first, none below a minimum.

import CoreGraphics

/// The widths of the pane strip's tabs. A tab is as wide as what it
/// holds while the strip has room. When it does not, the tabs give way
/// from the widest down: every tab is held to one common width, its title
/// cut with an ellipsis inside the tab, while a tab already narrower keeps
/// its own width. No title is cut below `titleMinimum`; past that the tabs
/// keep their minimum widths and the strip scrolls. So a tab is never cut
/// by the strip's edge or by the tab beside it, only shortened in its own
/// title.
enum PaneStripTabWidths {
    /// What one tab needs.
    struct Tab: Equatable {
        /// Its width with the whole title, up to the title's maximum.
        let ideal: CGFloat
        /// Its width with no room for the title: the badge, the marks, the
        /// close button, and the padding, none of which give way.
        let bare: CGFloat

        /// The narrowest the tab is drawn: room for `titleMinimum` of its
        /// title, or the whole tab when it is shorter than that.
        func minimum(titleMinimum: CGFloat) -> CGFloat {
            min(ideal, max(bare, 0) + titleMinimum)
        }
    }

    /// Each tab's width, in order, so the tabs with `spacing` between them
    /// fill no more than `available` while they can. The result sums to
    /// `available` when the tabs are cut, to less when every tab has its
    /// ideal width, and to more only when every tab is at its minimum, which
    /// is when the strip scrolls.
    static func widths(
        of tabs: [Tab],
        available: CGFloat,
        spacing: CGFloat,
        titleMinimum: CGFloat
    ) -> [CGFloat] {
        let ideals = tabs.map { max($0.ideal, 0) }
        let minimums = tabs.map { $0.minimum(titleMinimum: titleMinimum) }
        let budget = available - spacing * CGFloat(max(tabs.count - 1, 0))
        guard ideals.reduce(0, +) > budget else { return ideals }
        guard minimums.reduce(0, +) < budget else { return minimums }
        let cap = commonWidth(minimums: minimums, ideals: ideals, budget: budget)
        return zip(minimums, ideals).map { max($0, min($1, cap)) }
    }

    /// The one width the wider tabs are held to so the tabs fill `budget`:
    /// the `cap` at which the sum of `max(minimum, min(ideal, cap))` meets
    /// it. That sum grows in straight lines between the tabs' minimums and
    /// ideals, so the cap is found exactly on the stretch where it crosses
    /// the budget. The caller has seen that the minimums fall short of the
    /// budget and the ideals pass it.
    private static func commonWidth(minimums: [CGFloat], ideals: [CGFloat], budget: CGFloat) -> CGFloat {
        func total(_ cap: CGFloat) -> CGFloat {
            zip(minimums, ideals).reduce(0) { $0 + max($1.0, min($1.1, cap)) }
        }
        let points = Set(minimums + ideals).sorted()
        for (low, high) in zip(points, points.dropFirst()) where total(high) >= budget {
            let lowTotal = total(low)
            let slope = (total(high) - lowTotal) / (high - low)
            return slope > 0 ? low + (budget - lowTotal) / slope : low
        }
        // Unreachable while the ideals pass the budget: the last point is
        // the widest ideal, where the sum is the ideals'.
        return points.last ?? 0
    }
}
