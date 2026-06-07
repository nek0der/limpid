// PaneActions.swift
// Limpid — verbs over `SplitTree` and pane focus / zoom / swap. Largest
// slice from the `TabActions` namespace split (10 methods): split,
// close, focus, swap, activate-and-focus, toggleZoom, equalize, and
// the ⌘W cascade that closes the tab when the focused pane was last.
// See `SearchActions` for the pattern.

import AppKit
import Foundation

@MainActor
enum PaneActions {

    // MARK: - Split

    /// ⌘D / ⌘⇧D — split the focused pane in the given direction.
    /// Exits zoom so the freshly-inserted sibling is visible.
    ///
    /// Pass `registry` + `minPaneSize` + `toastCenter` to enable the
    /// pre-flight geometry check: when the focused pane's measured
    /// extent on the split axis can't accommodate `2 × minPaneSize +
    /// 6pt` (the divider), the split is rejected and an info toast is
    /// shown instead of producing a 1-pixel pane. All three are
    /// optional so unit tests can drive `split` without an attached
    /// view tree — pass none and the call goes straight through.
    static func split(
        _ session: WindowSession,
        direction: SplitDirection,
        registry: (any SurfaceViewProviding)? = nil,
        minPaneSize: Double = 0,
        toastCenter: ToastCenter? = nil
    ) {
        guard let tab = session.activeTab else { return }
        let pivotID = tab.splitTree.effectiveFocusedLeafID
        guard let pivotID else { return }

        // Pre-flight: would the new sibling fit? Mirrors
        // `SplitContainerView.dividerThickness = 6`. We keep the
        // constant inline rather than reaching across the UI layer
        // for an inert value — drift would be caught by the same
        // visual review that placed it there.
        if let registry, let toastCenter, minPaneSize > 0,
           let view = registry.view(for: pivotID)
        {
            let need = CGFloat(2 * minPaneSize) + 6
            let extent = direction == .horizontal ? view.frame.width : view.frame.height
            if extent < need {
                toastCenter.show(ToastItem(
                    message: String(localized: "Not enough room to split"),
                    undo: nil
                ))
                return
            }
        }

        session.update(tab.id) { t in
            let result = t.splitTree.insert(at: pivotID, direction: direction)
            t.splitTree = result.tree
            // Splitting while zoomed makes the new pane invisible — exit
            // zoom so the user sees the freshly-created sibling.
            t.zoomedLeafID = nil
        }
    }

    // MARK: - Close

    /// Close the focused pane without falling through to the tab even
    /// when it's the last one. The ⌘W "close pane or tab" cascade lives
    /// on `closeActivePaneOrTab` below.
    static func closeActivePane(
        _ session: WindowSession,
        registry: any SurfaceViewProviding,
        source: CloseConfirmer.Source = .keyboard,
        attention: AttentionState? = nil,
        claudeSessionTracker: ClaudeSessionTracker? = nil,
        codexSessionTracker: CodexSessionTracker? = nil,
        cwdEventTracker: CwdEventTracker? = nil
    ) {
        guard let tab = session.activeTab else { return }
        guard let leafID = tab.splitTree.effectiveFocusedLeafID
        else { return }
        guard CloseConfirmer.allow(.pane, source: source, paneIDs: [leafID]) else { return }
        session.update(tab.id) { t in
            let result = t.splitTree.remove(leafID)
            t.splitTree = result.tree
            // Clear zoom if the zoomed pane just disappeared.
            if let z = t.zoomedLeafID, !t.splitTree.contains(leafID: z) {
                t.zoomedLeafID = nil
            }
            // Drop every per-pane dictionary entry for the closed
            // leaf. `claudeSessions` / `codexSessions` were already
            // swept here; the other five (paneStates, scrollbackPaths,
            // initialCommands, claudeAgentBadges, codexAgentBadges)
            // are persisted through `SessionSnapshot` and used to
            // accumulate on disk on every ⌘W against a multi-pane
            // tab. `mergePaneIntoTab` already sweeps the same set on
            // its leaf-out path — keep the two close-leaf paths
            // structurally identical.
            t.claudeSessions[leafID] = nil
            t.codexSessions[leafID] = nil
            t.paneStates.removeValue(forKey: leafID)
            t.scrollbackPaths.removeValue(forKey: leafID)
            t.initialCommands.removeValue(forKey: leafID)
            t.claudeAgentBadges.removeValue(forKey: leafID)
            t.codexAgentBadges.removeValue(forKey: leafID)
        }
        session.paneSearchStates.removeValue(forKey: leafID)
        registry.unregister(leafID)
        claudeSessionTracker?.didClosePane(leafID)
        codexSessionTracker?.didClosePane(leafID)
        cwdEventTracker?.didClosePane(leafID)
        // `AttentionState`'s dismiss/viewed dictionaries are pane-id
        // keyed and session-scoped. `TabActions.closeTab` already
        // forgets every leaf in the closing tab; the close-split
        // path must mirror that or the entries leak across the
        // session for every ⌘W against a multi-pane tab.
        attention?.forget(paneID: leafID)
        // If the tab is now empty, close it altogether.
        if let refreshed = session.activeTab, refreshed.splitTree.isEmpty {
            session.closeTab(refreshed.id)
        } else {
            // Reconcile registry entries against EVERY tab's leaves —
            // not just the active tab's. Passing only the active tab's
            // ids would wipe surfaces in other tabs, and the next visit
            // to one of those tabs would spawn a fresh shell in place
            // of the (still-alive) leaf.
            let allLive = Set(session.tabs.flatMap { $0.splitTree.allLeafIDs() })
            registry.reconcile(activeIDs: allLive)
            // Promote the surviving sibling to first responder —
            // SwiftUI's reparent on close does NOT re-fire
            // `viewDidMoveToWindow`, so the just-closed pane's
            // `SurfaceView` leaves the responder chain and AppKit
            // falls back to the window itself. Without this pull,
            // the next keystroke is silently dropped on the floor
            // until the user clicks the surviving pane.
            if let surviving = session.activeTab?.splitTree.effectiveFocusedLeafID {
                pullKeyboardFocus(to: surviving, registry: registry)
            }
        }
    }

    /// ⌘W cascade: close the focused pane; if the tab has only one
    /// pane left after that, close the tab too. Both branches flow
    /// through `CloseConfirmer` so the confirm policy is honored
    /// regardless of which branch we end up taking.
    static func closeActivePaneOrTab(
        _ session: WindowSession,
        registry: any SurfaceViewProviding,
        source: CloseConfirmer.Source = .keyboard,
        attention: AttentionState? = nil,
        claudeSessionTracker: ClaudeSessionTracker? = nil,
        codexSessionTracker: CodexSessionTracker? = nil,
        cwdEventTracker: CwdEventTracker? = nil
    ) {
        guard let tab = session.activeTab else { return }
        let leafCount = tab.splitTree.allLeafIDs().count
        if leafCount <= 1 {
            TabActions.closeActiveTab(
                session,
                registry: registry,
                source: source,
                attention: attention,
                claudeSessionTracker: claudeSessionTracker,
                codexSessionTracker: codexSessionTracker,
                cwdEventTracker: cwdEventTracker
            )
        } else {
            closeActivePane(
                session,
                registry: registry,
                source: source,
                attention: attention,
                claudeSessionTracker: claudeSessionTracker,
                codexSessionTracker: codexSessionTracker,
                cwdEventTracker: cwdEventTracker
            )
        }
    }

    // MARK: - Focus + adjacency

    /// The neighbor leaf reachable from the active tab's focused pane
    /// in `direction`, plus the resolved tab and current leaf. `nil`
    /// when there's no active tab, the tab is zoomed (every leaf but
    /// one is hidden, so there's nowhere to go), or no neighbor exists
    /// on that edge. Single source of truth for the focus / swap
    /// actions and the Pane menu's per-direction enabled state.
    static func adjacentLeaf(
        _ session: WindowSession,
        direction: SpatialDirection
    ) -> PaneAdjacency? {
        guard let tab = session.activeTab, tab.zoomedLeafID == nil,
              let current = tab.splitTree.effectiveFocusedLeafID,
              let neighbor = tab.splitTree.neighborLeaf(of: current, direction: direction)
        else { return nil }
        return PaneAdjacency(tab: tab, current: current, neighbor: neighbor)
    }

    /// Pull AppKit first responder to `paneID`'s surface when it's
    /// mounted. When it isn't yet — a split / tab switch in the same
    /// runloop tick, before SwiftUI mounts the `SurfaceView` — we
    /// skip; `viewDidMoveToWindow` grabs focus on mount via the
    /// `focusedLeafID` the caller set. Do *not* "fix" the nil view by
    /// crashing.
    static func pullKeyboardFocus(to paneID: UUID, registry: any SurfaceViewProviding) {
        guard let view = registry.view(for: paneID) else { return }
        view.window?.makeFirstResponder(view)
    }

    /// ⌥⌘←/↑/↓/→ — move keyboard focus to the adjacent pane in the
    /// requested direction. tmux `select-pane -L/U/D/R` analogue.
    static func focusPane(
        _ session: WindowSession,
        registry: any SurfaceViewProviding,
        direction: SpatialDirection
    ) {
        guard let adjacency = adjacentLeaf(session, direction: direction) else { return }
        // Focus shift only — never overwrite `tab.title`. The label is
        // owned by the tab (agent prompt or latest OSC 2); pulling each
        // pane's last-known title up on focus would make the name
        // flicker and collide with
        // `GhosttyEventCoordinator.shouldPropagateTitle`.
        session.update(adjacency.tab.id) { $0.splitTree.focusedLeafID = adjacency.neighbor }
        pullKeyboardFocus(to: adjacency.neighbor, registry: registry)
    }

    /// ⌥⌘⇧←/↑/↓/→ — swap the focused pane with its neighbor in the
    /// requested direction. Each slot keeps its geometry; only the two
    /// panes trade places (tmux `swap-pane`). Focus follows the moved
    /// pane to its new slot, and a brief flash marks where it landed.
    /// No-op while zoomed or when there's no neighbor.
    static func swapPane(
        _ session: WindowSession,
        registry: any SurfaceViewProviding,
        direction: SpatialDirection
    ) {
        guard let adjacency = adjacentLeaf(session, direction: direction) else { return }
        // `swappingLeaves` moves focus to `current`, so it follows the
        // pane.
        session.update(adjacency.tab.id) {
            $0.splitTree = $0.splitTree.swappingLeaves(adjacency.current, adjacency.neighbor)
        }
        pullKeyboardFocus(to: adjacency.current, registry: registry)
        flashPane(adjacency.current, session: session)
    }

    /// Make `tabID` active, focus `paneID`, and pull keyboard focus to
    /// it. Shared with `AttentionState` (the ⌘J cursor + Waiting row
    /// taps) so the focus-pull primitive is single-source.
    static func activateAndFocus(
        _ session: WindowSession,
        registry: any SurfaceViewProviding,
        tabID: UUID,
        paneID: UUID
    ) {
        session.setActiveTab(tabID)
        session.update(tabID) { t in
            // Exit zoom if the jump target is not the zoomed leaf —
            // otherwise `PaneAreaView` keeps showing the (still-zoomed)
            // pane while `focusedLeafID` claims focus moved to an
            // off-screen leaf, and a follow-up ⌘W silently destroys
            // the unseen pane. ⌘J / Waiting-list taps are specifically
            // designed for cross-pane navigation, so this path is
            // routine.
            if let zoomed = t.zoomedLeafID, zoomed != paneID {
                t.zoomedLeafID = nil
            }
            t.splitTree.focusedLeafID = paneID
        }
        pullKeyboardFocus(to: paneID, registry: registry)
    }

    // MARK: - Zoom + layout

    /// Toggle full-screen "zoom" for the focused pane within its tab.
    /// tmux Prefix+z — while zoomed, the terminal column pane area
    /// renders only the zoomed leaf; the rest of the SplitTree stays
    /// intact so a second invocation restores the previous layout
    /// untouched. No-op when the active tab has a single leaf.
    static func toggleZoom(_ session: WindowSession) {
        guard let tab = session.activeTab else { return }
        guard tab.splitTree.allLeafIDs().count > 1 else { return }
        guard let focusID = tab.splitTree.effectiveFocusedLeafID
        else { return }
        session.update(tab.id) { t in
            let entering = t.zoomedLeafID == nil
            t.zoomedLeafID = entering ? focusID : nil
            // When entering zoom, pin focusedLeafID to the same leaf
            // so the "zoomed leaf is the focused leaf" invariant holds
            // even if focusedLeafID was nil and we fell back to
            // `allLeafIDs.first`. Without this, a later
            // `closeActivePane` could resolve focus to a different
            // leaf than the one the user sees zoomed.
            if entering { t.splitTree.focusedLeafID = focusID }
        }
    }

    /// Reset every split divider in the active tab back to 50/50.
    /// tmux `select-layout even-*` equivalent — most useful after one
    /// pane has drifted dominant from interactive drags.
    static func equalizeSplits(_ session: WindowSession) {
        guard let tab = session.activeTab else { return }
        session.update(tab.id) { t in
            t.splitTree = t.splitTree.equalize()
        }
    }
}
