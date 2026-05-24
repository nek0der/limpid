// ContainerPresentation.swift
// Limpid — single source of truth for "how does this container look".
// L1 ContainerRow, the L2/L3 chrome title, future Log / Diff mode
// headers — every place that surfaces a container reads from here
// instead of redoing the switch on ContainerID. Adding a new
// container type means updating one struct, not three views.

import SwiftUI

@MainActor
struct ContainerPresentation {
    /// SF Symbol name for the leading icon.
    let icon: String
    /// Tint for the icon. Project palette color for projects / their
    /// worktrees, group palette color for groups, neutral elsewhere.
    let tint: Color
    /// User-facing label (group / project name, worktree branch, etc).
    let title: String
    /// Optional one-line caption (path / count / branch).
    let subtitle: String?

    init(container: ContainerID, session: WindowSession) {
        switch container {
        case .loose:
            self.icon = "tray"
            self.tint = .secondary
            self.title = String(localized: "Quick Tabs")
            self.subtitle = Self.tabCount(container, session)

        case let .group(gid):
            let group = session.group(gid)
            self.icon = "folder"
            self.tint = Self.palette(group?.paletteIndex)
            self.title = group?.name ?? String(localized: "Group")
            self.subtitle = Self.tabCount(container, session)

        case let .project(pid):
            let project = session.project(pid)
            self.icon = "folder.fill"
            self.tint = Self.palette(project?.paletteIndex)
            self.title = project?.name ?? String(localized: "Project")
            // Subtitle = current branch of the project's main
            // checkout. Falls back to the rootURL basename for
            // non-git projects (no branch). `mainBranchName` is
            // populated by GitSyncCoordinator after the first
            // `git worktree list` for this project lands.
            self.subtitle = project?.mainBranchName
                ?? project?.rootURL.lastPathComponent

        case let .worktree(pid, wid):
            let project = session.project(pid)
            let wt = session.worktree(projectID: pid, worktreeID: wid)
            self.icon = "arrow.triangle.branch"
            self.tint = Self.palette(project?.paletteIndex)
            self.title = wt?.label ?? project?.name ?? String(localized: "Worktree")
            // Subtitle = current branch in this worktree. We pair it
            // with the basename title so the user sees both "where on
            // disk" (title) and "which branch is checked out"
            // (subtitle) without a redundant duplicate path.
            self.subtitle = wt?.gitRef?.branchName ?? Self.tabCount(container, session)
        }
    }

    // MARK: - Helpers

    private static func palette(_ idx: Int?) -> Color {
        if let idx, LimpidColor.projectPalette.indices.contains(idx) {
            return LimpidColor.projectPalette[idx]
        }
        return LimpidColor.accent
    }

    private static func tabCount(_ container: ContainerID, _ session: WindowSession) -> String? {
        let n = session.tabs(in: container).count
        return "\(n) session\(n == 1 ? "" : "s")"
    }
}

/// Convenience: palette color for a TabGroup / Project paletteIndex
/// without going through the full ContainerPresentation. Useful for
/// dot markers in L1 rows.
extension LimpidColor {
    static func paletteColor(_ idx: Int?) -> Color {
        if let idx, projectPalette.indices.contains(idx) {
            return projectPalette[idx]
        }
        return accent
    }
}
