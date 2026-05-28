// WindowSession+AgentState.swift
// Limpid — aggregate Claude agent lifecycle states up the hierarchy.
//
//   pane (ClaudeAgentBadge | CodexAgentBadge) → tab → container → project → window
//
// Mirrors the unread / ringing helpers in `WindowSession+Notifications`.
// L2 (TabRow) and L1 (ContainerRow) read these so the icons stay in
// lock-step with the underlying badges. Both Claude and Codex badges
// contribute — the enums share raw values, so we collapse a Codex
// state to the equivalent Claude one and run them through the existing
// reducer. PR-2 introduces per-kind iconography; for PR-1 the icon
// shape stays the same so a Codex pane lights up the same blue bolt
// the user already recognises.

import Foundation

@MainActor
extension WindowSession {
    /// Collect every observed agent state (Claude + Codex) for a tab,
    /// mapped to the unified `ClaudeAgentState` enum that drives the
    /// L1 / L2 reducer. The two enums share rawValues so the
    /// conversion is total.
    private func allAgentStates(in tab: Tab) -> [ClaudeAgentState] {
        var states: [ClaudeAgentState] = []
        for paneID in tab.splitTree.allLeafIDs() {
            if let c = tab.claudeAgentBadges[paneID]?.state {
                states.append(c)
            }
            if let cdx = tab.codexAgentBadges[paneID]?.state,
               let mapped = ClaudeAgentState(rawValue: cdx.rawValue)
            {
                states.append(mapped)
            }
        }
        return states
    }

    /// Aggregate state for a single tab — runs every split leaf's
    /// badge through the shared `aggregateClaudeState()` reducer.
    func aggregateAgentState(in tab: Tab) -> ClaudeAgentState? {
        allAgentStates(in: tab).aggregateClaudeState()
    }

    /// Aggregate across every tab in the given container.
    func aggregateAgentState(in container: ContainerID) -> ClaudeAgentState? {
        tabs(in: container)
            .flatMap { allAgentStates(in: $0) }
            .aggregateClaudeState()
    }

    /// Aggregate across project-direct + every worktree inside the
    /// project. Used by Project headers in L1.
    func aggregateAgentStateInProject(_ projectID: UUID) -> ClaudeAgentState? {
        tabs
            .filter { $0.container.projectID == projectID }
            .flatMap { allAgentStates(in: $0) }
            .aggregateClaudeState()
    }

    /// Breakdown counts used in the L1 hover tooltip
    /// (`"1 error · 2 needsInput · 1 running · 3 idle"`). Returns
    /// each state's pane count across the container's tabs. Both
    /// Claude and Codex panes contribute.
    func agentStateBreakdown(in container: ContainerID) -> [ClaudeAgentState: Int] {
        var out: [ClaudeAgentState: Int] = [:]
        for tab in tabs(in: container) {
            for state in allAgentStates(in: tab) {
                out[state, default: 0] += 1
            }
        }
        return out
    }

    /// "Is any agent live in this tab right now?" — distinct from
    /// `aggregateAgentState(in:)` because that one uses the L1 / L2
    /// icon reducer, which intentionally hides `.idle` (Claude open
    /// but at the prompt — no badge needed). For confirm-on-close
    /// the user considers that state worth protecting: closing the
    /// tab would tear down the session and force a `--resume` later.
    /// `.unknown` is genuinely no-state (no SessionStart observed)
    /// and stays excluded so a fresh shell-only pane doesn't fire
    /// the dialog.
    func hasLiveAgent(in tab: Tab) -> Bool {
        tab.splitTree.allLeafIDs().contains { hasLiveAgent(pane: $0, in: tab) }
    }

    /// Per-pane twin of `hasLiveAgent(in:)`. Used by pane-close
    /// confirmation in a split tab — only the focused leaf is being
    /// torn down, so the question is whether *that* leaf carries a
    /// tracked agent, not the tab as a whole.
    func hasLiveAgent(pane paneID: UUID, in tab: Tab) -> Bool {
        if let state = tab.claudeAgentBadges[paneID]?.state, state != .unknown {
            return true
        }
        if let state = tab.codexAgentBadges[paneID]?.state, state != .unknown {
            return true
        }
        return false
    }

    /// Window-wide twin of `hasLiveAgent(in:)`. Used by ⌘Q's
    /// `onlyWhenAgent` policy so any tab with a tracked agent gates
    /// the terminate.
    func hasLiveAgentAnywhere() -> Bool {
        tabs.contains { hasLiveAgent(in: $0) }
    }

    /// "Does any of these panes carry a live agent?" — used by
    /// `CloseConfirmer` so the same predicate works for a single-pane
    /// close (one id), a multi-pane tab close (every leaf), or a
    /// "close N tabs" prompt. Iterates the split tree (not the
    /// `claudeAgentBadges` dict directly) so we stay symmetrical with
    /// `hasLiveAgent(in:)` / `hasLiveAgentAnywhere()` — a stale badge
    /// for a pane that no longer exists in any tree must not light
    /// the predicate up.
    func hasLiveAgent(inAnyOf paneIDs: [UUID]) -> Bool {
        guard !paneIDs.isEmpty else { return false }
        let needle = Set(paneIDs)
        for tab in tabs {
            for leaf in tab.splitTree.allLeafIDs()
                where needle.contains(leaf) && hasLiveAgent(pane: leaf, in: tab)
            {
                return true
            }
        }
        return false
    }

    /// Same as the container variant but keyed off `Project.id`.
    func agentStateBreakdownInProject(_ projectID: UUID) -> [ClaudeAgentState: Int] {
        var out: [ClaudeAgentState: Int] = [:]
        for tab in tabs where tab.container.projectID == projectID {
            for state in allAgentStates(in: tab) {
                out[state, default: 0] += 1
            }
        }
        return out
    }
}
