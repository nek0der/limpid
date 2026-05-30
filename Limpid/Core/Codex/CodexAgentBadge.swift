// CodexAgentBadge.swift
// Limpid — in-memory mirror of one pane's Codex agent lifecycle.
// Lives on `Tab.codexAgentBadges` keyed by split-leaf UUID; the disk
// record under `~/Library/Application Support/Limpid/codex-agent-states/`
// is the authority and `CodexAgentStateTracker` rewrites this struct
// to match on every hook event.

import Foundation

struct CodexAgentBadge: Codable, Equatable, AgentNotificationBadge {
    /// Strict lifecycle. The icon shape + tint come from
    /// `state.iconName` / `state.iconColor`.
    var state: AgentState

    /// Free-form tag used by the hover tooltip: `tool_name` (PreToolUse),
    /// the permission request message, etc. Empty / nil when there is
    /// nothing useful to add.
    var detail: String?

    /// Wall-clock instant `UserPromptSubmit` was observed. Cleared on
    /// `Stop` / `SessionStart`. The tooltip's elapsed-seconds value is
    /// computed at render time as `Date().timeIntervalSince(runStartedAt)`.
    var runStartedAt: Date?

    /// `current_token_count` from the most recent `PreCompact`. Used
    /// for the compacting tooltip; not load-bearing for icon choice.
    var contextTokens: Int?

    /// Monotonic stamp used to drop out-of-order async hook updates.
    /// Tracker compares incoming `updatedAt` against the in-memory
    /// value and discards anything older.
    var updatedAt: Date

    /// User prompt captured at `UserPromptSubmit` and carried through
    /// every subsequent hook event of the same turn. Used by the
    /// "Codex finished" notification body so the user can identify
    /// *which* request just completed.
    var lastPrompt: String?

    /// The conversation's opening prompt, captured once at the first
    /// `UserPromptSubmit` and held for the session. Drives the tab
    /// title: Codex emits no auto-title and Limpid suppresses its OSC 2
    /// pwd title, so this is the only meaningful label a Codex pane gets.
    var firstPrompt: String?

    /// Wall-clock instant the Codex session began (`SessionStart`).
    /// `Tab.latestAgentSessionPaneID` compares this across Claude /
    /// Codex panes so the most recent session wins the tab title.
    var sessionStartedAt: Date?
}
