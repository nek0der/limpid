// AgentState.swift
// Limpid — lifecycle enum for the agent-state visualisation feature.
// Shared between Claude Code and Codex CLI integrations; the per-pane
// badge structs (`ClaudeAgentBadge`, `CodexAgentBadge`) carry the
// free-form display metadata around this strict enum. Pre-split this
// type was named `ClaudeAgentState`; after adding the Codex
// integration we lifted it into a shared model so the aggregator
// could collapse both kinds into one priority comparison.
//
// This file stays UI-free — the SF Symbol / `Color` mapping lives in
// `UI/Design/AgentStatePresentation.swift`. The split keeps Core/Models
// importable from non-SwiftUI contexts (CLI tools, command-line tests).

import Foundation

enum AgentState: String, Codable, Equatable, CaseIterable {
    /// Initial / SessionEnd / unobserved. No icon rendered.
    case unknown
    /// `Stop` (Claude) / equivalent observed, agent waiting for the
    /// next user prompt.
    case idle
    /// `UserPromptSubmit` / `PreToolUse` observed.
    case running
    /// `PreCompact` observed. Same icon as running for MVP; reserved
    /// for a distinct icon in Phase 2.
    case compacting
    /// `Notification(permission_prompt)` (Claude) /
    /// `PermissionRequest` (Codex) / equivalent observed. The user
    /// must answer before the agent can continue.
    case needsInput
    /// `StopFailure` observed. Rate limit, billing error, etc.
    case error

    /// Aggregate priority. Higher value wins when multiple panes have
    /// different states (error > needsInput > running > others). Used
    /// by both L1 (container) and L2 (tab) aggregation.
    var priority: Int {
        switch self {
        case .error: 4
        case .needsInput: 3
        case .running, .compacting: 2
        case .idle: 1
        case .unknown: 0
        }
    }

    /// Does this state warrant a visible status badge? Idle and
    /// unknown intentionally suppress the icon to keep rows quiet
    /// (a Claude pane sitting at the prompt should look like any
    /// other shell pane). Drives both the per-pane render decision
    /// and the aggregator's "should this propagate up" filter.
    var hasVisibleBadge: Bool {
        switch self {
        case .running, .compacting, .needsInput, .error: true
        case .idle, .unknown: false
        }
    }
}

extension Sequence<AgentState> {
    /// Collapse multiple pane states to the single state that should
    /// drive the aggregate icon. Returns `nil` when nothing warrants
    /// a visible badge (all idle / unknown / empty).
    ///
    /// Used by both L1 (container-wide pane states) and L2 (one tab's
    /// pane states); the function shape is identical, only the scope
    /// of the input differs.
    func aggregateAgentState() -> AgentState? {
        var best: AgentState?
        for state in self where state.hasVisibleBadge {
            if best == nil || state.priority > best!.priority {
                best = state
            }
        }
        return best
    }
}
