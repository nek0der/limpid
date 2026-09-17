// SurfaceView+Mirror.swift
// Limpid — a mirror surface's stream: which channel it reads, and why the view holds it.

import AppKit

extension SurfaceView {
    /// A pane whose bytes come from a channel rather than a pty: a tmux
    /// mirror. Decided at creation and never changes for the surface's life.
    var isMirror: Bool {
        mirrorChannel != nil
    }

    /// What `createSurface` hands libghostty as `mirror_io_fd`.
    ///
    /// libghostty's mirror backend duplicates this descriptor inside
    /// `ghostty_surface_new` and reads only its duplicate afterwards, so the
    /// number itself matters only until a surface exists. We still hold the
    /// channel for the view's whole life rather than dropping it then:
    /// `createSurface` runs again after a creation that failed, and the
    /// number handed over must still name this channel's socket rather
    /// than whatever the system reused it for. Holding it longer costs
    /// nothing, and it keeps the surface's stream open for as long as the
    /// view shows it, even after the store has let the leaf go.
    var mirrorIoFd: Int32 {
        mirrorChannel?.surfaceFd ?? -1
    }
}
