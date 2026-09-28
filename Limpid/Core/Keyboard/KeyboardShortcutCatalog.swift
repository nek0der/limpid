// KeyboardShortcutCatalog.swift
// Limpid — the rows the keyboard shortcut cheat sheet shows. One
// section per `LimpidShortcutCategory` built from the user's current
// bindings, followed by the bindings that are not rebindable: the
// ⌘1–⌘9 / ⌘⌃1–⌘⌃9 jumps hardcoded in the menu, the app-menu Settings
// item, and the system-wide quick terminal hotkey. libghostty's own
// defaults (⌘C, ⌘V, …) are deliberately absent: a user's Ghostty
// config can change them and Limpid does not own that table.

import Foundation

/// One row: a localized title and the keycap tokens to draw next to it.
struct KeyboardShortcutEntry: Identifiable, Equatable {
    let id: String
    /// Already localized for display; the sheet renders it verbatim.
    let title: String
    /// Extra strings the search matches against: the English title
    /// when the display language is not English (so a Japanese user
    /// can still type "split"), and the inline glyph form (`⌘⇧T`).
    let searchAliases: [String]
    /// One token per keycap, HIG order (⌃⌥⇧⌘ then the key).
    let tokens: [String]
}

struct KeyboardShortcutSection: Identifiable, Equatable {
    let id: String
    let title: String
    let entries: [KeyboardShortcutEntry]
}

enum KeyboardShortcutCatalog {

    /// Builds every section from the effective bindings. `keyboard`
    /// carries the user's overrides so a rebound action shows what
    /// the user actually presses, not the shipped default.
    static func sections(
        keyboard: KeyboardSettings,
        quickTerminalHotKey: StoredShortcut?
    ) -> [KeyboardShortcutSection] {
        var out: [KeyboardShortcutSection] = []
        for category in LimpidShortcutCategory.allCases {
            var entries = LimpidShortcutAction.allCases
                .filter { $0.category == category }
                .compactMap { action -> KeyboardShortcutEntry? in
                    guard let shortcut = keyboard.shortcut(for: action) else { return nil }
                    return entry(
                        id: "action.\(action.rawValue)",
                        title: action.localizedTitle,
                        tokens: shortcut.displayTokens
                    )
                }
            // ⇧⏎ is a forced libghostty keybind (`GhosttyConfigBridge`),
            // not a menu item, so it has no action case. Listing it
            // under Terminal keeps the sheet honest about a key TUIs
            // and agents rely on.
            if category == .terminal {
                entries.append(entry(id: "fixed.insertNewline", title: "Insert Newline", tokens: ["⇧", "⏎"]))
            }
            guard !entries.isEmpty else { continue }
            out.append(KeyboardShortcutSection(
                id: "category.\(category.rawValue)",
                title: String(localized: category.resourceTitle),
                entries: entries
            ))
        }

        out.append(KeyboardShortcutSection(
            id: "fixed.tabsAndSections",
            title: String(localized: "Tabs & Sections"),
            entries: [
                entry(id: "fixed.goToTab", title: "Go to Tab 1–9", tokens: ["⌘", "1–9"]),
                entry(id: "fixed.goToSection", title: "Go to Section 1–9", tokens: ["⌃", "⌘", "1–9"])
            ]
        ))
        // The app menu is not named in the sheet: "Limpid" is the
        // product name and stays verbatim in every language.
        out.append(KeyboardShortcutSection(
            id: "fixed.app",
            title: "Limpid",
            entries: [
                entry(id: "fixed.settings", title: "Settings…", tokens: ["⌘", ","])
            ]
        ))
        if let quickTerminalHotKey {
            out.append(KeyboardShortcutSection(
                id: "fixed.systemWide",
                title: String(localized: "System-wide"),
                entries: [
                    entry(
                        id: "fixed.quickTerminal",
                        title: "Quick Terminal hotkey",
                        tokens: quickTerminalHotKey.displayTokens
                    )
                ]
            ))
        }
        return out
    }

    /// Narrows `sections` to the rows matching `query`; sections left
    /// with no rows drop out so the sheet never shows a bare header.
    /// An empty query returns the input unchanged.
    static func filter(
        _ sections: [KeyboardShortcutSection],
        query: String
    ) -> [KeyboardShortcutSection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sections }
        return sections.compactMap { section in
            let entries = section.entries.filter { matches($0, query: trimmed) }
            guard !entries.isEmpty else { return nil }
            return KeyboardShortcutSection(id: section.id, title: section.title, entries: entries)
        }
    }

    // MARK: - Helpers

    private static func matches(_ entry: KeyboardShortcutEntry, query: String) -> Bool {
        if FuzzyMatch.score(query: query, candidate: entry.title) != nil {
            return true
        }
        return entry.searchAliases.contains { FuzzyMatch.score(query: query, candidate: $0) != nil }
    }

    /// `["⇧", "⌘", "T"]` → `"⌘⇧T"`: modifiers reordered as ⌘⇧⌥⌃,
    /// key last. Unknown tokens keep their relative order.
    private static func commandFirstGlyphs(_ tokens: [String]) -> String {
        guard let key = tokens.last else { return "" }
        let rank: [String: Int] = ["⌘": 0, "⇧": 1, "⌥": 2, "⌃": 3]
        let modifiers = tokens.dropLast().sorted { (rank[$0] ?? 4) < (rank[$1] ?? 4) }
        return (modifiers + [key]).joined()
    }

    private static func entry(
        id: String,
        title: LocalizedStringResource,
        tokens: [String]
    ) -> KeyboardShortcutEntry {
        let localized = String(localized: title)
        var englishResource = title
        englishResource.locale = Locale(identifier: "en")
        let english = String(localized: englishResource)
        // Fuzzy matching is order-sensitive, so offer the glyphs both in
        // HIG order (⇧⌘T, what the sheet shows) and with ⌘ first (⌘⇧T,
        // how people tend to type them).
        var aliases = [tokens.joined(), commandFirstGlyphs(tokens)]
        if english != localized {
            aliases.append(english)
        }
        return KeyboardShortcutEntry(
            id: id,
            title: localized,
            searchAliases: aliases,
            tokens: tokens
        )
    }
}

extension LimpidShortcutCategory {
    /// `LocalizedStringResource` twin of `sectionTitle`, for surfaces
    /// that need a `String` (the cheat sheet, Settings search) rather
    /// than a `Text` literal.
    var resourceTitle: LocalizedStringResource {
        switch self {
        case .file: "File"
        case .view: "View"
        case .navigation: "Navigation"
        case .splits: "Splits"
        case .search: "Find"
        case .terminal: "Terminal"
        case .font: "Font"
        case .help: "Help"
        }
    }
}
