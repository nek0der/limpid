// WindowSession+AgentState.swift
// Limpid — aggregate Claude agent lifecycle states up the hierarchy.
//
//   pane (ClaudeAgentBadge) → tab → container → project → window
//
// Mirrors the unread / ringing helpers in `WindowSession+Notifications`.
// L2 (TabRow) and L1 (ContainerRow) read these so the icons stay in
// lock-step with the underlying badges.

import Foundation

@MainActor
extension WindowSession {
    /// Aggregate state for a single tab — runs every split leaf's
    /// badge through the shared `aggregateClaudeState()` reducer.
    func aggregateAgentState(in tab: Tab) -> ClaudeAgentState? {
        tab.splitTree.allLeafIDs()
            .compactMap { tab.claudeAgentBadges[$0]?.state }
            .aggregateClaudeState()
    }

    /// Aggregate across every tab in the given container.
    func aggregateAgentState(in container: ContainerID) -> ClaudeAgentState? {
        tabs(in: container)
            .flatMap { tab in
                tab.splitTree.allLeafIDs().compactMap { paneID in
                    tab.claudeAgentBadges[paneID]?.state
                }
            }
            .aggregateClaudeState()
    }

    /// Aggregate across project-direct + every worktree inside the
    /// project. Used by Project headers in L1.
    func aggregateAgentStateInProject(_ projectID: UUID) -> ClaudeAgentState? {
        tabs
            .filter { $0.container.projectID == projectID }
            .flatMap { tab in
                tab.splitTree.allLeafIDs().compactMap { paneID in
                    tab.claudeAgentBadges[paneID]?.state
                }
            }
            .aggregateClaudeState()
    }

    /// Breakdown counts used in the L1 hover tooltip
    /// (`"1 error · 2 needsInput · 1 running · 3 idle"`). Returns
    /// each state's pane count across the container's tabs.
    func agentStateBreakdown(in container: ContainerID) -> [ClaudeAgentState: Int] {
        var out: [ClaudeAgentState: Int] = [:]
        for tab in tabs(in: container) {
            for paneID in tab.splitTree.allLeafIDs() {
                guard let badge = tab.claudeAgentBadges[paneID] else { continue }
                out[badge.state, default: 0] += 1
            }
        }
        return out
    }

    /// Same as the container variant but keyed off `Project.id`.
    func agentStateBreakdownInProject(_ projectID: UUID) -> [ClaudeAgentState: Int] {
        var out: [ClaudeAgentState: Int] = [:]
        for tab in tabs where tab.container.projectID == projectID {
            for paneID in tab.splitTree.allLeafIDs() {
                guard let badge = tab.claudeAgentBadges[paneID] else { continue }
                out[badge.state, default: 0] += 1
            }
        }
        return out
    }
}
