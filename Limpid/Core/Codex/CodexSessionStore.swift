// CodexSessionStore.swift
// Limpid — per-pane Codex session records written by `codex-shim/limpid-codex-hook`.

import Foundation

typealias CodexSessionStore = PaneStore<CodexSessionRecord>

extension PaneStore where Record == CodexSessionRecord {
    convenience init() {
        self.init(
            directory: LimpidPaths.applicationSupportDirectory()
                .appendingPathComponent("codex-sessions", isDirectory: true),
            maxRecords: 200,
            fileSuffix: ".json",
            logCategory: "codex.session.store"
        )
    }

    convenience init(directory: URL, maxRecords: Int = 200) {
        self.init(
            directory: directory,
            maxRecords: maxRecords,
            fileSuffix: ".json",
            logCategory: "codex.session.store"
        )
    }
}
