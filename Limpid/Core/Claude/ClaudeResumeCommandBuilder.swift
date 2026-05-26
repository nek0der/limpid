// ClaudeResumeCommandBuilder.swift
// Limpid — composes the shell command that re-launches Claude Code
// on the next surface mount when a pane has a remembered session in
// `Tab.claudeSessions[paneID]`. Lives alongside the shim + store so
// all the resume-related plumbing is in one folder.

import Foundation

enum ClaudeResumeCommandBuilder {
    /// Shell command that tries the persisted session first, then
    /// falls back to `--continue` (cwd's most recent session), then to
    /// a fresh `claude`. The chain uses `||` against exit codes so a
    /// stale or pruned session id (Claude rotates them, and the
    /// default 30-day cleanup eventually drops the on-disk JSONL)
    /// transparently degrades instead of leaving the user staring at
    /// a "No conversation found" error.
    ///
    /// When `cwd` is non-nil and non-empty, we prepend
    /// `cd '<cwd>' && …` so `claude --resume` runs in the same dir
    /// the session was originally captured in — Claude rejects resume
    /// otherwise and `--continue` would silently grab the wrong
    /// session.
    static func resumeCommand(sessionId: String, cwd: String? = nil) -> String {
        let base = "claude --resume \(sessionId) 2>/dev/null || claude --continue 2>/dev/null || claude"
        guard let cwd, !cwd.isEmpty else { return base }
        return "cd \(singleQuote(cwd)) && \(base)"
    }

    /// Decide whether `paneID` inside `tab` should auto-launch a
    /// resumed Claude session at surface-mount time. Returns the shell
    /// command string to feed into `SurfaceView.initialCommand`, or
    /// `nil` if no auto-resume should fire.
    ///
    /// Conditions for a non-nil return:
    /// 1. `tab.claudeSessions[paneID]` is set with a non-empty
    ///    `sessionId`. Each split-leaf carries its own session so
    ///    two panes running `claude` concurrently each resume
    ///    independently.
    /// 2. The user / demo fixture hasn't already staged a command
    ///    for this pane in `tab.initialCommands` — that slot is the
    ///    explicit override and we never clobber it.
    static func initialCommand(for tab: Tab, paneID: UUID) -> String? {
        guard let info = tab.claudeSessions[paneID], !info.sessionId.isEmpty else {
            return nil
        }
        if let existing = tab.initialCommands[paneID], !existing.isEmpty { return nil }
        return resumeCommand(sessionId: info.sessionId, cwd: info.cwd)
    }

    /// Wrap `value` in POSIX single quotes, escaping any embedded `'`
    /// via the standard `'\''` dance. Used so a path with a space or
    /// other shell metacharacter survives `cd …` without further
    /// quoting from the caller.
    private static func singleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
