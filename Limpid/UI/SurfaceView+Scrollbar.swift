// SurfaceView+Scrollbar.swift
// Limpid — the viewport metrics libghostty reports, handed to the mounted scroll host.

import AppKit

extension SurfaceView {
    /// Record libghostty's latest viewport metrics and pass them to the
    /// scroll host mounted now, if any. The one writer of `scrollbarState`;
    /// the property cannot be `private(set)` from here, because Swift keeps
    /// a private setter to the file that declares the property.
    func updateScrollbarState(_ state: TerminalScrollbarState) {
        scrollbarState = state
        onScrollbarStateChange?(state)
    }
}
