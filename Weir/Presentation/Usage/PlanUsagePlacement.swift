// PlanUsagePlacement.swift
// Weir — where the plan usage panel goes beside the rail button that opened it.

import CoreGraphics
import Foundation

/// Places the plan usage panel beside the rail button that opened it. The
/// button is in the rail's bottom group, so the panel's bottom is level with
/// the bottom of the columns beside the rail (the sidebar's foot), as the
/// notification history's top is level with their top, and it grows upward
/// as far as that top.
/// Pure, with the sizes passed in, so it is tested once.
enum PlanUsagePlacement {
    struct Metrics: Equatable {
        let width: CGFloat
        /// Kept clear between the panel and the window's edges.
        let inset: CGFloat
        /// Between the button and the panel.
        let gap: CGFloat
    }

    /// Where the panel goes in the window's coordinates, in which `anchor`
    /// is given too.
    struct Place: Equatable {
        let leading: CGFloat
        /// The panel's bottom edge.
        let bottom: CGFloat
        /// The most the panel may grow to, from `bottom` up.
        let maximumHeight: CGFloat
    }

    static func place(anchor: RailPanelAnchor, container: CGSize, metrics: Metrics) -> Place {
        let leading = min(anchor.frame.maxX + metrics.gap, max(metrics.inset, container.width - metrics.width - metrics.inset))
        let bottom = min(anchor.columnBottom, container.height - metrics.inset)
        let top = max(metrics.inset, anchor.columnTop)
        return Place(leading: leading, bottom: bottom, maximumHeight: max(0, bottom - top))
    }
}
