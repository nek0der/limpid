// WorkspaceSession+AgentPaneName.swift
// Limpid — what tells one agent pane from the others of its row, where the row's name alone does not.

import Foundation

@MainActor
extension WorkspaceSession {
    /// What names an agent's pane: the name the person gave it, else its
    /// conversation's title, as its header goes by, else the agent's own name,
    /// where the header has a folder to fall to and this names a neighbor of
    /// that same folder. `nil` for a pane with no agent.
    func agentPaneName(_ paneID: UUID) -> String? {
        guard let tab = tab(containing: paneID), let kind = tab.agentKind(inPane: paneID) else { return nil }
        return PaneHeaderRules.normalizedName(paneState(paneID).name)
            ?? tab.agentBadges[kind]?[paneID].flatMap { PaneHeaderRules.agentTitle(for: $0) }
            ?? AgentProviderRegistry.displayName(for: kind)
    }

    /// `agentPaneName(_:)` while `paneID`'s row has another agent pane, whose
    /// items and lines it would otherwise be taken for; `nil` for the only one.
    func agentPaneNameAmongNeighbors(_ paneID: UUID) -> String? {
        guard let tab = tab(containing: paneID),
              tabs(in: tab.container).reduce(0, { $0 + $1.agentPaneCount }) > 1
        else { return nil }
        return agentPaneName(paneID)
    }

    /// What a notification's history entry calls where it came from: the tab,
    /// or the pane in a tab of several agents, whose one title would leave
    /// their sources alike. Counted in the tab, not the row as in
    /// `agentPaneNameAmongNeighbors(_:)`: two tabs already differ by title.
    func notificationSourceName(paneID: UUID, in tab: Tab) -> String {
        guard tab.agentPaneCount > 1 else { return tab.shownTitle }
        return agentPaneName(paneID) ?? tab.shownTitle
    }
}
