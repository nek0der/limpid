// CwdEventStore.swift
// Limpid — per-pane `CwdChanged` records
// (`cwd-events/<uuid>.cwd.json`), written by
// `claude-shim/limpid-hook` on every cwd transition. See `PaneStore`
// for the shared storage logic.

import Foundation

typealias CwdEventStore = PaneStore<CwdEventRecord>

extension PaneStore where Record == CwdEventRecord {
    convenience init() {
        self.init(
            directory: LimpidPaths.applicationSupportDirectory()
                .appendingPathComponent("cwd-events", isDirectory: true),
            maxRecords: 200,
            fileSuffix: ".cwd.json",
            logCategory: "claude.cwd.event.store"
        )
    }

    convenience init(directory: URL, maxRecords: Int = 200) {
        self.init(
            directory: directory,
            maxRecords: maxRecords,
            fileSuffix: ".cwd.json",
            logCategory: "claude.cwd.event.store"
        )
    }
}
