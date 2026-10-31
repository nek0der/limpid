// PaneStripOverflow.swift
// Weir — which ends of the pane strip have tabs scrolled out of view.

import CoreGraphics

/// Where the pane strip holds more tabs than it shows. Once every title is
/// at its minimum the strip scrolls (`PaneStripTabWidths`), and a strip
/// that scrolls has to say so: a tab past an edge is otherwise simply
/// absent, and the review's tab or an agent's can be the one out of view.
/// Each end that continues is drawn as a fade into the strip's edge
/// (`PaneStripEdgeFade`), so the cut-off tab is seen to go on rather than
/// to end.
struct PaneStripOverflow: Equatable, Sendable {
    /// Tabs continue past the leading edge.
    var hasLeading: Bool
    /// Tabs continue past the trailing edge.
    var hasTrailing: Bool

    static let none = PaneStripOverflow(hasLeading: false, hasTrailing: false)

    /// The overflow of a strip scrolled by `offset` (the content's leading
    /// edge, as the scroll view reports it: 0 at the start) whose tabs
    /// take `contentWidth` of a `visibleWidth` view. A hair of a point past
    /// an edge is layout noise, not a hidden tab, so each end counts only
    /// past `tolerance`.
    static func of(
        offset: CGFloat,
        contentWidth: CGFloat,
        visibleWidth: CGFloat,
        tolerance: CGFloat = 1
    ) -> PaneStripOverflow {
        guard visibleWidth > 0, contentWidth > visibleWidth + tolerance else { return .none }
        return PaneStripOverflow(
            hasLeading: offset > tolerance,
            hasTrailing: contentWidth - visibleWidth - offset > tolerance
        )
    }
}
