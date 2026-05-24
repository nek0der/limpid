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

    var body: some View {
        if let tab = renderableTab, let root = tab.splitTree.root {
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
}
