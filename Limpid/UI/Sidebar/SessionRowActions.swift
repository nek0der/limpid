// SessionRowActions.swift
// Limpid — the right-click menu of a sidebar row, built once for every kind of row.

import SwiftUI

/// What a sidebar row's right-click menu offers. Each entry is shown
/// only when its action is set, in the order every row uses: reorder, name,
/// the pull request, Finder and the changes panel, then the entries that
/// put the row away, with the one that deletes a folder last. Only what
/// acts on the row is here; the operations on all of a project's worktrees
/// are its header's (`SidebarProjectActions`).
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
    /// Remove Label: hands a labeled row back to its branch, as clearing
    /// the label's field does, where a person can see it can be done.
    /// Offered only on a row with a label, so its presence says the row has
    /// one.
    var removeLabel: (() -> Void)?
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
    /// disk and in the sidebar, unlike Hide Worktree, which hides it.
    var removeFromWorking: (() -> Void)?
    /// Hide Worktree: hides a worktree's row and keeps the folder. The
    /// toast's Undo or Show Hidden Worktrees brings it back, so it is not
    /// marked destructive. It says "Hide", as the toast says "Hid".
    var hide: (() -> Void)?
    /// Remove from Sidebar, on a row whose folder is gone: there is nothing
    /// left to hide, so the row goes with its tabs and no Undo brings it
    /// back. That is why it does not share the hide's words.
    var removeMissing: (() -> Void)?
    /// Runs `git worktree remove`, after its own confirmation.
    var deleteWorktree: (() -> Void)?
    /// Close All Tabs: closes every tab in the row, agents and shells, after
    /// the usual confirmation; the row and its worktree stay, so the
    /// entry names the tabs rather than the workspace.
    var closeAllTabs: (() -> Void)?
}

/// The menu items for `actions`, for a `.contextMenu`. A divider stands
/// only between two groups that both have an entry: the scratch row and a
/// fold line start their menus partway down the order, and a menu that
/// opens on a divider reads as one with something missing.
struct SessionRowActionsMenu: View {
    let actions: SessionRowActions

    private var hasMoves: Bool {
        actions.moveUp != nil || actions.moveDown != nil
    }

    private var hasPullRequest: Bool {
        actions.openPullRequest != nil || actions.refreshPRStatus != nil
    }

    private var hasPlaces: Bool {
        actions.revealInFinder != nil || actions.openChangesPanel != nil
    }

    private var hasPutAway: Bool {
        actions.removeFromWorking != nil || actions.hide != nil
            || actions.removeMissing != nil || actions.closeAllTabs != nil || actions.deleteWorktree != nil
    }

    var body: some View {
        if hasMoves {
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
        }
        if let rename = actions.rename {
            if hasMoves {
                Divider()
            }
            Button(action: rename) {
                Label("Set Label…", systemImage: "pencil")
            }
            .tint(Color.primary)
        }
        if let removeLabel = actions.removeLabel {
            Button(action: removeLabel) {
                Label("Remove Label", systemImage: "arrow.uturn.backward")
            }
            .tint(Color.primary)
        }
        if hasPullRequest, hasMoves || actions.rename != nil {
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
        if hasPlaces, hasMoves || actions.rename != nil || hasPullRequest {
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
        if hasPutAway, hasMoves || actions.rename != nil || hasPullRequest || hasPlaces {
            Divider()
        }
        if let removeFromWorking = actions.removeFromWorking {
            Button(action: removeFromWorking) {
                Label("Move to Other Worktrees", systemImage: "tray.and.arrow.down")
            }
            .tint(Color.primary)
        }
        if let hide = actions.hide {
            Button(action: hide) {
                Label("Hide Worktree", systemImage: "eye.slash")
            }
            .tint(Color.primary)
        }
        if let removeMissing = actions.removeMissing {
            Button(role: .destructive, action: removeMissing) {
                Label("Remove from Sidebar", systemImage: "xmark")
            }
            .tint(Color.primary)
        }
        if let closeAllTabs = actions.closeAllTabs {
            Button(role: .destructive, action: closeAllTabs) {
                Label("Close All Tabs", systemImage: "xmark")
            }
            .tint(Color.primary)
        }
        // Last, as the one entry that takes a folder off the disk.
        if let deleteWorktree = actions.deleteWorktree {
            Button(role: .destructive, action: deleteWorktree) {
                Label("Delete Worktree…", systemImage: "trash")
            }
            .tint(Color.primary)
        }
    }

    private func entryButton(_ entry: SessionRowActions.Entry) -> some View {
        Button(action: entry.action) {
            Label {
                Text(entry.title)
            } icon: {
                Image(systemName: entry.systemImage)
            }
        }
        .tint(Color.primary)
    }
}
