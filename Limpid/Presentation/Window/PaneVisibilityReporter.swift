// PaneVisibilityReporter.swift
// Limpid — how a window's pane area says which panes it shows.

import Foundation

/// Applies the set of panes on screen to the terminals, so each one draws
/// only while it can be seen. Implemented by the surface registry in the
/// app layer; a protocol so the window registry stays free of AppKit.
@MainActor
protocol PaneOcclusionApplying: AnyObject {
    func updateOcclusion(visibleIDs: Set<UUID>)
}

/// Reports one window's visible panes to the window registry.
///
/// A pane area knows only its own window, so it reports through this
/// rather than telling the terminals directly: with a second window, the
/// panes one window reported would put to sleep the terminals the other
/// shows. The registry combines every window's report and applies the
/// union.
struct PaneVisibilityReporter: Sendable {
    /// `nil` outside a main window (previews, tests), where reports go
    /// nowhere.
    let windowID: WindowID?
    let registry: WindowRegistry?

    init(windowID: WindowID? = nil, registry: WindowRegistry? = nil) {
        self.windowID = windowID
        self.registry = registry
    }

    /// Reports what the window's pane area shows. The rendered and attended
    /// sets both come from `VisibilityInputBuilder`, so the two cannot
    /// disagree about zoom or the review surface.
    @MainActor
    func report(_ display: PaneAreaDisplay) {
        guard let windowID, let registry else { return }
        registry.didReportDisplay(
            window: windowID,
            rendered: VisibilityInputBuilder.renderedPanes(display),
            attended: VisibilityInputBuilder.attendedPanes(display)
        )
    }

    /// Wakes `paneIDs` before the layout mounts them, ahead of the full
    /// report that follows the mount. Only the drawing set moves; what the
    /// person can see is decided by the full report.
    @MainActor
    func wake(_ paneIDs: Set<UUID>) {
        guard let windowID, let registry else { return }
        registry.didReportVisibility(window: windowID, paneIDs: paneIDs)
    }
}
