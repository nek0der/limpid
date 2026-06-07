// ClaudeAgentStateStore.swift
// Limpid — per-pane Claude agent lifecycle records written by `claude-shim/limpid-hook`.

import Foundation

typealias ClaudeAgentStateStore = PaneStore<ClaudeAgentStateRecord>

extension PaneStore where Record == ClaudeAgentStateRecord {
    convenience init() {
        self.init(
            directory: LimpidPaths.applicationSupportDirectory()
                .appendingPathComponent("agent-states", isDirectory: true),
            maxRecords: 200,
            fileSuffix: ".state.json",
            logCategory: "claude.agent.state.store"
        )
    }

    convenience init(directory: URL, maxRecords: Int = 200) {
        self.init(
            directory: directory,
            maxRecords: maxRecords,
            fileSuffix: ".state.json",
            logCategory: "claude.agent.state.store"
        )
    }
}
