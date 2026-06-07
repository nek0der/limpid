// CodexSessionTracker.swift
// Limpid — backward-compat redirect to the generic
// `AgentSessionTracker<CodexAgent>`. See
// `ClaudeSessionTracker.swift` for the sub-phase 2.2b rationale.

import Foundation

typealias CodexSessionTracker = AgentSessionTracker<CodexAgent>

extension AgentSessionTracker where S == CodexAgent {
    convenience init() {
        self.init(store: CodexSessionStore())
    }
}
