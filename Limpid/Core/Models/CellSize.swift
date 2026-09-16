// CellSize.swift
// Limpid — one terminal cell's footprint in points, as reported by libghostty.

import Foundation

/// The width and height of a single terminal cell in points.
///
/// libghostty reports `GHOSTTY_ACTION_CELL_SIZE` in device pixels because
/// its renderer works in backing-store units. We convert at the boundary
/// so every layout consumer sees the same value regardless of which
/// display the window is on; a surface that migrates between a Retina
/// and a non-Retina screen re-reports its cell size, and both reports
/// land on the same point value.
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
