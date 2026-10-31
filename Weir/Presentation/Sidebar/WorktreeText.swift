// WorktreeText.swift
// Weir — what the supervision window calls a sidebar row, and the words for making one.

import Foundation

/// A sidebar row is a worktree: a Git worktree of the project, or the
/// project's own folder, with its agent and shell tabs. The folder's row is
/// a worktree too (Git's main one), and its mark and tooltip tell it apart.
/// We never call a row a workspace, a session, or a task. Weir
/// keeps "session" for window restore and tmux, other agent tools use it
/// for one conversation, and an agent's conversation inside a row is a
/// conversation. The views and the tests read the same resources here, so
/// a test pins the words the sidebar and the sheet show.
enum WorktreeText {
    /// The left rail's entry that shows the sidebar: its rows are
    /// worktrees. The sidebar's own heading names what it lists by, the
    /// projects (`ProjectListText.heading`); "Projects" on the rail would
    /// read as the All Projects entry beside it.
    static let railEntry = LocalizedStringResource(
        "Worktrees",
        comment: "Left rail entry that shows the sidebar, the worktree menu's placeholder, and Project Settings' section: the worktrees"
    )

    /// The new worktree sheet's title, which names the project the
    /// worktree is made in, in the words of the header's ＋.
    static func sheetTitle(project: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "New Worktree in \(project)",
            comment: "New worktree sheet: title; the argument is the project's name"
        )
    }

    /// What an empty pane area tells the person to do. It names the key
    /// New Tab has now, read from the keymap, because a fixed ⌘T was wrong
    /// for anyone who had moved it; with no key, it names only the action.
    static func emptyPaneDetail(newTabShortcut: String?) -> LocalizedStringResource {
        guard let newTabShortcut else {
            return LocalizedStringResource(
                "Choose a worktree in the sidebar, or open a new tab.",
                comment: "Empty pane: what to do, when New Tab has no shortcut"
            )
        }
        return LocalizedStringResource(
            "Choose a worktree in the sidebar, or open a new tab with \(newTabShortcut).",
            comment: "Empty pane: what to do; the argument is New Tab's shortcut, as in ⌘T"
        )
    }
}
