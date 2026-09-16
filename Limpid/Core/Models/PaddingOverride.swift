// PaddingOverride.swift
// Limpid — per-side padding a surface pins instead of taking from libghostty's config.

import Foundation

/// Padding pinned on some sides of a surface, in points. `nil` on a side
/// means "keep the configured `window-padding-*`", so an ordinary pane
/// never pins anything and a tmux mirror pane pins only the sides where
/// it meets another pane.
///
/// This is surface state, not config: libghostty redistributes its config
/// to every surface on reload and on the light/dark switch, and a value
/// stored there would be overwritten each time. Pinning survives both.
struct PaddingOverride: Equatable {
    var top: Int?
    var bottom: Int?
    var left: Int?
    var right: Int?

    /// The override a leaf needs given which of its edges touch the pane
    /// area's outer bounds.
    ///
    /// A tmux mirror tab keeps padding on outer edges and none where two
    /// panes meet: the divider between them is exactly one cell, and that
    /// budget cannot also pay for two inner paddings (`6.5 − 16 < 0`). The
    /// outer edges are pinned to Limpid's own values rather than left to
    /// the config, because the mirror lays panes out as `cells × cell size
    /// + padding` and reports the window grid as `(area − padding) / cell
    /// size`: both need the number, and libghostty cannot hand the
    /// configured padding back. Ordinary tabs keep the config everywhere,
    /// so they pin nothing and their surfaces are never touched.
    static func forEdges(_ edges: PaneEdges, isMirror: Bool) -> PaddingOverride? {
        guard isMirror else { return nil }
        let horizontal = GhosttyConfigBridge.windowPaddingX
        let vertical = GhosttyConfigBridge.windowPaddingY
        return PaddingOverride(
            top: edges.contains(.top) ? vertical : 0,
            bottom: edges.contains(.bottom) ? vertical : 0,
            left: edges.contains(.left) ? horizontal : 0,
            right: edges.contains(.right) ? horizontal : 0
        )
    }

    /// The four arguments `ghostty_surface_set_padding` takes, in its
    /// top / bottom / left / right order. A `nil` side becomes `-1`, which
    /// the C side reads as "keep the configured padding"; a pinned side is
    /// points clamped at zero. `nil` as a whole clears every pin.
    static func cSides(of override: PaddingOverride?) -> [Int32] {
        [override?.top, override?.bottom, override?.left, override?.right].map { side in
            guard let side else { return -1 }
            return Int32(clamping: max(0, side))
        }
    }
}
