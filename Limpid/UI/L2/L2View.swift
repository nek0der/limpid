// L2View.swift
// Limpid — middle pane wrapper. Shows the tab list for whichever
// container L1 has selected. Listens to `WindowSession.activeContainerID`
// so it stays in lockstep with L1 selection.
//
// History: an earlier draft hosted a segmented "mode switcher" for
// future Log/Diff/Stash placeholders. Those modes were dropped (the
// worktree × agent axis owns that surface area), so the L2 is now a
// thin wrapper around `TabsListView`.

import SwiftUI

struct L2View: View {
    @Environment(WindowSession.self) private var session

    var body: some View {
        TabsListView(container: session.activeContainerID)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
