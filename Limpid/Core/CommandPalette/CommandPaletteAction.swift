// CommandPaletteAction.swift
// Limpid — actions the command palette can dispatch.

import Foundation

enum CommandPaletteAction: Equatable {
    case shortcutAction(LimpidShortcutAction)
    case jumpToTab(UUID)
    case activateProject(UUID)
    case activateWorktree(projectID: UUID, worktreeID: UUID)
    case reopenClosedTab(UUID)
    case openRecentProject(URL)
    case openSettings
    /// The settings of the window's project.
    case openProjectSettings
    /// Close the window's project, after the confirmation.
    case closeProject
    /// "Restore Code to Before This Turn…": the restore strip in
    /// the decision bar of the turn's pane, with the keyboard on it.
    case restoreTurn
    case insertPrefix(PalettePrefix)

    var frecencyKey: String {
        switch self {
        case let .shortcutAction(action): "shortcut.\(action.rawValue)"
        case let .jumpToTab(id): "tab.\(id.uuidString)"
        case let .activateProject(id): "project.\(id.uuidString)"
        case let .activateWorktree(pid, wid): "worktree.\(pid.uuidString).\(wid.uuidString)"
        case let .reopenClosedTab(id): "reopen.\(id.uuidString)"
        case let .openRecentProject(url): "recent.\(url.path)"
        case .openSettings: "settings.open"
        case .openProjectSettings: "settings.project"
        case .closeProject: "project.close"
        case .restoreTurn: "restore.turn"
        case let .insertPrefix(mode): "prefix.\(mode.character)"
        }
    }
}
