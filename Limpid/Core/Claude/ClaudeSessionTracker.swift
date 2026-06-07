// ClaudeSessionTracker.swift
// Limpid — backward-compat redirect to the generic
// `AgentSessionTracker<ClaudeAgent>` (`Limpid/Core/Agent/`). Sub-phase
// 2.2b replaced the two parallel session-tracker classes with one
// generic parameterized on `AgentSpec`. Existing references to
// `ClaudeSessionTracker` resolve via the typealias below; the
// convenience `init()` mirrors the previous no-arg shape so call
// sites keep compiling unchanged.

import Foundation

typealias ClaudeSessionTracker = AgentSessionTracker<ClaudeAgent>

extension AgentSessionTracker where S == ClaudeAgent {
    convenience init() {
        self.init(store: ClaudeSessionStore())
    }
}
