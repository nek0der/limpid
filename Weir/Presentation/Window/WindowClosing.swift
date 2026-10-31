// WindowClosing.swift
// Weir — what goes with a window that closes for real, beyond the registry, and what the window left is told.

import Foundation

/// What the app holds for a window apart from the registry, let go as the
/// window closes, and the toast that says so (`WindowRegistry.onClose`).
@MainActor
enum WindowClosing {
    /// Lets go of what `window` holds: its approval card with the row
    /// frames the card stands beside (the request stays in the ledger and
    /// Needs Attention, where it opens again), and its toast. A window left
    /// says the window closed and its project's sessions and agents run on,
    /// unless the window showed no project, or was hidden: a hidden window
    /// ends as the last one shown is closed and hidden in turn, which is
    /// not news to tell in the window going away. Called while `window` is
    /// still listed, before the registry forgets it.
    ///
    /// Each window shows one toast, and Undo matters more than news the
    /// person just caused. A toast with Undo already in the window left
    /// stays: the person may be reaching for it there. Otherwise the
    /// closed window's toast with Undo moves there in place of the news.
    /// With both, the closed window's goes; its action can still be taken
    /// back where it is kept (the changes panel, the restore record).
    ///
    /// The notices waiting for an answer move by themselves: each is
    /// placed again once its window is gone (`WindowRegistry.placeNotice`).
    static func tidy(
        _ window: ProjectWindowState,
        session: WorkspaceSession,
        registry: WindowRegistry,
        toasts: ToastCenter
    ) {
        window.approvalCard.dismiss()
        window.approvalCard.clearRowAnchors()
        let undoable = toasts.current(in: window.id).flatMap { $0.undo == nil ? nil : $0 }
        toasts.dismiss(in: window.id)
        guard !window.isHidden, let left = registry.windowShown(besides: window.id) else { return }
        guard toasts.current(in: left.id)?.undo == nil else { return }
        if let undoable {
            toasts.show(undoable, in: left.id)
            return
        }
        guard let project = window.selection.shownProjectID.flatMap({ session.project($0) }) else { return }
        toasts.show(ToastItem(.windowClosed(projectName: project.name)), in: left.id)
    }
}
