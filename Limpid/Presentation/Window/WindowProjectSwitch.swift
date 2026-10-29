// WindowProjectSwitch.swift
// Limpid — what a window lets go of as it switches to another project in place, and what it keeps.

import Foundation

/// What a window holds for the project it shows beside its selection and
/// its review, let go as it switches to another project in place
/// (`WindowRegistry.onWillSwitchProject`). The review is the registry's to
/// hand to the project (`WindowRegistry.leaveReview`).
@MainActor
enum WindowProjectSwitch {
    /// The window's layers a switch closes (`WindowLayer`): every one but
    /// the notification history and the plan usage panel, which show every
    /// project's events and the accounts' usage, and hang from the window's
    /// own rail.
    static let layersLeft = Set(WindowLayer.allCases).subtracting([.notificationHistory, .planUsage])

    /// Lets go of what `window` has open over `from`, the project it
    /// leaves: the title bar's dropdown, the palette, the panels over the
    /// whole window (All Projects and the keyboard shortcuts panel, which
    /// hold the keyboard the switch hands to the next project's pane, as
    /// ⌘J closes them), and the floating panels that hang from its rows and
    /// headers (a rename, a color, a pull request's card, the prompt
    /// cache), none of which stands for anything in the next project. The
    /// approval card beside one of its rows closes (`forgetRows`). A request asked for there and not yet taken (the
    /// keyboard for a restore strip or the sidebar) is dropped, so it does
    /// not land in the next project. The decision bars' choices and "Done"
    /// lines and the restore strips of `from`'s panes go too: they would
    /// show again, stale, should the window come back to the project.
    ///
    /// What the window holds for itself stays: its chrome (the sidebar and
    /// the changes panel, a sidebar kept over the panel included), the
    /// notification history, and the new session sheet, which makes its
    /// session in the project it was opened for; one for a removed
    /// project closes with the project, in whichever window it is open
    /// (`WindowRegistry.forgetProjectsGone`). Called while the window still
    /// shows `from`.
    static func tidy(
        _ window: ProjectWindowState,
        leaving from: UUID?,
        session: WorkspaceSession
    ) {
        window.closeLayers(layersLeft, session: session)
        window.paneRename.close()
        window.containerColor.close()
        window.prHover.reset()
        window.promptCachePanel.close()
        window.approvalCard.forgetRows()
        if window.restoreFocusRequest != nil {
            window.restoreFocusRequest = nil
        }
        if window.sidebarFocusRequest != nil {
            window.sidebarFocusRequest = nil
        }
        forgetPanes(leaving: from, in: window, session: session)
        // How the changes panel shares the window stays: the sidebar and
        // the panel are the window's, a sidebar kept over the panel too,
        // and so is an open panel's layout, settled as the window stands on
        // the next project (`WindowRegistry.onDidSwitchProject`,
        // `ChangesPanelLayoutRule.redecides`).
    }

    /// Drops the decision bars' state and the restore strips of the panes
    /// of `from`, and of panes no tab holds any more (a removed project's).
    /// The panes of a tab in no project, a scratch tab's, stay: the window
    /// can still show it.
    private static func forgetPanes(leaving from: UUID?, in window: ProjectWindowState, session: WorkspaceSession) {
        let isLeft = { (pane: UUID) in
            guard let tab = session.tab(containing: pane) else { return true }
            return from != nil && tab.container.projectID == from
        }
        let panes = Set(window.decisionBarSelection.keys)
            .union(window.decisionBarDone.keys)
            .union(window.pendingDecisionBarDone.keys)
            .filter(isLeft)
        for pane in panes {
            window.forgetDecisionBarChoices(paneID: pane)
        }
        for pane in window.restoreStrips.keys where isLeft(pane) {
            window.restoreStrips[pane] = nil
        }
    }
}
