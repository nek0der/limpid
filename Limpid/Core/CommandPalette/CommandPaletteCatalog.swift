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
        /// Whether ⌘W has anything to do (`PaneActions.canClosePaneOrTab`).
        let canCloseSurface: Bool
        let canSplit: Bool
        let canEqualize: Bool
        let canReview: Bool
        let canReviewTurn: Bool
    }

    private struct ShortcutDependencies {
        let settings: SettingsStore
        let attention: AttentionState
        let registry: (any SurfaceViewProviding)?
        let reviewPresentation: ReviewPresentation?
    }

    static func buildItems(
        session: WindowSession,
        settings: SettingsStore,
        attention: AttentionState,
        registry: (any SurfaceViewProviding)? = nil,
        reviewPresentation: ReviewPresentation? = nil,
        isTmuxAvailable: Bool = false
    ) -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []
        items.reserveCapacity(80)
        appendShortcutActions(
            to: &items,
            session: session,
            dependencies: ShortcutDependencies(
                settings: settings,
                attention: attention,
                registry: registry,
                reviewPresentation: reviewPresentation
            )
        )
        if isTmuxAvailable {
            appendTmuxEntry(to: &items)
        }
        appendTabs(to: &items, session: session)
        appendGroups(to: &items, session: session)
        appendProjects(to: &items, session: session)
        appendClosedTabs(to: &items, session: session)
        appendRecentProjects(to: &items, session: session)
        appendSettings(to: &items)
        return items
    }

    // MARK: - tmux windows

    /// The row that switches the field to `$`. Listed whenever tmux is
    /// installed, before any window is known, so the mode can be found
    /// from the actions even when no server is running.
    private static func appendTmuxEntry(to items: inout [CommandPaletteItem]) {
        let resource: LocalizedStringResource = "Open tmux Window…"
        let localizedTitle = String(localized: resource)
        let englishTitle = englishString(resource)
        let action = CommandPaletteAction.insertPrefix(.tmux)
        items.append(CommandPaletteItem(
            id: action.frecencyKey,
            category: .actions,
            title: localizedTitle,
            searchAlias: localizedTitle != englishTitle ? englishTitle : nil,
            subtitle: nil,
            icon: "rectangle.split.2x1",
            shortcutDisplay: nil,
            action: action
        ))
    }

    /// One row per tmux window found on a reachable server, titled with
    /// the bare `session:window` name: the section header already says
    /// these are tmux windows. The verb stays searchable through hidden
    /// keywords, in English and in the UI language, so typing "tmux" or the
    /// localized verb still finds every window.
    ///
    /// A window on a server older than `TmuxMirrorTarget.minimumVersion`, or
    /// one whose version is unknown, is still listed, disabled and labeled
    /// with the version it needs, so the user learns why it will not open
    /// instead of wondering where it went.
    ///
    /// Rows that share a name carry a subtitle that tells them apart
    /// (`TmuxMirrorTarget.distinguishingLabels`); the rest carry none.
    static func tmuxWindowItems(
        targets: [TmuxMirrorTarget],
        isOpen: (TmuxMirrorTarget) -> Bool
    ) -> [CommandPaletteItem] {
        let verb: LocalizedStringResource = "Open tmux Window in Tab"
        let verbs = Array(Set([englishString(verb), String(localized: verb)])).sorted()
        let openLabel = String(localized: LocalizedStringResource("palette.tmux.windowOpen", defaultValue: "Open"))
        let unsupportedLabel = String(localized: "Needs tmux \(TmuxMirrorTarget.minimumVersion.description) or later")
        let labels = TmuxMirrorTarget.distinguishingLabels(for: targets)
        return zip(targets, labels).map { target, label in
            let action = CommandPaletteAction.mirrorTmuxWindow(target)
            let isShown = isOpen(target)
            return CommandPaletteItem(
                id: action.frecencyKey,
                category: .tmux,
                title: target.displayName,
                searchKeywords: verbs.map { "tmux \($0) \(target.displayName)" },
                subtitle: label,
                icon: "rectangle.split.2x1",
                shortcutDisplay: nil,
                statusLabel: isShown ? openLabel : (target.isSupported ? nil : unsupportedLabel),
                action: action,
                // A window a tab already shows stays selectable whatever its
                // server's version: choosing it brings that tab forward and
                // attaches nothing.
                isEnabled: isShown || target.isSupported
            )
        }
    }

    // MARK: - Shortcut actions

    private static func appendShortcutActions(
        to items: inout [CommandPaletteItem],
        session: WindowSession,
        dependencies: ShortcutDependencies
    ) {
        let hasActiveTab = session.activeTab != nil
        let hasMultipleTabs = session.tabs(in: session.activeContainerID).count > 1
        let hasMultipleSections = !session.groups.isEmpty || !session.projects.isEmpty
        let isSplit = session.activeTab?.splitTree.isSplit == true
        // Per-direction reachability — same source of truth the Pane menu
        // uses, so a Focus/Move action greys out in exactly the directions
        // it can't reach (also covers zoom + single-pane via `adjacentLeaf`).
        let reachable: (SpatialDirection) -> Bool = {
            PaneActions.adjacentLeaf(session, registry: dependencies.registry, direction: $0) != nil
        }
        let isProjectActive = session.activeContainerID.projectID != nil
        let hasClosedTabs = !session.closedTabStack.isEmpty
        let focusedPaneID = session.activeTab?.splitTree.effectiveFocusedLeafID
        let hasActiveSearch = focusedPaneID.map { session.paneSearchStates[$0] != nil } ?? false
        let hasWaitingAttention = !dependencies.attention.attentionEntries(in: session).isEmpty
        let capabilities = session.activeTab?.capabilities

        let context = ActionEnabledContext(
            hasActiveTab: hasActiveTab,
            hasMultipleTabs: hasMultipleTabs,
            hasMultipleSections: hasMultipleSections,
            isSplit: isSplit,
            reachable: reachable,
            isProjectActive: isProjectActive,
            hasClosedTabs: hasClosedTabs,
            hasActiveSearch: hasActiveSearch,
            hasWaitingAttention: hasWaitingAttention,
            canCloseSurface: PaneActions.canClosePaneOrTab(session.activeTab),
            canSplit: capabilities?.canSplit ?? false,
            canEqualize: capabilities?.canEqualize ?? false,
            canReview: ReviewAgents.canReview(
                session: session,
                attention: dependencies.attention,
                presentation: dependencies.reviewPresentation
            ),
            canReviewTurn: ReviewAgents.turnScope(
                session: session,
                attention: dependencies.attention,
                paneID: focusedPaneID
            ) != nil
        )

        for action in LimpidShortcutAction.allCases {
            let shortcut = dependencies.settings.settings.keyboard.shortcut(for: action)
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
                icon: ContainerSymbol.group,
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
                icon: ContainerSymbol.project,
                shortcutDisplay: nil,
                action: .activateProject(project.id)
            ))

            for worktree in project.worktrees where !worktree.isHidden {
                items.append(CommandPaletteItem(
                    id: "worktree.\(project.id.uuidString).\(worktree.id.uuidString)",
                    category: .navigate,
                    title: worktree.label,
                    subtitle: shortenPath(worktree.workingDirectory.path),
                    icon: ContainerSymbol.worktree,
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
            if alreadyOpen {
                continue
            }

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
        case .closeSurface: context.hasActiveTab && context.canCloseSurface
        case .closeTab: context.hasActiveTab
        case .nextTab, .previousTab: context.hasMultipleTabs
        case .nextSection, .previousSection: context.hasMultipleSections
        case .nextAttention, .previousAttention: context.hasWaitingAttention
        case .find: context.hasActiveTab
        case .findNext, .findPrevious: context.hasActiveSearch
        case .nextPrompt, .previousPrompt,
             .scrollToTop, .scrollToBottom, .scrollPageUp, .scrollPageDown: context.hasActiveTab
        case .splitRight, .splitDown: context.hasActiveTab && context.canSplit
        case .equalizeSplits: context.isSplit && context.canEqualize
        case .toggleSplitZoom: context.isSplit
        case .focusPaneLeft: context.reachable(.left)
        case .focusPaneRight: context.reachable(.right)
        case .focusPaneUp: context.reachable(.up)
        case .focusPaneDown: context.reachable(.down)
        case .reviewChanges: context.canReview
        case .reviewTurn: context.canReviewTurn
        case .commandPalette, .quickOpen: false
        default: true
        }
    }

    // MARK: - Helpers

    private static func englishString(_ resource: LocalizedStringResource) -> String {
        var english = resource
        english.locale = Locale(identifier: "en")
        return String(localized: english)
    }

    private static func shortenPath(_ path: String) -> String {
        guard let home = ProcessInfo.processInfo.environment["HOME"] else { return path }
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
