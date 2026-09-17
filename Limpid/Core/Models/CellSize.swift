// CellSize.swift
// Limpid — one terminal cell's footprint in points, as reported by libghostty.

import Foundation

/// The width and height of a single terminal cell in points.
///
/// libghostty reports `GHOSTTY_ACTION_CELL_SIZE` in device pixels because
/// its renderer works in backing-store units. We convert at the boundary
/// so layout consumers work in points. The point value can still differ
/// between scales: libghostty reports whole device pixels, so a 6.5pt cell
/// is 13px at 2x but rounds to 7px at 1x (measured). A surface moved to a
/// screen with another scale reports again, and a consumer takes each new
/// report as it comes. Every pane of one tab is in one window and shares
/// its scale, so a mirror tab can give all of its panes one value.
struct CellSize: Equatable {
    var width: Double
    var height: Double

    /// Convert libghostty's device-pixel report into points.
    ///
    /// Returns `nil` for a degenerate report (a zero dimension or a
    /// non-positive scale) so callers keep the previous value instead of
    /// laying panes out against a zero-sized grid.
    static func points(
        devicePixelWidth: UInt32,
        devicePixelHeight: UInt32,
        scale: Double
    ) -> CellSize? {
        guard devicePixelWidth > 0, devicePixelHeight > 0, scale > 0 else { return nil }
        return CellSize(
            width: Double(devicePixelWidth) / scale,
            height: Double(devicePixelHeight) / scale
        )
    }
}
