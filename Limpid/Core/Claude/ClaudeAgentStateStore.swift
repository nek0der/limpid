// ClaudeAgentStateStore.swift
// Limpid — per-pane Claude lifecycle records written by the selected hook receiver.

import Foundation

typealias ClaudeAgentStateStore = AgentStateStore<ClaudeAgentStateRecord>

extension AgentStateStore where Record == ClaudeAgentStateRecord {
    convenience init() {
        self.init(
            directory: LimpidPaths.applicationSupportDirectory()
                .appendingPathComponent("agent-states", isDirectory: true),
            maxRetiredRecords: 200,
            logCategory: "claude.agent.state.store"
        )
    }

    convenience init(directory: URL, maxRetiredRecords: Int = 200) {
        self.init(
            directory: directory,
            maxRetiredRecords: maxRetiredRecords,
            logCategory: "claude.agent.state.store"
        )
    }
}
