// PaneAreaView.swift
// Limpid — renders the active tab's SplitTree, the review surface over
// it, or an empty state.

import SwiftUI

struct PaneAreaView: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(ReviewPresentation.self) private var reviewPresentation
    @Environment(SettingsStore.self) private var settings
    @Environment(StopLedgerStore.self) private var stopLedger
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.paneVisibilityReporter) private var paneVisibility
    /// The window this pane area is in. Drawn only under
    /// `SessionTerminalView`, inside a main window, whose
    /// `MainWindowContent` puts the window in the environment.
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let ghosttyApp: GhosttyApp

    private var renderableTab: Tab? {
        session.drawnTab(in: window.id)
    }

    /// Whether this window has the scratch tabs selected while another
    /// window draws them, so this one says where they are rather than
    /// taking them (`WorkspaceSession.isScratchElsewhere(in:)`).
    private var isScratchElsewhere: Bool {
        session.isScratchElsewhere(in: window.id)
    }

    /// What this pane area shows, for the window registry: which terminals
    /// draw and which panes the person can be said to see.
    private var display: PaneAreaDisplay {
        let tab = renderableTab
        return PaneAreaDisplay(
            leafIDs: tab?.splitTree.allLeafIDs() ?? [],
            zoomedLeafID: tab?.zoomedLeafID,
            review: review
        )
    }

    private var review: PaneAreaDisplay.Review {
        window.review?.isShown == true ? .tab : .closed
    }

    var body: some View {
        // The review is a tab of its own: it stands where the terminal was,
        // and docks none. Behind a terminal tab it stays mounted,
        // hidden, so the comment being written and the place in the diff
        // are there when the person comes back.
        // Under the terminals: the diff is an AppKit view, and a click,
        // a scroll, or the cursor over a terminal must not reach it
        // through a hidden layer.
        ZStack {
            if let tab = window.review {
                ReviewTabView(tab: tab)
                    // Another opening is another tab: one taken from its
                    // project as the window switched in place is drawn
                    // anew, from what it kept, not from the view of the tab
                    // the window left.
                    .id(tab.opening)
                    .opacity(tab.isShown ? 1 : 0)
                    .allowsHitTesting(tab.isShown)
                    .accessibilityHidden(!tab.isShown)
            }
            if window.review?.isShown != true {
                terminals
            }
        }
        // Drive the occlusion update off the `SplitTree` itself rather
        // than a freshly-allocated `Set<UUID>`. SwiftUI calls the
        // `.onChange` key getter on every body re-eval to diff against
        // the previous value, so observing a computed `Set` allocated
        // a fresh set on every animation frame of a divider drag /
        // window resize. The tree comparison is cheap and only emits
        // on real structural changes.
        .onChange(of: renderableTab?.splitTree, initial: true) { _, _ in
            paneVisibility.report(display)
        }
        // Zooming changes which leaf counts as seen (the drawing set stays
        // whole; see `VisibilityInputBuilder.renderedPanes`).
        .onChange(of: renderableTab?.zoomedLeafID) { _, _ in
            paneVisibility.report(display)
        }
        // The review tab coming to the front, or going behind a terminal tab.
        .onChange(of: window.review?.isShown) { _, _ in
            paneVisibility.report(display)
        }
        // The window switching to another project: the registry let go of
        // what it reported of the project left, and the tab drawn can be
        // the same one (a scratch tab), which no change above reports.
        .onChange(of: window.selection.shownProjectID) { _, _ in
            paneVisibility.report(display)
        }
        // The review's surface opening or closing. Focus goes
        // back to the agent's pane in `ReviewTabActions.close`, not here.
        .onChange(of: reviewPresentation.directory) { _, _ in
            paneVisibility.report(display)
        }
    }

    /// The active tab's split tree, or what stands in for the scratch tabs
    /// another window draws.
    @ViewBuilder
    private var terminals: some View {
        if isScratchElsewhere {
            ScratchElsewhereNotice { session.claimScratch(for: window.id) }
        } else {
            splitTerminals
        }
    }

    /// The active tab's split tree, or the empty state.
    @ViewBuilder
    private var splitTerminals: some View {
        // Resolve UUID-keyed leaves to live `SurfaceView` references
        // here, then hand `SplitContainerView` a value tree whose
        // leaves carry the AppKit object directly. SwiftUI's view
        // identity locks onto the SurfaceView reference, mirroring
        // the identity model used by other libghostty SwiftUI
        // consumers' split-tree renderers.
        if let tab = renderableTab, let root = tab.splitTree.root {
            if let zoomID = tab.zoomedLeafID,
               tab.splitTree.contains(leafID: zoomID),
               let view = resolveSurfaceView(zoomID, in: tab)
            {
                PaneContainerView(paneID: zoomID, surfaceView: view)
            } else if let resolved = ResolvedSplitNode.build(root, resolveOrCreate: { id in
                resolveSurfaceView(id, in: tab)
            }) {
                SplitContainerView(
                    node: resolved,
                    onLeafFocus: { id in
                        // Move focus only; leave `tab.title` alone. The
                        // label is owned by the tab (Claude/Codex prompt
                        // routed through `latestAgentSessionPaneID`, or —
                        // when no agent is in the tab — the focused pane's
                        // OSC 2 stream). `GhosttyEventCoordinator.shouldPropagateTitle`
                        // enforces the latest-agent-owner rule; pulling
                        // each pane's last-known title up on focus would
                        // bypass it and re-introduce Codex's
                        // `process.title="codex"` flicker.
                        session.update(tab.id) { t in
                            t.splitTree.focusedLeafID = id
                        }
                    },
                    onResize: { splitPath, delta, bounds in
                        let floor = settings.settings.terminal.paneMinimumSize
                        session.update(tab.id) { t in
                            t.splitTree = t.splitTree.resize(
                                splitAt: splitPath,
                                by: delta,
                                bounds: bounds,
                                minSize: floor
                            )
                        }
                    },
                    onPaneSwapDrop: { source, target, zone in
                        // Drop landed inside the same window. Both
                        // ids must belong to the active tab; cross-
                        // tab drops are handled by the pane strip's
                        // tabs and never reach this overlay.
                        //
                        // Re-fetch the live tab from the session —
                        // the captured `tab` snapshot may be stale
                        // by the time the drop fires (right-click
                        // close on another pane mid-drag, agent
                        // crash, scrollback replay race). Mirrors
                        // the `isZoneEffective` guard below, which
                        // already follows this rule.
                        guard let liveTab = session.tab(tab.id),
                              liveTab.splitTree.contains(leafID: source),
                              liveTab.splitTree.contains(leafID: target),
                              source != target,
                              isPaneDropSizeFeasible(source: source, target: target, zone: zone)
                        else { return }
                        session.update(tab.id) { t in
                            t.splitTree = switch zone {
                            case .center:
                                t.splitTree.swappingLeaves(source, target)
                            case .left:
                                t.splitTree.inserting(source, beside: target, on: .left)
                            case .right:
                                t.splitTree.inserting(source, beside: target, on: .right)
                            case .top:
                                t.splitTree.inserting(source, beside: target, on: .top)
                            case .bottom:
                                t.splitTree.inserting(source, beside: target, on: .bottom)
                            }
                        }
                        // The mutation above sets focusedLeafID to
                        // `source` (swap / insert both follow the
                        // dragged pane), but SwiftUI's reparent does
                        // not re-fire `viewDidMoveToWindow`, so the
                        // surface never grabs first responder on
                        // its own. Pair the model write with the
                        // focus pull, same as the keyboard nav
                        // actions in `PaneActions`.
                        PaneActions.pullKeyboardFocus(to: source, registry: registry)
                    },
                    isZoneEffective: { source, target, zone in
                        // Read the *live* tree from the session
                        // each call — the user may have made other
                        // edits since the drag began.
                        guard let liveTab = session.tab(tab.id) else { return false }
                        let tree = liveTab.splitTree
                        let result: SplitTree = switch zone {
                        case .center: tree.swappingLeaves(source, target)
                        case .left: tree.inserting(source, beside: target, on: .left)
                        case .right: tree.inserting(source, beside: target, on: .right)
                        case .top: tree.inserting(source, beside: target, on: .top)
                        case .bottom: tree.inserting(source, beside: target, on: .bottom)
                        }
                        // 1. Zones whose drop would leave the tree
                        // unchanged are inert (cursor gets the
                        // no-drop badge).
                        guard result != tree else { return false }
                        // 2. Edges that produce the same tree as a
                        // center swap are folded into the center —
                        // showing two distinct highlights for the
                        // same outcome would suggest two different
                        // operations.
                        if zone != .center {
                            guard isPaneDropSizeFeasible(
                                source: source,
                                target: target,
                                zone: zone
                            ) else {
                                return false
                            }
                            let centerResult = tree.swappingLeaves(source, target)
                            if result == centerResult {
                                return false
                            }
                        }
                        return true
                    },
                    onEqualize: { splitPath in
                        // `LimpidMotion.expand` (0.2s easeInOut) gives the
                        // ratio change a soft transition; under Reduce
                        // Motion the panes take the same final sizes
                        // without the tween (`expandAnimation`).
                        // The `_ =` discard prevents Swift from inferring
                        // this single-expression closure's type from
                        // `withAnimation`'s generic `Result`, which would
                        // otherwise conflict with sibling closures' Bool /
                        // Void return shapes during type-check.
                        _ = withAnimation(LimpidMotion.expandAnimation(reduceMotion: reduceMotion)) {
                            session.update(tab.id) { t in
                                t.splitTree = t.splitTree.equalize(splitAt: splitPath)
                            }
                        }
                    },
                    minPaneSize: settings.settings.terminal.paneMinimumSize
                )
            }
        }
        // No tab to draw, or a tab with no panes: the empty state. A tree
        // whose every leaf failed to resolve (only possible mid-close)
        // passes the check above but takes neither branch inside it, so it
        // draws nothing until the model catches up rather than flash the
        // empty state.
        else {
            SupervisionEmptyState(
                .noOpenTab(newTabShortcut: settings.settings.keyboard.shortcut(for: .newTab)?.displayString),
                size: .regular
            )
        }
    }

    /// An edge drop moves an existing leaf before creating the target split,
    /// so checking only the target's current frame rejects layouts where the
    /// removed source frees enough room. Compare the candidate tree's complete
    /// requirement with the mounted pane area instead. When the window is
    /// already undersized, allow rearrangements that do not make it worse.
    private func isPaneDropSizeFeasible(
        source: UUID,
        target: UUID,
        zone: PaneDropZone
    ) -> Bool {
        guard zone != .center,
              let tree = session.activeTab(in: window.id)?.splitTree,
              let availableSize = PaneActions.mountedPaneAreaSize(of: tree, registry: registry)
        else { return true }
        let candidate = switch zone {
        case .center: tree
        case .left: tree.inserting(source, beside: target, on: .left)
        case .right: tree.inserting(source, beside: target, on: .right)
        case .top: tree.inserting(source, beside: target, on: .top)
        case .bottom: tree.inserting(source, beside: target, on: .bottom)
        }
        return PaneActions.fitsPaneArea(
            candidate,
            replacing: tree,
            availableSize: availableSize,
            minPaneSize: settings.settings.terminal.paneMinimumSize
        )
    }

    /// Resolve or create the `SurfaceView` for one leaf so the resolved
    /// split tree carries live AppKit references all the way down to
    /// `PaneHostRepresentable`. Goes through the existing factory on
    /// `PaneHostRepresentable` so the new-pane setup (initial command,
    /// env, scrollback replay, registry insert) keeps a single home.
    private func resolveSurfaceView(_ paneID: UUID, in tab: Tab) -> SurfaceView? {
        guard tab.splitTree.contains(leafID: paneID) else { return nil }
        return PaneHostRepresentable.resolveOrCreateSurfaceView(
            paneID: paneID,
            ghosttyApp: ghosttyApp,
            registry: registry,
            session: session,
            hostsAgentsInTmux: settings.settings.advanced.hostsAgentsInTmux,
            stopLedger: stopLedger
        )
    }
}

/// Stands where the scratch tabs would be while another window draws them,
/// with the way to bring them here.
private struct ScratchElsewhereNotice: View {
    let showHere: () -> Void

    var body: some View {
        // The empty state every surface shows, with the window's secondary
        // button as its action.
        SupervisionEmptyState(.scratchElsewhere, size: .regular) {
            Button(action: showHere) {
                Text("Show Here", comment: "Pane area: moves the scratch tabs into this window")
            }
            .buttonStyle(.supervisionSecondary)
            .accessibilityHint(Text("Moves the scratch tabs into this window", comment: "Pane area: what Show Here does"))
        }
        .pointerStyle(.default)
    }
}
