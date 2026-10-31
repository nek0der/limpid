// TabActions.swift
// Weir — centralized verbs over WorkspaceSession + SplitTree so keyboard
// shortcuts, menu items, and context menus all dispatch through the same
// surface. Each method is small and pure: pull the active tab, mutate its
// split tree, write it back.

import Foundation
import GhosttyKit
import OSLog
import WeirDomain

private let log = Logger.weir("tab.actions")

/// A focused leaf and its neighbor on a given edge of the same tab.
/// Returned from `PaneActions.adjacentLeaf`; the focus and
/// menu-enabled paths each consume the same record.
struct PaneAdjacency {
    let tab: Tab
    let current: UUID
    let neighbor: UUID
}

@MainActor
enum TabActions {

    // MARK: - Tab

    static func newTab(_ session: WorkspaceSession, in window: WindowID, intent: SelectionIntent) {
        session.openTabInActiveScope(in: window, intent: intent)
    }

    /// A tab in `container` running `agent`, or a shell when it is `nil`:
    /// the pane strip's "+". The agent's command is staged for the
    /// tab's one pane and typed once its terminal starts. Returns the pane.
    /// The tab is selected in `window` for `intent` when it `selects`, as
    /// each `newTab` below; one that does not opens behind
    /// (`WorkspaceSession.openTab`).
    @discardableResult
    static func newTab( // swiftlint:disable:this function_parameter_count
        _ session: WorkspaceSession,
        in container: ContainerID,
        running agent: AgentKind?,
        window: WindowID,
        intent: SelectionIntent,
        selects: Bool
    ) -> UUID? {
        if let agent {
            let paneID = newTab(session, in: container, typing: agent.launchCommand, window: window, intent: intent, selects: selects)
            stageAgentInFront(agent, paneID: paneID, in: session)
            return paneID
        }
        return session.openTab(container: container, in: window, intent: intent, selects: selects).splitTree.allLeafIDs().first
    }

    /// The agent a tab opened to run wears its badge from the start,
    /// before its command is typed or its run has a record: the tab is
    /// that agent's. What its terminal then runs in front takes over
    /// (`PaneAgentInFrontRules.next`).
    private static func stageAgentInFront(_ agent: AgentKind, paneID: UUID?, in session: WorkspaceSession) {
        guard let paneID, let tab = session.tab(containing: paneID) else { return }
        session.update(tab.id) { $0.agentsInFront[paneID] = PaneAgentInFront(kind: agent, isStaged: true) }
    }

    /// A tab in `container` whose shell runs `command` once its terminal
    /// starts, and stays when it ends, so its output can be read: "Create
    /// PR" and "Open in {tool}" in the changes panel, and a new
    /// workspace's terminal with a command.
    @discardableResult
    static func newTab( // swiftlint:disable:this function_parameter_count
        _ session: WorkspaceSession,
        in container: ContainerID,
        typing command: String,
        window: WindowID,
        intent: SelectionIntent,
        selects: Bool
    ) -> UUID? {
        let tab = session.openTab(container: container, in: window, intent: intent, selects: selects)
        guard let paneID = tab.splitTree.allLeafIDs().first else { return nil }
        session.update(tab.id) { $0.initialCommands[paneID] = command }
        return paneID
    }

    /// ⌘⇧R — start inline rename on the active pane strip tab. Asks the
    /// window to rename that tab, so the matching tab of that window flips
    /// into edit mode without us having to plumb an `@State` binding through
    /// the strip's view hierarchy. A tab could be listed in more than one
    /// window's strip; only the window asked edits its name.
    static func renameActiveTab(_ session: WorkspaceSession, in window: WindowID, commands: any WindowCommandPerforming) {
        guard let selection = session.selection(window), let tabID = selection.activeTabID else { return }
        commands.perform(.renameTab(tabID), in: selection.windowID)
    }

    /// Single entry point for closing a tab so the "snapshot leaves →
    /// closeTab → unregister leaves" cleanup pattern lives in one
    /// place. All user-initiated call sites (a tab's ×, ⌘W cascade,
    /// libghostty's ⌘⌥W, the ellipsis "Close All" menu) funnel
    /// through here, which is also the single chokepoint that
    /// consults `CloseConfirmer` — so the agent-aware modal is
    /// impossible to bypass from a new caller. The tab closes once the
    /// confirmation allows it, which may be after this returns.
    static func closeTab(
        _ session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        tabID: UUID,
        source: CloseConfirmer.Source = .keyboard,
        confirm: Bool = true,
        attention: AttentionState? = nil,
        agentProjection: AgentProjectionAdapter? = nil,
        in window: WindowID? = nil
    ) {
        guard let tab = session.tab(tabID) else { return }
        // `confirm: false` is reserved for batch callers (e.g.
        // `closeAllTabs`) that already showed an
        // aggregate prompt — without the opt-out we'd nag the user
        // once per tab inside the loop.
        guard confirm else {
            closeAllowedTab(session, registry: registry, tabID: tabID, askedLeafIDs: nil, agentProjection: agentProjection)
            return
        }
        let leafIDs = tab.splitTree.allLeafIDs()
        CloseConfirmer.confirm(.tab, source: source, paneIDs: leafIDs, window: window) {
            closeAllowedTab(
                session,
                registry: registry,
                tabID: tabID,
                askedLeafIDs: Set(leafIDs),
                agentProjection: agentProjection
            )
        }
    }

    /// Closes the tab, once allowed. Read again here: a confirmation may
    /// have been up while the tab closed some other way, or while it split.
    /// A pane that appeared meanwhile was never asked about (its agent may
    /// be the one the confirmation would have named), so the tab then stays
    /// rather than close what the person did not agree to; panes that
    /// ended meanwhile change nothing. `askedLeafIDs` nil closes it as it
    /// is, for a caller that asked about the whole container.
    static func closeAllowedTab(
        _ session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        tabID: UUID,
        askedLeafIDs: Set<UUID>?,
        agentProjection: AgentProjectionAdapter?
    ) {
        guard let tab = session.tab(tabID) else { return }
        let leafIDs = tab.splitTree.allLeafIDs()
        if let askedLeafIDs, !Set(leafIDs).isSubset(of: askedLeafIDs) {
            return
        }

        // Capture every pane's scrollback so reopen rebuilds the full
        // split layout, not just the focused leaf. Routes through the
        // shared helper so ⌘Q and per-tab close stay in lock-step on
        // filename / permissions / directory creation.
        var snapshot = tab
        var paths: [UUID: String] = [:]
        // A demo run's panes are not the person's; their scrollback would
        // be strays in the person's folder.
        if session.writesUserFiles, let files = session.scrollbackFiles {
            for pid in leafIDs {
                guard let url = files.capture(pid, with: registry) else { continue }
                paths[pid] = url.path
            }
        }
        snapshot.scrollbackPaths = paths
        session.recordClosedTab(snapshot)

        session.closeTab(tabID)
        for leafID in leafIDs {
            registry.unregister(leafID)
            // Tell the projection the leaves are gone so their hints are
            // judged now. The snapshot above still carries the resume hints
            // for an in-session `reopenClosedTab` to honor; once the user
            // quits, the closed-tab stack is gone anyway.
            agentProjection?.didClosePane(leafID)
        }
    }

    /// ⌘⇧T — pop the most-recently-closed tab back. Mints fresh pane
    /// IDs (the old SurfaceViews are gone, and Weir uses paneID as
    /// the surface registry key — collisions would point at nothing),
    /// remaps every paneID-keyed field on the Tab, and appends it.
    /// SwiftUI then mounts a new PaneHostView per leaf and the
    /// existing `stageScrollback` path replays each `.vt` above the
    /// fresh shell prompt — the same machinery ⌘Q + restart uses.
    static func reopenClosedTab(
        _ session: WorkspaceSession,
        specificID: UUID? = nil,
        in window: WindowID,
        intent: SelectionIntent
    ) {
        let closed: ClosedTab? = if let specificID {
            session.popClosedTab(id: specificID)
        } else {
            session.popClosedTab()
        }
        guard let closed else { return }

        let oldLeafIDs = closed.tab.splitTree.allLeafIDs()
        let idMap: [UUID: UUID] = Dictionary(
            uniqueKeysWithValues: oldLeafIDs.map { ($0, UUID()) }
        )

        var revived = Tab(
            id: UUID(),
            title: closed.tab.title,
            titleOverride: closed.tab.titleOverride,
            workingDirectory: closed.tab.workingDirectory,
            pwd: closed.tab.pwd,
            splitTree: closed.tab.splitTree.remapLeafIDs(idMap),
            paneStates: remapKeys(closed.tab.paneStates, using: idMap),
            zoomedLeafID: closed.tab.zoomedLeafID.flatMap { idMap[$0] },
            container: closed.tab.container,
            // Carry every provider's per-pane resume hints across
            // the pane id remap so an in-session ⌘⇧T can still try a
            // resume on the revived leaf (best-effort — the disk
            // record was already dropped at close time).
            agentSessions: closed.tab.agentSessions.mapValues { remapKeys($0, using: idMap) },
            tmuxBindings: remapKeys(closed.tab.tmuxBindings, using: idMap)
        )
        // What a scratch tab kept from its group comes back with it.
        revived.namePrefix = closed.tab.namePrefix
        revived.paletteIndex = closed.tab.paletteIndex
        revived.cwdMode = closed.tab.cwdMode
        revived.cwdPath = closed.tab.cwdPath
        // `scrollbackPaths` / `initialCommands` aren't in the Tab init
        // signature, so assign them after construction.
        revived.scrollbackPaths = remapKeys(closed.tab.scrollbackPaths, using: idMap)
        revived.initialCommands = remapKeys(closed.tab.initialCommands, using: idMap)
        revived.initialPromptFiles = remapKeys(closed.tab.initialPromptFiles, using: idMap)
        revived.initialAgentExecutables = remapKeys(closed.tab.initialAgentExecutables, using: idMap)
        // The projection answered which of those hints may resume while the
        // pane was open. The hint file went with the pane, so the next pass
        // cannot answer again; carrying the answer here gives the revived
        // pane its chance to resume, on the same best-effort terms as the
        // hints above (a pass that lands before the mount clears it).
        revived.agentResumeCandidates = remapKeys(closed.tab.agentResumeCandidates, using: idMap)
        // The conversation that named the tab's row names it again, in its
        // pane under the pane's new id, so a later move takes it along.
        revived.conversationName = closed.tab.conversationName?.remapped(idMap)

        session.tabs.append(revived)
        session.setActiveTab(revived.id, in: window, intent: intent)
    }

    /// Rewrite the keys of a `[UUID: T]` through the given mapping.
    /// Used by `reopenClosedTab` to renumber every paneID-keyed slot
    /// on a revived `Tab` in lock-step with the split tree.
    private static func remapKeys<T>(
        _ source: [UUID: T],
        using mapping: [UUID: UUID]
    ) -> [UUID: T] {
        var result: [UUID: T] = [:]
        for (old, value) in source {
            if let new = mapping[old] {
                result[new] = value
            }
        }
        return result
    }

    static func closeActiveTab(
        _ session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        source: CloseConfirmer.Source = .keyboard,
        attention: AttentionState? = nil,
        agentProjection: AgentProjectionAdapter? = nil,
        in window: WindowID
    ) {
        guard let id = session.selection(window)?.activeTabID else { return }
        closeTab(
            session,
            registry: registry,
            tabID: id,
            source: source,
            attention: attention,
            agentProjection: agentProjection,
            in: window
        )
    }

    /// Close every tab in `container`: Close All Tabs in a sidebar row's
    /// menu. One confirmation up front, then each tab without asking
    /// again.
    static func closeAllTabs(
        _ session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        in container: ContainerID,
        agentProjection: AgentProjectionAdapter? = nil,
        from window: WindowID? = nil
    ) {
        let tabs = session.tabs(in: container)
        guard !tabs.isEmpty else { return }
        let allLeafIDs = tabs.flatMap { $0.splitTree.allLeafIDs() }
        let askedLeafIDs = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, Set($0.splitTree.allLeafIDs())) })
        CloseConfirmer.confirm(.allTabs, source: .mouse, paneIDs: allLeafIDs, window: window) {
            closeTabs(askedLeafIDs, session, registry: registry, in: container, agentProjection: agentProjection)
        }
    }

    /// Closes the tabs Close All Tabs asked about once it is allowed: those
    /// still in `container` then, each as `closeAllowedTab` does. A tab
    /// opened while the question was up was not asked about, so it stays;
    /// so does one that split meanwhile.
    private static func closeTabs(
        _ askedLeafIDs: [UUID: Set<UUID>],
        _ session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        in container: ContainerID,
        agentProjection: AgentProjectionAdapter?
    ) {
        for tab in session.tabs(in: container) {
            guard let asked = askedLeafIDs[tab.id] else { continue }
            closeAllowedTab(
                session,
                registry: registry,
                tabID: tab.id,
                askedLeafIDs: asked,
                agentProjection: agentProjection
            )
        }
    }

    // `activateTabInActiveContainer` + `cycleTab` moved to
    // `Weir/Core/Actions/NavActions.swift`.

    // MARK: - Split + pane verbs

    // Pane verbs live in `PaneActions`.

    // MARK: - Closed-tab restore (⌘⇧T)

    // MARK: - In-pane search (⌘F / ⌘G / ⇧⌘G)

    // Moved to `Weir/Core/Actions/SearchActions.swift`. See the file
    // header there for the namespace-split rationale.

    // MARK: - Pane close that cascades into the tab when last (⌘W)

    // `closeActivePaneOrTab` moved to
    // `Weir/Core/Actions/PaneActions.swift`.

    // MARK: - Container deletion (frees SurfaceViews too)

    // Container verbs live in `ContainerActions`.

    // MARK: - Command Palette

    // `openCommandPalette` / `closeCommandPalette` /
    // `executeCommandPaletteAction` moved to
    // `Weir/Core/Actions/CommandPaletteActions.swift`.

    /// Bundles the optional projection adapter so the dispatcher chain
    /// stays under the parameter-count budget. The close path tells the
    /// projection a pane is gone, which is what feeds the `--resume`
    /// plumbing and lets the projection drop the closed pane's cwd history.
    struct SessionTrackers {
        let projection: AgentProjectionAdapter?
    }

    /// The session a shortcut acts on, the window it runs in, and the way to
    /// ask that window's views, carried together down the dispatch chain.
    struct ShortcutScope {
        let session: WorkspaceSession
        let window: WindowID
        let commands: any WindowCommandPerforming

        /// Asks the window to carry out `command` (`WindowCommand`).
        @MainActor
        func perform(_ command: WindowCommand) {
            commands.perform(command, in: window)
        }
    }

    // swiftlint:disable function_parameter_count
    /// Promoted from `private` to module-internal so
    /// `CommandPaletteActions.executeCommandPaletteAction` can route
    /// `.shortcutAction` cases through the same dispatch chain the
    /// menu bar and keyboard shortcuts already use. `toastCenter` +
    /// `minPaneSize` ride along for `PaneActions.split`'s pre-flight
    /// geometry check.
    ///
    /// Runs in `window`: its selection is the one moved, and what the
    /// window's own views do is asked of it alone (`WindowCommand`), not of
    /// every window. A window the
    /// session does not know runs nothing: what was asked of a window that
    /// is gone is not done in another (`WorkspaceSession.selection(_:)`).
    static func dispatchShortcutAction(
        _ action: WeirShortcutAction,
        session: WorkspaceSession,
        attention: AttentionState,
        registry: any SurfaceViewProviding,
        commands: any WindowCommandPerforming,
        trackers: SessionTrackers,
        toastCenter: ToastCenter,
        minPaneSize: PaneMinimumSize,
        window: WindowID
    ) {
        guard session.selection(window) != nil else { return }
        let scope = ShortcutScope(session: session, window: window, commands: commands)
        switch action.category {
        case .file:
            dispatchFileAction(action, in: scope, registry: registry, attention: attention, trackers: trackers)
        case .view:
            dispatchViewAction(action, in: scope)
        case .navigation:
            dispatchNavigationAction(action, in: scope, attention: attention)
        case .splits:
            dispatchSplitAction(action, in: scope, registry: registry, toastCenter: toastCenter, minPaneSize: minPaneSize)
        case .search:
            dispatchSearchAction(action, in: scope, registry: registry)
        case .terminal, .font:
            guard let ghosttyAction = action.ghosttyAction else { return }
            dispatchGhosttyAction(ghosttyAction, in: scope, registry: registry)
        case .help:
            dispatchHelpAction(action, in: scope)
        }
    }

    // swiftlint:enable function_parameter_count

    private static func dispatchFileAction(
        _ action: WeirShortcutAction,
        in scope: ShortcutScope,
        registry: any SurfaceViewProviding,
        attention: AttentionState,
        trackers: SessionTrackers
    ) {
        let (session, window) = (scope.session, scope.window)
        switch action {
        case .newTab: newTab(session, in: window, intent: .person)
        case .newWorktree:
            scope.perform(.newWorktree)
        case .newWorktreeNow:
            scope.perform(.newWorktreeNow)
        case .renameTab: renameActiveTab(session, in: window, commands: scope.commands)
        case .reopenClosedTab: reopenClosedTab(session, in: window, intent: .person)
        case .closeSurface:
            PaneActions.closeActivePaneOrTab(
                session,
                registry: registry,
                attention: attention,
                agentProjection: trackers.projection,
                in: window
            )
        case .closeTab:
            closeActiveTab(
                session,
                registry: registry,
                attention: attention,
                agentProjection: trackers.projection,
                in: window
            )
        case .openFolder:
            scope.perform(.openFolder)
        case .closeWindow:
            scope.perform(.closeWindow)
        case .newWindow:
            scope.perform(.newWindow)
        default:
            log.fault("dispatchFileAction missing handler for \(action.rawValue, privacy: .public) — add a case or fix action.category")
            assertionFailure("dispatchFileAction missing handler for \(action) — add a case or fix action.category")
        }
    }

    private static func dispatchViewAction(_ action: WeirShortcutAction, in scope: ShortcutScope) {
        switch action {
        case .toggleSidebar:
            scope.perform(.toggleSidebar)
        case .notificationHistory:
            scope.perform(.toggleNotificationHistory)
        case .review:
            scope.perform(.review)
        case .reviewLatestTurn:
            scope.perform(.reviewLatestTurn)
        // Palette / quick-open share the .view category but are
        // launched from `AppState` shortcuts rather than this dispatch
        // path — they intentionally no-op here.
        case .commandPalette, .quickOpen: break
        case .toggleChangesPanel:
            scope.perform(.toggleChangesPanel)
        case .allProjects:
            scope.perform(.toggleAllProjects)
        default:
            log.fault("dispatchViewAction missing handler for \(action.rawValue, privacy: .public) — add a case or fix action.category")
            assertionFailure("dispatchViewAction missing handler for \(action) — add a case or fix action.category")
        }
    }

    private static func dispatchHelpAction(_ action: WeirShortcutAction, in scope: ShortcutScope) {
        switch action {
        case .keyboardShortcuts:
            scope.perform(.toggleKeyboardShortcuts)
        default:
            log.fault("dispatchHelpAction missing handler for \(action.rawValue, privacy: .public) — add a case or fix action.category")
            assertionFailure("dispatchHelpAction missing handler for \(action) — add a case or fix action.category")
        }
    }

    private static func dispatchNavigationAction(
        _ action: WeirShortcutAction,
        in scope: ShortcutScope,
        attention: AttentionState
    ) {
        let (session, window) = (scope.session, scope.window)
        switch action {
        // The window walks its own session rows before this dispatch is
        // reached (`SupervisionWindowActions.runPaletteShortcut`), and Core
        // cannot name them.
        case .nextSession, .previousSession: break
        case .nextTab: NavActions.cycleTab(session, forward: true, in: window, intent: .person)
        case .previousTab: NavActions.cycleTab(session, forward: false, in: window, intent: .person)
        case .nextAttention:
            attention.walkAttention?(true)
        case .previousAttention:
            attention.walkAttention?(false)
        case .showNeedsAttention:
            scope.perform(.showNeedsAttention)
        case .showOpenTabs:
            scope.perform(.showOpenTabs)
        case .focusSidebar:
            scope.perform(.focusSidebar)
        // From the palette the sidebar does not have the keyboard, so the
        // project to move is the one the window shows.
        case .moveProjectUp, .moveProjectDown:
            guard let selection = session.selection(window), let projectID = selection.shownProjectID else { break }
            selection.sidebarArrangement.move(projectID, by: action == .moveProjectUp ? -1 : 1, among: session.projects.map(\.id))
        case .goBack: session.navigateBack(in: window, intent: .person)
        case .goForward: session.navigateForward(in: window, intent: .person)
        default:
            log
                .fault(
                    "dispatchNavigationAction missing handler for \(action.rawValue, privacy: .public) — add a case or fix action.category"
                )
            assertionFailure("dispatchNavigationAction missing handler for \(action) — add a case or fix action.category")
        }
    }

    private static func dispatchSplitAction(
        _ action: WeirShortcutAction,
        in scope: ShortcutScope,
        registry: any SurfaceViewProviding,
        toastCenter: ToastCenter,
        minPaneSize: PaneMinimumSize
    ) {
        let (session, window) = (scope.session, scope.window)
        switch action {
        case .splitRight:
            PaneActions.split(
                session,
                direction: .horizontal,
                registry: registry,
                minPaneSize: minPaneSize,
                toastCenter: toastCenter,
                in: window
            )
        case .splitDown:
            PaneActions.split(
                session,
                direction: .vertical,
                registry: registry,
                minPaneSize: minPaneSize,
                toastCenter: toastCenter,
                in: window
            )
        case .equalizeSplits: PaneActions.equalizeSplits(session, in: window)
        case .toggleSplitZoom: PaneActions.toggleZoom(session, in: window)
        case .focusPaneLeft: PaneActions.focusPane(session, registry: registry, direction: .left, in: window)
        case .focusPaneRight: PaneActions.focusPane(session, registry: registry, direction: .right, in: window)
        case .focusPaneUp: PaneActions.focusPane(session, registry: registry, direction: .up, in: window)
        case .focusPaneDown: PaneActions.focusPane(session, registry: registry, direction: .down, in: window)
        default:
            log.fault("dispatchSplitAction missing handler for \(action.rawValue, privacy: .public) — add a case or fix action.category")
            assertionFailure("dispatchSplitAction missing handler for \(action) — add a case or fix action.category")
        }
    }

    private static func dispatchSearchAction(
        _ action: WeirShortcutAction,
        in scope: ShortcutScope,
        registry: any SurfaceViewProviding
    ) {
        let (session, window) = (scope.session, scope.window)
        switch action {
        case .find: SearchActions.beginSearch(session, in: window)
        case .findNext: SearchActions.searchNext(session, registry: registry, in: window)
        case .findPrevious: SearchActions.searchPrevious(session, registry: registry, in: window)
        default:
            log.fault("dispatchSearchAction missing handler for \(action.rawValue, privacy: .public) — add a case or fix action.category")
            assertionFailure("dispatchSearchAction missing handler for \(action) — add a case or fix action.category")
        }
    }

    private static func dispatchGhosttyAction(
        _ action: String,
        in scope: ShortcutScope,
        registry: any SurfaceViewProviding
    ) {
        guard let tab = scope.session.activeTab(in: scope.window),
              let leafID = tab.splitTree.effectiveFocusedLeafID,
              let view = registry.view(for: leafID),
              let surface = view.surface
        else { return }
        GhosttyFFI.performBindingAction(action, on: surface)
    }

}
