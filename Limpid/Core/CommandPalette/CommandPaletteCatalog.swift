// CommandPaletteCatalog.swift
// Limpid — builds the palette item list from live `WindowSession` and `SettingsStore`.

import Foundation

@MainActor
enum CommandPaletteCatalog {

    /// Lightweight context bundle for `isActionEnabled` — keeps the
    /// per-action dispatch fed by one value instead of six loose flags.
    private struct ActionEnabledContext {
        let hasActiveTab: Bool
        let hasMultipleTabs: Bool
        let hasMultipleSections: Bool
        let isSplit: Bool
        let reachable: (SpatialDirection) -> Bool
        let isProjectActive: Bool
        let hasClosedTabs: Bool
        let hasActiveSearch: Bool
        let hasWaitingAttention: Bool
    }

    static func buildItems(
        session: WindowSession,
        settings: SettingsStore,
        attention: AttentionState
    ) -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []
        items.reserveCapacity(80)
        appendShortcutActions(to: &items, session: session, settings: settings, attention: attention)
        appendTabs(to: &items, session: session)
        appendGroups(to: &items, session: session)
        appendProjects(to: &items, session: session)
        appendClosedTabs(to: &items, session: session)
        appendRecentProjects(to: &items, session: session)
        appendSettings(to: &items)
        return items
    }

    // MARK: - Shortcut actions

    private static func appendShortcutActions(
        to items: inout [CommandPaletteItem],
        session: WindowSession,
        settings: SettingsStore,
        attention: AttentionState
    ) {
        let hasActiveTab = session.activeTab != nil
        let hasMultipleTabs = session.tabs(in: session.activeContainerID).count > 1
        let hasMultipleSections = !session.groups.isEmpty || !session.projects.isEmpty
        let isSplit = session.activeTab?.splitTree.isSplit == true
        // Per-direction reachability — same source of truth the Pane menu
        // uses, so a Focus/Move action greys out in exactly the directions
        // it can't reach (also covers zoom + single-pane via `adjacentLeaf`).
        let reachable: (SpatialDirection) -> Bool = {
            PaneActions.adjacentLeaf(session, direction: $0) != nil
        }
        let isProjectActive = session.activeContainerID.projectID != nil
        let hasClosedTabs = !session.closedTabStack.isEmpty
        let focusedPaneID = session.activeTab?.splitTree.effectiveFocusedLeafID
        let hasActiveSearch = focusedPaneID.map { session.paneSearchStates[$0] != nil } ?? false
        let hasWaitingAttention = !attention.attentionEntries(in: session).isEmpty

        let context = ActionEnabledContext(
            hasActiveTab: hasActiveTab,
            hasMultipleTabs: hasMultipleTabs,
            hasMultipleSections: hasMultipleSections,
            isSplit: isSplit,
            reachable: reachable,
            isProjectActive: isProjectActive,
            hasClosedTabs: hasClosedTabs,
            hasActiveSearch: hasActiveSearch,
            hasWaitingAttention: hasWaitingAttention
        )

        for action in LimpidShortcutAction.allCases {
            let shortcut = settings.settings.keyboard.shortcut(for: action)
            let enabled = isActionEnabled(action, context: context)
            let localizedTitle = String(localized: action.localizedTitle)
            var englishResource = action.localizedTitle
            englishResource.locale = Locale(identifier: "en")
            let englishTitle = String(localized: englishResource)
            items.append(CommandPaletteItem(
                id: "shortcut.\(action.rawValue)",
                category: .actions,
                title: localizedTitle,
                searchAlias: localizedTitle != englishTitle ? englishTitle : nil,
                subtitle: nil,
                icon: action.iconName,
                shortcutDisplay: shortcut?.displayString,
                action: .shortcutAction(action),
                isEnabled: enabled
            ))
        }
    }

    // MARK: - Tabs

    private static func appendTabs(
        to items: inout [CommandPaletteItem],
        session: WindowSession
    ) {
        for tab in session.tabs {
            let subtitle = tab.workingDirectory ?? tab.pwd
            items.append(CommandPaletteItem(
                id: "tab.\(tab.id.uuidString)",
                category: .navigate,
                title: tab.displayTitle,
                subtitle: subtitle.map { shortenPath($0) },
                icon: "macwindow",
                shortcutDisplay: nil,
                action: .jumpToTab(tab.id)
            ))
        }
    }

    // MARK: - Groups

    private static func appendGroups(
        to items: inout [CommandPaletteItem],
        session: WindowSession
    ) {
        for group in session.groups {
            items.append(CommandPaletteItem(
                id: "group.\(group.id.uuidString)",
                category: .navigate,
                title: group.name,
                subtitle: nil,
                icon: "folder",
                shortcutDisplay: nil,
                action: .activateGroup(group.id)
            ))
        }
    }

    // MARK: - Projects + worktrees

    private static func appendProjects(
        to items: inout [CommandPaletteItem],
        session: WindowSession
    ) {
        for project in session.projects {
            items.append(CommandPaletteItem(
                id: "project.\(project.id.uuidString)",
                category: .navigate,
                title: project.name,
                subtitle: shortenPath(project.rootURL.path),
                icon: "tray.full",
                shortcutDisplay: nil,
                action: .activateProject(project.id)
            ))

            for worktree in project.worktrees where !worktree.isHidden {
                items.append(CommandPaletteItem(
                    id: "worktree.\(project.id.uuidString).\(worktree.id.uuidString)",
                    category: .navigate,
                    title: worktree.label,
                    subtitle: shortenPath(worktree.workingDirectory.path),
                    icon: "arrow.triangle.branch",
                    shortcutDisplay: nil,
                    action: .activateWorktree(
                        projectID: project.id,
                        worktreeID: worktree.id
                    )
                ))
            }
        }
    }

    // MARK: - Closed tabs

    private static func appendClosedTabs(
        to items: inout [CommandPaletteItem],
        session: WindowSession
    ) {
        for closed in session.closedTabStack {
            items.append(CommandPaletteItem(
                id: "reopen.\(closed.tab.id.uuidString)",
                category: .reopen,
                title: closed.tab.displayTitle,
                subtitle: nil,
                icon: "arrow.uturn.backward",
                shortcutDisplay: nil,
                action: .reopenClosedTab(closed.tab.id)
            ))
        }
    }

    // MARK: - Recent projects

    private static func appendRecentProjects(
        to items: inout [CommandPaletteItem],
        session: WindowSession
    ) {
        for url in session.recentProjectPaths {
            let alreadyOpen = session.projects.contains { $0.rootURL == url }
            if alreadyOpen { continue }

            items.append(CommandPaletteItem(
                id: "recent.\(url.path)",
                category: .reopen,
                title: url.lastPathComponent,
                subtitle: shortenPath(url.path),
                icon: "clock",
                shortcutDisplay: nil,
                action: .openRecentProject(url)
            ))
        }
    }

    // MARK: - Settings

    private static func appendSettings(to items: inout [CommandPaletteItem]) {
        let resource: LocalizedStringResource = "Open Settings"
        let localizedTitle = String(localized: resource)
        var englishResource = resource
        englishResource.locale = Locale(identifier: "en")
        let englishTitle = String(localized: englishResource)
        items.append(CommandPaletteItem(
            id: "settings.open",
            category: .settings,
            title: localizedTitle,
            searchAlias: localizedTitle != englishTitle ? englishTitle : nil,
            subtitle: nil,
            icon: "gear",
            shortcutDisplay: nil,
            action: .openSettings
        ))
    }

    // MARK: - Action availability

    // swiftlint:disable:next cyclomatic_complexity
    private static func isActionEnabled(
        _ action: LimpidShortcutAction,
        context: ActionEnabledContext
    ) -> Bool {
        switch action {
        case .newWorktree: context.isProjectActive
        case .renameTab: context.hasActiveTab
        case .reopenClosedTab: context.hasClosedTabs
        case .closeSurface, .closeTab: context.hasActiveTab
        case .nextTab, .previousTab: context.hasMultipleTabs
        case .nextSection, .previousSection: context.hasMultipleSections
        case .nextAttention, .previousAttention: context.hasWaitingAttention
        case .find: context.hasActiveTab
        case .findNext, .findPrevious: context.hasActiveSearch
        case .nextPrompt, .previousPrompt: context.hasActiveTab
        case .splitRight, .splitDown: context.hasActiveTab
        case .equalizeSplits, .toggleSplitZoom: context.isSplit
        case .focusPaneLeft: context.reachable(.left)
        case .focusPaneRight: context.reachable(.right)
        case .focusPaneUp: context.reachable(.up)
        case .focusPaneDown: context.reachable(.down)
        case .commandPalette, .quickOpen: false
        default: true
        }
    }

    // MARK: - Helpers

    private static func shortenPath(_ path: String) -> String {
        guard let home = ProcessInfo.processInfo.environment["HOME"] else { return path }
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
