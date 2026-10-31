// StatusBandModel+Session.swift
// Weir — reads the status band from the window's selection, the pane's label, and its surface.

import Foundation

extension StatusBandModel {
    /// The band for the pane that has the keyboard in `window`: the selected
    /// tab's focused leaf, or the review standing in front of it. With no
    /// tab selected the band names the window's own project, where the
    /// next tab would open. `gridSize` is read from that pane's surface by
    /// the caller, which owns the registry.
    @MainActor
    static func input(
        session: WorkspaceSession,
        window: ProjectWindowState,
        attention: AttentionState,
        gridSize: (UUID) -> TerminalGridSize?,
        locale: Locale
    ) -> Input {
        let selection = session.selections[window.id]
        guard let tab = selection?.activeTabID.flatMap({ session.tab($0) }),
              let paneID = tab.splitTree.effectiveFocusedLeafID
        else {
            let project = selection?.shownProjectID.flatMap { session.project($0) }
            var input = Input(projectName: project?.name)
            input.projectFolder = project.map { PathFormatting.abbreviateHome($0.rootURL.path) }
            return input
        }
        // The tab's own place, which the pane is in, rather than the
        // selection's copy of it.
        let container = tab.container
        var input = Input(
            projectName: container.projectID.flatMap { session.project($0)?.name },
            checkoutName: CheckoutName.of(container, in: session)
        )
        if container.projectID == nil {
            // Scratch: where the tab works, as the folder it opened in.
            input.scratchFolder = (tab.workingDirectory ?? tab.pwd).map(PathFormatting.abbreviateHome)
        }
        let label = attention.paneHeaderLabel(paneID: paneID, in: session, locale: locale)
        input.paneName = label.name
        input.isUnnamedShell = !label.isAgent && !label.isNamedByPerson
        input.agentName = label.agentName
        input.folder = label.detail
        input.gridSize = gridSize(paneID)
        input.isReviewShown = window.review?.isShown == true
        return input
    }
}
