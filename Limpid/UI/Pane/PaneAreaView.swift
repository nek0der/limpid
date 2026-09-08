// PaneAreaView.swift
// Limpid — renders the active tab's SplitTree, the review surface over
// it, or an empty state.

import SwiftUI

struct PaneAreaView: View {
    @Environment(WindowSession.self) private var session
    @Environment(ReviewPresentation.self) private var reviewPresentation
    @Environment(SettingsStore.self) private var settings
    @Environment(\.surfaceRegistry) private var registry
    let ghosttyApp: GhosttyApp

    private var renderableTab: Tab? {
        session.activeTab
    }

    /// Pane IDs currently on screen — used by the occlusion onChange to
    /// tell libghostty which surfaces are visible. Review keeps its origin
    /// pane on screen, so occluding everything would freeze the very agent
    /// whose work is being reviewed.
    private var visiblePaneIDs: Set<UUID> {
        if reviewPresentation.isPresented {
            guard let paneID = reviewStripPaneID else { return [] }
            return [paneID]
        }
        guard let tab = renderableTab else { return [] }
        return Set(tab.splitTree.allLeafIDs())
    }

    /// The origin pane while it still exists. A pane closed from another
    /// window leaves the review surface intact and the strip empty.
    private var reviewOriginPaneID: UUID? {
        guard let paneID = reviewPresentation.originPaneID,
              session.tab(containing: paneID) != nil
        else { return nil }
        return paneID
    }

    /// The origin pane only while the strip actually renders it. Collapsed
    /// keeps the header — it is the control that brings the pane back — but
    /// mounts no surface, so libghostty is never handed a new size.
    private var reviewStripPaneID: UUID? {
        guard !reviewPresentation.isStripCollapsed else { return nil }
        return reviewOriginPaneID
    }

    var body: some View {
        Group {
            if let directory = reviewPresentation.directory {
                reviewLayout(directory: directory)
            }
            // Resolve UUID-keyed leaves to live `SurfaceView` references
            // here, then hand `SplitContainerView` a value tree whose
            // leaves carry the AppKit object directly. SwiftUI's view
            // identity locks onto the SurfaceView reference, mirroring
            // the identity model used by other libghostty SwiftUI
            // consumers' split-tree renderers.
            else if let tab = renderableTab, let root = tab.splitTree.root {
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
                        onResize: { leafID, delta, direction, bounds in
                            let floor = settings.settings.terminal.minPaneSize
                            session.update(tab.id) { t in
                                t.splitTree = t.splitTree.resize(
                                    node: leafID,
                                    by: delta,
                                    direction: direction,
                                    bounds: bounds,
                                    minSize: floor
                                )
                            }
                        },
                        onPaneSwapDrop: { source, target, zone in
                            // Drop landed inside the same window. Both
                            // ids must belong to the active tab; cross-
                            // tab drops are handled by the tab column
                            // drop targets and never reach this overlay.
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
                                  source != target
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
                                let centerResult = tree.swappingLeaves(source, target)
                                if result == centerResult {
                                    return false
                                }
                            }
                            return true
                        },
                        onEqualize: { leafID, direction in
                            // `LimpidMotion.expand` (0.2s easeInOut) gives the
                            // ratio change a soft transition; Reduce Motion
                            // users get the same final state without the
                            // tween via SwiftUI's standard animation respect.
                            // The `_ =` discard prevents Swift from inferring
                            // this single-expression closure's type from
                            // `withAnimation`'s generic `Result`, which would
                            // otherwise conflict with sibling closures' Bool /
                            // Void return shapes during type-check.
                            _ = withAnimation(LimpidMotion.expand) {
                                session.update(tab.id) { t in
                                    t.splitTree = t.splitTree.equalize(
                                        at: leafID,
                                        direction: direction
                                    )
                                }
                            }
                        },
                        minPaneSize: settings.settings.terminal.minPaneSize
                    )
                }
            }
            // If `ResolvedSplitNode.build` returned nil every leaf failed
            // to resolve (only possible mid-close); fall through to the
            // empty state until the model catches up.
            else {
                VStack(spacing: 12) {
                    Text("No active tab")
                        .font(LimpidFont.title)
                        .foregroundStyle(LimpidColor.secondaryText)
                    Text("Pick a worktree from the sidebar or press ⌘T")
                        .font(LimpidFont.bodySecondary)
                        .foregroundStyle(LimpidColor.tertiaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            registry.updateOcclusion(visibleIDs: visiblePaneIDs)
        }
        // Only whether the pane is on screen, never how tall it is: driving
        // this from the height ran an occlusion pass on every frame of a
        // divider drag, and pausing and resuming libghostty's rendering that
        // often is what made the drag flicker.
        .onChange(of: reviewPresentation.isStripCollapsed) { _, _ in
            registry.updateOcclusion(visibleIDs: visiblePaneIDs)
        }
        // The strip is the only terminal on screen while review is up, so it
        // shows whichever pane the user is on rather than the one they opened
        // review from. The destination chip reads the same id, so the agent
        // that receives the feedback is always the one they are looking at.
        .onChange(of: renderableTab?.splitTree.effectiveFocusedLeafID) { _, newValue in
            guard reviewPresentation.isPresented else { return }
            reviewPresentation.focusedPaneChanged(to: newValue)
        }
        // The docked pane is the only one review leaves visible, so changing
        // which one it is has to hand libghostty a new visible set. Picking a
        // pane from the destination menu otherwise mounted a surface that had
        // been told it was occluded, and it sat there not drawing.
        .onChange(of: reviewPresentation.originPaneID) { _, _ in
            guard reviewPresentation.isPresented else { return }
            registry.updateOcclusion(visibleIDs: visiblePaneIDs)
        }
        // Switching project or worktree means reviewing that one. Closing
        // instead would be defensible, but it throws away the surface for a
        // move the user makes constantly.
        .onChange(of: session.activeContainerID) { _, _ in
            guard reviewPresentation.isPresented else { return }
            let paneID = renderableTab?.splitTree.effectiveFocusedLeafID
            if let directory = ReviewAgents.directory(session: session) {
                reviewPresentation.retarget(directory, originPaneID: paneID)
            } else {
                reviewPresentation.close()
            }
        }
        .onChange(of: reviewPresentation.directory) { oldValue, newValue in
            registry.updateOcclusion(visibleIDs: visiblePaneIDs)
            guard oldValue != nil, newValue == nil else { return }
            let paneID = reviewPresentation.insertedPaneID
                ?? session.activeTab?.splitTree.effectiveFocusedLeafID
            reviewPresentation.insertedPaneID = nil
            if let paneID {
                Task { @MainActor in
                    PaneActions.pullKeyboardFocus(to: paneID, registry: registry)
                }
            }
        }
    }

    /// Review replaces the split tree but keeps the origin pane docked below
    /// it, so the agent that produced the diff stays visible and stays the
    /// destination. `collapsed` renders no pane at all rather than a zero
    /// height one — an unmounted surface is never handed a new size, so the
    /// agent's tty keeps its geometry until the strip comes back.
    private func reviewLayout(directory: URL) -> some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ReviewPane(
                    directory: directory,
                    available: geo.size.width,
                    onClose: {
                        ReviewPresentationCommand.reveal(session: session, registry: registry)
                        reviewPresentation.close()
                    },
                    onInserted: { reviewPresentation.insertedPaneID = $0 }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let originID = reviewOriginPaneID {
                    ReviewAgentStripHeader(paneID: originID, available: geo.size.height)
                    if let paneID = reviewStripPaneID,
                       let tab = session.tab(containing: paneID),
                       let view = resolveSurfaceView(paneID, in: tab)
                    {
                        // The height is read inside this view, not here. Read
                        // in this body it made every frame of a divider drag
                        // rebuild the review surface — the diff table, the
                        // file list, all of it — beside the terminal that was
                        // being resized, which is what made the drag flicker.
                        ReviewStripPane(
                            paneID: paneID,
                            surfaceView: view,
                            available: geo.size.height
                        )
                    }
                }
            }
        }
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
            hostsAgentsInTmux: settings.settings.advanced.hostsAgentsInTmux
        )
    }
}

/// The docked terminal, sized from the strip. It owns the observation of the
/// height so a drag invalidates this view alone.
private struct ReviewStripPane: View {
    let paneID: UUID
    let surfaceView: SurfaceView
    let available: CGFloat
    @Environment(ReviewPresentation.self) private var reviewPresentation

    var body: some View {
        if let height = reviewPresentation.stripHeight(in: available) {
            PaneContainerView(paneID: paneID, surfaceView: surfaceView)
                .frame(height: height)
        }
    }
}
