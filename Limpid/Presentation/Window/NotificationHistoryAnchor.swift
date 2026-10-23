// NotificationHistoryAnchor.swift
// Limpid — the control a window's notification history hangs from.

import CoreGraphics
import Foundation

/// Where a window's notification history opens: its control's frame in
/// global coordinates, beside which the panel goes, and the top of the
/// surfaces beside the rail, which the panel's top is level with.
struct NotificationHistoryAnchor: Equatable {
    let frame: CGRect
    /// The top of the window's columns, in the same coordinates: the
    /// sidebar's, the session's, and the rail's own.
    let columnTop: CGFloat
}
