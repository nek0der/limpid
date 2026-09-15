// CodexAgent.swift
// Limpid — concrete `AgentSpec` for the Codex flavor. Mirror of
// `ClaudeAgent`: its `AgentKind` case and the `codex resume` command
// shape.

import Foundation

enum CodexAgent: AgentSpec {
    static var kind: AgentKind {
        .codex
    }

    /// Shell command that tries `codex resume <id>` first then falls
    /// back to a fresh `codex` if the session is gone (e.g. user
    /// purged `~/.codex/sessions/`). We use the explicit id rather
    /// than `--last` because two panes in the same cwd both want
    /// their own sessions; `--last` would collapse them.
    static func resumeCommand(sessionId: String, cwd: String?) -> String {
        // `sessionId` is restored from on-disk state; a tampered value
        // would inject shell when interpolated below. Resume only for
        // the id shape Codex emits; fall back to a fresh `codex`.
        let base = AgentSessionIDValidator.isValid(sessionId)
            ? "codex resume \(sessionId) 2>/dev/null || codex"
            : "codex"
        guard let cwd, !cwd.isEmpty else { return base }
        return "cd \(ShellQuote.single(cwd)) && \(base)"
    }
}
