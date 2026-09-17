// CommandPaletteItem.swift
// Limpid — unified row model for command palette results.

import Foundation

struct CommandPaletteItem: Identifiable, Equatable {
    let id: String
    let category: CommandPaletteCategory
    let title: String
    /// Alternative search text (e.g. English name when the UI is
    /// localized). Fuzzy search matches against both `title` and
    /// `searchAlias`; the row shows it as a second line.
    var searchAlias: String?
    /// Extra search text that is never shown. A row whose title is a bare
    /// name (a tmux window) is still found by the words that describe what
    /// it does, without repeating those words on every row.
    var searchKeywords: [String] = []
    var subtitle: String?
    let icon: String
    let shortcutDisplay: String?
    /// Short state text shown at the trailing edge, such as a tmux window
    /// that a tab already shows. Kept apart from `shortcutDisplay` because
    /// that one is drawn as a key cap.
    var statusLabel: String?
    let action: CommandPaletteAction
    var isEnabled: Bool = true
}
