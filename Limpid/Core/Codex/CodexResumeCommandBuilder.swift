// CodexResumeCommandBuilder.swift
// Limpid — composes the shell command that re-launches Codex on the
// next surface mount when a pane has a remembered session in
// `Tab.codexSessions[paneID]`. Mirror of `ClaudeResumeCommandBuilder`.

import Foundation

enum CodexResumeCommandBuilder {
    /// Shell command that tries `codex resume <id>` first then falls
    /// back to a fresh `codex` if the session is gone (e.g. user
    /// purged `~/.codex/sessions/`). We use the explicit id rather
    /// than `--last` because two panes in the same cwd both want
    /// their own sessions; `--last` would collapse them.
    static func resumeCommand(sessionId: String, cwd: String? = nil) -> String {
        let base = "codex resume \(sessionId) 2>/dev/null || codex"
        guard let cwd, !cwd.isEmpty else { return base }
        return "cd \(singleQuote(cwd)) && \(base)"
    }

    /// Decide whether `paneID` inside `tab` should auto-launch a
    /// resumed Codex session at surface-mount time. Returns the shell
    /// command, or `nil` if no auto-resume should fire.
    ///
    /// Conditions:
    /// 1. `tab.codexSessions[paneID]` is set with a non-empty
    ///    `sessionId`.
    /// 2. The user / demo fixture hasn't already staged a command for
    ///    this pane in `tab.initialCommands`.
    /// 3. The pane doesn't already have a Claude session — Claude
    ///    takes precedence because it was launched first
    ///    historically. If both somehow exist, the Claude resume
    ///    wins and Codex stays dormant.
    static func initialCommand(for tab: Tab, paneID: UUID) -> String? {
        guard let info = tab.codexSessions[paneID], !info.sessionId.isEmpty else {
            return nil
        }
        if let existing = tab.initialCommands[paneID], !existing.isEmpty { return nil }
        if let claude = tab.claudeSessions[paneID], !claude.sessionId.isEmpty { return nil }
        return resumeCommand(sessionId: info.sessionId, cwd: info.cwd)
    }

    private static func singleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
