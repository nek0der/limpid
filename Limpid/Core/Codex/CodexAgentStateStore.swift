// CodexAgentStateStore.swift
// Limpid — per-pane Codex agent lifecycle records
// (`codex-agent-states/<uuid>.state.json`), written by
// `codex-shim/limpid-codex-hook` on every relevant hook event. See
// `PaneStore` for the shared storage logic.

import Foundation

typealias CodexAgentStateStore = PaneStore<CodexAgentStateRecord>

extension PaneStore where Record == CodexAgentStateRecord {
    convenience init() {
        self.init(
            directory: LimpidPaths.applicationSupportDirectory()
                .appendingPathComponent("codex-agent-states", isDirectory: true),
            maxRecords: 200,
            fileSuffix: ".state.json",
            logCategory: "codex.agent.state.store"
        )
    }

    convenience init(directory: URL, maxRecords: Int = 200) {
        self.init(
            directory: directory,
            maxRecords: maxRecords,
            fileSuffix: ".state.json",
            logCategory: "codex.agent.state.store"
        )
    }
}
