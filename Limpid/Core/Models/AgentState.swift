// AgentState.swift
// Limpid — lifecycle enum for the agent-state visualization feature.
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
    /// `SessionStart` / fresh — a launched agent that hasn't run a
    /// turn yet. No icon rendered. (A turn that *has* finished maps to
    /// `finished`, not here, so the attention cursor can tell "your turn"
    /// apart from "never used".)
    case idle
    /// `UserPromptSubmit` / `PreToolUse` observed.
    case running
    /// `PreCompact` observed. Renders with the running icon today;
    /// reserved for a distinct compaction icon when multi-state UI lands.
    case compacting
    /// `Notification(permission_prompt)` (Claude) /
    /// `PermissionRequest` (Codex) / equivalent observed. The user
    /// must answer before the agent can continue.
    case needsInput
    /// `StopFailure` observed. Rate limit, billing error, etc.
    case error
    /// `Stop` observed — the agent finished its turn and is waiting on
    /// the user's next input ("your turn"). Distinct from `idle` (the
    /// fresh / at-launch state) so the attention cursor treats a finished
    /// turn as actionable without snagging on never-used panes, and so
    /// a finished pane shows a badge while a freshly launched one stays
    /// quiet.
    case finished

    /// Aggregate priority. Higher value wins when multiple panes have
    /// different states (error > needsInput > finished > running >
    /// others). Used by both container column (container) and tab column (tab) aggregation.
    var priority: Int {
        switch self {
        case .error: 5
        case .needsInput: 4
        case .finished: 3
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
        case .running, .compacting, .needsInput, .error, .finished: true
        case .idle, .unknown: false
        }
    }

    /// Localized label used in the agent-breakdown tooltip surfaces
    /// (`ContainerRow.agentTooltip` / `TabRow.agentTooltip`). Both
    /// sites previously leaked the raw Swift case identifier (e.g.
    /// `needsInput`) into the tooltip even in ja. Resolving through
    /// the catalog at the model layer keeps the two tooltip sites in
    /// lockstep.
    var localizedLabel: String {
        switch self {
        case .error: String(localized: "Error", comment: "Agent state label")
        case .needsInput: String(localized: "Needs input", comment: "Agent state label")
        case .finished: String(localized: "Finished", comment: "Agent state label")
        case .running, .compacting: String(localized: "Running", comment: "Agent state label")
        case .idle: String(localized: "Idle", comment: "Agent state label")
        case .unknown: String(localized: "Unknown", comment: "Agent state label")
        }
    }
}

extension Sequence<AgentState> {
    /// Collapse multiple pane states to the single state that should
    /// drive the aggregate icon. Returns `nil` when nothing warrants
    /// a visible badge (all idle / unknown / empty).
    ///
    /// Used by both container column (container-wide pane states) and tab column (one tab's
    /// pane states); the function shape is identical, only the scope
    /// of the input differs.
    func aggregateAgentState() -> AgentState? {
        var best: AgentState?
        for state in self where state.hasVisibleBadge {
            if best.map({ state.priority > $0.priority }) ?? true {
                best = state
            }
        }
        return best
    }
}
