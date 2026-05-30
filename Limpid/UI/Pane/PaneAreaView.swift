// PaneAreaView.swift
// Limpid — renders the active tab's SplitTree, or an empty state.

import SwiftUI

struct PaneAreaView: View {
    @Environment(WindowSession.self) private var session
    @Environment(\.surfaceRegistry) private var registry
    let ghosttyApp: GhosttyApp

    /// Render only tabs that belong to the active group. After a group
    /// switch, `activeTabID` may still point at the previous group's tab,
    /// which would leave a stale pane on screen — enforce consistency here.
    private var renderableTab: Tab? {
        session.activeTab
    }

    /// Pane IDs currently on screen — used by the occlusion onChange to
    /// tell libghostty which surfaces are visible.
    private var visiblePaneIDs: Set<UUID> {
        guard let tab = renderableTab else { return [] }
        return Set(tab.splitTree.allLeafIDs())
    }

    var body: some View {
        Group {
            if let tab = renderableTab, let root = tab.splitTree.root {
                // Switching between this branch and SplitContainerView
                // rebuilds the subtree; the libghostty surface survives
                // because PaneHostView.makeNSView hits SurfaceRegistry by
                // paneID before creating a new SurfaceView.
                if let zoomID = tab.zoomedLeafID, tab.splitTree.contains(leafID: zoomID) {
                    PaneContainerView(paneID: zoomID, ghosttyApp: ghosttyApp)
                        .id(tab.id)
                } else {
                    SplitContainerView(
                        node: root,
                        ghosttyApp: ghosttyApp,
                        onLeafFocus: { id in
                            // Pull the newly-focused pane's last known title up
                            // to the tab so the label and window title snap to
                            // the new pane immediately, without waiting for the
                            // shell's next prompt to re-emit SET_TITLE.
                            let pulledTitle = registry.view(for: id)?.paneTitle
                            session.update(tab.id) { t in
                                t.splitTree.focusedLeafID = id
                                if let pulledTitle { t.title = pulledTitle }
                            }
                        },
                        onResize: { leafID, delta, direction, bounds in
                            session.update(tab.id) { t in
                                t.splitTree = t.splitTree.resize(
                                    node: leafID,
                                    by: delta,
                                    direction: direction,
                                    bounds: bounds,
                                    minSize: 80
                                )
                            }
                        }
                    )
                    .id(tab.id) // force fresh layout on tab switch
                }
            } else {
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
        .onChange(of: visiblePaneIDs, initial: true) { _, ids in
            (registry as? SurfaceRegistry)?.updateOcclusion(visibleIDs: ids)
        }
    }
}
