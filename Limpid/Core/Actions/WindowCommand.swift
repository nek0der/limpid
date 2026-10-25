// WindowCommand.swift
// Limpid — what one main window is asked to do by its menus, the palette, and its rails, and the port that delivers it.

import Foundation

/// A command for one main window's views to carry out: what the menu
/// bar, the palette, the keyboard shortcuts, and the window's own rails ask
/// of the window they act in. Delivered to that window alone
/// (`WindowCommandPerforming`), so no other window that shares the session
/// acts on it, and a command no view of the window took is told apart from
/// one that ran.
enum WindowCommand: Equatable {
    /// Open a folder as a project.
    case openFolder
    /// Hide the window; its sessions keep running.
    case closeWindow
    /// Open a window that shows nothing yet.
    case newWindow
    /// "New Worktree…" (⌘N): the new worktree sheet for the window's
    /// project, from the menu, the palette, the sidebar's ＋, and the
    /// worktree ▾.
    case newWorktree
    /// ⌥⌘N: a worktree made at once with the last choices, no sheet.
    case newWorktreeNow
    /// Show or hide the sessions sidebar: the window's layout decides
    /// whether that is the wide window's kept choice or the overlay of a
    /// narrow one.
    case toggleSidebar
    /// Open or close the window's notification history.
    case toggleNotificationHistory
    /// Open or close the window's keyboard shortcuts panel.
    case toggleKeyboardShortcuts
    /// Open or close the all projects sheet.
    case toggleAllProjects
    /// Open or close the changes panel.
    case toggleChangesPanel
    /// ⌥⌘R: the review tab on the focused pane's unviewed turns, or closed.
    case review
    /// The review tab on the focused pane's latest turn.
    case reviewLatestTurn
    /// Find, Find Next, or Find Previous in the review tab in front.
    case reviewFind(LimpidShortcutAction)
    /// Open the Needs Attention list from the title bar.
    case showNeedsAttention
    /// Open the Open Tabs list from the pane strip.
    case showOpenTabs
    /// Move the keyboard to the sessions sidebar.
    case focusSidebar
    /// Open the settings of the project `UUID` names, or of the window's
    /// own for `nil`.
    case openProjectSettings(UUID?)
    /// Ask to close the project `UUID` names, or the window's own for
    /// `nil`; the window confirms first.
    case closeProject(UUID?)
    /// Start an inline rename of the pane strip's tab `tabID`.
    case renameTab(UUID)
    /// Run a row the window's command palette committed.
    case runPaletteRow(CommandPaletteExecution)
}

/// Delivers a `WindowCommand` to the window it is for. The app's window
/// registry answers it; Core asks through this because it cannot name a
/// window's views.
@MainActor
protocol WindowCommandPerforming: AnyObject {
    /// Asks `window` to carry out `command`. `false` when no such window is
    /// open or none of its views took the command (the view that would is
    /// not on screen), which the deliverer logs.
    @discardableResult
    func perform(_ command: WindowCommand, in window: WindowID) -> Bool
}
