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

    /// Convert libghostty's device-pixel cell report into points. We divide
    /// by the window's scale, not `lastPushedScale`: the first report fires
    /// inside `ghostty_surface_new`, before any scale has been pushed.
    /// Returns whether the stored value changed, so the caller can pass a
    /// new size on to whoever lays panes out from it.
    @discardableResult
    func updateCellSize(devicePixelWidth: UInt32, devicePixelHeight: UInt32) -> Bool {
        let scale = Double(window?.backingScaleFactor ?? 1)
        guard let size = CellSize.points(
            devicePixelWidth: devicePixelWidth,
            devicePixelHeight: devicePixelHeight,
            scale: scale
        ) else {
            log.debug("CELL_SIZE ignored (degenerate report)")
            return false
        }
        guard size != cellSize else { return false }
        cellSize = size
        log.debug("CELL_SIZE \(size.width, privacy: .public)x\(size.height, privacy: .public)pt scale=\(scale, privacy: .public)")
        return true
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
