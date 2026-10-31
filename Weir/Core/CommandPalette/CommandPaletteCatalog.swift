// CommandPaletteCatalog.swift
// Weir — builds the palette item list from live `WorkspaceSession` and `SettingsStore`.

import Foundation
import WeirDomain

@MainActor
enum CommandPaletteCatalog {

    /// Lightweight context bundle for `isActionEnabled` — keeps the
    /// per-action dispatch fed by one value instead of six loose flags.
    private struct ActionEnabledContext {
        let hasActiveTab: Bool
        /// ⇧⌘[ ⇧⌘] have a tab to step to: another terminal tab, or the
        /// window's review tab.
        let canCycleTab: Bool
        /// ⌘[ ⌘] have somewhere to go: another session row.
        let canCycleSession: Bool
        let isSplit: Bool
        let reachable: (SpatialDirection) -> Bool
        let isProjectActive: Bool
        /// The window shows a project (not its project chooser): the one
        /// Move Project Up and Down move.
        let hasShownProject: Bool
        let hasClosedTabs: Bool
        let hasActiveSearch: Bool
        let hasWaitingAttention: Bool
        let canReview: Bool
        let canGoBack: Bool
        let canGoForward: Bool
        /// The window shows a session, whose strip Open Tabs hangs from.
        let hasPaneStrip: Bool
    }

    private struct ShortcutDependencies {
        let settings: SettingsStore
        let attention: AttentionState
        let registry: (any SurfaceViewProviding)?
        let supervision: SupervisionPaletteFacts
        /// The window the palette opened in, whose tab the actions act on.
        let window: WindowID
        let locale: Locale
    }

    /// Item titles are `String`s, because fuzzy matching and its highlight
    /// work on characters, so they are resolved here in `locale`: the app
    /// locale, which the palette's window is drawn in. The list is rebuilt
    /// every time the palette opens, so a language switch shows up on the
    /// next open.
    static func buildItems( // swiftlint:disable:this function_parameter_count
        session: WorkspaceSession,
        settings: SettingsStore,
        attention: AttentionState,
        registry: (any SurfaceViewProviding)? = nil,
        // The window it opens in, as far as its rows' enabled states need it.
        supervision: SupervisionPaletteFacts,
        window: WindowID,
        locale: Locale
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
                supervision: supervision,
                window: window,
                locale: locale
            )
        )
        appendTabs(to: &items, session: session)
        appendProjects(to: &items, session: session, window: window, supervision: supervision, locale: locale)
        appendClosedTabs(to: &items, session: session)
        appendRecentProjects(to: &items, session: session)
        appendRestore(to: &items, facts: supervision, locale: locale)
        appendSettings(to: &items, locale: locale)
        // A project ID the window still holds after its project went is no
        // project to set up or close, like the project ▾'s items.
        if let projectID = supervision.projectID, let project = session.project(projectID) {
            appendProjectSettings(to: &items, projectName: project.name, locale: locale)
            appendCloseProject(to: &items, projectName: project.name, locale: locale)
        }
        return items
    }

    // MARK: - Shortcut actions

    private static func appendShortcutActions(
        to items: inout [CommandPaletteItem],
        session: WorkspaceSession,
        dependencies: ShortcutDependencies
    ) {
        let window = dependencies.window
        let activeTab = session.activeTab(in: window)
        let hasActiveTab = activeTab != nil
        let supervision = dependencies.supervision
        // A window the session does not know has no tabs, and nothing to
        // act on.
        let selection = session.selection(window)
        let tabCount = selection.map { session.tabs(in: $0.activeContainerID).count } ?? 0
        // As the menu decides (`PaneCommands`, `NavigationCommands`): the
        // window's review tab is one of the tabs stepped through, and ⌘[ ⌘]
        // walk its session rows.
        let canCycleTab = SupervisionPaletteFacts.canCycleTab(tabCount: tabCount, facts: supervision)
        let canCycleSession = supervision.sessionRowCount > 1
        let isSplit = activeTab?.splitTree.isSplit == true
        // Per-direction reachability — same source of truth the Pane menu
        // uses, so a Focus/Move action grays out in exactly the directions
        // it can't reach (also covers zoom + single-pane via `adjacentLeaf`).
        let reachable: (SpatialDirection) -> Bool = {
            PaneActions.adjacentLeaf(session, registry: dependencies.registry, direction: $0, in: window) != nil
        }
        // The window's project, kept while a scratch tab is selected, so the
        // palette offers what the title bar does.
        let isProjectActive = (supervision.projectID ?? selection?.activeContainerID.projectID) != nil
        let hasClosedTabs = !session.closedTabStack.isEmpty
        let focusedPaneID = activeTab?.splitTree.effectiveFocusedLeafID
        let hasActiveSearch = focusedPaneID.map { session.paneSearchStates[$0] != nil } ?? false
        let hasWaitingAttention = dependencies.attention.hasAttentionItems()

        let context = ActionEnabledContext(
            hasActiveTab: hasActiveTab,
            canCycleTab: canCycleTab,
            canCycleSession: canCycleSession,
            isSplit: isSplit,
            reachable: reachable,
            isProjectActive: isProjectActive,
            hasShownProject: supervision.projectID != nil,
            hasClosedTabs: hasClosedTabs,
            hasActiveSearch: hasActiveSearch,
            hasWaitingAttention: hasWaitingAttention,
            // The review tab opens from any tab, and says why when there is
            // nothing to read.
            canReview: hasActiveTab,
            canGoBack: session.canNavigateBack(in: window),
            canGoForward: session.canNavigateForward(in: window),
            hasPaneStrip: !supervision.isChoosingProject
        )

        for action in WeirShortcutAction.allCases {
            let shortcut = dependencies.settings.settings.keyboard.shortcut(for: action)
            // A pane command is off while the review hides the panes.
            let enabled = isActionEnabled(action, context: context)
                && !SupervisionPaletteFacts.isOffPaneCommand(action, arePanesHidden: supervision.arePanesHidden)
            let localizedTitle = action.localizedTitle.resolved(in: dependencies.locale)
            let englishTitle = action.localizedTitle.resolved(in: .english)
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
        session: WorkspaceSession
    ) {
        for tab in session.tabs {
            let subtitle = tab.workingDirectory ?? tab.pwd
            items.append(CommandPaletteItem(
                id: "tab.\(tab.id.uuidString)",
                category: .navigate,
                title: tab.shownTitle,
                subtitle: subtitle.map { PathFormatting.abbreviateHome($0) },
                icon: "macwindow",
                shortcutDisplay: nil,
                action: .jumpToTab(tab.id)
            ))
        }
    }

    // MARK: - Projects + worktrees

    /// Each project, then its worktrees by the names their rows have
    /// (`RowName`), so the palette finds a row by the name the sidebar
    /// shows. A worktree only Git reported, folded among the other
    /// worktrees, says so before its folder. Projects come in the window's
    /// sidebar order, and each one's worktrees as its sidebar lists them
    /// (`SupervisionPaletteFacts.rowOrder`). The list "#" opens on therefore
    /// starts from the order the person keeps, and use re-ranks it from
    /// there.
    private static func appendProjects(
        to items: inout [CommandPaletteItem],
        session: WorkspaceSession,
        window: WindowID,
        supervision: SupervisionPaletteFacts,
        locale: Locale
    ) {
        let other = LocalizedStringResource(
            "Other Worktrees",
            comment: "Sidebar fold line: the worktrees Git reports that nobody has opened in Weir"
        ).resolved(in: locale)
        let byID = Dictionary(session.projects.map { ($0.id, $0) }) { first, _ in first }
        let projectIDs = session.projects.map(\.id)
        let order = session.selection(window)?.sidebarArrangement.ordered(projectIDs) ?? projectIDs
        let rowSections = supervision.rowSections
        let rank = Dictionary(supervision.rowOrder.enumerated().map { ($1, $0) }) { first, _ in first }
        for project in order.compactMap({ byID[$0] }) {
            items.append(CommandPaletteItem(
                id: "project.\(project.id.uuidString)",
                category: .navigate,
                title: project.name,
                subtitle: PathFormatting.abbreviateHome(project.rootURL.path),
                icon: ContainerSymbol.project,
                shortcutDisplay: nil,
                action: .activateProject(project.id)
            ))

            // A row the order does not name keeps the project's order,
            // after the ones it does.
            let worktrees = project.worktrees.enumerated()
                .filter { !$0.element.isHidden }
                .sorted { lhs, rhs in
                    let left = rank[.worktree(projectID: project.id, worktreeID: lhs.element.id)] ?? Int.max
                    let right = rank[.worktree(projectID: project.id, worktreeID: rhs.element.id)] ?? Int.max
                    return left != right ? left < right : lhs.offset < rhs.offset
                }
                .map(\.element)
            for worktree in worktrees {
                let row = ContainerID.worktree(projectID: project.id, worktreeID: worktree.id)
                let folder = PathFormatting.abbreviateHome(worktree.workingDirectory.path)
                // Where the sidebar lists it, an item waiting in it
                // included; without the sidebar's sections, by what the row
                // holds: a tab keeps it among the working ones.
                let isOther = rowSections.isEmpty
                    ? SidebarSectionRule.isUnopened(admission: worktree.admission, hasTabs: !session.tabs(in: row).isEmpty)
                    : rowSections[row] == .other
                items.append(CommandPaletteItem(
                    id: "worktree.\(project.id.uuidString).\(worktree.id.uuidString)",
                    category: .navigate,
                    title: session.rowName(of: row)?.text ?? worktree.label,
                    subtitle: isOther ? "\(other) · \(folder)" : folder,
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
        session: WorkspaceSession
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
        session: WorkspaceSession
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
                subtitle: PathFormatting.abbreviateHome(url.path),
                icon: "clock",
                shortcutDisplay: nil,
                action: .openRecentProject(url)
            ))
        }
    }

    // MARK: - Settings

    private static func appendSettings(to items: inout [CommandPaletteItem], locale: Locale) {
        let resource: LocalizedStringResource = "Open Settings"
        let localizedTitle = resource.resolved(in: locale)
        let englishTitle = resource.resolved(in: .english)
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

    /// "Restore Code to Before This Turn…", with the turn it goes
    /// back to as its subtitle; off when there is no turn to restore to
    /// (`SupervisionPaletteFacts.restoreTurnNumber`). Whether the restore
    /// can run now, the strip it opens says, as every entry's does.
    private static func appendRestore(to items: inout [CommandPaletteItem], facts: SupervisionPaletteFacts, locale: Locale) {
        let localizedTitle = RestoreGate.entryTitle.resolved(in: locale)
        let englishTitle = RestoreGate.entryTitle.resolved(in: .english)
        items.append(CommandPaletteItem(
            id: "restore.turn",
            category: .actions,
            title: localizedTitle,
            searchAlias: localizedTitle != englishTitle ? englishTitle : nil,
            subtitle: facts.restoreTurnNumber.map { "T\($0)" },
            icon: "arrow.uturn.backward",
            shortcutDisplay: nil,
            action: .restoreTurn,
            isEnabled: facts.restoreTurnNumber != nil
        ))
    }

    /// The window's project settings: the palette's way to them in the
    /// supervision window, where the project ▾ also has them. The detail
    /// names the project, since the palette's other settings are the app's.
    private static func appendProjectSettings(to items: inout [CommandPaletteItem], projectName: String, locale: Locale) {
        let resource: LocalizedStringResource = "Project Settings…"
        let localizedTitle = resource.resolved(in: locale)
        let englishTitle = resource.resolved(in: .english)
        items.append(CommandPaletteItem(
            id: "settings.project",
            category: .settings,
            title: localizedTitle,
            searchAlias: localizedTitle != englishTitle ? englishTitle : nil,
            subtitle: projectName,
            icon: "gearshape",
            shortcutDisplay: nil,
            action: .openProjectSettings
        ))
    }

    /// Close Project…, beside the project ▾'s: it asks first, as
    /// that one does. The detail names the project it closes.
    private static func appendCloseProject(to items: inout [CommandPaletteItem], projectName: String, locale: Locale) {
        let resource: LocalizedStringResource = "Close Project…"
        let localizedTitle = resource.resolved(in: locale)
        let englishTitle = resource.resolved(in: .english)
        items.append(CommandPaletteItem(
            id: "project.close",
            category: .actions,
            title: localizedTitle,
            searchAlias: localizedTitle != englishTitle ? englishTitle : nil,
            subtitle: projectName,
            icon: "xmark",
            shortcutDisplay: nil,
            action: .closeProject
        ))
    }

    // MARK: - Action availability

    // swiftlint:disable:next cyclomatic_complexity
    private static func isActionEnabled(
        _ action: WeirShortcutAction,
        context: ActionEnabledContext
    ) -> Bool {
        switch action {
        // A window that shows no project has nowhere to make one.
        case .newWorktree, .newWorktreeNow: context.isProjectActive
        // The palette moves the window's own project, which it must show.
        case .moveProjectUp, .moveProjectDown: context.hasShownProject
        case .renameTab: context.hasActiveTab
        case .reopenClosedTab: context.hasClosedTabs
        case .closeSurface, .closeTab: context.hasActiveTab
        case .nextTab, .previousTab: context.canCycleTab
        case .nextSession, .previousSession: context.canCycleSession
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
        // Review Latest Turn opens the same tab on the pane's latest turn.
        case .review, .reviewLatestTurn: context.canReview
        case .commandPalette, .quickOpen: false
        case .goBack: context.canGoBack
        case .goForward: context.canGoForward
        case .showOpenTabs: context.hasPaneStrip
        default: true
        }
    }
}
