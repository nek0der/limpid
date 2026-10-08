// PaneMinimumSize.swift
// Limpid — the smallest width and height a pane in a split may take.
//
// One number used to serve both axes. A split pane can carry a header,
// which takes height from the terminal and needs a width of its own to
// keep its glyph and menu, so the two axes stopped having the same floor.

import CoreGraphics

/// The floor every split-tree path applies to a leaf: divider drags,
/// restored ratios, the split pre-flight, and pane drops. Only panes laid
/// out by the split machinery are held to it; a zoomed or lone pane fills
/// whatever it is given.
struct PaneMinimumSize: Equatable {
    var width: CGFloat
    var height: CGFloat

    init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    /// The same floor on both axes.
    init(uniform extent: CGFloat) {
        self.init(width: extent, height: extent)
    }

    /// No floor at all: what callers without the user's settings pass.
    static let zero = PaneMinimumSize(uniform: 0)

    /// Whether there is any floor to check against. The split pre-flight
    /// skips its geometry walk when there is not.
    var isEnforced: Bool {
        width > 0 || height > 0
    }

    /// The floor along the axis a split divides. A horizontal split puts
    /// its panes side by side, so it divides width; a vertical one stacks
    /// them, so it divides height.
    func extent(along axis: SplitDirection) -> CGFloat {
        switch axis {
        case .horizontal: width
        case .vertical: height
        }
    }

    /// The floor for a split pane under the user's settings. Without
    /// headers both axes take the user's minimum. With them the terminal
    /// keeps that minimum and the header's height is added on top, so a
    /// header never eats into the rows the user asked for. The width needs
    /// no adjustment: `TerminalSettings.minPaneSizeRange` starts at the
    /// header's narrowest form, so any minimum the user can pick already
    /// leaves room for its glyph and menu. `showsHeaders` is the setting
    /// alone: a zoomed pane shows its header with the setting off, but it
    /// is alone on screen and never held to this floor.
    static func resolved(
        minPaneSize: Double,
        showsHeaders: Bool,
        headerHeight: CGFloat = PaneHeaderMetrics.height
    ) -> PaneMinimumSize {
        let minimum = CGFloat(minPaneSize)
        guard showsHeaders else { return PaneMinimumSize(uniform: minimum) }
        return PaneMinimumSize(width: minimum, height: minimum + headerHeight)
    }
}

extension TerminalSettings {
    /// The floor every split pane is held to under these settings.
    var paneMinimumSize: PaneMinimumSize {
        .resolved(minPaneSize: minPaneSize, showsHeaders: showsSplitPaneHeaders)
    }
}
