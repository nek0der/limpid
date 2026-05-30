// WindowSession+AgentState.swift
// Limpid — "is anything live?" predicates that read raw Claude/Codex
// badges. Used by the close-confirmation flow only — these are
// intentionally NOT filtered through `TriageState`, because a
// dismissed-finished pane is still a live session worth protecting
// before close.
//
// L1 / L2 aggregate badges + the WAITING list live on `TriageState`
// (it owns the dismissed / viewed filter the aggregate needs to honour).

import Foundation

@MainActor
extension WindowSession {
    /// "Is any agent live in this tab right now?" — used by close-
    /// confirmation. A pane the user has dismissed from triage still
    /// counts as live (closing the tab would tear down the session and
    /// force a `--resume` later), so we read raw badges here without
    /// going through `TriageState`. `.unknown` is genuinely no-state
    /// (no SessionStart observed) and stays excluded so a fresh
    /// shell-only pane doesn't fire the dialog.
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

}
