// ClaudeAgent.swift
// Weir — concrete `AgentSpec` for the Claude flavor: its `AgentKind`
// case and the arguments that resume one of its sessions.

import Foundation
import WeirDomain

enum ClaudeAgent: AgentSpec {
    static var kind: AgentKind {
        .claude
    }

    /// `claude --resume <id>`, and not `claude --continue`: that picks the
    /// cwd's most recent session, so several panes in the same cwd would
    /// all land on the same conversation and silently collapse into one.
    static func strictResumeArguments(sessionId: String) -> String {
        "claude --resume \(sessionId)"
    }
}
