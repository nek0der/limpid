// ProjectListText.swift
// Limpid — the words over a list of projects, and for the sidebar's ＋ that opens a folder as one.

import Foundation

/// The words over a list of projects, and for the sidebar's ＋ over it:
/// the sidebar, project ▾, and an empty window read the same resources,
/// and the tests pin them.
enum ProjectListText {
    /// The heading over a list of projects, in the sidebar's order: the
    /// sidebar's, project ▾'s, and an empty window's.
    static let heading = LocalizedStringResource(
        "Projects",
        comment: "Heading over a list of projects in the sidebar's order: the sidebar, the project dropdown, an empty window"
    )

    /// The sidebar heading's ＋, as VoiceOver names it. It opens a folder as
    /// a project, as ⌘O does. The heading stands over every project, so a
    /// new worktree from it could not say which project it goes to; each
    /// header's ＋ makes one in its own. Its tooltip names the action as
    /// the File menu does (`LimpidShortcutAction.openFolder`), with the
    /// ellipsis that says a panel follows.
    static let openFolderLabel = LocalizedStringResource(
        "Open Folder",
        comment: "Sidebar, VoiceOver: the heading's + button, which opens a folder as a project"
    )
}
