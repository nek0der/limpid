// CodexAgentStateStore.swift
// Limpid — per-pane Codex agent lifecycle records
// (`codex-agent-states/<uuid>.state.json`), written by
// `codex-shim/limpid-hook` on every relevant hook event. See
// `PaneStore` for the shared storage logic.

import Foundation

typealias CodexAgentStateStore = AgentStateStore<CodexAgentStateRecord>

extension AgentStateStore where Record == CodexAgentStateRecord {
    convenience init() {
        self.init(
            directory: LimpidPaths.applicationSupportDirectory()
                .appendingPathComponent("codex-agent-states", isDirectory: true),
            maxRetiredRecords: 200,
            logCategory: "codex.agent.state.store"
        )
    }

    convenience init(directory: URL, maxRetiredRecords: Int = 200) {
        self.init(
            directory: directory,
            maxRetiredRecords: maxRetiredRecords,
            logCategory: "codex.agent.state.store"
        )
    }
}
