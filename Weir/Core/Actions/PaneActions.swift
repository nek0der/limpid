// PaneActions.swift
// Weir — verbs over `SplitTree` and pane focus / zoom / swap. Largest
// slice from the `TabActions` namespace split (10 methods): split,
// close, focus, swap, activate-and-focus, toggleZoom, equalize, and
// the ⌘W cascade that closes the tab when the focused pane was last.
// See `SearchActions` for the pattern.

import AppKit
import Foundation
import WeirDomain

@MainActor
enum PaneActions {

    // MARK: - Split

    /// ⌘D / ⌘⇧D — split the focused pane in the given direction.
    /// Exits zoom so the freshly-inserted sibling is visible.
    ///
    /// Pass `registry` + `minPaneSize` + `toastCenter` to enable the
    /// pre-flight geometry check. The candidate tree is compared with the
    /// complete rendered pane area so splitting a zoomed pane cannot reveal
    /// an undersized sibling when zoom is cleared. All three are optional so
    /// unit tests can drive `split` without an attached view tree.
    static func split(
        _ session: WorkspaceSession,
        direction: SplitDirection,
        registry: (any SurfaceViewProviding)? = nil,
        minPaneSize: PaneMinimumSize = .zero,
        toastCenter: ToastCenter? = nil,
        in window: WindowID
    ) {
        guard let tab = session.activeTab(in: window) else { return }
        let pivotID = tab.splitTree.effectiveFocusedLeafID
        guard let pivotID else { return }

        if let registry, let toastCenter, minPaneSize.isEnforced,
           let availableSize = renderedPaneAreaSize(
               tab: tab,
               pivotID: pivotID,
               registry: registry
           ),
           !hasRoomToSplit(
               tree: tab.splitTree,
               paneID: pivotID,
               direction: direction,
               availableSize: availableSize,
               minPaneSize: minPaneSize
           )
        {
            toastCenter.show(ToastItem(
                message: .localized("Not enough room to split"),
                undo: nil
            ), in: window)
            return
        }

        session.update(tab.id) { t in
            let result = t.splitTree.insert(at: pivotID, direction: direction)
            t.splitTree = result.tree
            // Splitting while zoomed makes the new pane invisible — exit
            // zoom so the user sees the freshly-created sibling.
            t.zoomedLeafID = nil
        }
    }

    /// Whether replacing a leaf with a split fits the complete pane area.
    static func hasRoomToSplit(
        tree: SplitTree,
        paneID: UUID,
        direction: SplitDirection,
        availableSize: CGSize,
        minPaneSize: PaneMinimumSize
    ) -> Bool {
        guard minPaneSize.isEnforced, tree.contains(leafID: paneID) else { return true }
        let candidate = tree.insert(at: paneID, direction: direction, newID: UUID()).tree
        return fitsPaneArea(candidate, replacing: tree, availableSize: availableSize, minPaneSize: minPaneSize)
    }

    /// Whether `candidate` fits a pane area of `availableSize` once it replaces
    /// `tree`. Splitting and dropping a pane on an edge both ask this. An
    /// already undersized area accepts a candidate only when it does not
    /// raise the requirement on either axis, so the reader can still
    /// rearrange a window that has been made too small.
    static func fitsPaneArea(
        _ candidate: SplitTree,
        replacing tree: SplitTree,
        availableSize: CGSize,
        minPaneSize: PaneMinimumSize
    ) -> Bool {
        guard let currentRoot = tree.root else { return true }
        guard let candidateRoot = candidate.root else { return false }
        func fits(_ axis: SplitDirection, available: CGFloat) -> Bool {
            let current = currentRoot.minimumExtent(along: axis, leafMinimum: minPaneSize)
            let required = candidateRoot.minimumExtent(along: axis, leafMinimum: minPaneSize)
            return required <= max(available, current) + 0.5
        }
        return fits(.horizontal, available: availableSize.width)
            && fits(.vertical, available: availableSize.height)
    }

    /// Resolve the pane area's visible size. A zoomed surface fills the whole
    /// area; otherwise the union of every mounted leaf includes all dividers.
    private static func renderedPaneAreaSize(
        tab: Tab,
        pivotID: UUID,
        registry: any SurfaceViewProviding
    ) -> CGSize? {
        if tab.zoomedLeafID != nil {
            guard let view = registry.view(for: pivotID), view.window != nil else { return nil }
            return view.bounds.size
        }
        return mountedPaneAreaSize(of: tab.splitTree, registry: registry)
    }

    /// The size of the union of every leaf's view, which includes the
    /// dividers between them, or nil while any leaf is not in a window.
    static func mountedPaneAreaSize(of tree: SplitTree, registry: any SurfaceViewProviding) -> CGSize? {
        let paneIDs = tree.allLeafIDs()
        let rects = paneIDs.compactMap { paneID -> CGRect? in
            guard let view = registry.view(for: paneID), view.window != nil else { return nil }
            return view.convert(view.bounds, to: nil)
        }
        guard rects.count == paneIDs.count, let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }.size
    }

    // MARK: - Close

    /// Close the focused pane without falling through to the tab even
    /// when it's the last one. The ⌘W "close pane or tab" cascade lives
    /// on `closeActivePaneOrTab` below, which passes
    /// `fallsThroughToTab`: its pane, left alone while the question was up,
    /// closes as its tab does.
    static func closeActivePane(
        _ session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        source: CloseConfirmer.Source = .keyboard,
        attention: AttentionState? = nil,
        agentProjection: AgentProjectionAdapter? = nil,
        in window: WindowID,
        fallsThroughToTab: Bool = false
    ) {
        guard let tab = session.activeTab(in: window) else { return }
        guard let leafID = tab.splitTree.effectiveFocusedLeafID
        else { return }
        let pane = ClosingPane(leafID: leafID, tabID: tab.id, window: window, fallsThroughToTab: fallsThroughToTab)
        CloseConfirmer.confirm(.pane, source: source, paneIDs: [leafID], window: window) {
            closePane(pane, session, registry: registry, agentProjection: agentProjection)
        }
    }

    /// The pane a close asked about, kept while the question is up.
    private struct ClosingPane {
        let leafID: UUID
        let tabID: UUID
        let window: WindowID
        /// Whether the pane, if it is its tab's last, closes as the tab
        /// does (⌘W's cascade).
        let fallsThroughToTab: Bool
    }

    /// Closes the pane the person asked to close, once allowed. The tab
    /// and the pane are read again here, not the window's active tab: a
    /// confirmation may have been up while the window moved to another tab.
    /// A sibling that ended meanwhile can leave the pane its tab's last;
    /// under ⌘W's cascade the tab then closes as a tab, so it can be
    /// reopened with its scrollback.
    private static func closePane(
        _ pane: ClosingPane,
        _ session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        agentProjection: AgentProjectionAdapter?
    ) {
        let leafID = pane.leafID
        let tabID = pane.tabID
        let window = pane.window
        guard let tab = session.tab(tabID), tab.splitTree.contains(leafID: leafID) else { return }
        if pane.fallsThroughToTab, tab.splitTree.allLeafIDs() == [leafID] {
            TabActions.closeAllowedTab(
                session,
                registry: registry,
                tabID: tabID,
                askedLeafIDs: [leafID],
                agentProjection: agentProjection
            )
            return
        }
        // Closed before its agent started: nothing will take the file.
        InitialPromptFile.remove(tab.initialPromptFiles[leafID])
        session.update(tab.id) { t in
            let result = t.splitTree.remove(leafID)
            t.splitTree = result.tree
            if let z = t.zoomedLeafID, !t.splitTree.contains(leafID: z) {
                t.zoomedLeafID = nil
            }
            // Drop every per-pane dictionary entry for the closed leaf. Most
            // are persisted through `SessionSnapshot`, where a missed one
            // accumulates on disk on every ⌘W against a multi-pane tab; the
            // rest (`initialAgentExecutables`, `agentsInFront`) live only in
            // memory but would tie a stale state to a leaf that is gone.
            // Tmux bindings are pruned when they are next captured
            // (`captureTmuxBindings`).
            // `mergePaneIntoTab` sweeps the same set on its leaf-out path;
            // keep the two close-leaf paths structurally identical.
            for provider in AgentKind.allCases {
                t.agentSessions[provider]?.removeValue(forKey: leafID)
            }
            t.paneStates.removeValue(forKey: leafID)
            t.scrollbackPaths.removeValue(forKey: leafID)
            t.initialCommands.removeValue(forKey: leafID)
            t.initialPromptFiles.removeValue(forKey: leafID)
            t.initialAgentExecutables.removeValue(forKey: leafID)
            for provider in AgentKind.allCases {
                t.agentBadges[provider]?.removeValue(forKey: leafID)
            }
            t.agentsInFront.removeValue(forKey: leafID)
        }
        session.paneSearchStates.removeValue(forKey: leafID)
        session.paneTransients.removeValue(forKey: leafID)
        registry.unregister(leafID)
        agentProjection?.didClosePane(leafID)
        // If the tab is now empty, close it altogether.
        if let refreshed = session.tab(tabID), refreshed.splitTree.isEmpty {
            session.closeTab(refreshed.id)
        } else {
            // Reconcile registry entries against EVERY tab's leaves —
            // not just the active tab's. Passing only the active tab's
            // ids would wipe surfaces in other tabs, and the next visit
            // to one of those tabs would spawn a fresh shell in place
            // of the (still-alive) leaf.
            let allLive = session.allPaneIDs
            registry.reconcile(activeIDs: allLive)
            // Promote the surviving sibling to first responder —
            // SwiftUI's reparent on close does NOT re-fire
            // `viewDidMoveToWindow`, so the just-closed pane's
            // `SurfaceView` leaves the responder chain and AppKit
            // falls back to the window itself. Without this pull,
            // the next keystroke is silently dropped on the floor
            // until the user clicks the surviving pane.
            if session.selection(window)?.activeTabID == tabID,
               let surviving = session.tab(tabID)?.splitTree.effectiveFocusedLeafID
            {
                pullKeyboardFocus(to: surviving, registry: registry)
            }
        }
    }

    /// ⌘W cascade: close the focused pane; if the tab has only one
    /// pane left after that, close the tab too. Both branches flow
    /// through `CloseConfirmer` so the confirm policy is honored
    /// regardless of which branch we end up taking.
    static func closeActivePaneOrTab(
        _ session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        source: CloseConfirmer.Source = .keyboard,
        attention: AttentionState? = nil,
        agentProjection: AgentProjectionAdapter? = nil,
        in window: WindowID
    ) {
        guard let tab = session.activeTab(in: window) else { return }
        let leafCount = tab.splitTree.allLeafIDs().count
        if leafCount <= 1 {
            TabActions.closeActiveTab(
                session,
                registry: registry,
                source: source,
                attention: attention,
                agentProjection: agentProjection,
                in: window
            )
        } else {
            closeActivePane(
                session,
                registry: registry,
                source: source,
                attention: attention,
                agentProjection: agentProjection,
                in: window,
                fallsThroughToTab: true
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
        _ session: WorkspaceSession,
        registry: (any SurfaceViewProviding)? = nil,
        direction: SpatialDirection,
        in window: WindowID
    ) -> PaneAdjacency? {
        guard let tab = session.activeTab(in: window), tab.zoomedLeafID == nil,
              let current = tab.splitTree.effectiveFocusedLeafID
        else { return nil }
        let paneIDs = tab.splitTree.allLeafIDs()
        let renderedRects: [(id: UUID, rect: CGRect)] = registry.map { registry in
            paneIDs.compactMap { paneID in
                guard let view = registry.view(for: paneID), view.window != nil else { return nil }
                let windowRect = view.convert(view.bounds, to: nil)
                // AppKit window coordinates grow upward; SplitTree spatial
                // directions use SwiftUI's top-down convention.
                let topDownRect = CGRect(
                    x: windowRect.minX,
                    y: -windowRect.maxY,
                    width: windowRect.width,
                    height: windowRect.height
                )
                return (paneID, topDownRect)
            }
        } ?? []
        let neighbor = if renderedRects.count == paneIDs.count {
            tab.splitTree.neighborLeaf(of: current, direction: direction, rects: renderedRects)
        } else {
            tab.splitTree.neighborLeaf(of: current, direction: direction)
        }
        guard let neighbor else { return nil }
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
        _ session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        direction: SpatialDirection,
        in window: WindowID
    ) {
        guard let adjacency = adjacentLeaf(session, registry: registry, direction: direction, in: window) else { return }
        // Focus shift only — never overwrite `tab.title`. The label is
        // owned by the tab (agent prompt or latest OSC 2); pulling each
        // pane's last-known title up on focus would make the name
        // flicker and collide with
        // `GhosttyEventCoordinator.shouldPropagateTitle`.
        session.update(adjacency.tab.id) { $0.splitTree.focusedLeafID = adjacency.neighbor }
        pullKeyboardFocus(to: adjacency.neighbor, registry: registry)
    }

    /// Make `tabID` active, focus `paneID`, and pull keyboard focus to
    /// it. Shared with `AttentionState.focusAttention` (⌘J and the
    /// attention list) so the focus-pull primitive is single-source.
    ///
    /// The window and the intent stay two arguments, as in every selection:
    /// one value for both would hide the intent at the call site.
    static func activateAndFocus( // swiftlint:disable:this function_parameter_count
        _ session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        tabID: UUID,
        paneID: UUID,
        in window: WindowID,
        intent: SelectionIntent
    ) {
        session.setActiveTab(tabID, in: window, intent: intent)
        session.update(tabID) { t in
            // Exit zoom if the jump target is not the zoomed leaf —
            // otherwise `PaneAreaView` keeps showing the (still-zoomed)
            // pane while `focusedLeafID` claims focus moved to an
            // off-screen leaf, and a follow-up ⌘W silently destroys
            // the unseen pane. ⌘J and the Needs Attention list are
            // specifically designed for cross-pane navigation, so this
            // path is routine.
            if let zoomed = t.zoomedLeafID, zoomed != paneID {
                t.zoomedLeafID = nil
            }
            t.splitTree.focusedLeafID = paneID
        }
        pullKeyboardFocus(to: paneID, registry: registry)
    }

    // MARK: - Zoom + layout

    /// Leaves zoom on `tabID`: the tab comes forward, so the restored split
    /// is what the user sees, and its zoom clears. Unlike `toggleZoom` it
    /// never zooms, so a button that means "back to the split" cannot zoom
    /// another pane if the tab has unzoomed under it.
    static func unzoom(_ session: WorkspaceSession, tabID: UUID, in window: WindowID, intent: SelectionIntent) {
        session.setActiveTab(tabID, in: window, intent: intent)
        session.update(tabID) { $0.zoomedLeafID = nil }
    }

    /// Toggle full-screen "zoom" for the focused pane within its tab.
    /// tmux Prefix+z — while zoomed, the terminal column pane area
    /// renders only the zoomed leaf; the rest of the SplitTree stays
    /// intact so a second invocation restores the previous layout
    /// untouched. No-op when the active tab has a single leaf.
    static func toggleZoom(_ session: WorkspaceSession, in window: WindowID) {
        guard let tab = session.activeTab(in: window) else { return }
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
            if entering {
                t.splitTree.focusedLeafID = focusID
            }
        }
    }

    /// Give the panes of the active tab equal sizes along each axis, by the
    /// leaf weights `SplitTree.equalize` uses, rather than 50/50 at every
    /// divider.
    ///
    /// tmux `select-layout even-*` equivalent — most useful after one
    /// pane has drifted dominant from interactive drags.
    static func equalizeSplits(_ session: WorkspaceSession, in window: WindowID) {
        guard let tab = session.activeTab(in: window) else { return }
        session.update(tab.id) { t in
            t.splitTree = t.splitTree.equalize()
        }
    }
}
