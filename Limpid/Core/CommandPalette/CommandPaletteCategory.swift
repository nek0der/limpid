// CommandPaletteCategory.swift
// Limpid — section grouping for command palette results.

import Foundation

enum CommandPaletteCategory: Int, CaseIterable, Comparable {
    case navigate = 0
    case actions = 1
    case reopen = 2
    case settings = 3

    var localizedTitle: LocalizedStringResource {
        switch self {
        case .navigate: "Navigate"
        case .actions: "Actions"
        case .reopen: "Reopen"
        case .settings: "Settings"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Prefix mode

/// Maps a prefix character to a filtered subset of categories.
/// Mirrors VS Code's Quick Access prefix system: the prefix is part
/// of the input text, not a separate UI element.
enum PalettePrefix: CaseIterable {
    case actions // >
    case tabs // @
    case projects // #
    case settings // :
    case help // ?

    var character: Character {
        switch self {
        case .actions: ">"
        case .tabs: "@"
        case .projects: "#"
        case .settings: ":"
        case .help: "?"
        }
    }

    var categories: Set<CommandPaletteCategory> {
        switch self {
        case .actions: [.actions]
        case .tabs: [.navigate]
        case .projects: [.navigate]
        case .settings: [.settings]
        case .help: []
        }
    }

    var placeholder: LocalizedStringResource {
        switch self {
        case .actions: "Type an action name..."
        case .tabs: "Type a tab name..."
        case .projects: "Type a project or worktree name..."
        case .settings: "Type a setting name..."
        case .help: "Select a mode..."
        }
    }

    var description: LocalizedStringResource {
        switch self {
        case .actions: "Filter by actions"
        case .tabs: "Go to tab"
        case .projects: "Go to project or worktree"
        case .settings: "Open settings"
        case .help: "Show all prefix modes"
        }
    }

    /// For `@` and `#` we further filter navigate items: `@` shows
    /// only tabs (jumpToTab), `#` shows only projects/worktrees.
    func matchesItem(_ item: CommandPaletteItem) -> Bool {
        switch self {
        case .tabs:
            if case .jumpToTab = item.action { return true }
            return false
        case .projects:
            switch item.action {
            case .activateProject, .activateWorktree, .activateGroup: return true
            default: return false
            }
        default:
            return categories.contains(item.category)
        }
    }

    static func from(_ query: String) -> (prefix: PalettePrefix?, filterQuery: String) {
        guard let first = query.first else {
            return (nil, query)
        }
        if let matched = allCases.first(where: { $0.character == first }) {
            return (matched, String(query.dropFirst()))
        }
        return (nil, query)
    }
}
