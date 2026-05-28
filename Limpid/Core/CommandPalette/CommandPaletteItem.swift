// CommandPaletteItem.swift
// Limpid — unified row model for command palette results.

import Foundation

struct CommandPaletteItem: Identifiable, Equatable {
    let id: String
    let category: CommandPaletteCategory
    let title: String
    /// Alternative search text (e.g. English name when the UI is
    /// localized). Fuzzy search matches against both `title` and
    /// `searchAlias`; the display always shows `title`.
    var searchAlias: String?
    var subtitle: String?
    let icon: String
    let shortcutDisplay: String?
    let action: CommandPaletteAction
    var isEnabled: Bool = true
}
