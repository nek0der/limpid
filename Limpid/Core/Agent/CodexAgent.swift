// CodexAgent.swift
// Limpid — concrete `AgentSpec` for the Codex flavor. Mirror of
// `ClaudeAgent`: its `AgentKind` case and the `codex resume` arguments.

import Foundation

enum CodexAgent: AgentSpec {
    static var kind: AgentKind {
        .codex
    }

    /// `codex resume <id>` with the explicit id rather than `--last`: two
    /// panes in the same cwd both want their own sessions, and `--last`
    /// would collapse them.
    static func strictResumeArguments(sessionId: String) -> String {
        "codex resume \(sessionId)"
    }
}
