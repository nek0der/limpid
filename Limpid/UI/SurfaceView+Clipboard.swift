// SurfaceView+Clipboard.swift
// Limpid — the surface's userdata token and the clipboard requests it tracks.

import Foundation

/// Its address, unique while retained, is a surface's `userdata`. It also
/// carries the surface's unanswered clipboard requests, because it is the
/// one thing a callback can reach that lives until the surface is freed,
/// after the view itself is gone.
final class SurfaceUserdataToken {
    let clipboardRequests = ClipboardRequestTracker()
}

extension SurfaceView: ClipboardRequestTarget {
    /// The unanswered clipboard requests of this view's surface.
    var clipboardRequests: ClipboardRequestTracker {
        Self.clipboardRequests(forUserdata: userdata)
    }

    var surfaceView: SurfaceView? {
        self
    }

    /// The clipboard requests of the surface `userdata` belongs to, read in
    /// a libghostty callback's own frame, before any hop, or by the view
    /// itself. Safe there and only there: the token is retained until
    /// `ghostty_surface_free` has returned, and libghostty calls a surface's
    /// callbacks before then. The tracker returned is a strong reference,
    /// so it stays valid after the token is released.
    nonisolated static func clipboardRequests(forUserdata userdata: UnsafeMutableRawPointer) -> ClipboardRequestTracker {
        Unmanaged<SurfaceUserdataToken>.fromOpaque(userdata).takeUnretainedValue().clipboardRequests
    }
}
