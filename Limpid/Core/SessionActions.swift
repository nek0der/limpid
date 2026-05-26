// SessionActions.swift
// Limpid — centralized verbs over WindowSession + SplitTree so keyboard
// shortcuts, menu items, and context menus all dispatch through the same
// surface. Each method is small and pure: pull the active tab, mutate its
// split tree, write it back.

import Foundation
import GhosttyKit
import OSLog

private let log = Logger(subsystem: "dev.limpid", category: "session.actions")

extension Notification.Name {
    /// Posted by `SessionActions.beginSearch` carrying the pane id as
    /// `object`. The search overlay observes this so it re-grabs
    /// keyboard focus when ⌘F is hit a second time while the overlay
    /// is already on screen.
    static let limpidSearchFocus = Notification.Name("dev.limpid.searchFocus")

    /// Posted by ⌘⇧R to start an inline rename on the active L2 tab.
    /// TabRow observes and flips its `isEditing` state when the
    /// notification carries its own tab id.
    static let limpidRenameActiveTab = Notification.Name("dev.limpid.renameActiveTab")
}

@MainActor
enum SessionActions {

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
    /// place. All call sites (TabRow's per-row close button,
    /// closeActiveTab from ⌘W, closeAllTabsInActiveContainer from the
    /// ellipsis menu) funnel through here.
    static func closeTab(
        _ session: WindowSession,
        registry: any SurfaceViewProviding,
        tabID: UUID,
        claudeSessionTracker: ClaudeSessionTracker? = nil
    ) {
        guard let tab = session.tab(tabID) else { return }
        let leafIDs = tab.splitTree.allLeafIDs()

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
        }
    }

    /// ⌘⇧T — pop the most-recently-closed tab back. Mints fresh pane
    /// IDs (the old SurfaceViews are gone, and Limpid uses paneID as
    /// the surface registry key — collisions would point at nothing),
    /// remaps every paneID-keyed field on the Tab, and appends it.
    /// SwiftUI then mounts a new PaneHostView per leaf and the
    /// existing `stageScrollback` path replays each `.vt` above the
    /// fresh shell prompt — the same machinery ⌘Q + restart uses.
    static func reopenClosedTab(_ session: WindowSession) {
        guard let closed = session.popClosedTab() else { return }

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
            claudeSessions: remapKeys(closed.tab.claudeSessions, using: idMap)
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
        claudeSessionTracker: ClaudeSessionTracker? = nil
    ) {
        guard let id = session.activeTabID else { return }
        closeTab(
            session,
            registry: registry,
            tabID: id,
            claudeSessionTracker: claudeSessionTracker
        )
    }

    /// Close every tab in the active L1 container. Triggered from the
    /// L2 chrome ellipsis menu.
    static func closeAllTabsInActiveContainer(
        _ session: WindowSession,
        registry: any SurfaceViewProviding,
        claudeSessionTracker: ClaudeSessionTracker? = nil
    ) {
        let ids = session.tabs(in: session.activeContainerID).map(\.id)
        for tabID in ids {
            closeTab(
                session,
                registry: registry,
                tabID: tabID,
                claudeSessionTracker: claudeSessionTracker
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
        claudeSessionTracker: ClaudeSessionTracker? = nil
    ) {
        guard let tab = session.activeTab else { return }
        guard let leafID = tab.splitTree.focusedLeafID
            ?? tab.splitTree.allLeafIDs().first
        else { return }
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
        }
        session.paneSearchStates.removeValue(forKey: leafID)
        registry.unregister(leafID)
        claudeSessionTracker?.didClosePane(leafID)
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
            // Mirror SplitContainerView.onLeafFocus — pull the new pane's
            // last-known title up so the window/tab label snaps to it.
            if let pulledTitle = registry.view(for: next)?.paneTitle {
                t.title = pulledTitle
            }
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
    /// one pane left after that, close the tab too. Matches what most
    /// terminal users expect from ⌘W.
    static func closeActivePaneOrTab(
        _ session: WindowSession,
        registry: any SurfaceViewProviding,
        claudeSessionTracker: ClaudeSessionTracker? = nil
    ) {
        guard let tab = session.activeTab else { return }
        let leafCount = tab.splitTree.allLeafIDs().count
        if leafCount <= 1 {
            closeActiveTab(
                session,
                registry: registry,
                claudeSessionTracker: claudeSessionTracker
            )
        } else {
            closeActivePane(
                session,
                registry: registry,
                claudeSessionTracker: claudeSessionTracker
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

}
