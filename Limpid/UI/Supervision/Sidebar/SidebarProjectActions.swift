// SidebarProjectActions.swift
// Limpid — the right-click menu of a project's header in the sidebar, and its VoiceOver actions.

import SwiftUI

/// What a project's header offers: a new worktree in the project, the
/// moves, the folds, the operations on all of its worktrees, and the
/// project's own entries. The same entries are its VoiceOver actions, for
/// a person who does not drag or right-click.
struct SidebarProjectActions {
    var newWorktree: () -> Void = {}
    /// The key the sheet's own command has (⌘N), shown beside the entry.
    var newWorktreeShortcut: StoredShortcut?
    /// The keys Move Project Up and Down have now, shown beside the
    /// moves; `nil` for one the person unassigned.
    var moveUpShortcut: StoredShortcut?
    var moveDownShortcut: StoredShortcut?
    var moveUp: () -> Void = {}
    var moveDown: () -> Void = {}
    var moveToTop: () -> Void = {}
    var canMoveUp = false
    var canMoveDown = false
    var toggle: () -> Void = {}
    var collapseOthers: () -> Void = {}
    /// Asks Git for the project's worktrees again.
    var syncWorktrees: () -> Void = {}
    /// Brings back every row hidden with Hide Worktree; `nil` with
    /// none hidden.
    var showHiddenWorktrees: (() -> Void)?
    /// Takes every row whose folder is gone out of the sidebar, with its
    /// tabs; `nil` with none missing.
    var removeMissingWorktrees: (() -> Void)?
    var openSettings: () -> Void = {}
    var revealInFinder: () -> Void = {}
    var closeProject: () -> Void = {}
    /// Brings forward the window that shows the project; `nil` for a
    /// project no other window shows.
    var bringOtherWindowForward: (() -> Void)?
}

/// The words of the header's entries. The moves are keyed apart from the
/// row menu's entries of the same English, so a project's can be worded
/// on its own in Japanese.
enum SidebarProjectActionText {
    static let moveUp = LocalizedStringResource(
        "sidebar.project.moveUp",
        defaultValue: "Move Up",
        comment: "Sidebar project header menu: moves the project above the one before it"
    )
    static let moveDown = LocalizedStringResource(
        "sidebar.project.moveDown",
        defaultValue: "Move Down",
        comment: "Sidebar project header menu: moves the project below the one after it"
    )
    static let moveToTop = LocalizedStringResource(
        "Move to Top",
        comment: "Sidebar project header menu: moves the project to the top of the sidebar"
    )
    static let collapse = LocalizedStringResource("Collapse", comment: "Sidebar project header menu: folds the project's rows")
    static let expand = LocalizedStringResource("Expand", comment: "Sidebar project header menu: unfolds the project's rows")
    static let collapseOthers = LocalizedStringResource(
        "Collapse Others",
        comment: "Sidebar project header menu: folds every other project, and unfolds this one"
    )
    /// The operations on all of a project's worktrees. They are the
    /// header's, not a row's: a row's menu holds what acts on that row, and
    /// "Remove Missing Worktrees" beside a row's own "Remove from Sidebar"
    /// read as that row's alone.
    static let syncWorktrees = LocalizedStringResource(
        "Sync Worktrees",
        comment: "Sidebar project header menu: asks Git for the project's worktrees again"
    )
    static let showHiddenWorktrees = LocalizedStringResource(
        "Show Hidden Worktrees",
        comment: "Sidebar project header menu: brings back every worktree hidden from the sidebar"
    )
    static let removeMissingWorktrees = LocalizedStringResource(
        "Remove Missing Worktrees",
        comment: "Sidebar project header menu: removes from the sidebar every worktree whose folder is gone, and closes their tabs"
    )
    /// The title bar's own words for the same sheet.
    static let settings = LocalizedStringResource("Project Settings…")
    static let bringForward = LocalizedStringResource(
        "Bring Other Window Forward",
        comment: "Sidebar project header, VoiceOver action: brings forward the window that shows the project"
    )
}

/// The header's right-click menu, in the order of the design: the new
/// worktree, the moves, the folds, the operations on all of its worktrees,
/// then the project's own entries, the one that takes the project away
/// last.
struct SidebarProjectActionsMenu: View {
    let header: SidebarProjectHeader
    let actions: SidebarProjectActions

    var body: some View {
        Button(action: actions.newWorktree) {
            Label {
                Text(SidebarHeaderText.newWorktree(in: header.name))
            } icon: {
                Image(systemName: "plus")
            }
        }
        .contextMenuShortcut(actions.newWorktreeShortcut)
        .tint(Color.primary)
        Divider()
        // The keys the sidebar takes for these while it has the keyboard
        // (`SidebarKeyRoute`), as the person has them bound, shown beside
        // them; inside a context menu they answer only while it is open.
        Button(action: actions.moveUp) {
            Label { Text(SidebarProjectActionText.moveUp) } icon: { Image(systemName: "arrow.up") }
        }
        .contextMenuShortcut(actions.moveUpShortcut)
        .disabled(!actions.canMoveUp)
        .tint(Color.primary)
        Button(action: actions.moveDown) {
            Label { Text(SidebarProjectActionText.moveDown) } icon: { Image(systemName: "arrow.down") }
        }
        .contextMenuShortcut(actions.moveDownShortcut)
        .disabled(!actions.canMoveDown)
        .tint(Color.primary)
        Button(action: actions.moveToTop) {
            Label { Text(SidebarProjectActionText.moveToTop) } icon: { Image(systemName: "arrow.up.to.line") }
        }
        .disabled(!actions.canMoveUp)
        .tint(Color.primary)
        Divider()
        Button(action: actions.toggle) {
            Label {
                Text(header.isCollapsed ? SidebarProjectActionText.expand : SidebarProjectActionText.collapse)
            } icon: {
                Image(systemName: header.isCollapsed ? "chevron.down" : "chevron.right")
            }
        }
        .keyboardShortcut(header.isCollapsed ? .rightArrow : .leftArrow, modifiers: [])
        .tint(Color.primary)
        Button(action: actions.collapseOthers) {
            Label { Text(SidebarProjectActionText.collapseOthers) } icon: { Image(systemName: "rectangle.compress.vertical") }
        }
        .tint(Color.primary)
        Divider()
        Button(action: actions.syncWorktrees) {
            Label { Text(SidebarProjectActionText.syncWorktrees) } icon: { Image(systemName: "arrow.clockwise") }
        }
        .tint(Color.primary)
        if let showHiddenWorktrees = actions.showHiddenWorktrees {
            Button(action: showHiddenWorktrees) {
                Label { Text(SidebarProjectActionText.showHiddenWorktrees) } icon: { Image(systemName: "eye") }
            }
            .tint(Color.primary)
        }
        // Marked destructive, as the row's own Remove from Sidebar is: the
        // rows go with their tabs, and no Undo brings them back.
        if let removeMissingWorktrees = actions.removeMissingWorktrees {
            Button(role: .destructive, action: removeMissingWorktrees) {
                Label { Text(SidebarProjectActionText.removeMissingWorktrees) } icon: { Image(systemName: "xmark") }
            }
            .tint(Color.primary)
        }
        Divider()
        Button(action: actions.openSettings) {
            Label { Text(SidebarProjectActionText.settings) } icon: { Image(systemName: "gearshape") }
        }
        .tint(Color.primary)
        Button(action: actions.revealInFinder) {
            Label("Show in Finder", systemImage: "folder")
        }
        .tint(Color.primary)
        Button(role: .destructive, action: actions.closeProject) {
            Label("Close Project…", systemImage: "xmark")
        }
        .tint(Color.primary)
    }
}
