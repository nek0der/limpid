// SidebarDropText.swift
// Limpid — what VoiceOver says once a tab or pane dropped on the sidebar has moved.

import Foundation

/// The words said as a dragged tab or pane lands on a sidebar row, read by the
/// sidebar and by the tests. The row's light says it on screen; VoiceOver
/// has only these.
enum SidebarDropText {
    /// The tab or pane moved to `container`: the row by the name it shows, and its
    /// project, which a row of another project needs to be told apart.
    @MainActor
    static func moved(isPane: Bool, to container: ContainerID, in session: WorkspaceSession, locale: Locale) -> String {
        let row = SessionSidebarModel.rowName(of: container, in: session, locale: locale)
        guard let project = container.projectID.flatMap({ session.project($0) }) else {
            return (isPane
                ? LocalizedStringResource(
                    "Moved the pane to \(row)",
                    comment: "Sidebar, VoiceOver: a dragged pane was dropped on the scratch row, named here"
                )
                : LocalizedStringResource(
                    "Moved the tab to \(row)",
                    comment: "Sidebar, VoiceOver: a dragged tab was dropped on the scratch row, named here"
                )).resolved(in: locale)
        }
        return (isPane
            ? LocalizedStringResource(
                "Moved the pane to \(row) in \(project.name)",
                comment: "Sidebar, VoiceOver: a dragged pane was dropped on a row (first) of a project (second)"
            )
            : LocalizedStringResource(
                "Moved the tab to \(row) in \(project.name)",
                comment: "Sidebar, VoiceOver: a dragged tab was dropped on a row (first) of a project (second)"
            )).resolved(in: locale)
    }
}
