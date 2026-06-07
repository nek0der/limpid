// TabColumnView.swift
// Limpid — middle pane wrapper. Shows the tab list for whichever
// container the container column has selected. Listens to `WindowSession.activeContainerID`
// so it stays in lockstep with container column selection.

import SwiftUI

struct TabColumnView: View {
    @Environment(WindowSession.self) private var session

    var body: some View {
        TabsListView(container: session.activeContainerID)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
