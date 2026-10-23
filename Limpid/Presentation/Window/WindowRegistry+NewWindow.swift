// WindowRegistry+NewWindow.swift
// Limpid — the windows the person asks for: a project in a new window, and New Window.

import Foundation
import OSLog

private let log = Logger.limpid("window.registry")

extension WindowRegistry {
    /// Opens `projectID` in a new window for the person:
    /// ⌘-click or ⌘Return on another project's row in project ▾, the
    /// palette's "#" and "@", and the all projects sheet, and ⌘-click in
    /// the Needs Attention list. `from` `nil` is the window commands act on.
    ///
    /// The window that shows the project already, hidden or not, comes
    /// forward instead, as choosing the project anywhere brings it
    /// (`raise`): one project, one window. `from`'s own project is left as
    /// it is, and `from` returned with nothing done: there is nothing to
    /// open. Otherwise a new window opens on what the project showed last
    /// (`WorkspaceSession.addWindow(showing:layoutFrom:)`), laid out like
    /// `from` and on its screen, and takes the review tab and the scroll
    /// positions the project kept, as a window switching to it does. A
    /// `from` that is hidden switches in place and comes back instead
    /// (`show(project:in:from:intent:)`), so a hidden window never stands
    /// beside a shown one. Returns the window that shows the project;
    /// `nil` for a `from` that closed or a project the session does not
    /// have, where nothing changes.
    @discardableResult
    func openInNewWindow(project projectID: UUID, in session: WorkspaceSession, from: ProjectWindowState?) -> ProjectWindowState? {
        let from = from ?? backgroundCommandTarget
        guard window(from.id) === from, session.project(projectID) != nil else { return nil }
        if from.selection.shownProjectID == projectID {
            return from
        }
        if let shown = window(showingProject: projectID, in: session) {
            raise(shown.id, in: session)
            session.noteProjectUsed(projectID)
            return shown
        }
        guard !from.isHidden else {
            return show(project: projectID, in: session, from: from, intent: .person)
        }
        let opened = listed(session.addWindow(showing: projectID, layoutFrom: from.id))
        log.notice("window \(opened.id.rawValue.uuidString, privacy: .public) opened on a project")
        presenter?.show(opened, openedFrom: from.id)
        return opened
    }

    /// New Window, from the File menu, the palette, or the Dock
    /// menu: a window that shows nothing yet, laid out like `from` (the
    /// window commands act on when `nil`, or when `from` closed) and on its
    /// screen, offering the projects no window shows
    /// (`WindowSelection.isChoosingProject`). With every window hidden, the
    /// one hidden window comes back instead, as a Dock click brings it: no
    /// window is made beside it. Returns the window shown.
    @discardableResult
    func openEmptyWindow(in session: WorkspaceSession, from: ProjectWindowState?) -> ProjectWindowState {
        guard windows.contains(where: { !$0.isHidden }) else {
            let last = lastUsedWindow
            show(last.id)
            return last
        }
        let asked = from.flatMap { window($0.id) === $0 && !$0.isHidden ? $0 : nil } ?? backgroundCommandTarget
        let opened = listed(session.addWindow(showing: nil, layoutFrom: asked.id))
        log.notice("window \(opened.id.rawValue.uuidString, privacy: .public) opened showing nothing")
        presenter?.show(opened, openedFrom: asked.id)
        return opened
    }

    /// The window of a selection the session has just added: listed as the
    /// session told of it (`connectProjectSwitching`), or here when the
    /// session switches no window and so tells nothing (tests, with no app
    /// layer connected).
    private func listed(_ selection: WindowSelection) -> ProjectWindowState {
        window(selection.windowID) ?? addWindow(selection)
    }
}
