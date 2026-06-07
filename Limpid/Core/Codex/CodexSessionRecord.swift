// CodexSessionRecord.swift
// Limpid — on-disk model for one persisted Codex session, written by
// `Limpid/Resources/codex-shim/limpid-codex-hook` and consumed by
// `CodexSessionStore`. One record per split-tree leaf
// (= `LIMPID_PANE_ID`); the hook overwrites the file on SessionStart
// so the stored sessionId is captured up front.

import Foundation

struct CodexSessionRecord: PaneScopedRecord, Equatable {
    /// Bumped if we ever need a breaking on-disk migration.
    var schemaVersion: Int
    /// UUID string of the split-tree leaf this session belongs to.
    var paneId: String
    /// Codex's own session id (UUID v7).
    var sessionId: String
    /// Working directory at the time the hook fired.
    var cwd: String
    /// ISO-8601 timestamp of the most recent hook event.
    var updatedAt: String
    /// Which hook fired last. Diagnostic only.
    var lastHookEvent: String?
}
