// SurfaceRegistry+Scrollback.swift
// Weir — the registry's answer to the session's scrollback capture: the pane's terminal writes it.

import Foundation

extension SurfaceRegistry {
    /// The pane's terminal dumps its own scrollback (libghostty's
    /// `ghostty_surface_write_scrollback`). Here in App rather than with the
    /// session, so the session's capture and its folder never name the view
    /// that draws a terminal (`ScrollbackWriting`).
    func writeScrollback(ofPane paneID: UUID, to url: URL) -> Bool {
        view(for: paneID)?.writeScrollback(to: url.path) ?? false
    }
}
