// SessionRowActions.swift
// Limpid — the right-click menu of a sidebar row, built once for every kind of row.

import SwiftUI

/// What a sidebar row's right-click menu offers. Each entry is shown
/// only when its action is set, in the order every row uses: reorder, name,
/// worktrees, the pull request, Finder and the changes panel, then the
/// destructive entries last.
struct SessionRowActions {
    /// A menu entry whose words and symbol depend on the row's kind.
    struct Entry {
        let title: LocalizedStringResource
        let systemImage: String
        let action: () -> Void
    }

    var moveUp: (() -> Void)?
    var moveDown: (() -> Void)?
    var canMoveUp = true
    var canMoveDown = true
    var rename: (() -> Void)?
    var showHiddenWorktrees: (() -> Void)?
    var syncWorktrees: (() -> Void)?
    var removeMissingWorktrees: (() -> Void)?
    /// "Open on GitHub" (or the row's forge): the hover card's one action,
    /// for a person who does not point at the row's mark. Offered on
    /// rows with a pull request on file.
    var openPullRequest: Entry?
    /// Offered only on rows with a pull request on file; on one with none
    /// there is nothing to refresh, and the entry would read as dead.
    var refreshPRStatus: (() -> Void)?
    var revealInFinder: (() -> Void)?
    /// Selects the row and opens the changes panel on it: from the menu, a
    /// person reads another row's changes without first switching to it.
    var openChangesPanel: (() -> Void)?
    /// Move to Other Worktrees: moves a worktree with nothing open among the
    /// other worktrees, where the ones Git only reported wait; it stays on
    /// disk and in the sidebar, unlike Remove from Sidebar, which hides it.
    var removeFromWorking: (() -> Void)?
    /// Remove from Sidebar: hides a worktree's row and keeps the folder
    /// (Remove Row once the folder is gone).
    var removeFromSidebar: Entry?
    /// Hide All, on the line the worktrees ready to clean up fold into:
    /// hides every one of them, as Remove from Sidebar hides one.
    var hideAll: (() -> Void)?
    /// Runs `git worktree remove`, after its own confirmation.
    var deleteWorktree: (() -> Void)?
    /// Close All Tabs: closes every tab in the row, agents and shells, after
    /// the usual confirmation; the row and its worktree stay, so the
    /// entry names the tabs rather than the workspace.
    var closeAllTabs: (() -> Void)?
}

/// The menu items for `actions`, for a `.contextMenu`.
struct SessionRowActionsMenu: View {
    let actions: SessionRowActions

    var body: some View {
        if actions.moveUp != nil || actions.moveDown != nil {
            if let moveUp = actions.moveUp {
                Button(action: moveUp) {
                    Label("Move Up", systemImage: "arrow.up")
                }
                .disabled(!actions.canMoveUp)
                .tint(Color.primary)
            }
            if let moveDown = actions.moveDown {
                Button(action: moveDown) {
                    Label("Move Down", systemImage: "arrow.down")
                }
                .disabled(!actions.canMoveDown)
                .tint(Color.primary)
            }
            Divider()
        }
        if let rename = actions.rename {
            Button(action: rename) {
                Label("Rename…", systemImage: "pencil")
            }
            .tint(Color.primary)
        }
        if let showHiddenWorktrees = actions.showHiddenWorktrees {
            Button(action: showHiddenWorktrees) {
                Label("Show Hidden Worktrees", systemImage: "eye")
            }
            .tint(Color.primary)
        }
        if let syncWorktrees = actions.syncWorktrees {
            Button(action: syncWorktrees) {
                Label("Sync Worktrees", systemImage: "arrow.clockwise")
            }
            .tint(Color.primary)
        }
        if let removeMissingWorktrees = actions.removeMissingWorktrees {
            Button(action: removeMissingWorktrees) {
                Label("Remove Missing Worktrees", systemImage: "exclamationmark.triangle")
            }
            .tint(Color.primary)
        }
        if actions.openPullRequest != nil || actions.refreshPRStatus != nil {
            Divider()
        }
        if let openPullRequest = actions.openPullRequest {
            entryButton(openPullRequest)
        }
        if let refreshPRStatus = actions.refreshPRStatus {
            Button(action: refreshPRStatus) {
                Label("Refresh PR Status", systemImage: "arrow.clockwise")
            }
            .tint(Color.primary)
        }
        if actions.revealInFinder != nil || actions.openChangesPanel != nil {
            Divider()
        }
        if let revealInFinder = actions.revealInFinder {
            Button(action: revealInFinder) {
                Label("Show in Finder", systemImage: "folder")
            }
            .tint(Color.primary)
        }
        if let openChangesPanel = actions.openChangesPanel {
            // The right rail's symbol, so the entry and the button it
            // stands in for read as one.
            Button(action: openChangesPanel) {
                Label("Open Changes Panel", systemImage: "plus.forwardslash.minus")
            }
            .tint(Color.primary)
        }
        if actions.removeFromSidebar != nil || actions.closeAllTabs != nil || actions.removeFromWorking != nil {
            Divider()
        }
        if let removeFromWorking = actions.removeFromWorking {
            Button(action: removeFromWorking) {
                Label("Move to Other Worktrees", systemImage: "tray.and.arrow.down")
            }
            .tint(Color.primary)
        }
        if let removeFromSidebar = actions.removeFromSidebar {
            entryButton(removeFromSidebar, role: .destructive)
        }
        if let hideAll = actions.hideAll {
            Button(action: hideAll) {
                Label("Hide All", systemImage: "eye.slash")
            }
            .tint(Color.primary)
        }
        if let deleteWorktree = actions.deleteWorktree {
            Button(role: .destructive, action: deleteWorktree) {
                Label("Delete Worktree…", systemImage: "trash")
            }
            .tint(Color.primary)
        }
        if let closeAllTabs = actions.closeAllTabs {
            Button(role: .destructive, action: closeAllTabs) {
                Label("Close All Tabs", systemImage: "xmark")
            }
            .tint(Color.primary)
        }
    }

    private func entryButton(_ entry: SessionRowActions.Entry, role: ButtonRole? = nil) -> some View {
        Button(role: role, action: entry.action) {
            Label {
                Text(entry.title)
            } icon: {
                Image(systemName: entry.systemImage)
            }
        }
        .tint(Color.primary)
    }
}
