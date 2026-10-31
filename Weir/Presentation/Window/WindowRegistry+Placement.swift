// WindowRegistry+Placement.swift
// Weir — which window shows a project, and which one news, a pane's request, or a result is told in.

import Foundation
import WeirDomain

extension WindowRegistry {
    /// The window that shows `projectID`: the first, in the windows'
    /// order, whose selection stands for it, hidden or not.
    func window(showingProject projectID: UUID, in session: WorkspaceSession) -> ProjectWindowState? {
        windows.first { session.selections[$0.id]?.shownProjectID == projectID }
    }

    /// The projects the windows other than `window` show, hidden ones
    /// included: going to one of them brings that window forward rather
    /// than switching `window`. What a place is said to be in
    /// "another window" by (the Needs Attention list, the approval card's
    /// heading, the notification history). `nil` for every window's, which
    /// the menu bar, in none, reads.
    func projectsShown(besides window: WindowID?, in session: WorkspaceSession) -> Set<UUID> {
        Set(windows.filter { $0.id != window }.compactMap { session.selections[$0.id]?.shownProjectID })
    }

    /// The window app-wide news is told in (the approval service's
    /// trouble) and a request from a pane no shown window draws is asked
    /// in: the shown window the person was in most recently, else the
    /// first shown one, else the primary. Never a hidden window while
    /// another is shown.
    var noticeWindow: ProjectWindowState {
        windowShown(besides: nil) ?? primary
    }

    /// The window a pane's request (the clipboard's confirmation) is asked
    /// in: the shown window that draws the pane, else `noticeWindow`.
    func requestWindow(forPane paneID: UUID?, in session: WorkspaceSession) -> ProjectWindowState {
        paneID.flatMap { session.window(showingPane: $0) }.flatMap { window($0) } ?? noticeWindow
    }

    /// Where a notice waiting for an answer is told: `placed`, the window
    /// it was told in, while that window is shown, else `fresh`, where it
    /// would go now. Placed once, it stays rather than following the
    /// keyboard from window to window; taken from its window, SwiftUI
    /// would dismiss it as if answered.
    func placeNotice(keeping placed: WindowID?, fresh: () -> ProjectWindowState) -> WindowID {
        if let placed, window(placed)?.isHidden == false {
            return placed
        }
        return fresh().id
    }

    /// Where a result of work begun in `window` is told once it ends (a
    /// restore, a discard, a review's open): `window` while it is still
    /// listed, else the shown window of the project it showed, else
    /// `noticeWindow`. A toast there keeps its Undo, so nothing begun in
    /// a window that closed meanwhile is left without a way back.
    func windowForResult(of window: ProjectWindowState, in session: WorkspaceSession) -> ProjectWindowState {
        if self.window(window.id) === window {
            return window
        }
        if let projectID = window.selection.shownProjectID,
           let shown = self.window(showingProject: projectID, in: session), !shown.isHidden
        {
            return shown
        }
        return noticeWindow
    }

    /// Where a result about `hidden` is told once it is gone: of the
    /// windows still shown, the one the person was in most recently, else
    /// the first. `nil` with every window hidden, where nothing could show
    /// it. With `hidden` `nil`, no window is left out (`noticeWindow`).
    func windowShown(besides hidden: WindowID?) -> ProjectWindowState? {
        let shown = { (id: WindowID) in id != hidden && self.window(id)?.isHidden == false }
        if let recent = keyOrder.first(where: shown) {
            return window(recent)
        }
        return windows.first { shown($0.id) }
    }
}
