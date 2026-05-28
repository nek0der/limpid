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
