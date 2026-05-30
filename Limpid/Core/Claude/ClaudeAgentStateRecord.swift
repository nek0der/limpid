// ClaudeAgentStateRecord.swift
// Limpid — on-disk shape of an agent lifecycle record written by
// `Limpid/Resources/claude-shim/limpid-hook` after every relevant
// hook event. `ClaudeAgentStateStore` reads / writes; the live
// `Tab.claudeAgentBadges[paneID]` mirror is rebuilt from this struct
// via `ClaudeAgentStateTracker`.

import Foundation

struct ClaudeAgentStateRecord: Codable, Equatable {
    /// Bumped on a breaking on-disk migration. Records that don't
    /// match the expected version are ignored by callers.
    var schemaVersion: Int
    /// UUID of the owning split-tree leaf. Must equal the filename
    /// (defense in depth against path-traversal via crafted env).
    var paneId: String
    /// The lifecycle state encoded by the hook script.
    /// Decoded back into `ClaudeAgentState` by callers.
    var state: String
    /// Free-form tag for the tooltip (`tool_name`, `error_type`,
    /// `"permission"`, etc.). Empty / nil when the event doesn't
    /// carry a useful descriptor.
    var detail: String?
    /// ISO-8601 instant `UserPromptSubmit` was observed, or empty
    /// when the agent is idle / unknown. Stored as String (not Date)
    /// so the shell hook can write it with `date -u +"%Y-…%Z"`
    /// without depending on `JSONEncoder` quirks.
    var runStartedAt: String?
    /// ISO-8601 instant of this record's write. Tracker compares
    /// incoming `updatedAt` against the in-memory value and drops
    /// any out-of-order async hook (cmux #1492 root cause).
    var updatedAt: String
    /// Diagnostic — which hook event produced this record.
    var lastHookEvent: String?
    /// `current_token_count` from the most recent `PreCompact`.
    var contextTokens: Int?
    /// Real claude process pid as a decimal string, captured by the
    /// shim via `$$`. Read by the 30-second PID sweep to clear
    /// stale state when the process dies without firing `Stop`.
    var pid: String?
    /// The most recent user prompt observed via UserPromptSubmit.
    /// Persisted through running / tool-use / compact events so the
    /// Stop-hook → notification body can quote what was asked. May be
    /// missing for older records or when sed extraction couldn't
    /// parse the payload (embedded quotes / multi-line input).
    var lastPrompt: String?
    /// The session's opening prompt, captured once at the first
    /// `UserPromptSubmit` and held verbatim across every later event.
    /// Used by the hook's tab-title fallback (`terminalSequence` OSC 2)
    /// when Claude hasn't yet generated an `ai-title`. The Swift side
    /// only needs to know it exists for migration purposes.
    var firstPrompt: String?
    /// ISO-8601 instant the `SessionStart` hook fired for this pane.
    /// Captured once and held verbatim across every later event in the
    /// session. Used by the title selector to pick which pane owns the
    /// tab label when more than one Claude/Codex session is alive — the
    /// most recent SessionStart wins.
    var sessionStartedAt: String?
}
