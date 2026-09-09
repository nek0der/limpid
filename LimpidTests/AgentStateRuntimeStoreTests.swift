// AgentStateRuntimeStoreTests.swift
// Limpid — runtime identity and cleanup behavior beyond legacy pane storage.

import Foundation
import Testing
@testable import Limpid

@Suite("Agent runtime state store")
struct AgentStateRuntimeStoreTests {
    private func record(
        runID: UUID,
        paneID: UUID,
        revision: Int,
        tmuxPaneID: String? = nil
    ) -> ClaudeAgentStateRecord {
        ClaudeAgentStateRecord(
            schemaVersion: 2,
            runId: runID.uuidString,
            revision: revision,
            paneId: paneID.uuidString,
            state: "running",
            detail: nil,
            runStartedAt: nil,
            updatedAt: "2026-09-09T00:00:00Z",
            lastHookEvent: "UserPromptSubmit",
            contextTokens: nil,
            pid: nil,
            lastPrompt: nil,
            tmuxSocketPath: tmuxPaneID.map { _ in "/tmp/tmux-501/default" },
            tmuxSessionId: tmuxPaneID.map { _ in "$1" },
            tmuxPaneId: tmuxPaneID
        )
    }

    @Test("keeps multiple agent runs launched from one pane")
    func save_sameLaunchPane_keepsEveryRun() throws {
        try withTempDir { directory in
            let store = ClaudeAgentStateStore(directory: directory)
            let paneID = UUID()
            let first = record(runID: UUID(), paneID: paneID, revision: 1)
            let second = record(runID: UUID(), paneID: paneID, revision: 1)

            try store.save(first)
            try store.save(second)

            #expect(Set(store.allRecords().map(\.storageID)) == [
                first.storageID, second.storageID
            ])
        }
    }

    @Test("closing an outer pane removes direct runs but preserves tmux runs")
    func cleanup_missingLaunchPane_preservesTmuxRuntime() throws {
        try withTempDir { directory in
            let store = ClaudeAgentStateStore(directory: directory)
            let paneID = UUID()
            let direct = record(runID: UUID(), paneID: paneID, revision: 1)
            let tmux = record(runID: UUID(), paneID: paneID, revision: 1, tmuxPaneID: "%2")
            try store.save(direct)
            try store.save(tmux)

            let removable = AgentLifecyclePolicy.removableRecords(store.allRecords(), alivePanes: [], processStatus: { _ in .dead })
            store.cleanup(removing: removable)

            #expect(store.allRecords().map(\.storageID) == [tmux.storageID])
        }
    }

    @Test("legacy records use their pane id as storage identity")
    func storageID_legacyRecord_fallsBackToPane() {
        let paneID = UUID()
        let legacy = ClaudeAgentStateRecord(
            schemaVersion: 1,
            paneId: paneID.uuidString,
            state: "idle",
            detail: nil,
            runStartedAt: nil,
            updatedAt: "2026-09-09T00:00:00Z",
            lastHookEvent: "SessionStart",
            contextTokens: nil,
            pid: nil,
            lastPrompt: nil
        )

        #expect(legacy.storageID == paneID.uuidString)
    }

    @Test("a valid run id cannot hide an invalid launch pane id")
    func save_validRunIDInvalidPaneID_isRejected() throws {
        try withTempDir { directory in
            let store = ClaudeAgentStateStore(directory: directory)
            var invalid = record(
                runID: UUID(),
                paneID: UUID(),
                revision: 1
            )
            invalid.paneId = "../../state.json"

            #expect(throws: (any Error).self) {
                try store.save(invalid)
            }
        }
    }
}
