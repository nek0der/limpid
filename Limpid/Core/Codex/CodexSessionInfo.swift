// CodexSessionInfo.swift
// Limpid — in-memory mirror of one pane's resumable Codex session.
// Lives on `Tab.codexSessions` keyed by split-leaf UUID; the disk
// record under `~/Library/Application Support/Limpid/codex-sessions/`
// is the authority and bootstrap rewrites this struct to match.

import Foundation

struct CodexSessionInfo: Codable, Equatable {
    /// Codex's own session id (UUID v7), suitable for
    /// `codex resume <id>`. We capture this in the hook from the
    /// `session_id` field of every event payload.
    var sessionId: String
    /// Working directory at the time the session was captured. Codex
    /// filters `codex resume --last` by cwd by default, so storing
    /// this lets us emit `--cd <cwd>` when re-launching to ensure the
    /// right rollout is picked even when several sessions exist.
    var cwd: String?
}
