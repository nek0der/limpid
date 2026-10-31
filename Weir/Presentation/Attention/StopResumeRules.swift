// StopResumeRules.swift
// Weir — whether a stop can be resumed or start a new conversation, and what the resume types.

import Foundation

/// When a stop can be resumed in its conversation: it has the
/// session id to resume by, and the pane is back at its shell's prompt with
/// nothing half typed, so the resume runs as a command and nothing else.
/// With the agent still in front, the person carries on in its TUI, which
/// clears the stop as well. The bar and the button read the same answer.
enum StopResumeRules {
    static func offer(record: StopLedger.Record?, job: AgentForeground.Job, hasDraft: Bool) -> DecisionBarContent.StopResume {
        guard let record, command(for: record) != nil else { return .unavailable }
        if case .resuming = record.resume {
            return .resuming
        }
        switch job {
        case .agent:
            return .unavailable
        case .other:
            return .blocked(.notAtShell)
        case .shell where hasDraft:
            return .blocked(.draft)
        case .shell:
            return record.resume == .failed ? .failed : .available
        }
    }

    /// Whether the stop's pane can start a new conversation: the same
    /// shell at its prompt with nothing half typed that a resume needs.
    static func startsNew(job: AgentForeground.Job, hasDraft: Bool) -> Bool {
        newConversationBlocker(job: job, hasDraft: hasDraft) == nil
    }

    /// Why the stop's pane cannot start a new conversation now, `nil` when
    /// it can. An agent in front is as much in the way as an editor: the
    /// command would be keys to it.
    static func newConversationBlocker(job: AgentForeground.Job, hasDraft: Bool) -> DecisionBarContent.ResumeBlocker? {
        switch job {
        case .shell: hasDraft ? .draft : nil
        case .agent, .other: .notAtShell
        }
    }

    /// What the disabled ⋯ item says as its tooltip: what to do so it can
    /// start, as the bar says it for a resume.
    static func newConversationHelp(_ blocker: DecisionBarContent.ResumeBlocker) -> LocalizedStringResource {
        switch blocker {
        case .notAtShell:
            LocalizedStringResource(
                "To start a new conversation, return the pane to its shell prompt.",
                comment: "Tooltip of the decision bar's disabled Start New Conversation: another program is in front of the pane"
            )
        case .draft:
            LocalizedStringResource(
                "To start a new conversation, clear the prompt with Control-C.",
                comment: "Tooltip of the decision bar's disabled Start New Conversation: text is half typed at the shell's prompt"
            )
        }
    }

    /// What "Start New Conversation" types: the agent, in the folder
    /// the conversation was in, as the resume is (`command(for:)`). The
    /// shell may have moved since; a new conversation elsewhere would
    /// start in another worktree. `nil` for a folder whose name holds a
    /// control character, which typed would be keys rather than a name.
    static func newConversationCommand(for record: StopLedger.Record) -> String? {
        record.provider.newConversationCommand(cwd: record.cwd)
    }

    /// The resume typed into the stop's pane: the strict one, which leaves
    /// a failure on screen rather than starting a new conversation, in the
    /// folder the conversation was in.
    static func command(for record: StopLedger.Record) -> String? {
        record.sessionID.flatMap { record.provider.strictResumeCommand(sessionId: $0, cwd: record.cwd) }
    }
}
