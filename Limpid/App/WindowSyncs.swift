// WindowSyncs.swift
// Limpid — the observers that keep one NSWindow and its selection in step.

import AppKit

/// Keeps one window's title, frame, full-screen state, and on-screen state
/// in step with its `WindowSelection` and the window registry. Held as one
/// value so every main window binds the same set, and the window that owns
/// them releases them together.
@MainActor
final class WindowSyncs {
    private let title: WindowTitleSync
    private let frame: WindowFrameSync
    private let fullScreen: WindowFullScreenSync
    private let occlusion: WindowOcclusionSync

    init(
        session: WorkspaceSession,
        selection: WindowSelection,
        registry: WindowRegistry,
        window: NSWindow
    ) {
        title = WindowTitleSync(
            session: session,
            selection: selection,
            window: window,
            stripHeight: LimpidLayout.Supervision.titleBarHeight
        )
        frame = WindowFrameSync(selection: selection, window: window)
        fullScreen = WindowFullScreenSync(selection: selection, window: window)
        occlusion = WindowOcclusionSync(windowID: selection.windowID, registry: registry, window: window)
    }

    /// The window could not enter full screen: told by its delegate, which
    /// the observers cannot hear.
    func fullScreenEntryFailed() {
        fullScreen.resync()
    }
}
