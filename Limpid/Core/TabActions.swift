// TabActions.swift
// Limpid — centralized verbs over WindowSession + SplitTree so keyboard
// shortcuts, menu items, and context menus all dispatch through the same
// surface. Each method is small and pure: pull the active tab, mutate its
// split tree, write it back.

import AppKit
import Foundation
import GhosttyKit
import OSLog

private let log = Logger(subsystem: "dev.limpid", category: "tab.actions")

extension Notification.Name {
    /// Posted by `TabActions.beginSearch` carrying the pane id as
    /// `object`. The search overlay observes this so it re-grabs
    /// keyboard focus when ⌘F is hit a second time while the overlay
    /// is already on screen.
    static let limpidSearchFocus = Notification.Name("dev.limpid.searchFocus")

    /// Posted by ⌘⇧R to start an inline rename on the active L2 tab.
    /// TabRow observes and flips its `isEditing` state when the
    /// notification carries its own tab id.
    static let limpidRenameActiveTab = Notification.Name("dev.limpid.renameActiveTab")

    /// Posted when the command palette opens so the overlay grabs focus.
    static let limpidCommandPaletteFocus = Notification.Name("dev.limpid.commandPaletteFocus")

    /// Posted by the chrome palette field when the user presses Enter.
    /// The `object` carries the `CommandPaletteAction` to execute.
    static let limpidCommandPaletteExecute = Notification.Name("dev.limpid.commandPaletteExecute")

    /// Toggle the notification history popover from the palette.
    static let limpidToggleNotificationHistory = Notification.Name("dev.limpid.toggleNotificationHistory")

    /// Open the Settings window from the palette.
    static let limpidOpenSettings = Notification.Name("dev.limpid.openSettings")
}

@MainActor
enum TabActions {

    // MARK: - Tab

    static func newTab(_ session: WindowSession) {
        session.openTabInActiveScope()
    }

    /// ⌘⇧R — start inline rename on the active L2 tab. Posts a
    /// notification with the tab id so the matching TabRow flips into
    /// edit mode without us having to plumb an `@State` binding through
    /// the L2 list / row hierarchy.
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
        triage: TriageState? = nil,
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
            // Drop the triage bookkeeping for the closed pane so the
            // viewed / dismissed dictionaries don't accumulate dead
            // entries across long sessions. UUIDs aren't reused, so
            // this is a pure cleanup — never affects live panes.
            triage?.forget(paneID: leafID)
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
            claudeSessionTracker: claudeSessionTracker,
            codexSessionTracker: codexSessionTracker,
            cwdEventTracker: cwdEventTracker
        )
    }

    /// Close every tab in the active L1 container. Triggered from the
    /// L2 chrome ellipsis menu. Shows one aggregate confirm
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

    /// Activate the Nth tab inside the L1-selected container. Used by
    /// ⌘1 … ⌘9 to map directly onto the L2 list the user is looking
    /// at (rather than the global tab array, which would jump around
    /// containers unexpectedly).
    static func activateTabInActiveContainer(at index: Int, in session: WindowSession) {
        let tabs = session.tabs(in: session.activeContainerID)
        guard index >= 0, index < tabs.count else { return }
        session.setActiveTab(tabs[index].id)
    }

    static func cycleTab(_ session: WindowSession, forward: Bool) {
        // Cycle within the currently-selected container — matches the
        // L2 list scope. If the L1 selection is empty we just bail.
        let visible = session.tabs(in: session.activeContainerID)
        guard !visible.isEmpty else { return }
        let current = session.activeTabID.flatMap { id in
            visible.firstIndex(where: { $0.id == id })
        } ?? 0
        let count = visible.count
        let next = forward
            ? (current + 1) % count
            : (current - 1 + count) % count
        session.setActiveTab(visible[next].id)
    }

    // MARK: - Split

    static func split(_ session: WindowSession, direction: SplitDirection) {
        guard let tab = session.activeTab else { return }
        let pivotID = tab.splitTree.focusedLeafID
            ?? tab.splitTree.allLeafIDs().first
        guard let pivotID else { return }
        session.update(tab.id) { t in
            let result = t.splitTree.insert(at: pivotID, direction: direction)
            t.splitTree = result.tree
            // Splitting while zoomed makes the new pane invisible — exit
            // zoom so the user sees the freshly-created sibling.
            t.zoomedLeafID = nil
        }
    }

    static func closeActivePane(
        _ session: WindowSession,
        registry: any SurfaceViewProviding,
        source: CloseConfirmer.Source = .keyboard,
        claudeSessionTracker: ClaudeSessionTracker? = nil,
        codexSessionTracker: CodexSessionTracker? = nil,
        cwdEventTracker: CwdEventTracker? = nil
    ) {
        guard let tab = session.activeTab else { return }
        guard let leafID = tab.splitTree.focusedLeafID
            ?? tab.splitTree.allLeafIDs().first
        else { return }
        guard CloseConfirmer.allow(.pane, source: source, paneIDs: [leafID]) else { return }
        session.update(tab.id) { t in
            let result = t.splitTree.remove(leafID)
            t.splitTree = result.tree
            // Clear zoom if the zoomed pane just disappeared.
            if let z = t.zoomedLeafID, !t.splitTree.contains(leafID: z) {
                t.zoomedLeafID = nil
            }
            // Drop the in-memory mirror for the closed leaf so a
            // future bootstrap doesn't keep resurrecting the entry.
            t.claudeSessions[leafID] = nil
            t.codexSessions[leafID] = nil
        }
        session.paneSearchStates.removeValue(forKey: leafID)
        registry.unregister(leafID)
        claudeSessionTracker?.didClosePane(leafID)
        codexSessionTracker?.didClosePane(leafID)
        cwdEventTracker?.didClosePane(leafID)
        // If the tab is now empty, close it altogether.
        if let refreshed = session.activeTab, refreshed.splitTree.isEmpty {
            session.closeTab(refreshed.id)
        } else if let refreshed = session.activeTab {
            // Reconcile any stray registry entries against the new tree.
            registry.reconcile(activeIDs: Set(refreshed.splitTree.allLeafIDs()))
        }
    }

    /// ⌥⌘←/↑/↓/→ — move keyboard focus to the adjacent pane in the
    /// requested direction. tmux `select-pane -L/U/D/R` analogue. Pulls
    /// the surface's NSView into firstResponder so subsequent typing
    /// lands in the new pane immediately.
    static func focusPane(
        _ session: WindowSession,
        registry: any SurfaceViewProviding,
        direction: SpatialDirection
    ) {
        guard let tab = session.activeTab else { return }
        // Zoom hides every leaf except the zoomed one — there's nothing
        // to navigate to while it's engaged.
        guard tab.zoomedLeafID == nil else { return }
        guard let current = tab.splitTree.focusedLeafID
            ?? tab.splitTree.allLeafIDs().first
        else { return }
        guard let next = tab.splitTree.neighborLeaf(of: current, direction: direction)
        else { return }
        session.update(tab.id) { t in
            t.splitTree.focusedLeafID = next
            // Mirror `SplitContainerView.onLeafFocus`: focus shift only,
            // never overwrite `tab.title`. The label is owned by the tab
            // (Claude/Codex agent prompt, or the latest OSC 2 stream) —
            // pulling each pane's last-known title up on focus would
            // make the tab name flicker across pane switches and collide
            // with the latest-agent-owner rule in
            // `GhosttyEventCoordinator.shouldPropagateTitle`.
        }
        // View may not be registered yet when focusPane fires the same
        // runloop tick as a split — SwiftUI hasn't mounted the new
        // pane's SurfaceView. Skip the firstResponder push in that
        // case; SurfaceView.viewDidMoveToWindow will grab it once the
        // view mounts. Do *not* "fix" this to crash on a missing view.
        if let view = registry.view(for: next) {
            view.window?.makeFirstResponder(view)
        }
    }

    /// Make `tabID` active, focus `paneID`, and pull keyboard focus to
    /// its surface. The target tab's SurfaceView may not be mounted yet
    /// (we just switched tabs); when it isn't, `viewDidMoveToWindow`
    /// grabs first responder on mount via the focusedLeafID we set —
    /// the same contract `focusPane` relies on. Internal so `TriageState`
    /// (the owner of the ⌘J cursor + WAITING row taps) can share this
    /// one focus-pull primitive with `TabActions`.
    static func activateAndFocus(
        _ session: WindowSession,
        registry: any SurfaceViewProviding,
        tabID: UUID,
        paneID: UUID
    ) {
        session.setActiveTab(tabID)
        session.update(tabID) { $0.splitTree.focusedLeafID = paneID }
        if let view = registry.view(for: paneID) {
            view.window?.makeFirstResponder(view)
        }
    }

    /// Toggle full-screen "zoom" for the focused pane within its tab.
    /// tmux Prefix+z — while zoomed, the L3 pane area renders only the
    /// zoomed leaf; the rest of the SplitTree stays intact so a second
    /// invocation restores the previous layout untouched.
    ///
    /// No-op when the active tab has a single leaf (nothing to zoom).
    static func toggleZoom(_ session: WindowSession) {
        guard let tab = session.activeTab else { return }
        guard tab.splitTree.allLeafIDs().count > 1 else { return }
        guard let focusID = tab.splitTree.focusedLeafID
            ?? tab.splitTree.allLeafIDs().first
        else { return }
        session.update(tab.id) { t in
            let entering = t.zoomedLeafID == nil
            t.zoomedLeafID = entering ? focusID : nil
            // When entering zoom, pin focusedLeafID to the same leaf so
            // the "zoomed leaf is the focused leaf" invariant holds even
            // if focusedLeafID was nil and we fell back to allLeafIDs.first.
            // Without this, a later closeActivePane could resolve focus
            // to a different leaf than the one the user sees zoomed.
            if entering { t.splitTree.focusedLeafID = focusID }
        }
    }

    /// Reset every split divider in the active tab back to 50/50. tmux
    /// `select-layout even-*` equivalent — most useful after one pane
    /// has drifted dominant from interactive drags.
    static func equalizeSplits(_ session: WindowSession) {
        guard let tab = session.activeTab else { return }
        session.update(tab.id) { t in
            t.splitTree = t.splitTree.equalize()
        }
    }

    // MARK: - Closed-tab restore (⌘⇧T)

    // MARK: - L1 container navigation (⌘[ / ⌘] / ⌘⌃1…9)

    static func cycleContainer(_ session: WindowSession, forward: Bool) {
        session.cycleTopLevelContainer(forward: forward)
    }

    static func activateContainer(at index: Int, in session: WindowSession) {
        session.activateTopLevelContainer(at: index)
    }

    // MARK: - In-pane search (⌘F / ⌘G / ⇧⌘G)

    /// Resolve the focused pane id of the active tab so the search
    /// actions know which surface to target.
    private static func focusedPaneID(_ session: WindowSession) -> UUID? {
        guard let tab = session.activeTab else { return nil }
        return tab.splitTree.focusedLeafID ?? tab.splitTree.allLeafIDs().first
    }

    /// ⌘F — show the search overlay on the focused pane. Idempotent:
    /// if a state already exists, focus it (the overlay observes
    /// `paneSearchStates` and re-grabs focus on the next render).
    static func beginSearch(_ session: WindowSession) {
        guard let id = focusedPaneID(session) else { return }
        if session.paneSearchStates[id] == nil {
            session.paneSearchStates[id] = PaneSearchState()
        }
        NotificationCenter.default.post(name: .limpidSearchFocus, object: id)
    }

    /// Drop the search state for a pane AND tell libghostty's
    /// renderer to tear its match highlights down. Used by Esc in the
    /// overlay, the close button, and (via registry) any future
    /// caller that wants to end search without going through the
    /// overlay. Single source of truth for "search lifetime ends".
    static func endSearch(
        _ session: WindowSession,
        registry: any SurfaceViewProviding,
        paneID: UUID
    ) {
        session.paneSearchStates[paneID] = nil
        guard let surface = registry.view(for: paneID)?.surface else { return }
        let action = "end_search"
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    /// ⌘G — jump to the next match for the focused pane, if any.
    static func searchNext(
        _ session: WindowSession,
        registry: any SurfaceViewProviding
    ) {
        guard let id = focusedPaneID(session),
              session.paneSearchStates[id] != nil,
              let view = registry.view(for: id),
              let surface = view.surface
        else { return }
        let action = "navigate_search:next"
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    /// ⇧⌘G — jump to the previous match.
    static func searchPrevious(
        _ session: WindowSession,
        registry: any SurfaceViewProviding
    ) {
        guard let id = focusedPaneID(session),
              session.paneSearchStates[id] != nil,
              let view = registry.view(for: id),
              let surface = view.surface
        else { return }
        let action = "navigate_search:previous"
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    // MARK: - Pane close that cascades into the tab when last (⌘W)

    /// iTerm2-style ⌘W: close the focused pane; if the tab has only
    /// one pane left after that, close the tab too. Both branches
    /// flow through `CloseConfirmer` so the confirm policy is honored
    /// regardless of which branch we end up taking.
    static func closeActivePaneOrTab(
        _ session: WindowSession,
        registry: any SurfaceViewProviding,
        source: CloseConfirmer.Source = .keyboard,
        claudeSessionTracker: ClaudeSessionTracker? = nil,
        codexSessionTracker: CodexSessionTracker? = nil,
        cwdEventTracker: CwdEventTracker? = nil
    ) {
        guard let tab = session.activeTab else { return }
        let leafCount = tab.splitTree.allLeafIDs().count
        if leafCount <= 1 {
            closeActiveTab(
                session,
                registry: registry,
                source: source,
                claudeSessionTracker: claudeSessionTracker,
                codexSessionTracker: codexSessionTracker,
                cwdEventTracker: cwdEventTracker
            )
        } else {
            closeActivePane(
                session,
                registry: registry,
                source: source,
                claudeSessionTracker: claudeSessionTracker,
                codexSessionTracker: codexSessionTracker,
                cwdEventTracker: cwdEventTracker
            )
        }
    }

    // MARK: - Container deletion (frees SurfaceViews too)

    /// Delete a Group + every tab/pane it contained, unregistering the
    /// affected SurfaceViews so the registry doesn't leak.
    static func removeGroup(
        _ session: WindowSession,
        registry: any SurfaceViewProviding,
        groupID: UUID
    ) {
        let leafIDs = session.removeGroup(groupID)
        for id in leafIDs {
            registry.unregister(id)
        }
    }

    /// Delete a Project (worktrees + project-direct tabs) and free
    /// every SurfaceView that lived inside.
    static func removeProject(
        _ session: WindowSession,
        registry: any SurfaceViewProviding,
        projectID: UUID
    ) {
        let leafIDs = session.removeProject(projectID)
        for id in leafIDs {
            registry.unregister(id)
        }
    }

    /// Drop a single worktree row + close every tab in it. Used for
    /// orphan / missing rows and after a successful
    /// `git worktree remove`. Hide-from-sidebar uses `hideWorktree`
    /// instead because that flow needs to keep tabs alive.
    static func removeWorktree(
        _ session: WindowSession,
        registry: any SurfaceViewProviding,
        projectID: UUID,
        worktreeID: UUID
    ) {
        let leafIDs = session.removeWorktree(projectID: projectID, worktreeID: worktreeID)
        for id in leafIDs {
            registry.unregister(id)
        }
    }

    /// Prune all `isMissing` rows under a project and free their
    /// SurfaceViews.
    static func pruneMissingWorktrees(
        _ session: WindowSession,
        registry: any SurfaceViewProviding,
        projectID: UUID
    ) {
        let leafIDs = session.pruneMissingWorktrees(projectID: projectID)
        for id in leafIDs {
            registry.unregister(id)
        }
    }

    /// Async wrapper around `WindowSession.deleteGitWorktree` that
    /// also frees the affected SurfaceViews on success.
    static func deleteGitWorktree(
        _ session: WindowSession,
        registry: any SurfaceViewProviding,
        projectID: UUID,
        worktreeID: UUID,
        force: Bool
    ) async throws {
        let leafIDs = try await session.deleteGitWorktree(
            projectID: projectID,
            worktreeID: worktreeID,
            force: force
        )
        for id in leafIDs {
            registry.unregister(id)
        }
    }

    // MARK: - Command Palette

    static func openCommandPalette(
        _ session: WindowSession,
        settings: SettingsStore,
        frecencyStore: FrecencyStore,
        initialQuery: String = ">"
    ) {
        if session.commandPaletteState != nil {
            NotificationCenter.default.post(name: .limpidCommandPaletteFocus, object: nil)
            return
        }
        let state = CommandPaletteState()
        state.allItems = CommandPaletteCatalog.buildItems(session: session, settings: settings)
        state.initialQuery = initialQuery.isEmpty ? nil : initialQuery
        state.applyFilter(query: "", frecencyStore: frecencyStore)
        session.commandPaletteState = state
    }

    static func closeCommandPalette(_ session: WindowSession) {
        session.commandPaletteState = nil
    }

    static func executeCommandPaletteAction(
        _ action: CommandPaletteAction,
        session: WindowSession,
        triage: TriageState,
        registry: any SurfaceViewProviding,
        frecencyStore: FrecencyStore,
        claudeSessionTracker: ClaudeSessionTracker? = nil,
        codexSessionTracker: CodexSessionTracker? = nil,
        cwdEventTracker: CwdEventTracker? = nil
    ) {
        closeCommandPalette(session)
        frecencyStore.record(action.frecencyKey)

        switch action {
        case let .shortcutAction(shortcut):
            dispatchShortcutAction(
                shortcut,
                session: session,
                triage: triage,
                registry: registry,
                trackers: SessionTrackers(
                    claude: claudeSessionTracker,
                    codex: codexSessionTracker,
                    cwdEvent: cwdEventTracker
                )
            )
        case let .jumpToTab(tabID):
            if let tab = session.tab(tabID) {
                session.setActiveContainer(tab.container)
                session.setActiveTab(tabID)
            }
        case let .activateGroup(groupID):
            session.setActiveContainer(.group(groupID))
        case let .activateProject(projectID):
            session.setActiveContainer(.project(projectID))
        case let .activateWorktree(pid, wid):
            session.setActiveContainer(.worktree(projectID: pid, worktreeID: wid))
        case let .reopenClosedTab(tabID):
            reopenClosedTab(session, specificID: tabID)
        case let .openRecentProject(url):
            session.addOrActivateProject(rootURL: url)
        case .openSettings:
            NotificationCenter.default.post(name: .limpidOpenSettings, object: nil)
        case .insertPrefix:
            break // Handled in ChromePaletteField, never reaches here.
        }

        // Restore focus to the terminal surface.
        if let tab = session.activeTab,
           let leafID = tab.splitTree.focusedLeafID ?? tab.splitTree.allLeafIDs().first,
           let view = registry.view(for: leafID)
        {
            view.window?.makeFirstResponder(view)
        }
    }

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

    private static func dispatchShortcutAction(
        _ action: LimpidShortcutAction,
        session: WindowSession,
        triage: TriageState,
        registry: any SurfaceViewProviding,
        trackers: SessionTrackers
    ) {
        switch action.category {
        case .file:
            dispatchFileAction(
                action,
                session: session,
                registry: registry,
                trackers: trackers
            )
        case .view:
            dispatchViewAction(action, session: session)
        case .navigation:
            dispatchNavigationAction(action, session: session, triage: triage, registry: registry)
        case .splits:
            dispatchSplitAction(action, session: session, registry: registry)
        case .search:
            dispatchSearchAction(action, session: session, registry: registry)
        case .terminal, .font:
            guard let ghosttyAction = action.ghosttyAction else { return }
            dispatchGhosttyAction(ghosttyAction, session: session, registry: registry)
        }
    }

    private static func dispatchFileAction(
        _ action: LimpidShortcutAction,
        session: WindowSession,
        registry: any SurfaceViewProviding,
        trackers: SessionTrackers
    ) {
        switch action {
        case .newTab: newTab(session)
        case .newWorktree:
            NotificationCenter.default.post(name: .limpidCreateWorktreeRequested, object: nil)
        case .renameTab: renameActiveTab(session)
        case .reopenClosedTab: reopenClosedTab(session)
        case .closeSurface:
            closeActivePaneOrTab(
                session,
                registry: registry,
                claudeSessionTracker: trackers.claude,
                codexSessionTracker: trackers.codex,
                cwdEventTracker: trackers.cwdEvent
            )
        case .closeTab:
            closeActiveTab(
                session,
                registry: registry,
                claudeSessionTracker: trackers.claude,
                codexSessionTracker: trackers.codex,
                cwdEventTracker: trackers.cwdEvent
            )
        default: break
        }
    }

    private static func dispatchViewAction(
        _ action: LimpidShortcutAction,
        session: WindowSession
    ) {
        switch action {
        case .toggleSidebar: session.sidebarHidden.toggle()
        case .toggleTabLayout: session.l2Horizontal.toggle()
        case .notificationHistory:
            NotificationCenter.default.post(name: .limpidToggleNotificationHistory, object: nil)
        case .commandPalette, .quickOpen: break
        default: break
        }
    }

    private static func dispatchNavigationAction(
        _ action: LimpidShortcutAction,
        session: WindowSession,
        triage: TriageState,
        registry: any SurfaceViewProviding
    ) {
        switch action {
        case .nextSection: cycleContainer(session, forward: true)
        case .previousSection: cycleContainer(session, forward: false)
        case .nextTab: cycleTab(session, forward: true)
        case .previousTab: cycleTab(session, forward: false)
        case .nextAttention:
            triage.jumpToAttention(in: session, registry: registry, forward: true)
        case .previousAttention:
            triage.jumpToAttention(in: session, registry: registry, forward: false)
        default: break
        }
    }

    private static func dispatchSplitAction(
        _ action: LimpidShortcutAction,
        session: WindowSession,
        registry: any SurfaceViewProviding
    ) {
        switch action {
        case .splitRight: split(session, direction: .horizontal)
        case .splitDown: split(session, direction: .vertical)
        case .equalizeSplits: equalizeSplits(session)
        case .toggleSplitZoom: toggleZoom(session)
        case .focusPaneLeft: focusPane(session, registry: registry, direction: .left)
        case .focusPaneRight: focusPane(session, registry: registry, direction: .right)
        case .focusPaneUp: focusPane(session, registry: registry, direction: .up)
        case .focusPaneDown: focusPane(session, registry: registry, direction: .down)
        default: break
        }
    }

    private static func dispatchSearchAction(
        _ action: LimpidShortcutAction,
        session: WindowSession,
        registry: any SurfaceViewProviding
    ) {
        switch action {
        case .find: beginSearch(session)
        case .findNext: searchNext(session, registry: registry)
        case .findPrevious: searchPrevious(session, registry: registry)
        default: break
        }
    }

    private static func dispatchGhosttyAction(
        _ action: String,
        session: WindowSession,
        registry: any SurfaceViewProviding
    ) {
        guard let tab = session.activeTab,
              let leafID = tab.splitTree.focusedLeafID ?? tab.splitTree.allLeafIDs().first,
              let view = registry.view(for: leafID),
              let surface = view.surface
        else { return }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

}
