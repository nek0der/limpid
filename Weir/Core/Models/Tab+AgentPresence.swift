// Tab+AgentPresence.swift
// Weir — whether an agent has a session in a tab, and whether the tab runs inside tmux.

import Foundation
import WeirDomain

extension Tab {
    /// The kinds of agent the tab's panes are for, each once, in
    /// `AgentKind`'s order, so a badge keeps its place as panes come and go.
    /// Empty for a plain terminal.
    var agentKinds: [AgentKind] {
        let kinds = Set(splitTree.allLeafIDs().compactMap(agentKind(inPane:)))
        return AgentKind.allCases.filter(kinds.contains)
    }

    /// The agent `paneID` is for: the one whose run the projection placed
    /// there, else the one its terminal runs in front before that run has
    /// a record (`agentsInFront`), which a record overrides. `nil` for a
    /// plain terminal. With two runs placed in the pane, it is the one that
    /// reported last, as `AttentionState.headerRuntime` reads a pane, so a
    /// run left behind in the pane does not name the agent now in front.
    ///
    /// A run whose state is unknown counts, as it does on the sidebar's row
    /// (`SessionRowFact`) and in the decision bar: it is a run restored at
    /// launch whose agent has not reported since (a `codex resume` reports
    /// nothing before its first prompt), not one that is gone. A run that
    /// is gone leaves `agentBadges` when the projection retires it, which
    /// is what turns the pane back into a plain terminal once its job in
    /// front is the shell again. Only its state is left off the badge
    /// (`PaneStripModel.tabGlyph`).
    func agentKind(inPane paneID: UUID) -> AgentKind? {
        let placed = AgentKind.allCases.compactMap { kind in
            agentBadges[kind]?[paneID].map { (kind: kind, badge: $0) }
        }
        let reported = placed.filter { $0.badge.state != .unknown }
        return reported.max { $0.badge.updatedAt < $1.badge.updatedAt }?.kind
            ?? placed.first?.kind
            ?? agentInFrontWithoutRecord(inPane: paneID)
    }

    /// How many of the tab's panes are for an agent.
    var agentPaneCount: Int {
        splitTree.allLeafIDs().count { agentKind(inPane: $0) != nil }
    }

    /// What the person sees the tab called, everywhere it is named.
    var shownTitle: String {
        folderTitleWhileUnnamed ?? displayTitle
    }

    /// What names the tab while its panes run several agents and the one its
    /// title follows has no name for its conversation yet: the last component
    /// of its folder. Until then the terminal title is whatever that agent
    /// writes for itself ("Claude Code"), which reads as the whole tab's. `nil`
    /// for any other tab, and for one the person named.
    var folderTitleWhileUnnamed: String? {
        guard titleOverride?.isEmpty ?? true, agentPaneCount > 1, !isTitleNamedByItsConversation else { return nil }
        return (pwd ?? workingDirectory).flatMap(PaneHeaderRules.directoryName(of:)).map(prefixedTitle)
    }

    /// Whether the agent the title follows (`latestAgentSessionPaneID`) has a
    /// name for its conversation, as the projection names a tab by.
    private var isTitleNamedByItsConversation: Bool {
        guard let pane = latestAgentSessionPaneID else { return false }
        return AgentKind.allCases.contains { kind in
            agentBadges[kind]?[pane].flatMap { PaneHeaderRules.agentTitle(for: $0) } != nil
        }
    }

    /// The agent `paneID` runs in front while no run of any agent is placed
    /// there: what the sidebar's row and the pane's header add to the runs
    /// they read, so they name the agents the tab does.
    func agentInFrontWithoutRecord(inPane paneID: UUID) -> AgentKind? {
        guard AgentKind.allCases.allSatisfy({ agentBadges[$0]?[paneID] == nil }) else { return nil }
        return agentsInFront[paneID]?.kind
    }

    /// Whether any pane in the tab runs inside a tmux session we host.
    /// Two sources because neither covers the other's panes: the poll
    /// (`mountedTmuxPaneIDs`) sees any mounted pane, including a shell the
    /// user put into tmux by hand, and sees nothing for a tab not opened
    /// this launch; the agent's record survives exactly that case and
    /// clears itself when the session ends.
    func isHostedInTmux(mountedTmuxPaneIDs: Set<UUID>) -> Bool {
        splitTree.allLeafIDs().contains { leaf in
            mountedTmuxPaneIDs.contains(leaf)
                || AgentKind.allCases.contains { agentBadges[$0]?[leaf]?.isTmuxHosted == true }
        }
    }
}
