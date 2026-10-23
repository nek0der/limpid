// SettingsSearchCatalog.swift
// Limpid — complete, stable inventory of Settings search destinations.

import Foundation

enum SettingsSearchCatalog {
    static let entries: [SettingsSearchEntry] = {
        var entries: [SettingsSearchEntry] = [
            makeEntry("general.display-language", .general, "Language", "Display Language", keywords: ["App Language"], order: 0),
            makeEntry(
                "general.menu-bar-extra",
                .general,
                "Menu Bar",
                "Show in menu bar",
                keywords: ["Menu bar item", "Status item"],
                order: 1
            ),
            makeEntry(
                "general.usage-limit-reset",
                .general,
                "Usage Limits",
                "Notify when a usage limit resets",
                keywords: ["Rate limit", "Usage limit"],
                order: 2
            ),
            makeEntry(
                "general.quit-confirmation",
                .general,
                "Action Confirmations",
                "Quit Limpid",
                keywords: ["Quit confirmation"],
                order: 3
            ),
            makeEntry(
                "general.close-tab-keyboard-confirmation",
                .general,
                "Action Confirmations",
                "Close Tab (Keyboard)",
                keywords: ["Close confirmation"],
                order: 4
            ),
            makeEntry(
                "general.close-tab-mouse-confirmation",
                .general,
                "Action Confirmations",
                "Close Tab (× Button)",
                keywords: ["Close confirmation"],
                order: 5
            ),
            makeEntry(
                "general.close-pane-confirmation",
                .general,
                "Action Confirmations",
                "Close Pane",
                keywords: ["Close confirmation"],
                order: 6
            ),
            makeEntry(
                "general.file-application",
                .general,
                "Open Files With",
                "App",
                keywords: ["Editor", "Open file in editor", "Review application"],
                order: 7
            ),
            makeEntry(
                "general.automatic-updates",
                .general,
                "Software Update",
                "Automatically check for updates",
                keywords: ["Auto update"],
                order: 8
            ),
            makeEntry("general.check-for-updates", .general, "Software Update", "Check Now…", keywords: ["Check for updates"], order: 9),
            makeEntry("general.version", .general, "About", "Limpid version", keywords: ["Version"], order: 10),

            makeEntry("appearance.theme", .appearance, "Color", "Theme", keywords: ["Color scheme"], order: 0),
            makeEntry("appearance.accent", .appearance, "Color", "Accent", keywords: ["Accent color"], order: 1),
            makeEntry("appearance.transparency", .appearance, "Transparency", "Translucent window", keywords: ["Transparency"], order: 2),
            makeEntry("appearance.background-opacity", .appearance, "Transparency", "Background opacity", keywords: ["Opacity"], order: 3),
            makeEntry(
                "appearance.unfocused-pane-opacity",
                .appearance,
                "Panes",
                "Unfocused pane opacity",
                keywords: ["Inactive pane opacity"],
                order: 4
            ),

            makeEntry("font.family", .font, "Typeface", "Family", keywords: ["Font family"], order: 0),
            makeEntry("font.size", .font, "Typeface", "Size", keywords: ["Font size"], order: 1),
            makeEntry("font.ligatures", .font, "Typography", "Ligatures", order: 2),
            makeEntry("font.line-height", .font, "Typography", "Line spacing", keywords: ["Line height"], order: 3),

            makeEntry("terminal.scrollback", .terminal, "History", "Scrollback", keywords: ["Scrollback lines"], order: 0),
            makeEntry(
                "terminal.bell",
                .terminal,
                "Bell",
                "Flash the screen",
                keywords: ["Bell", "Terminal bell", "Play a sound"],
                order: 1
            ),
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
                "tabs-and-panes.split-pane-headers",
                .tabsAndPanes,
                "Pane Headers",
                "Show headers on split panes",
                keywords: ["Pane name", "Pane header"],
                order: 1
            ),
            makeEntry(
                "tabs-and-panes.default-working-directory",
                .tabsAndPanes,
                "Scratch",
                "Working folder",
                keywords: ["Scratch directory"],
                order: 2
            ),

            makeEntry(
                "quick-terminal.hotkey",
                .quickTerminal,
                "Hotkey",
                "Show or hide",
                keywords: ["Global shortcut", "Quick Terminal hotkey"],
                order: 0
            ),
            makeEntry("quick-terminal.position", .quickTerminal, "Layout", "Position", keywords: ["Screen edge"], order: 1),
            // The row says Height or Width by position; the search finds it by either.
            makeEntry(
                "quick-terminal.size",
                .quickTerminal,
                "Layout",
                "Size",
                keywords: ["Quick Terminal size", "Height", "Width"],
                order: 2
            ),
            makeEntry(
                "quick-terminal.hides-on-focus-loss",
                .quickTerminal,
                "Behavior",
                "Hide when focus leaves",
                keywords: ["Autohide"],
                order: 3
            ),

            makeEntry(
                "keyboard.quick-terminal-hotkey",
                .keyboard,
                "System-wide",
                "Quick Terminal hotkey",
                keywords: ["Global shortcut"],
                order: 99
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
                "Unread Turns",
                "Open Review when jumping to an unread turn",
                keywords: ["Needs Attention"],
                order: 0
            ),
            makeEntry(
                "review.instructions",
                .review,
                "Review Instructions",
                "Review instructions",
                keywords: ["Agent instructions", "Reset review instructions"],
                order: 1
            ),
            makeEntry(
                "review.external-diff-command",
                .review,
                "External Diff Tool",
                "Command",
                keywords: ["External tool", "Diff tool"],
                order: 2
            ),

            makeEntry(
                "advanced.reveal-settings-file",
                .advanced,
                "settings.json",
                "Show settings.json in Finder",
                keywords: ["Show in Finder", "Open settings file"],
                technicalAliases: ["json"],
                order: 0
            ),
            makeEntry(
                "advanced.restore-all-defaults",
                .advanced,
                "Reset",
                "Restore Default Settings",
                keywords: ["Reset all settings"],
                order: 3
            ),
            makeEntry(
                "advanced.turn-retention-days",
                .advanced,
                "Turn History",
                "Keep turns for",
                keywords: ["Turn records", "Retention"],
                order: 1
            ),
            makeEntry(
                "advanced.turn-retention-turns",
                .advanced,
                "Turn History",
                "Turns per conversation",
                keywords: ["Turn records", "Retention"],
                order: 2
            )
        ]

        entries += LimpidShortcutAction.allCases.enumerated().map { offset, action in
            SettingsSearchEntry(
                id: shortcutID(action),
                section: .keyboard,
                groupTitle: action.category.resourceTitle,
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

    static var menuBarExtra: SettingsSearchEntry {
        requiredEntry("general.menu-bar-extra")
    }

    static var usageLimitReset: SettingsSearchEntry {
        requiredEntry("general.usage-limit-reset")
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

    static var splitPaneHeaders: SettingsSearchEntry {
        requiredEntry("tabs-and-panes.split-pane-headers")
    }

    static var defaultWorkingDirectory: SettingsSearchEntry {
        requiredEntry("tabs-and-panes.default-working-directory")
    }

    static var quickTerminalHotKey: SettingsSearchEntry {
        requiredEntry("quick-terminal.hotkey")
    }

    static var quickTerminalPosition: SettingsSearchEntry {
        requiredEntry("quick-terminal.position")
    }

    static var quickTerminalSize: SettingsSearchEntry {
        requiredEntry("quick-terminal.size")
    }

    static var quickTerminalHidesOnFocusLoss: SettingsSearchEntry {
        requiredEntry("quick-terminal.hides-on-focus-loss")
    }

    static var keyboardQuickTerminalHotKey: SettingsSearchEntry {
        requiredEntry("keyboard.quick-terminal-hotkey")
    }

    static var keyboardRestoreDefaults: SettingsSearchEntry {
        requiredEntry("keyboard.restore-defaults")
    }

    static var ghosttyConfig: SettingsSearchEntry {
        requiredEntry("integrations.ghostty-config")
    }

    static var hostsAgentsInTmux: SettingsSearchEntry {
        requiredEntry("integrations.tmux")
    }

    static var turnRetentionDays: SettingsSearchEntry {
        requiredEntry("advanced.turn-retention-days")
    }

    static var turnRetentionTurns: SettingsSearchEntry {
        requiredEntry("advanced.turn-retention-turns")
    }

    static var externalDiffCommand: SettingsSearchEntry {
        requiredEntry("review.external-diff-command")
    }

    static var jumpOpensTurnReview: SettingsSearchEntry {
        requiredEntry("review.jump-opens-turn-review")
    }

    static var fileApplication: SettingsSearchEntry {
        requiredEntry("general.file-application")
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
