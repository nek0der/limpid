// NotificationReadSync.swift
// Limpid — keeps persisted notification reads, live agent acknowledgement,
// and the explicit mark-all action aligned.
//
// Same observe-and-push shape as `DockBadgeSync`: watch the attention
// facts (`runtimesByKind`, viewed / dismissed tokens) and the history
// entries, and mark rows read when the Waiting side already answered
// them. The history store stays ignorant of `AttentionState`; this
// object is the only place the two meet.

import Foundation

@MainActor
final class NotificationReadSync {
    private let historyStore: NotificationHistoryStore
    private let attention: AttentionState

    init(historyStore: NotificationHistoryStore, attention: AttentionState) {
        self.historyStore = historyStore
        self.attention = attention
        // The tracking closure captures the collaborators, not `self`:
        // both outlive this object, and a dead sync must not keep them.
        observeRepeatedly { [attention, historyStore] in
            // Every input `reconcile` reads: runtimes decide "still
            // waiting", the tokens decide "viewed / dismissed", and a
            // freshly recorded entry needs its first pass.
            _ = attention.runtimesByKind
            _ = attention.viewedRuntimeTokens
            _ = attention.dismissedRuntimeTokens
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
    /// - `finished` rows whose turn was viewed or dismissed in the
    ///   Waiting list — the user already looked at the result.
    ///
    /// Rows without a runtime (command / script rows, pre-`runtimeID`
    /// history) are left to the existing tap / navigate paths.
    /// `markRead(where:)` only saves when something flipped, so the
    /// observation this triggers on `entries` settles after one pass.
    func reconcile() {
        // History is persisted while live attention is rebuilt on launch.
        // Restore acknowledgement before retiring newly resolved rows so the
        // same finished episode cannot be gray in history but green in Waiting.
        attention.markFinishedRuntimesViewed(
            matching: Self.finishedEventTokens(in: historyStore.entries.filter(\.isRead))
        )
        historyStore.markRead { [attention] entry in
            if attention.liveStatus(for: entry) == .resolved {
                return true
            }
            return attention.isFinishedRowHandled(entry) == true
        }
    }

    /// Keep every inbox-wide acknowledgement surface aligned. Pane counts and
    /// history are cleared together, while only matching live finished episodes
    /// gain the viewed state used by agent status indicators.
    static func markAllRead(
        historyStore: NotificationHistoryStore,
        attention: AttentionState,
        session: WindowSession
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
