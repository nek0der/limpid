// AgentState.swift
// Limpid — lifecycle enum for the agent-state visualization feature.
// Shared between Claude Code and Codex CLI integrations; the per-pane
// badge struct (`AgentBadge`) carries the free-form display metadata
// around this strict enum. One enum for both providers, so both kinds
// read through one set of rules (`SessionRowFact`).
//
// This file stays UI-free — the state glyph mapping lives in
// `UI/Design/AgentStatePresentation.swift`. The split keeps it a Domain
// value, importable from non-SwiftUI contexts (CLI tools, command-line tests).

import Foundation

enum AgentState: String, Codable, Equatable, CaseIterable {
    /// Initial / SessionEnd / unobserved: no hook has said what the run is
    /// doing.
    case unknown
    /// `SessionStart` / fresh — a launched agent that hasn't run a
    /// turn yet. (A turn that *has* finished maps to `finished`, not here,
    /// so the attention list can tell "your turn" apart from "never
    /// used".)
    case idle
    /// `UserPromptSubmit` / `PreToolUse` observed.
    case running
    /// `PreCompact` observed. Drawn with the running glyph; the row's line
    /// says it is compacting.
    case compacting
    /// `Notification(permission_prompt)` (Claude) /
    /// `PermissionRequest` (Codex) / equivalent observed. The user
    /// must answer before the agent can continue.
    case needsInput
    /// `StopFailure` observed. Rate limit, billing error, etc.
    case error
    /// `Stop` observed — the agent finished its turn and is waiting on
    /// the user's next input ("your turn"). Distinct from `idle` (the
    /// fresh / at-launch state) so the attention list treats a finished
    /// turn as actionable without snagging on never-used panes.
    case finished
}

extension AgentState {
    /// Whether the run is in a turn: working, compacting, or waiting on the
    /// person to answer before it goes on. The one meaning of "an agent is
    /// at work" every place that waits on one reads: an approval card's
    /// place (`ApprovalPresentationStore`), the new worktree sheet's note
    /// on the project's folder, and what holds "Create PR" back
    /// (`AttentionState.isAgentMidTurn`). A run waiting on an answer is
    /// counted: its turn is not over, and what it changes next is still to
    /// come. The hook's rules count the same states as at work
    /// (`RunState::is_at_work`); the two sides check the set against
    /// `rust/fixtures/contract/shared-values.json`.
    var isMidTurn: Bool {
        switch self {
        case .running, .compacting, .needsInput: true
        case .unknown, .finished, .error, .idle: false
        }
    }
}
