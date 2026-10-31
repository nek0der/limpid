// KeyboardShortcutCatalog.swift
// Weir — the rows the keyboard shortcut cheat sheet shows. One
// section per `WeirShortcutCategory` built from the user's current
// bindings, followed by the bindings that are not rebindable: the
// ⌘1–⌘9 / ⌘⌃1–⌘⌃9 jumps hardcoded in the menu, the app-menu Settings
// item, and the system-wide quick terminal hotkey. libghostty's own
// defaults (⌘C, ⌘V, …) are deliberately absent: a user's Ghostty
// config can change them and Weir does not own that table.

import Foundation
import WeirDomain

/// One row: a localized title and the keycap tokens to draw next to it.
struct KeyboardShortcutEntry: Identifiable, Equatable {
    let id: String
    /// Resolved in the sheet's locale, because the search matches against
    /// it; the sheet renders it verbatim and rebuilds it on every body.
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
    /// the user actually presses, not the shipped default. Titles are
    /// resolved in `locale`, the sheet's.
    static func sections(
        keyboard: KeyboardSettings,
        quickTerminalHotKey: StoredShortcut?,
        locale: Locale
    ) -> [KeyboardShortcutSection] {
        var out: [KeyboardShortcutSection] = []
        for category in WeirShortcutCategory.allCases {
            var entries = WeirShortcutAction.allCases
                .filter { $0.category == category }
                .compactMap { action -> KeyboardShortcutEntry? in
                    guard let shortcut = keyboard.shortcut(for: action) else { return nil }
                    return entry(
                        id: "action.\(action.rawValue)",
                        title: action.localizedTitle,
                        tokens: shortcut.displayTokens,
                        locale: locale
                    )
                }
            // ⇧⏎ is a forced libghostty keybind (`GhosttyConfigBridge`),
            // not a menu item, so it has no action case. Listing it
            // under Terminal keeps the sheet honest about a key TUIs
            // and agents rely on.
            if category == .terminal {
                entries.append(entry(
                    id: "fixed.insertNewline",
                    title: "Insert Newline",
                    tokens: ["⇧", "⏎"],
                    locale: locale
                ))
            }
            // The restore has no key of its own: the palette's entry is the
            // keyboard's way to it, so the sheet lists it under
            // the palette's keys.
            if category == .view, let palette = keyboard.shortcut(for: .commandPalette) {
                entries.append(entry(
                    id: "palette.restoreTurn",
                    title: RestoreGate.entryTitle,
                    tokens: palette.displayTokens,
                    locale: locale
                ))
            }
            guard !entries.isEmpty else { continue }
            out.append(KeyboardShortcutSection(
                id: "category.\(category.rawValue)",
                title: category.resourceTitle.resolved(in: locale),
                entries: entries
            ))
        }

        // The review's keys while its diff has the keyboard: unmodified,
        // so never the TUI's, and not rebindable. The review tab writes
        // them here rather than along its foot.
        out.append(KeyboardShortcutSection(
            id: "fixed.review",
            title: LocalizedStringResource("Review").resolved(in: locale),
            entries: reviewEntries(locale: locale)
        ))
        // ⌘-click has no key to bind and no menu item: the sheet is where
        // it is found, beside the row tooltips.
        out.append(KeyboardShortcutSection(
            id: "fixed.window",
            title: LocalizedStringResource(
                "Window",
                comment: "Shortcut sheet: the section of what opens a project in a new window"
            ).resolved(in: locale),
            entries: [
                entry(
                    id: "fixed.newWindowClick",
                    // The words of the rows' VoiceOver action, which does
                    // the same (`NewWindowText.actionName`).
                    title: LocalizedStringResource(
                        "Open in New Window",
                        comment: "VoiceOver action on a row of another project: opens it in a new window, as Command-click does"
                    ),
                    tokens: ["⌘", LocalizedStringResource(
                        "Click",
                        comment: "Shortcut sheet: the keycap after ⌘ for a Command-click"
                    ).resolved(in: locale)],
                    locale: locale
                )
            ]
        ))
        // ⌃⌘1–9 goes to the nth working worktree the sidebar shows.
        out.append(KeyboardShortcutSection(
            id: "fixed.tabsAndWorktrees",
            title: LocalizedStringResource(
                "Tabs & Worktrees",
                comment: "Shortcut sheet: the section of the fixed keys that move between tabs and worktrees"
            ).resolved(in: locale),
            entries: [
                entry(id: "fixed.goToTab", title: "Go to Tab 1–9", tokens: ["⌘", "1–9"], locale: locale),
                entry(
                    id: "fixed.goToWorktree",
                    title: LocalizedStringResource(
                        "Go to Worktree 1–9",
                        comment: "Shortcut sheet: ⌃⌘1–9, the nth working worktree the sidebar shows"
                    ),
                    tokens: ["⌃", "⌘", "1–9"],
                    locale: locale
                )
            ]
        ))
        // The app menu is not named in the sheet: "Weir" is the
        // product name and stays verbatim in every language.
        out.append(KeyboardShortcutSection(
            id: "fixed.app",
            title: "Weir",
            entries: [
                entry(id: "fixed.settings", title: "Settings…", tokens: ["⌘", ","], locale: locale)
            ]
        ))
        if let quickTerminalHotKey {
            out.append(KeyboardShortcutSection(
                id: "fixed.systemWide",
                title: LocalizedStringResource("System-wide").resolved(in: locale),
                entries: [
                    entry(
                        id: "fixed.quickTerminal",
                        title: "Quick Terminal hotkey",
                        tokens: quickTerminalHotKey.displayTokens,
                        locale: locale
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

    /// One row per key, as the review's diff answers them
    /// (`ReviewDiffTable`'s key handling).
    private static func reviewEntries(locale: Locale) -> [KeyboardShortcutEntry] {
        func row(_ id: String, _ title: LocalizedStringResource, _ tokens: [String]) -> KeyboardShortcutEntry {
            entry(id: "review.\(id)", title: title, tokens: tokens, locale: locale)
        }
        return [
            row("nextLine", LocalizedStringResource("Next Line", comment: "Shortcut sheet, Review: j"), ["J"]),
            row("previousLine", LocalizedStringResource("Previous Line", comment: "Shortcut sheet, Review: k"), ["K"]),
            row("extendDown", LocalizedStringResource("Extend Selection Down", comment: "Shortcut sheet, Review: ⇧J"), ["⇧", "J"]),
            row("extendUp", LocalizedStringResource("Extend Selection Up", comment: "Shortcut sheet, Review: ⇧K"), ["⇧", "K"]),
            row("nextHunk", LocalizedStringResource("Next Hunk", comment: "Shortcut sheet, Review: ]"), ["]"]),
            row("previousHunk", LocalizedStringResource("Previous Hunk", comment: "Shortcut sheet, Review: ["), ["["]),
            row("oldSide", LocalizedStringResource("Select Old Side", comment: "Shortcut sheet, Review: h, side by side"), ["H"]),
            row("newSide", LocalizedStringResource("Select New Side", comment: "Shortcut sheet, Review: l, side by side"), ["L"]),
            row("nextFile", LocalizedStringResource("Next File", comment: "Shortcut sheet, Review: n"), ["N"]),
            row("previousFile", LocalizedStringResource("Previous File", comment: "Shortcut sheet, Review: p"), ["P"]),
            row("comment", LocalizedStringResource("Comment on Selection", comment: "Shortcut sheet, Review: c"), ["C"]),
            row("viewed", LocalizedStringResource("Toggle File Viewed", comment: "Shortcut sheet, Review: v, the file's checkbox"), ["V"]),
            row("open", LocalizedStringResource("Open in Editor", comment: "Shortcut sheet, Review: o"), ["O"])
        ]
    }

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
        tokens: [String],
        locale: Locale
    ) -> KeyboardShortcutEntry {
        let localized = title.resolved(in: locale)
        let english = title.resolved(in: .english)
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

extension WeirShortcutCategory {
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
