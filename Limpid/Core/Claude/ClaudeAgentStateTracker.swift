// ClaudeAgentStateTracker.swift
// Limpid — backward-compat redirect to the generic
// `AgentStateTracker<ClaudeAgent>`. Sub-phase 2.2d collapsed the two
// parallel agent-state trackers (~785 LOC of near-identical code)
// onto `AgentSpec`. Existing references to `ClaudeAgentStateTracker`
// resolve via the typealias; the convenience `init()` mirrors the
// previous no-arg shape so call sites keep compiling.

import Foundation

typealias ClaudeAgentStateTracker = AgentStateTracker<ClaudeAgent>

extension AgentStateTracker where S == ClaudeAgent {
    convenience init() {
        self.init(store: ClaudeAgentStateStore())
    }
}

// MARK: - WindowSession helper

@MainActor
extension WindowSession {
    /// Apply a mutating transform to every tab. Used by the agent
    /// state tracker so it can clear stale per-pane entries without
    /// hard-coding the iteration shape at the call site.
    func applyAcrossTabs(_ transform: (inout Tab) -> Void) {
        for tab in tabs {
            update(tab.id, transform: transform)
        }
    }
}
