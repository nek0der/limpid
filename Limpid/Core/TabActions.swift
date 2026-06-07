// TabActions.swift
// Limpid — centralized verbs over WindowSession + SplitTree so keyboard
// shortcuts, menu items, and context menus all dispatch through the same
// surface. Each method is small and pure: pull the active tab, mutate its
// split tree, write it back.

import Foundation
import GhosttyKit
import OSLog

private let log = Logger.limpid("tab.actions")

extension Notification.Name {
    /// Posted by ⌘⇧R to start an inline rename on the active tab column tab.
    /// TabRow observes and flips its `isEditing` state when the
    /// notification carries its own tab id.
    static let limpidRenameActiveTab = Notification.Name("dev.limpid.renameActiveTab")

    /// Toggle the notification history popover from the palette.
    /// Posted from `TabActions.dispatchViewAction` so it stays
    /// colocated with the dispatch slice that emits it.
    static let limpidToggleNotificationHistory = Notification.Name("dev.limpid.toggleNotificationHistory")
}

/// A focused leaf and its neighbor on a given edge of the same tab.
/// Returned from `PaneActions.adjacentLeaf`; the focus, swap, and
/// menu-enabled paths each consume the same record.
struct PaneAdjacency {
    let tab: Tab
    let current: UUID
    let neighbor: UUID
}

@MainActor
enum TabActions {

    // MARK: - Tab

    static func newTab(_ session: WindowSession) {
        session.openTabInActiveScope()
    }

    /// ⌘⇧R — start inline rename on the active tab column tab. Posts a
    /// notification with the tab id so the matching TabRow flips into
    /// edit mode without us having to plumb an `@State` binding through
    /// the tab column list / row hierarchy.
    static func renameActiveTab(_ session: WindowSession) {
        guard let tabID = session.activeTabID else { return }
        NotificationCenter.default.post(name: .limpidRenameActiveTab, object: tabID)
    }

    /// Single entry point for closing a tab so the "snapshot leaves →
    /// closeTab → unregister leaves" cleanup pattern lives in one
    /// place. All user-initiated call sites (TabRow's ×, ⌘W cascade,
    /// libghostty's ⌘⌥W, the ellipsis "Close All" menu) funnel
    /// through here, which is also the single chokepoint that
    /// consults `CloseConfirmer` — so the agent-aware modal is
    /// impossible to bypass from a new caller.
    static func closeTab(
        _ session: WindowSession,
        registry: any SurfaceViewProviding,
        tabID: UUID,
        source: CloseConfirmer.Source = .keyboard,
        confirm: Bool = true,
        attention: AttentionState? = nil,
        claudeSessionTracker: ClaudeSessionTracker? = nil,
        codexSessionTracker: CodexSessionTracker? = nil,
        cwdEventTracker: CwdEventTracker? = nil
    ) {
        guard let tab = session.tab(tabID) else { return }
        let leafIDs = tab.splitTree.allLeafIDs()
        // `confirm: false` is reserved for batch callers (e.g.
        // `closeAllTabsInActiveContainer`) that already showed an
        // aggregate prompt — without the opt-out we'd nag the user
        // once per tab inside the loop.
        if confirm,
           !CloseConfirmer.allow(.tab, source: source, paneIDs: leafIDs)
        {
            return
        }

        // Capture every pane's scrollback so reopen rebuilds the full
        // split layout, not just the focused leaf. Routes through the
        // shared helper so ⌘Q and per-tab close stay in lock-step on
        // filename / permissions / directory creation.
        var snapshot = tab
        var paths: [UUID: String] = [:]
        for pid in leafIDs {
            guard let view = registry.view(for: pid),
                  let url = WindowSession.captureScrollback(paneID: pid, view: view)
            else { continue }
            paths[pid] = url.path
        }
        snapshot.scrollbackPaths = paths
        session.recordClosedTab(snapshot)

        session.closeTab(tabID)
        for leafID in leafIDs {
            registry.unregister(leafID)
            // Drop each leaf's on-disk Claude session record. The
            // snapshot above still carries `claudeSessions` for an
            // in-session `reopenClosedTab` to honor; once the user
            // quits, the closed-tab stack is gone anyway and stale
            // records would sit there until the next bootstrap
            // cleanup pass swept them.
            claudeSessionTracker?.didClosePane(leafID)
            codexSessionTracker?.didClosePane(leafID)
            cwdEventTracker?.didClosePane(leafID)
            // Drop the attention bookkeeping for the closed pane so the
            // viewed / dismissed dictionaries don't accumulate dead
            // entries across long sessions. UUIDs aren't reused, so
            // this is a pure cleanup — never affects live panes.
            attention?.forget(paneID: leafID)
        }
    }

    /// ⌘⇧T — pop the most-recently-closed tab back. Mints fresh pane
    /// IDs (the old SurfaceViews are gone, and Limpid uses paneID as
    /// the surface registry key — collisions would point at nothing),
    /// remaps every paneID-keyed field on the Tab, and appends it.
    /// SwiftUI then mounts a new PaneHostView per leaf and the
    /// existing `stageScrollback` path replays each `.vt` above the
    /// fresh shell prompt — the same machinery ⌘Q + restart uses.
    static func reopenClosedTab(_ session: WindowSession, specificID: UUID? = nil) {
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
            // Carry the per-pane Claude session map across the
            // pane id remap so an in-session ⌘⇧T can still try a
            // resume on the revived leaf (best-effort — the disk
            // record was already dropped at close time).
            claudeSessions: remapKeys(closed.tab.claudeSessions, using: idMap),
            codexSessions: remapKeys(closed.tab.codexSessions, using: idMap)
        )
        // `scrollbackPaths` / `initialCommands` aren't in the Tab init
        // signature, so assign them after construction.
        revived.scrollbackPaths = remapKeys(closed.tab.scrollbackPaths, using: idMap)
        revived.initialCommands = remapKeys(closed.tab.initialCommands, using: idMap)

        session.tabs.append(revived)
        session.setActiveTab(revived.id)
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
            if let new = mapping[old] { result[new] = value }
        }
        return result
    }

    static func closeActiveTab(
        _ session: WindowSession,
        registry: any SurfaceViewProviding,
        source: CloseConfirmer.Source = .keyboard,
        attention: AttentionState? = nil,
        claudeSessionTracker: ClaudeSessionTracker? = nil,
        codexSessionTracker: CodexSessionTracker? = nil,
        cwdEventTracker: CwdEventTracker? = nil
    ) {
        guard let id = session.activeTabID else { return }
        closeTab(
            session,
            registry: registry,
            tabID: id,
            source: source,
            attention: attention,
            claudeSessionTracker: claudeSessionTracker,
            codexSessionTracker: codexSessionTracker,
            cwdEventTracker: cwdEventTracker
        )
    }

    /// Close every tab in the active container. Triggered from the
    /// tab column toolbar ellipsis menu. Shows one aggregate confirm
    /// (`CloseConfirmer.allow(.allTabs, ...)`) up front, then loops
    /// with `confirm: false` so the per-tab `closeTab` doesn't
    /// re-prompt for every iteration.
    static func closeAllTabsInActiveContainer(
        _ session: WindowSession,
        registry: any SurfaceViewProviding,
        claudeSessionTracker: ClaudeSessionTracker? = nil,
        codexSessionTracker: CodexSessionTracker? = nil,
        cwdEventTracker: CwdEventTracker? = nil
    ) {
        let tabs = session.tabs(in: session.activeContainerID)
        guard !tabs.isEmpty else { return }
        let allLeafIDs = tabs.flatMap { $0.splitTree.allLeafIDs() }
        guard CloseConfirmer.allow(.allTabs, source: .mouse, paneIDs: allLeafIDs) else { return }
        for tab in tabs {
            closeTab(
                session,
                registry: registry,
                tabID: tab.id,
                confirm: false,
                claudeSessionTracker: claudeSessionTracker,
                codexSessionTracker: codexSessionTracker,
                cwdEventTracker: cwdEventTracker
            )
        }
    }

    // `activateTabInActiveContainer` + `cycleTab` moved to
    // `Limpid/Core/Actions/NavActions.swift`.

    // MARK: - Split + pane verbs

    // `split` / `closeActivePane` / `adjacentLeaf` / `pullKeyboardFocus`
    // / `focusPane` / `swapPane` / `activateAndFocus` / `toggleZoom` /
    // `equalizeSplits` moved to `Limpid/Core/Actions/PaneActions.swift`.

    // MARK: - Closed-tab restore (⌘⇧T)

    // MARK: - container navigation (⌘[ / ⌘] / ⌘⌃1…9)

    // `cycleContainer` + `activateContainer` moved to
    // `Limpid/Core/Actions/NavActions.swift`.

    // MARK: - In-pane search (⌘F / ⌘G / ⇧⌘G)

    // Moved to `Limpid/Core/Actions/SearchActions.swift`. See the file
    // header there for the namespace-split rationale.

    // MARK: - Pane close that cascades into the tab when last (⌘W)

    // `closeActivePaneOrTab` moved to
    // `Limpid/Core/Actions/PaneActions.swift`.

    // MARK: - Container deletion (frees SurfaceViews too)

    // `removeGroup` / `removeProject` / `removeWorktree` /
    // `pruneMissingWorktrees` / `deleteGitWorktree` moved to
    // `Limpid/Core/Actions/ContainerActions.swift`.

    // MARK: - Command Palette

    // `openCommandPalette` / `closeCommandPalette` /
    // `executeCommandPaletteAction` moved to
    // `Limpid/Core/Actions/CommandPaletteActions.swift`.

    /// Bundles the optional CLI-session and cwd-event trackers so the
    /// dispatcher chain stays under the parameter-count budget. The
    /// session trackers feed `--resume` plumbing; the cwd-event one
    /// keeps the worktree-move suggester's seen-map in sync with the
    /// close path.
    struct SessionTrackers {
        let claude: ClaudeSessionTracker?
        let codex: CodexSessionTracker?
        let cwdEvent: CwdEventTracker?
    }

    // swiftlint:disable function_parameter_count
    /// Promoted from `private` to module-internal so
    /// `CommandPaletteActions.executeCommandPaletteAction` can route
    /// `.shortcutAction` cases through the same dispatch chain the
    /// menu bar and keyboard shortcuts already use. `toastCenter` +
    /// `minPaneSize` ride along for `PaneActions.split`'s pre-flight
    /// geometry check.
    static func dispatchShortcutAction(
        _ action: LimpidShortcutAction,
        session: WindowSession,
        attention: AttentionState,
        registry: any SurfaceViewProviding,
        trackers: SessionTrackers,
        toastCenter: ToastCenter,
        minPaneSize: Double
    ) {
        switch action.category {
        case .file:
            dispatchFileAction(
                action,
                session: session,
                registry: registry,
                attention: attention,
                trackers: trackers
            )
        case .view:
            dispatchViewAction(action, session: session)
        case .navigation:
            dispatchNavigationAction(action, session: session, attention: attention, registry: registry)
        case .splits:
            dispatchSplitAction(
                action,
                session: session,
                registry: registry,
                toastCenter: toastCenter,
                minPaneSize: minPaneSize
            )
        case .search:
            dispatchSearchAction(action, session: session, registry: registry)
        case .terminal, .font:
            guard let ghosttyAction = action.ghosttyAction else { return }
            dispatchGhosttyAction(ghosttyAction, session: session, registry: registry)
        }
    }

    // swiftlint:enable function_parameter_count

    private static func dispatchFileAction(
        _ action: LimpidShortcutAction,
        session: WindowSession,
        registry: any SurfaceViewProviding,
        attention: AttentionState,
        trackers: SessionTrackers
    ) {
        switch action {
        case .newTab: newTab(session)
        case .newWorktree:
            NotificationCenter.default.post(name: .limpidCreateWorktreeRequested, object: nil)
        case .renameTab: renameActiveTab(session)
        case .reopenClosedTab: reopenClosedTab(session)
        case .closeSurface:
            PaneActions.closeActivePaneOrTab(
                session,
                registry: registry,
                attention: attention,
                claudeSessionTracker: trackers.claude,
                codexSessionTracker: trackers.codex,
                cwdEventTracker: trackers.cwdEvent
            )
        case .closeTab:
            closeActiveTab(
                session,
                registry: registry,
                attention: attention,
                claudeSessionTracker: trackers.claude,
                codexSessionTracker: trackers.codex,
                cwdEventTracker: trackers.cwdEvent
            )
        default:
            log.fault("dispatchFileAction missing handler for \(action.rawValue, privacy: .public) — add a case or fix action.category")
            assertionFailure("dispatchFileAction missing handler for \(action) — add a case or fix action.category")
        }
    }

    private static func dispatchViewAction(
        _ action: LimpidShortcutAction,
        session: WindowSession
    ) {
        switch action {
        case .toggleSidebar: session.sidebarHidden.toggle()
        case .toggleTabLayout: session.tabColumnHorizontal.toggle()
        case .notificationHistory:
            NotificationCenter.default.post(name: .limpidToggleNotificationHistory, object: nil)
        // Palette / quick-open share the .view category but are
        // launched from `AppState` shortcuts rather than this dispatch
        // path — they intentionally no-op here.
        case .commandPalette, .quickOpen: break
        default:
            log.fault("dispatchViewAction missing handler for \(action.rawValue, privacy: .public) — add a case or fix action.category")
            assertionFailure("dispatchViewAction missing handler for \(action) — add a case or fix action.category")
        }
    }

    private static func dispatchNavigationAction(
        _ action: LimpidShortcutAction,
        session: WindowSession,
        attention: AttentionState,
        registry: any SurfaceViewProviding
    ) {
        switch action {
        case .nextSection: NavActions.cycleContainer(session, forward: true)
        case .previousSection: NavActions.cycleContainer(session, forward: false)
        case .nextTab: NavActions.cycleTab(session, forward: true)
        case .previousTab: NavActions.cycleTab(session, forward: false)
        case .nextAttention:
            attention.jumpToAttention(in: session, registry: registry, forward: true)
        case .previousAttention:
            attention.jumpToAttention(in: session, registry: registry, forward: false)
        default:
            log
                .fault(
                    "dispatchNavigationAction missing handler for \(action.rawValue, privacy: .public) — add a case or fix action.category"
                )
            assertionFailure("dispatchNavigationAction missing handler for \(action) — add a case or fix action.category")
        }
    }

    private static func dispatchSplitAction(
        _ action: LimpidShortcutAction,
        session: WindowSession,
        registry: any SurfaceViewProviding,
        toastCenter: ToastCenter,
        minPaneSize: Double
    ) {
        switch action {
        case .splitRight:
            PaneActions.split(
                session,
                direction: .horizontal,
                registry: registry,
                minPaneSize: minPaneSize,
                toastCenter: toastCenter
            )
        case .splitDown:
            PaneActions.split(
                session,
                direction: .vertical,
                registry: registry,
                minPaneSize: minPaneSize,
                toastCenter: toastCenter
            )
        case .equalizeSplits: PaneActions.equalizeSplits(session)
        case .toggleSplitZoom: PaneActions.toggleZoom(session)
        case .focusPaneLeft: PaneActions.focusPane(session, registry: registry, direction: .left)
        case .focusPaneRight: PaneActions.focusPane(session, registry: registry, direction: .right)
        case .focusPaneUp: PaneActions.focusPane(session, registry: registry, direction: .up)
        case .focusPaneDown: PaneActions.focusPane(session, registry: registry, direction: .down)
        default:
            log.fault("dispatchSplitAction missing handler for \(action.rawValue, privacy: .public) — add a case or fix action.category")
            assertionFailure("dispatchSplitAction missing handler for \(action) — add a case or fix action.category")
        }
    }

    private static func dispatchSearchAction(
        _ action: LimpidShortcutAction,
        session: WindowSession,
        registry: any SurfaceViewProviding
    ) {
        switch action {
        case .find: SearchActions.beginSearch(session)
        case .findNext: SearchActions.searchNext(session, registry: registry)
        case .findPrevious: SearchActions.searchPrevious(session, registry: registry)
        default:
            log.fault("dispatchSearchAction missing handler for \(action.rawValue, privacy: .public) — add a case or fix action.category")
            assertionFailure("dispatchSearchAction missing handler for \(action) — add a case or fix action.category")
        }
    }

    private static func dispatchGhosttyAction(
        _ action: String,
        session: WindowSession,
        registry: any SurfaceViewProviding
    ) {
        guard let tab = session.activeTab,
              let leafID = tab.splitTree.effectiveFocusedLeafID,
              let view = registry.view(for: leafID),
              let surface = view.surface
        else { return }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

}
