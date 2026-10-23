// Tab+AgentPresence.swift
// Limpid — whether an agent has a session in a tab, and whether the tab runs inside tmux.

import Foundation

extension Tab {
    /// The agent the tab is for, for its badge: the first in
    /// `AgentKind`'s order when two share a tab, since a tab has room for
    /// one. `nil` for a plain terminal.
    var agentKind: AgentKind? {
        let kinds = Set(splitTree.allLeafIDs().compactMap(agentKind(inPane:)))
        return AgentKind.allCases.first(where: kinds.contains)
    }

    /// The agent `paneID` is for: the one whose run the projection placed
    /// there, else the one its terminal runs in front before that run has
    /// a record (`agentsInFront`), which a record overrides. `nil` for a
    /// plain terminal.
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
        AgentKind.allCases.first { agentBadges[$0]?[paneID] != nil } ?? agentInFrontWithoutRecord(inPane: paneID)
    }

    /// The agent `paneID` runs in front while no run of any agent is placed
    /// there: what the sidebar's row and the pane's header add to the runs
    /// they read, so they wear the badge the tab does.
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
