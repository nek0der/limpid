// ClaudeSessionStore.swift
// Limpid — per-pane Claude session records (`sessions/<uuid>.json`),
// written by `claude-shim/limpid-hook`. Storage logic lives on
// `PaneStore<Record>`; this file just pins the production directory,
// max retention, file suffix, and log category for the Claude session
// flavour. Tests bypass `init()` and inject their own directory via
// the designated `PaneStore.init(directory:maxRecords:fileSuffix:logCategory:)`.

import Foundation

typealias ClaudeSessionStore = PaneStore<ClaudeSessionRecord>

extension PaneStore where Record == ClaudeSessionRecord {
    convenience init() {
        self.init(
            directory: LimpidPaths.applicationSupportDirectory()
                .appendingPathComponent("sessions", isDirectory: true),
            maxRecords: 200,
            fileSuffix: ".json",
            logCategory: "claude.session.store"
        )
    }

    /// Test-injection convenience: production callers go through the
    /// no-arg `init()`; tests hand in an isolated `directory`.
    convenience init(directory: URL, maxRecords: Int = 200) {
        self.init(
            directory: directory,
            maxRecords: maxRecords,
            fileSuffix: ".json",
            logCategory: "claude.session.store"
        )
    }
}
