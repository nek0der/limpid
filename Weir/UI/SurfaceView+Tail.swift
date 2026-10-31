// SurfaceView+Tail.swift
// Weir — reads the text a terminal shows, for the all projects cards.

import Foundation
import GhosttyKit

extension SurfaceView {
    /// The last lines with text at the bottom of the terminal, the active
    /// screen, whatever the pane is scrolled back to (`TerminalTail`); empty
    /// before the surface exists. Read once when a card appears rather than
    /// kept current: copying the screen costs a pass over its cells, which
    /// a sheet of cards would pay on every frame of output.
    func lastLines(_ count: Int = TerminalTail.lineCount) -> [String] {
        guard let surface else { return [] }
        let screen = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, screen, &text) else { return [] }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let bytes = text.text, text.text_len > 0 else { return [] }
        let buffer = UnsafeRawBufferPointer(start: bytes, count: Int(text.text_len))
        guard let shown = String(bytes: buffer, encoding: .utf8) else { return [] }
        return TerminalTail.lastLines(of: shown, count: count)
    }
}
