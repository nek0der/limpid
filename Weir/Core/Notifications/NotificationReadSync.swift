// NotificationReadSync.swift
// Weir — keeps persisted notification reads, live agent acknowledgment,
// and the explicit mark-all action aligned.
//
// Same observe-and-push shape as `DockBadgeSync`: watch the attention
// facts (`runtimesByKind`, the viewed marks, the turn reads) and the
// history entries, and mark rows read when the run behind them already
// reads as handled. The history store stays ignorant of `AttentionState`;
// this object is the only place the two meet.

import Foundation

@MainActor
final class NotificationReadSync {
    private let historyStore: NotificationHistoryStore
    private let attention: AttentionState
    /// The approval ledger, which decides whether a request row still
    /// waits (`NotificationLiveStatus.ofRequest`).
    private let requests: ApprovalLedger

    init(historyStore: NotificationHistoryStore, attention: AttentionState, requests: ApprovalLedger) {
        self.historyStore = historyStore
        self.attention = attention
        self.requests = requests
        // The tracking closure captures the collaborators, not `self`:
        // they outlive this object, and a dead sync must not keep them.
        observeRepeatedly { [attention, historyStore, requests] in
            // Every input `reconcile` reads: runtimes and the ledger decide
            // "still waiting", the marks and the turn reads decide
            // "viewed", and a freshly recorded entry needs its first pass.
            _ = attention.runtimesByKind
            _ = requests.entries
            _ = requests.epoch
            _ = attention.viewedRuntimeTokens
            attention.observeTurnReadSources()
            _ = historyStore.entries
        } onChange: { [weak self] in
            self?.reconcile()
        }
        reconcile()
    }

    /// Mark read every unread agent row the user no longer has to act
    /// on:
    ///
    /// - `needsInput` / `error` rows whose runtime left that state (or
    ///   ended) — the prompt was answered or the session is gone.
    /// - request rows whose request the ledger reads as answered,
    ///   withdrawn, or gone with its turn.
    /// - `finished` rows whose run reads as viewed (`isViewed`) — the
    ///   user already looked at the result.
    ///
    /// Rows without a runtime (command / script rows, pre-`runtimeID`
    /// history) are left to the existing tap / navigate paths.
    /// `markRead(where:)` only saves when something flipped, so the
    /// observation this triggers on `entries` settles after one pass.
    func reconcile() {
        // History is persisted while live attention is rebuilt on launch.
        // Restore acknowledgment before retiring newly resolved rows so the
        // same finished episode cannot be gray in history but unread in the
        // attention list.
        // Only for runs their turn records do not decide: those are read as
        // their turns are, which knows a turn that changed files is not read
        // by being looked at, where a read notification row would say it was.
        let runsWithTurns = Set(attention.allRuntimes.filter { attention.turnReadDecision($0) != nil }.map(\.id))
        attention.markFinishedRuntimesViewed(
            matching: Self.finishedEventTokens(in: historyStore.entries.filter(\.isRead))
                .filter { !runsWithTurns.contains($0.key) }
        )
        historyStore.markRead { [attention, requests] entry in
            if attention.liveStatus(for: entry, requests: requests) == .resolved {
                return true
            }
            return attention.isFinishedRowHandled(entry) == true
        }
    }

    /// Keep every inbox-wide acknowledgment surface aligned. Pane counts and
    /// history are cleared together, while only matching live finished episodes
    /// gain the viewed state used by agent status indicators. A run whose turns
    /// are recorded is read as they are (`AttentionState.turnReadDecision`), so
    /// clearing the history does not mark a turn that changed files viewed.
    static func markAllRead(
        historyStore: NotificationHistoryStore,
        attention: AttentionState,
        session: WorkspaceSession
    ) {
        session.clearAllUnread()
        attention.markFinishedRuntimesViewed(matching: finishedEventTokens(in: historyStore.entries))
        historyStore.markAllRead()
    }

    /// Build an exact episode lookup once so reconciliation stays linear in
    /// the bounded history and live runtime counts.
    private static func finishedEventTokens(
        in entries: [NotificationEntry]
    ) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for entry in entries {
            guard entry.kind == .agentFinished,
                  let runtimeID = entry.runtimeID,
                  let eventToken = entry.eventToken
            else { continue }
            result[runtimeID, default: []].insert(eventToken)
        }
        return result
    }
}
