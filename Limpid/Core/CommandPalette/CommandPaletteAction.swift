// CommandPaletteAction.swift
// Limpid — actions the command palette can dispatch.

import Foundation

enum CommandPaletteAction: Equatable {
    case shortcutAction(LimpidShortcutAction)
    case jumpToTab(UUID)
    case activateGroup(UUID)
    case activateProject(UUID)
    case activateWorktree(projectID: UUID, worktreeID: UUID)
    case reopenClosedTab(UUID)
    case openRecentProject(URL)
    case openSettings
    case insertPrefix(PalettePrefix)
    case mirrorTmuxWindow(TmuxMirrorTarget)
    /// Start a detached tmux session and show it as a tab (design D2).
    case newTmuxSession
    /// Show the tmux session a pane is attached to by hand in a tab of its
    /// own (design D5). Carries the pane, because the palette row is drawn
    /// for the pane the user was in when they opened it.
    case showPaneTmuxSession(UUID)

    var frecencyKey: String {
        switch self {
        case let .shortcutAction(action): "shortcut.\(action.rawValue)"
        case let .jumpToTab(id): "tab.\(id.uuidString)"
        case let .activateGroup(id): "group.\(id.uuidString)"
        case let .activateProject(id): "project.\(id.uuidString)"
        case let .activateWorktree(pid, wid): "worktree.\(pid.uuidString).\(wid.uuidString)"
        case let .reopenClosedTab(id): "reopen.\(id.uuidString)"
        case let .openRecentProject(url): "recent.\(url.path)"
        case .openSettings: "settings.open"
        case let .insertPrefix(mode): "prefix.\(mode.character)"
        case let .mirrorTmuxWindow(target): "tmux.mirror.\(target.binding.socketPath).\(target.windowID)"
        case .newTmuxSession: "tmux.newSession"
        // Not the pane: a frecency key is what the palette learns the row
        // by, and a pane id is one run of one pane.
        case .showPaneTmuxSession: "tmux.showPaneSession"
        }
    }
}
