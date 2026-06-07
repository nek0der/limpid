// CodexAgentStateTracker.swift
// Limpid — backward-compat redirect to the generic
// `AgentStateTracker<CodexAgent>`. See
// `ClaudeAgentStateTracker.swift` for the sub-phase 2.2d rationale.
// The Codex-only `cleanupDeadSessionsOnLaunch` and
// `preserveLiveSessionsOnTerminate` methods live in
// `AgentStateTracker.swift`'s `extension where S == CodexAgent`.

import Foundation

typealias CodexAgentStateTracker = AgentStateTracker<CodexAgent>

extension AgentStateTracker where S == CodexAgent {
    /// No-arg convenience matching the previous `CodexAgentStateTracker`
    /// init shape. The explicit `Optional` cast on `sessionStore` is
    /// load-bearing: without it, Swift's overload resolution picks this
    /// very convenience init as the more-specific match for the
    /// `(store:sessionStore:)` call below and recurses forever (the
    /// designated init declares `sessionStore: SessionStore? = nil`).
    convenience init() {
        let store: PaneStore<CodexAgentStateRecord> = CodexAgentStateStore()
        let sessionStore: PaneStore<CodexSessionRecord>? = CodexSessionStore()
        self.init(store: store, sessionStore: sessionStore)
    }
}
