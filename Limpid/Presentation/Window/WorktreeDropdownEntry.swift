// WorktreeDropdownEntry.swift
// Limpid — the worktree ▾'s checkouts, in the sidebar's order and by the names its rows go by.

import Foundation

/// One checkout the worktree ▾ lists: the row it opens, the name the
/// sidebar's row goes by, and its branch and folder.
struct WorktreeDropdownEntry: Identifiable, Equatable {
    let container: ContainerID
    /// The name the checkout's row goes by (`RowName`), and where it is
    /// cut, as the sidebar cuts it.
    let name: String
    let nameTruncation: SupervisionTruncation
    let branch: String
    let folder: URL
    /// The folder is gone from disk; the row stays so the person sees it,
    /// but it cannot be opened.
    let isMissing: Bool

    var id: ContainerID {
        container
    }

    /// The checkouts a person can open, in the sidebar's order
    /// (`SidebarPresentedSections.ordered`): the working worktrees, the
    /// folder, then those ready to clean up and the others, so the ▾ and the
    /// sidebar never disagree on where a checkout is. Hidden ones stay
    /// hidden here too. Each goes by its row's name (one rule for every
    /// place a row is named), and by its branch while the sidebar has no
    /// row for it.
    static func entries(
        of project: Project,
        in sections: SidebarPresentedSections,
        rows: [ContainerID: SessionSidebarModel.Row]
    ) -> [Self] {
        sections.ordered(project).compactMap { listed in
            let branch: String
            let folder: URL
            let isMissing: Bool
            if let worktreeID = listed.row.worktreeID {
                guard let worktree = project.worktrees.first(where: { $0.id == worktreeID }) else { return nil }
                (branch, folder, isMissing) = (CheckoutName.of(worktree), worktree.workingDirectory, worktree.isMissing)
            } else {
                (branch, folder, isMissing) = (CheckoutName.label(of: project), project.rootURL, false)
            }
            let row = rows[listed.row]
            return Self(
                container: listed.row,
                name: row?.name ?? branch,
                nameTruncation: row?.nameTruncation ?? .branch,
                branch: branch,
                folder: folder,
                isMissing: isMissing
            )
        }
    }

    /// The checkouts the keys move through: a folder gone from disk cannot
    /// be opened, so the keys pass it by as the pointer cannot press it.
    static func choosable(_ entries: [Self]) -> [ContainerID] {
        entries.filter { !$0.isMissing }.map(\.container)
    }
}
