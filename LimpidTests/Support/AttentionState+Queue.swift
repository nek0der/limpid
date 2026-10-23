// AttentionState+Queue.swift
// Limpid — the attention list these runtimes alone would make, for tests that ask which runs wait.

import Foundation
@testable import Limpid

extension AttentionState {
    /// The attention list the app would build from these runtimes alone:
    /// no turn records, no requests, so each finished run's episode is read
    /// as its viewed mark says (`isViewed`). Built through
    /// `AttentionQueueStore`, as the app builds it, so a test asks the
    /// supervision window's list rather than a copy of its rules.
    func queueItems(in session: WorkspaceSession) -> [AttentionItem] {
        let store = AttentionQueueStore()
        store.apply(
            AttentionQueueStore.makeInput(
                runtimes: allRuntimes,
                isRead: { self.isViewed($0) },
                approvals: [],
                session: session,
                isApprovalServiceRunning: false
            ),
            announces: false
        )
        return store.queue.items
    }
}
