// NotificationLiveStatus.swift
// Limpid — what an agent notification row's runtime is doing *now*.
//
// The history panel is a log of past events, but an agent row points at
// an invocation that is still alive in `AttentionState`. Joining the two
// lets the panel say whether a "needs input" row is still blocking the
// agent or was answered since, and lets `NotificationReadSync` retire
// rows the user no longer needs to be told about.

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

@MainActor
extension AttentionState {
    /// Live status for `entry`, or nil when the row cannot be matched to an
    /// exact runtime event (shell / command rows and pre-event-token
    /// history), or is a kind that has no "still pending" reading — a
    /// finished turn is a fact, not a wait.
    func liveStatus(for entry: NotificationEntry) -> NotificationLiveStatus? {
        guard let runtimeID = entry.runtimeID,
              let eventToken = entry.eventToken,
              let expected = entry.kind.agentState,
              expected == .needsInput || expected == .error
        else { return nil }
        // A runtime that has disappeared is one whose state file was
        // cleaned up — SessionEnd, or the PID sweep after a crash — so
        // nothing is waiting behind it any more.
        guard let runtime = allRuntimes.first(where: { $0.id == runtimeID }) else {
            return .resolved
        }
        return runtime.attentionEventToken == eventToken && runtime.badge.state == expected ? .stillWaiting : .resolved
    }

    /// Whether a finished-turn row has been handled in the Waiting
    /// list — focus visited it or the user pressed ×. Nil when the row
    /// is not a finished agent row or its runtime is unknown.
    func isFinishedRowHandled(_ entry: NotificationEntry) -> Bool? {
        guard entry.kind == .agentFinished,
              let runtimeID = entry.runtimeID,
              let eventToken = entry.eventToken,
              let runtime = allRuntimes.first(where: { $0.id == runtimeID })
        else { return nil }
        guard runtime.attentionEventToken == eventToken else { return false }
        return isViewed(runtime) || isDismissed(runtime)
    }
}
