// ClaudeAgent.swift
// Limpid — concrete `AgentSpec` for the Claude flavor: its `AgentKind`
// case and the shell command that resumes one of its sessions.

import Foundation

enum ClaudeAgent: AgentSpec {
    static var kind: AgentKind {
        .claude
    }

    /// Shell command that tries the persisted session first, then
    /// falls back to a fresh `claude` if the id is stale or pruned
    /// (Claude rotates them, and the default 30-day cleanup eventually
    /// drops the on-disk JSONL). We deliberately do *not* chain
    /// `claude --continue` in between: it picks the cwd's most recent
    /// session, which means several panes in the same cwd would all
    /// land on the same conversation and silently collapse into one.
    ///
    /// When `cwd` is non-nil and non-empty, we prepend `cd '<cwd>' && …`
    /// so `claude --resume` runs in the same dir the session was
    /// captured in — Claude rejects resume otherwise.
    static func resumeCommand(sessionId: String, cwd: String?) -> String {
        // `sessionId` is restored from on-disk state; a tampered value
        // would inject shell when interpolated below. Resume only for
        // the id shape Claude emits; fall back to a fresh `claude`.
        let base = AgentSessionIDValidator.isValid(sessionId)
            ? "claude --resume \(sessionId) 2>/dev/null || claude"
            : "claude"
        guard let cwd, !cwd.isEmpty else { return base }
        return "cd \(ShellQuote.single(cwd)) && \(base)"
    }
}
