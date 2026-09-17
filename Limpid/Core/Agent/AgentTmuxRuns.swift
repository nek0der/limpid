// AgentTmuxRuns.swift
// Limpid — what a mirror tab asks about the agent run inside it, and what it reports back about that run's tmux.

import Foundation

/// The seam between the tmux side of the app and the projection.
///
/// Both questions here are about run records, and records are read by the
/// rules alone, so this passes them on rather than answering them: whether the
/// run in one leaf ended on its own terms, and that an endpoint's tmux is
/// gone. Held weakly, so a store that outlives a projection asks nobody rather
/// than keeping one alive.
@MainActor
final class AgentTmuxRuns {
    private weak var projection: AgentProjectionAdapter?
    private weak var presence: TmuxPanePresence?

    init(projection: AgentProjectionAdapter?, presence: TmuxPanePresence?) {
        self.projection = projection
        self.presence = presence
    }

    /// Whether the run in `paneID` ended by its own session end, read from the
    /// records as they stand now.
    ///
    /// A fresh pass rather than the last one's answer: the hook writes the
    /// record before the agent exits, so by the time tmux announces the closed
    /// window the answer is on disk — while the pass that would have read it
    /// is only scheduled by a file event that may not have arrived. A pass
    /// re-reads everything and is safe to ask for at any moment.
    ///
    /// The pass runs inside the caller, which is a tmux notification handler,
    /// and it writes to the session — every tab's badges and titles. That is
    /// the same re-entry every hook file event already makes on the main
    /// actor, and it reaches this store only through `session.tabs` changing,
    /// which releases connections no mirror uses. The tab being asked about
    /// is still a mirror at this point, so its connection is not among them,
    /// and the caller decides what becomes of it after the answer.
    func hasEndedRun(inPane paneID: UUID) -> Bool {
        guard let projection else { return false }
        if projection.endedTmuxPanes.contains(paneID) {
            return true
        }
        projection.refresh()
        return projection.endedTmuxPanes.contains(paneID)
    }

    /// Report that the tmux behind `endpoint` is gone, and read the records
    /// again with that in hand.
    ///
    /// The rules hold a run's conversation out of resume while tmux has it,
    /// and a killed server tells them nothing, so this is the evidence that
    /// ends the run for them. The pass runs here rather than on the next file
    /// change because the tab that lost its tmux is about to build a surface,
    /// and the surface resumes from what the rules last answered.
    func reportGone(_ endpoint: TmuxRuntimeEndpoint) {
        guard let presence else { return }
        presence.reportGone(endpoint)
        projection?.refresh()
    }
}

/// Where one agent's run lives in tmux, as its own record names it, and which
/// leaf Limpid gave it.
///
/// What it takes to show the run again after its tab was closed: the pane is
/// found on the server by `paneID` of the endpoint, and the tab that opens
/// takes `leafID`, so it is the tab the run's records already name (design §6
/// decision 3).
struct AgentTmuxRun: Equatable {
    let kind: AgentKind
    let endpoint: TmuxRuntimeEndpoint
    let leafID: UUID
}
