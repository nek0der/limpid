// ClaudeSessionInfo.swift
// Limpid — in-memory mirror of one pane's resumable Claude session.
// Lives on `Tab.claudeSessions` keyed by split-leaf UUID; the disk
// record under `~/Library/Application Support/Limpid/sessions/` is
// the authority and bootstrap rewrites this struct to match.

import Foundation

struct ClaudeSessionInfo: Codable, Equatable {
    /// Claude Code's own session id, suitable for `claude --resume <id>`.
    var sessionId: String
    /// Working directory at the time the session was captured.
    /// `claude --resume` rejects when the spawn cwd does not match,
    /// so the resume builder issues `cd '<cwd>' && claude --resume …`.
    /// `nil` (or empty after normalization) means "no usable cwd
    /// recorded" — caller falls back to the surface's cwd.
    var cwd: String?
}
