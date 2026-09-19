// WindowSession+AgentState.swift
// Limpid — "is anything live?" predicates that read raw Claude/Codex
// badges. Used by the quit and close confirmations only — these are
// intentionally NOT filtered through `AttentionState`, because a
// dismissed-finished pane is still a live session worth protecting
// before close.
//
// container / tab column aggregate badges + the Waiting list live on `AttentionState`
// (it owns the dismissed / viewed filter the aggregate needs to honor).

import Foundation

@MainActor
extension WindowSession {
    /// "Is any agent live in this tab right now?" — used by close-
    /// confirmation. A pane the user has dismissed from attention still
    /// counts as live (closing the tab would tear down the session and
    /// force a `--resume` later), so we read raw badges here without
    /// going through `AttentionState`. We deliberately don't reuse its
    /// sidebar summary: that reducer hides `.idle` (Claude open at the
    /// prompt — no badge needed), but for confirm-on-close, idle still counts.
    /// `.unknown` is genuinely no-state (no SessionStart observed) and
    /// stays excluded so a fresh shell-only pane doesn't fire the dialog.
    func hasLiveAgent(in tab: Tab) -> Bool {
        tab.splitTree.allLeafIDs().contains { hasLiveAgent(pane: $0, in: tab) }
    }

    /// Per-pane twin of `hasLiveAgent(in:)`. Used by pane-close
    /// confirmation in a split tab — only the focused leaf is being
    /// torn down, so the question is whether *that* leaf carries a
    /// tracked agent, not the tab as a whole.
    func hasLiveAgent(pane paneID: UUID, in tab: Tab) -> Bool {
        !liveAgentBadges(pane: paneID, in: tab).isEmpty
    }

    /// Whether quitting would stop a live agent: one running in a pane of
    /// ours rather than in a tmux session. Used by ⌘Q's `onlyWhenAgent`
    /// policy so any tab with such an agent gates the terminate.
    ///
    /// An agent in tmux outlives the quit — the server keeps it running and
    /// the next launch shows it again — so warning about it would say work
    /// is at risk when none is. Once that tmux is gone the tab has become a
    /// terminal the agent resumes in, and quitting would stop it after all
    /// (`stoppableAgentBadges`).
    func hasAgentThatQuitWouldStop() -> Bool {
        tabs.contains { tab in
            tab.splitTree.allLeafIDs().contains { leaf in
                !stoppableAgentBadges(pane: leaf, in: tab).isEmpty
            }
        }
    }

    /// "Would closing these panes stop an agent?" — used by
    /// `CloseConfirmer` so the same predicate works for a single-pane
    /// close (one id), a multi-pane tab close (every leaf), or a
    /// "close N tabs" prompt. Iterates the split tree (not the
    /// badges directly) so we stay symmetrical with
    /// `hasLiveAgent(in:)` / `hasAgentThatQuitWouldStop()` — a stale badge
    /// for a pane that no longer exists in any tree must not light
    /// the predicate up.
    ///
    /// An agent in tmux is not counted, for the reason ⌘Q does not count
    /// it: closing its tab leaves it running in the server, and the Waiting
    /// list opens its tab again.
    func hasAgentThatClosingWouldStop(inAnyOf paneIDs: [UUID]) -> Bool {
        guard !paneIDs.isEmpty else { return false }
        let needle = Set(paneIDs)
        for tab in tabs {
            for leaf in tab.splitTree.allLeafIDs()
                where needle.contains(leaf) && !stoppableAgentBadges(pane: leaf, in: tab).isEmpty
            {
                return true
            }
        }
        return false
    }

    /// The live badges of `paneID` whose agent stops with the pane: every
    /// one but those in tmux. The badge's `isTmuxHosted` is what says so —
    /// the rules set it from the run's own record and clear it once that
    /// tmux is gone.
    private func stoppableAgentBadges(pane paneID: UUID, in tab: Tab) -> [AgentBadge] {
        liveAgentBadges(pane: paneID, in: tab).filter { $0.isTmuxHosted != true }
    }

    /// The badges of `paneID` that say an agent is there. `.unknown` is
    /// genuinely no state (no SessionStart observed), so a fresh shell-only
    /// pane has none.
    private func liveAgentBadges(pane paneID: UUID, in tab: Tab) -> [AgentBadge] {
        [tab.agentBadges[.claude]?[paneID], tab.agentBadges[.codex]?[paneID]]
            .compactMap(\.self)
            .filter { $0.state != .unknown }
    }
}
