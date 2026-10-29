// RailPanelAnchor.swift
// Limpid — the rail control a window's floating panel hangs from: the notification history's, the plan usage's.

import CoreGraphics
import Foundation

/// Where a panel opened from the rail goes: its control's frame in global
/// coordinates, beside which the panel goes, and the top and bottom of the
/// surfaces beside the rail, which a panel from the rail's top group is
/// level with at the top, and one from its bottom group at the bottom.
struct RailPanelAnchor: Equatable {
    let frame: CGRect
    /// The top of the window's columns, in the same coordinates: the
    /// sidebar's, the session's, and the rail's own.
    let columnTop: CGFloat
    /// The bottom of the window's columns, in the same coordinates: where
    /// the sidebar's foot (Scratch) ends.
    let columnBottom: CGFloat
}
