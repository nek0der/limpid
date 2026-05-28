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
        }
    }
}
