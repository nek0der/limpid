// DividerResizeRule.swift
// Limpid — what a column divider writes for a drag or a VoiceOver step, and when it writes nothing.

import CoreGraphics

/// The width a divider (`DividerResizeHandle`) asks its column for.
enum DividerResizeRule {
    /// The width to write for `proposed`, held to `minWidth...maxWidth`, or
    /// `nil` when that is the width already drawn. A column can be drawn
    /// narrower than its saved width (the sidebar in a narrow window,
    /// `SupervisionWindowWidths.sidebarDrawnWidth`), with the divider held
    /// to that drawn width; a step or a drag that the range takes back to
    /// it changes nothing on screen, and writing it would replace the
    /// saved width the column returns to when the window widens.
    static func width(
        proposed: CGFloat,
        current: CGFloat,
        minWidth: CGFloat,
        maxWidth: CGFloat
    ) -> CGFloat? {
        let clamped = min(max(proposed, minWidth), maxWidth)
        return clamped == current ? nil : clamped
    }
}
