// AgentResumeCommandBuilder.swift
// Limpid — generic resume-command composer for any `AgentSpec` flavor.

import Foundation

enum AgentResumeCommandBuilder<S: AgentSpec> {
    /// Decide whether `paneID` inside `tab` should auto-launch a
    /// resumed agent session at surface-mount time. Returns the shell
    /// command to feed into `SurfaceView.initialCommand`, or `nil` if
    /// no auto-resume should fire.
    ///
    /// Conditions for a non-nil return:
    /// 1. `tab.agentSessions[S.kind][paneID]` is set with a
    ///    non-empty `sessionId`. Each split-leaf carries its own
    ///    session so two panes running the same agent concurrently
    ///    each resume independently.
    /// 2. The user / demo fixture hasn't already staged a command
    ///    for this pane in `tab.initialCommands` — that slot is the
    ///    explicit override and we never clobber it.
    /// 3. The projection named this provider in
    ///    `tab.agentResumeCandidates[paneID]`. Which provider yields when
    ///    two have a hint for one pane is a rule, and the rules live on the
    ///    other side of the boundary; this side only reads the answer.
    static func initialCommand(for tab: Tab, paneID: UUID) -> String? {
        // An unresolved tmux restore hint is not permission to create a
        // duplicate native invocation while its original runtime survives.
        guard tab.tmuxBindings[paneID] == nil else { return nil }
        guard let info = tab.agentSessions[S.kind]?[paneID],
              !info.sessionId.isEmpty
        else {
            return nil
        }
        if let existing = tab.initialCommands[paneID], !existing.isEmpty {
            return nil
        }
        guard tab.agentResumeCandidates[paneID]?.contains(S.kind) == true else { return nil }
        return S.resumeCommand(sessionId: info.sessionId, cwd: info.cwd)
    }

    static func resumeCommand(sessionId: String, cwd: String? = nil) -> String {
        S.resumeCommand(sessionId: sessionId, cwd: cwd)
    }
}
