// ClaudeAgentBadge.swift
// Limpid — in-memory mirror of one pane's agent lifecycle. Lives on
// `Tab.claudeAgentBadges` keyed by split-leaf UUID; the disk record
// under `~/Library/Application Support/Limpid/agent-states/` is the
// authority and `ClaudeAgentStateTracker` rewrites this struct to
// match on every hook event.

import Foundation

struct ClaudeAgentBadge: Codable, Equatable, AgentNotificationBadge {
    /// Strict lifecycle. The icon shape + tint come from
    /// `state.iconName` / `state.iconColor`.
    var state: AgentState

    /// Free-form tag used by the hover tooltip: `tool_name` (PreToolUse),
    /// `error_type` (StopFailure), `"permission"` (Notification), etc.
    /// Empty / nil when there is nothing to add (Stop / SessionStart).
    var detail: String?

    /// Wall-clock instant `UserPromptSubmit` was observed. Cleared on
    /// `Stop` / `SessionStart` / `SessionEnd`. The tooltip's elapsed-
    /// seconds value is computed at render time as
    /// `Date().timeIntervalSince(runStartedAt)` so it never goes stale.
    var runStartedAt: Date?

    /// `current_token_count` from the most recent `PreCompact`. Used
    /// for the compacting tooltip; not load-bearing for icon choice.
    var contextTokens: Int?

    /// Monotonic stamp used to drop out-of-order async hook updates
    /// (cmux #1492). Tracker compares incoming `updatedAt` against
    /// the in-memory value and discards anything older.
    var updatedAt: Date

    /// User prompt captured at `UserPromptSubmit` and carried through
    /// every subsequent hook event of the same turn. Used by the
    /// "Claude finished" notification body so the user can identify
    /// *which* request just completed. May be `nil` for older
    /// records or when shell extraction missed the field.
    var lastPrompt: String?
}
