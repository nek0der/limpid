// SettingsSearchCatalog.swift
// Limpid — complete, stable inventory of Settings search destinations.

import Foundation

enum SettingsSearchCatalog {
    static let entries: [SettingsSearchEntry] = {
        var entries: [SettingsSearchEntry] = [
            makeEntry("general.display-language", .general, "Language", "Display Language", keywords: ["App Language"], order: 0),
            makeEntry(
                "general.quit-confirmation",
                .general,
                "Action Confirmations",
                "Quit Limpid",
                keywords: ["Quit confirmation"],
                order: 1
            ),
            makeEntry(
                "general.close-tab-keyboard-confirmation",
                .general,
                "Action Confirmations",
                "Close Tab (Keyboard)",
                keywords: ["Close confirmation"],
                order: 2
            ),
            makeEntry(
                "general.close-tab-mouse-confirmation",
                .general,
                "Action Confirmations",
                "Close Tab (X Button)",
                keywords: ["Close confirmation"],
                order: 3
            ),
            makeEntry(
                "general.close-pane-confirmation",
                .general,
                "Action Confirmations",
                "Close Pane",
                keywords: ["Close confirmation"],
                order: 4
            ),
            makeEntry(
                "general.automatic-updates",
                .general,
                "Software Update",
                "Automatically check for updates",
                keywords: ["Auto update"],
                order: 5
            ),
            makeEntry("general.check-for-updates", .general, "Software Update", "Check Now…", keywords: ["Check for updates"], order: 6),
            makeEntry("general.version", .general, "About", "Limpid version", keywords: ["Version"], order: 7),

            makeEntry("appearance.theme", .appearance, "Theme", "Theme", keywords: ["Color scheme"], order: 0),
            makeEntry("appearance.accent", .appearance, "Theme", "Accent", keywords: ["Accent color"], order: 1),
            makeEntry("appearance.transparency", .appearance, "Transparency", "Transparency", order: 2),
            makeEntry("appearance.background-opacity", .appearance, "Transparency", "Opacity", keywords: ["Background opacity"], order: 3),
            makeEntry(
                "appearance.unfocused-pane-opacity",
                .appearance,
                "Panes",
                "Unfocused pane opacity",
                keywords: ["Inactive pane opacity"],
                order: 4
            ),

            makeEntry("font.family", .font, "Font", "Family", keywords: ["Font family"], order: 0),
            makeEntry("font.size", .font, "Font", "Size", keywords: ["Font size"], order: 1),
            makeEntry("font.ligatures", .font, "Typography", "Ligatures", order: 2),
            makeEntry("font.line-height", .font, "Typography", "Line height", keywords: ["Line spacing"], order: 3),

            makeEntry("terminal.scrollback", .terminal, "History", "Scrollback", keywords: ["Scrollback lines"], order: 0),
            makeEntry("terminal.bell", .terminal, "Bell", "Alert Style", keywords: ["Bell", "Terminal bell"], order: 1),
            makeEntry("terminal.cursor", .terminal, "Cursor", "Style", keywords: ["Cursor", "Cursor style"], order: 2),
            makeEntry("terminal.cursor-blink", .terminal, "Cursor", "Blink", keywords: ["Cursor blink", "Blinking cursor"], order: 3),

            makeEntry(
                "tabs-and-panes.minimum-pane-size",
                .tabsAndPanes,
                "Pane Layout",
                "Minimum pane size",
                keywords: ["Split size"],
                order: 0
            ),
            makeEntry(
                "tabs-and-panes.default-working-directory",
                .tabsAndPanes,
                "Quick Tabs",
                "Default working directory",
                keywords: ["Quick Tab directory"],
                order: 1
            ),

            makeEntry("keyboard.restore-defaults", .keyboard, "Reset", "Restore Defaults", keywords: ["Reset shortcuts"], order: 100),

            makeEntry(
                "integrations.ghostty-config",
                .integrations,
                "Ghostty Config",
                "Use Ghostty config file",
                keywords: ["Ghostty configuration"],
                technicalAliases: ["Ghostty"],
                order: 0
            ),
            makeEntry(
                "integrations.pr-status",
                .integrations,
                "Pull Requests",
                "Show PR status in sidebar",
                keywords: ["Pull request status"],
                technicalAliases: ["PR", "gh", "glab"],
                order: 1
            ),
            makeEntry(
                "integrations.pr-attention",
                .integrations,
                "Pull Requests",
                "Mark only rows needing attention",
                keywords: ["Pull request attention"],
                technicalAliases: ["PR", "gh", "glab"],
                order: 2
            ),
            makeEntry(
                "integrations.tmux",
                .integrations,
                "tmux",
                "Run agents in tmux",
                keywords: ["Agents"],
                technicalAliases: ["tmux"],
                order: 3
            ),

            makeEntry(
                "review.jump-opens-turn-review",
                .review,
                "Finished Agents",
                "Open the turn's changes when jumping to a finished agent",
                keywords: ["Waiting", "This turn"],
                order: 0
            ),
            makeEntry(
                "review.choose-application",
                .review,
                "Review Files",
                "Choose App…",
                keywords: ["Review application", "Reset review application"],
                order: 1
            ),
            makeEntry(
                "review.instructions",
                .review,
                "Review Instructions",
                "Review instructions",
                keywords: ["Agent instructions", "Reset review instructions"],
                order: 2
            ),

            makeEntry(
                "advanced.reveal-settings-file",
                .advanced,
                "settings.json",
                "Reveal settings.json in Finder",
                keywords: ["Reveal in Finder", "Open settings file"],
                technicalAliases: ["json"],
                order: 0
            ),
            makeEntry(
                "advanced.restore-all-defaults",
                .advanced,
                "Reset",
                "Restore All Defaults",
                keywords: ["Reset all settings"],
                order: 1
            )
        ]

        entries += LimpidShortcutAction.allCases.enumerated().map { offset, action in
            SettingsSearchEntry(
                id: shortcutID(action),
                section: .keyboard,
                groupTitle: action.category.searchGroupTitle,
                title: action.localizedTitle,
                keywords: ["Keyboard Shortcut"],
                order: offset
            )
        }
        return entries
    }()

    static func shortcutID(_ action: LimpidShortcutAction) -> String {
        "keyboard.shortcut.\(action.rawValue)"
    }

    static var displayLanguage: SettingsSearchEntry {
        requiredEntry("general.display-language")
    }

    static var confirmationQuit: SettingsSearchEntry {
        requiredEntry("general.quit-confirmation")
    }

    static var confirmationCloseTabKeyboard: SettingsSearchEntry {
        requiredEntry("general.close-tab-keyboard-confirmation")
    }

    static var confirmationCloseTabMouse: SettingsSearchEntry {
        requiredEntry("general.close-tab-mouse-confirmation")
    }

    static var confirmationClosePane: SettingsSearchEntry {
        requiredEntry("general.close-pane-confirmation")
    }

    static var automaticUpdates: SettingsSearchEntry {
        requiredEntry("general.automatic-updates")
    }

    static var checkForUpdates: SettingsSearchEntry {
        requiredEntry("general.check-for-updates")
    }

    static var appVersion: SettingsSearchEntry {
        requiredEntry("general.version")
    }

    static var theme: SettingsSearchEntry {
        requiredEntry("appearance.theme")
    }

    static var accentColor: SettingsSearchEntry {
        requiredEntry("appearance.accent")
    }

    static var transparency: SettingsSearchEntry {
        requiredEntry("appearance.transparency")
    }

    static var backgroundOpacity: SettingsSearchEntry {
        requiredEntry("appearance.background-opacity")
    }

    static var unfocusedPaneOpacity: SettingsSearchEntry {
        requiredEntry("appearance.unfocused-pane-opacity")
    }

    static var fontFamily: SettingsSearchEntry {
        requiredEntry("font.family")
    }

    static var fontSize: SettingsSearchEntry {
        requiredEntry("font.size")
    }

    static var ligatures: SettingsSearchEntry {
        requiredEntry("font.ligatures")
    }

    static var lineHeight: SettingsSearchEntry {
        requiredEntry("font.line-height")
    }

    static var scrollback: SettingsSearchEntry {
        requiredEntry("terminal.scrollback")
    }

    static var bell: SettingsSearchEntry {
        requiredEntry("terminal.bell")
    }

    static var cursorStyle: SettingsSearchEntry {
        requiredEntry("terminal.cursor")
    }

    static var cursorBlink: SettingsSearchEntry {
        requiredEntry("terminal.cursor-blink")
    }

    static var minimumPaneSize: SettingsSearchEntry {
        requiredEntry("tabs-and-panes.minimum-pane-size")
    }

    static var defaultWorkingDirectory: SettingsSearchEntry {
        requiredEntry("tabs-and-panes.default-working-directory")
    }

    static var keyboardRestoreDefaults: SettingsSearchEntry {
        requiredEntry("keyboard.restore-defaults")
    }

    static var ghosttyConfig: SettingsSearchEntry {
        requiredEntry("integrations.ghostty-config")
    }

    static var showPRStatus: SettingsSearchEntry {
        requiredEntry("integrations.pr-status")
    }

    static var showPRStatusOnlyWhenAttention: SettingsSearchEntry {
        requiredEntry("integrations.pr-attention")
    }

    static var hostsAgentsInTmux: SettingsSearchEntry {
        requiredEntry("integrations.tmux")
    }

    static var jumpOpensTurnReview: SettingsSearchEntry {
        requiredEntry("review.jump-opens-turn-review")
    }

    static var reviewFileApplication: SettingsSearchEntry {
        requiredEntry("review.choose-application")
    }

    static var reviewInstructions: SettingsSearchEntry {
        requiredEntry("review.instructions")
    }

    static var settingsFile: SettingsSearchEntry {
        requiredEntry("advanced.reveal-settings-file")
    }

    static var restoreAllDefaults: SettingsSearchEntry {
        requiredEntry("advanced.restore-all-defaults")
    }

    private static func requiredEntry(_ id: String) -> SettingsSearchEntry {
        guard let entry = entries.first(where: { $0.id == id }) else {
            fatalError("Settings search catalog is missing \(id)")
        }
        return entry
    }

    private static func makeEntry(
        _ id: String,
        _ section: SettingsSection,
        _ groupTitle: LocalizedStringResource,
        _ title: LocalizedStringResource,
        keywords: [LocalizedStringResource] = [],
        technicalAliases: [String] = [],
        order: Int
    ) -> SettingsSearchEntry {
        SettingsSearchEntry(
            id: id,
            section: section,
            groupTitle: groupTitle,
            title: title,
            keywords: keywords,
            technicalAliases: technicalAliases,
            order: order
        )
    }
}

private extension LimpidShortcutCategory {
    var searchGroupTitle: LocalizedStringResource {
        switch self {
        case .file: "File"
        case .view: "View"
        case .navigation: "Navigation"
        case .splits: "Splits"
        case .search: "Find"
        case .terminal: "Terminal"
        case .font: "Font"
        }
    }
}
