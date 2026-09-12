// NotificationReadSync.swift
// Limpid — retires agent notification rows once their runtime has moved
// on, so the unread count the bell / Dock / panel show is "what still
// needs you" rather than "what was ever announced".
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
        historyStore.markRead { [attention] entry in
            if attention.liveStatus(for: entry) == .resolved {
                return true
            }
            return attention.isFinishedRowHandled(entry) == true
        }
    }
}
