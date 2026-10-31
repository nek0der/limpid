// AgentKind.swift
// Weir — identifier for which AI agent is driving a pane. Currently
// `.claude` and `.codex` are the only producers of lifecycle badges;
// future agents (Gemini, etc.) extend this enum. Lives next to
// `AgentState` because anywhere we surface "which agent finished /
// is waiting", we need both pieces together.

import Foundation

package enum AgentKind: String, Codable, CaseIterable, Equatable, Sendable {
    case claude
    case codex

    /// What a pane types to start the agent. The name resolves to Weir's
    /// shim on the pane's `PATH`, which installs the hooks and finds the
    /// real binary.
    package var launchCommand: String {
        rawValue
    }
}
