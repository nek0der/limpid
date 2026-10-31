// PaneStripModel+Session.swift
// Weir — builds the pane strip from the session's tabs and the attention list.

import Foundation

@MainActor
extension PaneStripModel {
    /// The strip for `container`'s tabs as the app's state describes them,
    /// with `window`'s tab marked active. Each tab's glyph is read from its
    /// panes' header marks (`PaneHeaderRules.mark`) and the items behind
    /// them, so a tab and its panes never disagree on what state they are
    /// in, a turn's unread aside. Each kind of agent in a tab has its own
    /// state, read the same way from the panes that are for it
    /// (`Tab.agentKind(inPane:)`), and each tab carries the conversations its
    /// panes run (`ConversationTabs`), with the colors `identities` gives
    /// them (`ConversationIdentityStore`).
    init(
        container: ContainerID,
        session: WorkspaceSession,
        window: WindowID,
        queue: AttentionQueue,
        runtimes: [AgentRuntimePresentation] = [],
        identities: [ConversationKey: Int] = [:],
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
        let tabs = session.tabs(in: container)
        // None for a scratch tab: it has no worktree whose cards the tab
        // could be matched with.
        let conversations = ConversationTabs(tabs: container == .loose ? [] : tabs, runtimes: runtimes)
        let inputs = tabs.map { tab in
            let panes = tab.splitTree.allLeafIDs()
            let runs = conversations.conversations(of: tab.id)
            var runningIdentities: [ConversationKey: Int] = [:]
            for key in runs?.all ?? [] {
                runningIdentities[key] = identities[key]
            }
            let glyphsByPane = panes.reduce(into: [UUID: SessionRowFact.Glyph]()) { glyphs, pane in
                glyphs[pane] = PaneHeaderRules.mark(paneItems: itemsByPane[pane] ?? [], shown: runsByPane[pane] ?? [])?.glyph
            }
            let paneItems = panes.flatMap { itemsByPane[$0] ?? [] }
            // The agents the panes are for, with any an item still speaks for:
            // a stop outlives its agent, as on the sidebar's row, and without
            // a badge of its own no line of the tab would say it.
            let kinds = Set(tab.agentKinds + paneItems.compactMap(\.subject.agentKind))
            let agents = AgentKind.allCases.filter(kinds.contains).map { kind in
                let items = paneItems.filter { $0.subject.agentKind == kind }
                return AgentInput(
                    kind: kind,
                    // By the run or the item's own agent, not the agent the
                    // pane is for now: a run left behind in the pane speaks
                    // for itself.
                    paneGlyphs: panes.compactMap { pane in
                        PaneHeaderRules.mark(
                            paneItems: items.filter { $0.subject.paneID == pane },
                            shown: (runsByPane[pane] ?? []).filter { $0.kind == kind }
                        )?.glyph
                    },
                    paneItems: items,
                    identities: (runs?.all ?? []).filter { $0.provider == kind }.compactMap { identities[$0] }
                )
            }
            return ItemInput(
                id: tab.id,
                title: tab.shownTitle,
                paletteIndex: tab.paletteIndex,
                agents: agents,
                paneGlyphs: panes.compactMap { glyphsByPane[$0] },
                paneItems: paneItems,
                hasUnread: session.hasUnread(in: tab),
                isInTmux: tab.isHostedInTmux(mountedTmuxPaneIDs: mountedTmuxPaneIDs),
                exitCodes: panes.compactMap { session.childExitCode(paneID: $0) },
                paneCount: panes.count,
                runningIdentities: runningIdentities
            )
        }
        self.init(items: inputs, activeTabID: session.selection(window)?.activeTabID, reviewTab: reviewTab)
    }
}
