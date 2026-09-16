// SurfaceView+Geometry.swift
// Limpid — the geometry a surface exchanges with libghostty: the cell size it reports and the padding we pin.

import AppKit
import GhosttyKit
import OSLog

private let log = Logger.limpid("surface.view")

extension SurfaceView {
    /// A pane whose bytes come from a descriptor rather than a pty: a tmux
    /// mirror. Decided at creation and never changes for the surface's life.
    var isMirror: Bool {
        mirrorIoFd >= 0
    }

    func updateScrollbarState(_ state: TerminalScrollbarState) {
        scrollbarState = state
        onScrollbarStateChange?(state)
    }

    /// Read the grid libghostty is drawing and tell the listener when it
    /// differs from the last report. Called after every size push; the
    /// comparison keeps a tmux mirror from re-sending the same window size
    /// on every layout pass.
    func reportGridIfChanged() {
        guard let onGridChange, let surface else { return }
        let grid = GhosttyFFI.surfaceGrid(surface)
        guard grid.columns > 0, grid.rows > 0,
              grid.columns != lastReportedGrid?.columns || grid.rows != lastReportedGrid?.rows
        else { return }
        lastReportedGrid = grid
        onGridChange(grid.columns, grid.rows)
    }

    /// Convert libghostty's device-pixel cell report into points. We divide
    /// by the window's scale, not `lastPushedScale`: the first report fires
    /// inside `ghostty_surface_new`, before any scale has been pushed.
    func updateCellSize(devicePixelWidth: UInt32, devicePixelHeight: UInt32) {
        let scale = Double(window?.backingScaleFactor ?? 1)
        guard let size = CellSize.points(
            devicePixelWidth: devicePixelWidth,
            devicePixelHeight: devicePixelHeight,
            scale: scale
        ) else {
            log.debug("CELL_SIZE ignored (degenerate report)")
            return
        }
        guard size != cellSize else { return }
        cellSize = size
        log.debug("CELL_SIZE \(size.width, privacy: .public)x\(size.height, privacy: .public)pt scale=\(scale, privacy: .public)")
    }

    /// Hand the current `paddingOverride` to libghostty. A no-op until the
    /// surface exists; `createSurface` calls this again once it does, which
    /// is how a value placed on a not-yet-mounted view still lands.
    func applyPaddingOverride() {
        guard let surface else { return }
        GhosttyFFI.setPadding(paddingOverride, on: surface)
        log.debug("padding override applied: \(String(describing: self.paddingOverride), privacy: .public)")
    }
}
