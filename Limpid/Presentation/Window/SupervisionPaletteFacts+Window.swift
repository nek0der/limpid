// SupervisionPaletteFacts+Window.swift
// Limpid — reads a supervision window's palette facts from its state.

import Foundation

extension SupervisionPaletteFacts {
    /// Reads what `window` shows: its project, its session rows, whether its
    /// strip shows a review tab (one opened from the session it is on), and
    /// whether that tab is in front, the
    /// same facts its menu reads. `restoreTurnNumber` is the turn the
    /// palette's restore entry goes back to, which the window's restore
    /// handler works out. `sections` are the sidebar's
    /// (`AppState.sidebarSections(in:)`); without them, the sections it last
    /// drew, which are enough to tell whether there is more than one row,
    /// and to list each project's rows in the sidebar's order.
    @MainActor
    init(window: ProjectWindowState, session: WorkspaceSession, sections: SidebarPresentedSections? = nil, restoreTurnNumber: Int? = nil) {
        let selection = window.selection
        let sections = sections ?? window.presentedSections
        self.init(
            projectID: selection.shownProjectID,
            sessionRowCount: SessionRowNavigation.rows(in: window, session: session, sections: sections).count,
            hasReviewTab: window.review?.belongs(to: selection.activeContainerID, in: session) ?? false,
            restoreTurnNumber: restoreTurnNumber,
            rowOrder: session.projects.flatMap { sections.ordered($0).map(\.row) },
            rowSections: sections.sections,
            arePanesHidden: window.arePanesHidden,
            isChoosingProject: selection.isChoosingProject
        )
    }
}
