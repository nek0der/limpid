// AgentResumeCommandBuilder.swift
// Weir — generic resume-command composer for any `AgentSpec` flavor.

import Foundation

/// The resume typed into a restored pane at launch: the session and the
/// command, so the stop ledger can watch the one the command resumes
/// (`StopLedgerStore.markResumingAtLaunch`).
struct AgentResume: Equatable, Sendable {
    let provider: AgentKind
    let sessionID: String
    let cwd: String?
    let command: String
}

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
        resume(for: tab, paneID: paneID)?.command
    }

    /// `initialCommand`, with the session it resumes.
    static func resume(for tab: Tab, paneID: UUID) -> AgentResume? {
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
        guard tab.agentResumeCandidates[paneID]?.contains(S.kind) == true,
              let command = resumeCommand(sessionId: info.sessionId, cwd: info.cwd)
        else { return nil }
        return AgentResume(provider: S.kind, sessionID: info.sessionId, cwd: info.cwd, command: command)
    }

    /// The strict resume (`AgentKind.strictResumeCommand`), as "Resume
    /// Same Conversation" types it: no fresh agent after a resume that
    /// fails, since a relaunch is no reason to start a new conversation in
    /// the old one's place; the failure stays on screen, and a
    /// new conversation is the person's own "Start New Conversation". `nil`
    /// for an id that is not a session's (the state file is read, not
    /// trusted) or a folder with a control character in its name, which the
    /// typed command would carry to the line editor as a key: no resume
    /// then, rather than one somewhere else.
    static func resumeCommand(sessionId: String, cwd: String? = nil) -> String? {
        S.kind.strictResumeCommand(sessionId: sessionId, cwd: cwd)
    }
}
