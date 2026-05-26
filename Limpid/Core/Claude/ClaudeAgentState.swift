// ClaudeAgentState.swift
// Limpid — lifecycle enum for the agent-state visualisation feature.
// Mirrors cmux's `AgentHibernationLifecycleState` 2-layer split: this
// is the strict enum used for gating and aggregation; `ClaudeAgentBadge`
// carries the free-form display metadata around it.

import Foundation
import SwiftUI

enum ClaudeAgentState: String, Codable, Equatable, CaseIterable {
    /// Initial / SessionEnd / unobserved. No icon rendered.
    case unknown
    /// `Stop` observed, claude waiting for the next user prompt.
    case idle
    /// `UserPromptSubmit` / `PreToolUse` (non-AskUserQuestion) observed.
    case running
    /// `PreCompact` observed. Same icon as running for MVP; reserved
    /// for a distinct icon in Phase 2.
    case compacting
    /// `Notification(permission_prompt)` or
    /// `PreToolUse(tool_name=AskUserQuestion)` observed. The user must
    /// answer before claude can continue.
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

    /// SF Symbol used for the L1 / L2 status icon. `nil` when nothing
    /// should be rendered (idle / unknown — keeps the row quiet).
    ///
    /// All three states share the `.circle.fill` family so the row of
    /// status indicators reads as a single visual language — colour
    /// and the inner glyph distinguish the state, the surrounding
    /// circle stays constant.
    var iconName: String? {
        switch self {
        case .running, .compacting: "bolt.circle.fill"
        case .needsInput: "questionmark.circle.fill"
        case .error: "exclamationmark.circle.fill"
        case .idle, .unknown: nil
        }
    }

    /// System-tinted colour for the icon. `nil` when no icon renders.
    /// Dark / light mode is handled by the SwiftUI `Color(.system…)`
    /// initialiser.
    var iconColor: Color? {
        switch self {
        case .running, .compacting: Color(.systemBlue)
        case .needsInput: Color(.systemOrange)
        case .error: Color(.systemRed)
        case .idle, .unknown: nil
        }
    }
}

extension Sequence<ClaudeAgentState> {
    /// Collapse multiple pane states to the single state that should
    /// drive the aggregate icon. Returns `nil` when nothing warrants
    /// a visible badge (all idle / unknown / empty).
    ///
    /// Used by both L1 (container-wide pane states) and L2 (one tab's
    /// pane states); the function shape is identical, only the scope
    /// of the input differs.
    func aggregateClaudeState() -> ClaudeAgentState? {
        var best: ClaudeAgentState?
        for state in self {
            guard state.iconName != nil else { continue }
            if best == nil || state.priority > best!.priority {
                best = state
            }
        }
        return best
    }
}
