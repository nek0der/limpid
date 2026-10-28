// Tab+ConversationName.swift
// Limpid — keeps a tab's first conversation name as passes run and panes move between tabs.

import Foundation

extension Tab {
    /// Remembers the tab's first conversation from the badges on it
    /// (`ConversationName.remembered`). The title is the pane header's
    /// (`PaneHeaderRules.agentTitle`), so the row and the header agree on
    /// what a running conversation is called.
    mutating func rememberConversationName() {
        let badges = agentBadges
        let observed = badges.flatMap { provider, panes in
            panes.map { paneID, badge in
                ConversationName.Observed(
                    provider: provider,
                    paneID: paneID,
                    conversationID: badge.conversationID,
                    startedAt: badge.sessionStartedAt
                )
            }
        }
        let next = ConversationName.remembered(conversationName, observed: observed) { session in
            badges[session.provider]?[session.paneID].flatMap { badge in
                PaneHeaderRules.agentTitle(for: badge)
            }
        }
        if next != conversationName {
            conversationName = next
        }
    }

    /// Names a tab that has no name yet by the badges it holds before a
    /// pass replaces them. A tab restored from a file written before
    /// conversation names were kept has its last badges and no name, and
    /// an agent that has ended leaves no badge for the pass to read the
    /// name from.
    ///
    /// A saved badge is the last conversation each pane held, so the name
    /// read here only approximates the tab's first conversation: an earlier
    /// one the pane held before is not on record. It runs on every pass;
    /// a named tab reads nothing, and an unnamed one reads the badges the
    /// previous pass already read, so the result is the same each time.
    mutating func rememberSavedConversationName() {
        guard conversationName == nil else { return }
        rememberConversationName()
    }

    /// The name of the first conversation among `tabs` to start: what names
    /// a row whose tabs they are; `nil` when no agent has named one of them.
    static func firstConversationName(in tabs: [Tab]) -> String? {
        ConversationName.first(tabs.compactMap(\.conversationName))?.name
    }

    /// Takes the conversation name from the tab when it belongs to
    /// `paneID`, which is leaving the tab: the name goes with the pane its
    /// conversation ran in, so the tab left behind does not keep naming a
    /// row after a conversation it no longer holds.
    mutating func takeConversationName(of paneID: UUID) -> ConversationName? {
        guard let name = conversationName, name.paneID == paneID else { return nil }
        conversationName = nil
        return name
    }

    /// Takes in the name a pane brought from another tab, keeping whichever
    /// conversation started first (`ConversationName.earlier`).
    mutating func receiveConversationName(_ name: ConversationName?) {
        let next = ConversationName.earlier(conversationName, name)
        if next != conversationName {
            conversationName = next
        }
    }
}
