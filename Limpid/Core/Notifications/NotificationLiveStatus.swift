// NotificationLiveStatus.swift
// Limpid — what an agent notification row's runtime is doing *now*.
//
// The history panel is a log of past events, but an agent row points at
// an invocation that is still alive in `AttentionState`. Joining the two
// lets the panel say whether a waiting row is still blocking the
// agent or was answered since, and lets `NotificationReadSync` retire
// rows the user no longer needs to be told about. A request row joins
// the approval ledger's entry for its own request instead.

import Foundation

/// Live state of the runtime behind an agent notification row.
enum NotificationLiveStatus: Equatable {
    /// The runtime is still in the state that produced the row — the
    /// agent is still blocked on the user (or still errored).
    case stillWaiting
    /// The runtime has moved past that state, or is gone entirely: the
    /// user answered, the agent resumed, or the session ended.
    case resolved
}

extension NotificationLiveStatus {
    /// Live status of a request row (`NotificationEntry.requestKey`), read
    /// from where the ledger says that exact request stands: `state` is the
    /// ledger's state for the row's key, nil when the ledger does not hold
    /// it. We join on the request's own key rather than on its run's state
    /// file, because a run can ask two requests in one turn, and its hook
    /// and the service report them in either order; only the key names the
    /// one the row announced.
    ///
    /// The row waits by the predicate the attention list lists the request
    /// by (`ApprovalRequestState.hasLeftTheQueue`): held, being sent, after
    /// a failed send, handed to the agent's own prompt, timed out (and so
    /// answered at that prompt now), or with its result lost. It is
    /// resolved once answered or withdrawn, and once the ledger lets it go
    /// with its turn. The ledger lives in memory, so after a launch only a
    /// request the service still lists as pending waits; one that had
    /// already left that list for the agent's prompt reads as resolved, as
    /// the attention list no longer lists it either. Nil while the ledger has read no pending list yet
    /// (`hasReadService` is false), after a launch or since the service
    /// stopped: the service may still hold the request, and calling it
    /// resolved would retire a row that still waits.
    static func ofRequest(state: ApprovalRequestState?, hasReadService: Bool) -> NotificationLiveStatus? {
        if let state {
            return state.hasLeftTheQueue ? .resolved : .stillWaiting
        }
        return hasReadService ? .resolved : nil
    }
}

@MainActor
extension ApprovalLedger {
    /// `NotificationLiveStatus.ofRequest` for the request `key`.
    func liveStatus(of key: ApprovalKey) -> NotificationLiveStatus? {
        NotificationLiveStatus.ofRequest(state: entries[key]?.state, hasReadService: epoch != nil)
    }
}

@MainActor
extension AttentionState {
    /// Live status for `entry`, or nil when the row cannot be matched to an
    /// exact runtime event or request (shell / command rows and
    /// pre-event-token history), or is a kind that has no "still pending"
    /// reading — a finished turn is a fact, not a wait. A request row is
    /// read from `requests`, the approval ledger, never from its run.
    func liveStatus(for entry: NotificationEntry, requests: ApprovalLedger) -> NotificationLiveStatus? {
        Self.liveStatus(for: entry, requests: requests) { id in allRuntimes.first { $0.id == id } }
    }

    /// `liveStatus(for:requests:)` for many rows at once, as the history
    /// asks it of every row it draws: the runtimes are looked up by ID from
    /// a table made once, rather than searched for each row.
    func liveStatusLookup(requests: ApprovalLedger) -> (NotificationEntry) -> NotificationLiveStatus? {
        let runtimes = Dictionary(allRuntimes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return { entry in Self.liveStatus(for: entry, requests: requests) { runtimes[$0] } }
    }

    private static func liveStatus(
        for entry: NotificationEntry,
        requests: ApprovalLedger,
        runtime: (String) -> AgentRuntimePresentation?
    ) -> NotificationLiveStatus? {
        if let key = entry.requestKey {
            return requests.liveStatus(of: key)
        }
        guard let runtimeID = entry.runtimeID,
              let eventToken = entry.eventToken,
              let expected = entry.kind.agentState,
              expected == .needsInput || expected == .error
        else { return nil }
        // A runtime that has disappeared is one whose state file was
        // cleaned up — SessionEnd, or the PID sweep after a crash — so
        // nothing is waiting behind it any more.
        guard let runtime = runtime(runtimeID) else {
            return .resolved
        }
        return runtime.attentionEventToken == eventToken && runtime.badge.state == expected ? .stillWaiting : .resolved
    }

    /// Whether a finished-turn row has been handled: its run reads as
    /// viewed (`isViewed`), by its turn records or, for a run none stands
    /// for, by its episode's viewed mark. Nil when the row is not a
    /// finished agent row or its runtime is unknown.
    func isFinishedRowHandled(_ entry: NotificationEntry) -> Bool? {
        guard entry.kind == .agentFinished,
              let runtimeID = entry.runtimeID,
              let eventToken = entry.eventToken,
              let runtime = allRuntimes.first(where: { $0.id == runtimeID })
        else { return nil }
        guard runtime.attentionEventToken == eventToken else { return false }
        return isViewed(runtime)
    }
}
