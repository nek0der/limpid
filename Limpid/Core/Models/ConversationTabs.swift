// ConversationTabs.swift
// Limpid — which conversations each tab of a session runs, and which tab and pane run each conversation.

import Foundation

/// The one mapping between a session's tabs and the agent conversations
/// their panes run, read by every surface that matches a conversation to a
/// tab: the pane strip's tabs and their hover, the changes panel's "Show
/// Tab" and its live tab names, and the identity colors' running set. Read
/// once, so a split tab answers the same in all of them: its title stands
/// for one conversation, while its bars, its hover, and a card of any
/// conversation it runs answer for them all.
struct ConversationTabs: Equatable, Sendable {
    /// What one tab runs.
    struct TabConversations: Equatable, Sendable {
        /// The conversation the tab's title stands for: the one in
        /// `Tab.latestAgentSessionPaneID`'s pane, or with no such pane the
        /// tab's one conversation. Optional because a tab whose title
        /// follows a shell, a pane whose agent has not yet named its
        /// conversation, or a tab of two with neither's start known stands
        /// for none.
        let titled: ConversationKey?
        /// Every conversation the tab's panes run, in pane order, each
        /// once.
        let all: [ConversationKey]
    }

    /// Where a conversation runs: the first pane in the tabs' order that
    /// runs it, and that pane's tab.
    struct Place: Equatable, Sendable {
        let tabID: UUID
        /// The tab's place among the session's tabs, from 1, as the pane
        /// strip and ⌘1…9 count them.
        let position: Int
        let paneID: UUID
    }

    private(set) var tabs: [UUID: TabConversations] = [:]
    private(set) var places: [ConversationKey: Place] = [:]
    /// Every conversation a pane runs, in the tabs' and then the panes'
    /// order, each once: the order in which a conversation with no turn yet
    /// is handed its identity color.
    private(set) var running: [ConversationKey] = []

    /// `tabs` in their order, each pane read through `conversation`.
    init(tabs: [Tab], conversation: (UUID) -> ConversationKey?) {
        for (index, tab) in tabs.enumerated() {
            var all: [ConversationKey] = []
            var titled: ConversationKey?
            for pane in tab.splitTree.allLeafIDs() {
                guard let key = conversation(pane) else { continue }
                if pane == tab.latestAgentSessionPaneID {
                    titled = key
                }
                if !all.contains(key) {
                    all.append(key)
                }
                if places[key] == nil {
                    places[key] = Place(tabID: tab.id, position: index + 1, paneID: pane)
                    running.append(key)
                }
            }
            // No pane says when its session started (a run whose start was
            // never reported): a tab running one conversation still stands
            // for it, as its title can only be that one's. With two, which
            // one the title follows is unknown, and the tab stands for none.
            if tab.latestAgentSessionPaneID == nil, all.count == 1 {
                titled = all.first
            }
            self.tabs[tab.id] = TabConversations(titled: titled, all: all)
        }
    }

    /// `tabs` with each pane's conversation read from the agent its header
    /// speaks for among `runtimes` (`AttentionState.headerRuntime`), as the
    /// pane strip and the changes panel name a pane's agent.
    init(tabs: [Tab], runtimes: [AgentRuntimePresentation]) {
        self.init(tabs: tabs) { AttentionState.headerRuntime(inPane: $0, among: runtimes)?.conversation }
    }

    /// What the tab with `id` runs; `nil` for a tab not in the mapping.
    func conversations(of id: UUID) -> TabConversations? {
        tabs[id]
    }

    /// Where `conversation` runs; `nil` when no pane of these tabs runs it.
    func place(of conversation: ConversationKey) -> Place? {
        places[conversation]
    }
}
