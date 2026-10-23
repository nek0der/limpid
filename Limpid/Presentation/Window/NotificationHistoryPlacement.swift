// NotificationHistoryPlacement.swift
// Limpid — where the notification history panel goes beside the control that opened it.

import CoreGraphics
import Foundation

/// Places the notification history panel: from the left rail, top-aligned
/// to the trailing side of the control. Pure, with the sizes passed
/// in, so it is tested once.
enum NotificationHistoryPlacement {
    struct Metrics: Equatable, Sendable {
        let width: CGFloat
        let preferredHeight: CGFloat
        /// Kept clear between the panel and the window's edges.
        let inset: CGFloat
        /// Between the control and the panel.
        let gap: CGFloat
    }

    /// The panel's frame in the window's coordinates, kept inside the window
    /// by `inset` and shortened to fit (the list scrolls) rather than run
    /// past its bottom. `anchor` and `columnTop` are in the same
    /// coordinates.
    static func frame(anchor: CGRect, columnTop: CGFloat, container: CGSize, metrics: Metrics) -> CGRect {
        let width = metrics.width
        let inset = metrics.inset
        let x = min(anchor.maxX + metrics.gap, max(inset, container.width - width - inset))
        // Level with the top of the columns beside it, as the sidebar and
        // the session start there, rather than with its control, which
        // left the panel hanging below them. Raised further only if it
        // would run off the bottom, and never above the inset.
        let top = max(inset, min(columnTop, container.height - inset - metrics.preferredHeight))
        let height = min(metrics.preferredHeight, max(0, container.height - top - inset))
        return CGRect(x: x, y: top, width: width, height: height)
    }
}
