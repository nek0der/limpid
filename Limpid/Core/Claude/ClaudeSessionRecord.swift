// ClaudeSessionRecord.swift
// Limpid — on-disk model for one persisted Claude Code session,
// written by `Limpid/Resources/claude-shim/limpid-hook` and consumed
// by `ClaudeSessionStore`. One record per split-tree leaf
// (= `LIMPID_PANE_ID`); the hook overwrites the file on
// SessionStart so the stored sessionId is captured up front, and
// drops it on SessionEnd when the user gracefully exited Claude.

import Foundation

struct ClaudeSessionRecord: Codable, Equatable {
    /// Bumped if we ever need a breaking on-disk migration. Old
    /// records without the field decode as schemaVersion == 0 and
    /// are treated as "unknown — keep but refuse to resume" by
    /// callers.
    var schemaVersion: Int
    /// UUID string of the split-tree leaf this session belongs to.
    /// The hook receives this from the `LIMPID_PANE_ID` env var; the
    /// filename must match. Named `paneId` because Limpid keys
    /// records by split leaf — `cmux`-style naming, intentionally not
    /// the parent `Tab.id`.
    var paneId: String
    /// Claude Code's own session id, suitable for `claude --resume <id>`.
    var sessionId: String
    /// Working directory at the time the hook fired. Used as the cwd
    /// when we re-launch claude on next start (Claude rejects resume
    /// when the cwd differs from the session's original path).
    var cwd: String
    /// ISO-8601 timestamp of the most recent hook event.
    var updatedAt: String
    /// Which hook fired last (SessionStart / SessionEnd). Diagnostic
    /// only, never load-bearing.
    var lastHookEvent: String?
}
