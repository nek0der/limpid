// AppState+PlanUsage.swift
// Weir — builds the plan usage store from the record directory and the Codex reader it reads.

import Foundation

extension AppState {
    /// The store behind the rail's usage panel: the status line relay's
    /// records under Weir's data folder, and the Codex the new worktree
    /// sheet would start. It reads and watches from the start. In demo mode
    /// it reads nothing, so a screenshot shows none of the person's accounts.
    static func makePlanUsageStore(readsUsage: Bool) -> PlanUsageStore {
        let store = PlanUsageStore(
            records: PlanUsageRecordDirectory(
                directory: AgentProviderRegistry.usageDirectory(under: WeirPaths.applicationSupportDirectory())
            ),
            codexReader: CodexUsageReader(),
            readsUsage: readsUsage
        )
        store.start()
        return store
    }
}
