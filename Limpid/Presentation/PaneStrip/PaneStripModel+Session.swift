// PaneStripModel+Session.swift
// Limpid — builds the pane strip from the session's tabs and the attention list.

import Foundation

extension PaneStripModel {
    /// The strip for `container`'s tabs as the app's state describes them,
    /// with `window`'s tab marked active. Each tab's glyph is read from its
    /// panes' header marks (`PaneHeaderRules.mark`) and the items behind
    /// them, so a tab and its panes never disagree on what state they are
    /// in, a turn's unread aside.
    @MainActor
    init(
        container: ContainerID,
        session: WorkspaceSession,
        window: WindowID,
        queue: AttentionQueue,
        runtimes: [AgentRuntimePresentation] = [],
        mountedTmuxPaneIDs: Set<UUID>,
        reviewTab: ReviewTab
    ) {
        // A tab never shows a turn's unread, and the row's rule would
        // let one stand over a run still going: a running agent with an
        // unread turn would show nothing. Its unread items are left out
        // before the panes are marked, so the run shows.
        var itemsByPane: [UUID: [AttentionItem]] = [:]
        for item in queue.items {
            switch (item.kind, item.subject.paneID) {
            case (.unread, _), (_, nil):
                continue
            case let (_, pane?):
                itemsByPane[pane, default: []].append(item)
            }
        }
        // Each run is placed once, not once for every pane asked about.
        var runsByPane: [UUID: [AgentRuntimePresentation]] = [:]
        for runtime in runtimes {
            guard let pane = AttentionState.shownPane(of: runtime, in: session) else { continue }
            runsByPane[pane, default: []].append(runtime)
        }
        let inputs = session.tabs(in: container).map { tab in
            let panes = tab.splitTree.allLeafIDs()
            return ItemInput(
                id: tab.id,
                title: tab.displayTitle,
                paletteIndex: tab.paletteIndex,
                agent: tab.agentKind,
                paneGlyphs: panes.compactMap { pane in
                    PaneHeaderRules.mark(paneItems: itemsByPane[pane] ?? [], shown: runsByPane[pane] ?? [])?.glyph
                },
                paneItems: panes.flatMap { itemsByPane[$0] ?? [] },
                hasUnread: session.hasUnread(in: tab),
                isInTmux: tab.isHostedInTmux(mountedTmuxPaneIDs: mountedTmuxPaneIDs),
                exitCodes: panes.compactMap { session.childExitCode(paneID: $0) }
            )
        }
        self.init(items: inputs, activeTabID: session.selection(window)?.activeTabID, reviewTab: reviewTab)
    }
}
