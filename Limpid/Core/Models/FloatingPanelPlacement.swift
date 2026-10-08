// FloatingPanelPlacement.swift
// Limpid — where a floating panel goes relative to what opened it, and where
// its arrow points.
//
// Limpid draws its small panels (the pane rename field, the prompt cache
// panel, the container color picker) at scene root rather than through
// `.popover`, so they share one surface and can overlap whatever lies below
// the row or header that opened them. Each hangs from an anchor rect; these
// rules decide the panel's corner and its arrow from that rect alone, so the
// panels agree and the geometry is tested once. Pure and free of
// `LimpidLayout`: the sizes come in as arguments.

import CoreGraphics
import Foundation

enum FloatingPanelPlacement {
    /// How the panel lines up with its anchor horizontally.
    enum Alignment: Equatable {
        /// The panel's leading edge follows the anchor's, as a field that
        /// stands in for the header it renames.
        case leading
        /// The panel is centered on the anchor, as one that points at a
        /// small mark with its arrow.
        case centered
    }

    /// Which edge of the panel faces its anchor.
    enum ArrowEdge: Equatable {
        /// The panel hangs below the anchor.
        case top
        /// The panel sits above the anchor, near the window's bottom.
        case bottom
    }

    /// Where the panel's arrow goes: the edge facing the anchor, and the
    /// arrow's center along that edge in the panel's own coordinates.
    struct Arrow: Equatable {
        let edge: ArrowEdge
        let x: CGFloat
    }

    /// Where the panel's top-leading corner goes, in the same coordinates as
    /// `anchor` and `container`. Horizontally it follows `alignment`, pulled
    /// inside the window by `margin`. It hangs `gap` below the anchor, or
    /// sits that far above it when below would run past the window's bottom;
    /// when neither fits, it is pinned inside the bottom. Whatever the
    /// branch, the result is kept within `margin` of the window's top and
    /// bottom, so an anchor that has scrolled or been laid out off screen
    /// cannot take the panel with it.
    static func origin(
        anchor: CGRect,
        panelSize: CGSize,
        container: CGSize,
        margin: CGFloat,
        gap: CGFloat,
        alignment: Alignment = .leading
    ) -> CGPoint {
        let preferredX = switch alignment {
        case .leading: anchor.minX
        case .centered: anchor.midX - panelSize.width / 2
        }
        let maximumX = container.width - panelSize.width - margin
        let x = maximumX >= margin ? min(max(preferredX, margin), maximumX) : margin

        let below = anchor.maxY + gap
        let above = anchor.minY - gap - panelSize.height
        let maximumY = container.height - panelSize.height - margin
        let y: CGFloat = if below <= maximumY {
            below
        } else if above >= margin {
            above
        } else {
            max(margin, maximumY)
        }
        return CGPoint(x: x, y: min(max(y, margin), max(margin, maximumY)))
    }

    /// The arrow for a panel placed at `panelOrigin`, in the same
    /// coordinates as `anchor`. The panel is placed and clamped to the
    /// window first (`origin`); the arrow then points at the anchor's center
    /// from wherever the panel ended up, kept `minimumInset` from either
    /// corner so it never sits on the rounding. Nil when the panel overlaps
    /// the anchor vertically, which only happens when the window is too
    /// short for it either side: an arrow there would point from inside the
    /// anchor.
    static func arrow(
        anchor: CGRect,
        panelOrigin: CGPoint,
        panelSize: CGSize,
        minimumInset: CGFloat
    ) -> Arrow? {
        let edge: ArrowEdge
        if panelOrigin.y >= anchor.maxY {
            edge = .top
        } else if panelOrigin.y + panelSize.height <= anchor.minY {
            edge = .bottom
        } else {
            return nil
        }
        let wanted = anchor.midX - panelOrigin.x
        let maximum = panelSize.width - minimumInset
        let x = maximum >= minimumInset ? min(max(wanted, minimumInset), maximum) : panelSize.width / 2
        return Arrow(edge: edge, x: x)
    }
}

/// An open floating panel, as its presentation publishes it: an identity
/// minted per opening, and the frame it hangs from in global coordinates.
protocol FloatingPanelRequest: Identifiable where ID == UUID {
    var anchor: CGRect { get }
}
