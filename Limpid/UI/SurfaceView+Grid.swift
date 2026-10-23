// SurfaceView+Grid.swift
// Limpid — the terminal grid's live measures, read from libghostty for views that size or describe a pane.

import AppKit

extension SurfaceView {
    /// The grid last reported through `onGridSizeChange`, and whether a
    /// report waits for the layout pass to end. Touched only by
    /// `reportGridSizeIfChanged` and `forgetReportedGridSize`.
    struct GridSizeReport {
        var lastReported: TerminalGridSize?
        var isPending = false
    }

    /// Reports a new grid once the layout pass is over. We run inside
    /// `setFrameSize`, during AppKit's layout: a SwiftUI view observing the
    /// grid would be asked to update its constraints mid-layout, which AppKit
    /// raises an exception for. A live resize changes the grid many times in
    /// one pass; one report covers them. Called on a new frame, on a font
    /// change, and when the view joins a window, so `lastReported` never
    /// stands for a grid nobody was told about.
    func reportGridSizeIfChanged() {
        guard onGridSizeChange != nil,
              let grid = gridSize,
              grid != gridSizeReport.lastReported
        else { return }
        gridSizeReport.lastReported = grid
        guard !gridSizeReport.isPending else { return }
        gridSizeReport.isPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            gridSizeReport.isPending = false
            onGridSizeChange?()
        }
    }

    /// Off screen the grid reads as `nil`; back on screen it is new again,
    /// even at the size it had before.
    func forgetReportedGridSize() {
        gridSizeReport.lastReported = nil
    }

    /// The live cell width in points, which only the font and the screen's
    /// scale move. With it a pane's columns at another width can be worked
    /// out at once, where the grid is reported a moment after a resize.
    var cellWidth: CGFloat? {
        guard let surface,
              let pixels = GhosttyFFI.surfaceCellWidthPixels(surface),
              let scale = window?.backingScaleFactor, scale > 0
        else { return nil }
        return CGFloat(pixels) / scale
    }

    /// The terminal's grid now, read live like `cellWidth`. `nil` before
    /// the surface exists or while it has no window to size it.
    var gridSize: TerminalGridSize? {
        guard let surface, window != nil else { return nil }
        return GhosttyFFI.surfaceGridSize(surface)
    }
}
