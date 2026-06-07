// ClaudeAgentStateRecord.swift
// Limpid — on-disk shape of an agent lifecycle record written by
// `Limpid/Resources/claude-shim/limpid-hook` after every relevant
// hook event. `ClaudeAgentStateStore` reads / writes; the live
// `Tab.claudeAgentBadges[paneID]` mirror is rebuilt from this struct
// via `ClaudeAgentStateTracker`.

import Foundation

struct ClaudeAgentStateRecord: AgentLifecycleRecord, Equatable {
    /// Bumped on a breaking on-disk migration.
    var schemaVersion: Int
    /// UUID of the owning split-tree leaf. Must equal the filename —
    /// defense-in-depth against path traversal via crafted env.
    var paneId: String
    /// Lifecycle state encoded by the hook script; decoded back into
    /// `ClaudeAgentState` by callers.
    var state: String
    /// Free-form tooltip tag (`tool_name`, `error_type`, `"permission"`).
    var detail: String?
    /// ISO-8601 instant `UserPromptSubmit` was observed. Stored as
    /// `String` so the shell hook can write `date -u +"%Y-…%Z"` without
    /// going through `JSONEncoder`'s Date strategies.
    var runStartedAt: String?
    /// ISO-8601 instant of this record's write. The tracker drops any
    /// incoming record whose `updatedAt` precedes the in-memory one
    /// (out-of-order async hook).
    var updatedAt: String
    /// Diagnostic — which hook event produced this record.
    var lastHookEvent: String?
    /// `current_token_count` from the most recent `PreCompact`.
    var contextTokens: Int?
    /// Real claude pid (decimal string, captured via `$$`). Read by
    /// the 30-second PID sweep to clear stale state when the process
    /// dies without firing `Stop`.
    var pid: String?
    /// Most recent user prompt observed via `UserPromptSubmit`.
    /// Persisted through running / tool-use / compact so the Stop-hook
    /// notification can quote what was asked. Missing for older
    /// records or when sed extraction failed (embedded quotes,
    /// multi-line input).
    var lastPrompt: String?
    /// First user prompt of the session, captured once at the first
    /// `UserPromptSubmit` and never overwritten. Used by the hook's
    /// tab-title fallback (OSC 2) when Claude hasn't generated an
    /// `ai-title` yet.
    var firstPrompt: String?
    /// ISO-8601 instant the `SessionStart` hook fired for this pane.
    /// The title selector picks which pane owns the tab label when
    /// more than one Claude / Codex session is alive — most recent
    /// `SessionStart` wins.
    var sessionStartedAt: String?
}
