// AgentResumeCommandBuilder.swift
// Limpid — generic resume-command composer for any `AgentSpec` flavour.

import Foundation

enum AgentResumeCommandBuilder<S: AgentSpec> {
    /// Decide whether `paneID` inside `tab` should auto-launch a
    /// resumed agent session at surface-mount time. Returns the shell
    /// command to feed into `SurfaceView.initialCommand`, or `nil` if
    /// no auto-resume should fire.
    ///
    /// Conditions for a non-nil return:
    /// 1. `tab[keyPath: S.sessionsKeyPath][paneID]` is set with a
    ///    non-empty `sessionId`. Each split-leaf carries its own
    ///    session so two panes running the same agent concurrently
    ///    each resume independently.
    /// 2. The user / demo fixture hasn't already staged a command
    ///    for this pane in `tab.initialCommands` — that slot is the
    ///    explicit override and we never clobber it.
    /// 3. `S.shouldResume(in:paneID:)` returns true. Default is yes;
    ///    Codex overrides to skip when a Claude session is live on
    ///    the same pane (Claude wins the priority race).
    static func initialCommand(for tab: Tab, paneID: UUID) -> String? {
        guard let info = tab[keyPath: S.sessionsKeyPath][paneID],
              !info.sessionId.isEmpty
        else {
            return nil
        }
        if let existing = tab.initialCommands[paneID], !existing.isEmpty {
            return nil
        }
        guard S.shouldResume(in: tab, paneID: paneID) else { return nil }
        return S.resumeCommand(sessionId: info.sessionId, cwd: info.cwd)
    }

    static func resumeCommand(sessionId: String, cwd: String? = nil) -> String {
        S.resumeCommand(sessionId: sessionId, cwd: cwd)
    }
}
