// SessionLayoutDefaults.swift
// Limpid — the column sizes a session starts with and resets to.

import CoreGraphics

/// Defaults for the layout values `WindowSession` persists. They live in
/// Core because the session, its snapshot and the demo fixture start from
/// them; the views read them only to reset a divider. Presentation metrics
/// stay in `LimpidLayout`.
enum SessionLayoutDefaults {
    /// Container column width. `LimpidLayout` holds the drag bounds.
    static let containerColumnWidth: CGFloat = 240

    /// Tab column (tab list / mode body) default width. The current value
    /// lives on `WindowSession.tabColumnWidth` so the user can drag-resize
    /// it; double-clicking the divider resets to this default.
    ///
    /// Derived from the container column rather than set apart from it.
    /// It used to be 260 against the container's 240, which gave the
    /// wider column to the shorter names — a tab list holds `main` and
    /// `shell`, the container list holds branch names long enough to
    /// truncate. Two widths that near each other also read as a mistake
    /// rather than as hierarchy.
    static var tabColumnWidth: CGFloat {
        containerColumnWidth
    }

    /// Container column Waiting region height as a fraction of the slab height.
    /// Default for `WindowSession.attentionHeightFraction`: the share a
    /// session opens at until the user moves the divider, and the share
    /// a double-click resets to. A fraction (not points) so the region
    /// keeps its proportion when the window resizes.
    static let attentionHeightFraction: CGFloat = 0.25
}
