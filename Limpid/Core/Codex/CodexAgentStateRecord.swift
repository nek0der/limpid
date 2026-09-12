// CodexAgentStateRecord.swift
// Limpid — on-disk shape of a Codex agent lifecycle record written by
// `Limpid/Resources/codex-shim/limpid-hook` after every relevant
// hook event. `CodexAgentStateStore` reads / writes; the live
// `Tab.codexAgentBadges[paneID]` mirror is rebuilt from this struct
// via `CodexAgentStateTracker`.

import Foundation

struct CodexAgentStateRecord: AgentLifecycleRecord, Equatable {
    /// Bumped on a breaking on-disk migration.
    var schemaVersion: Int
    /// One shim invocation. Nil only for schema-v1 pane-scoped records.
    var runId: String?
    /// Per-runtime ordering independent of wall-clock timestamp resolution.
    var revision: Int?
    /// Revision at which the current lifecycle-state episode began.
    var stateEpisodeToken: String?
    /// UUID of the split-tree leaf that launched this runtime.
    var paneId: String
    /// The lifecycle state encoded by the hook script.
    var state: String
    /// Free-form tag for the tooltip.
    var detail: String?
    /// ISO-8601 instant `UserPromptSubmit` was observed.
    var runStartedAt: String?
    /// ISO-8601 instant of this record's write.
    var updatedAt: String
    /// Diagnostic — which hook event produced this record.
    var lastHookEvent: String?
    /// `current_token_count` from the most recent `PreCompact`.
    var contextTokens: Int?
    /// Real codex process pid as a decimal string, captured by the
    /// hook from the parent shell pid. Read by the PID sweep to clear
    /// stale state when the process dies without firing `Stop`.
    var pid: String?
    /// The most recent user prompt observed via UserPromptSubmit.
    var lastPrompt: String?
    /// The session's opening user prompt, captured once and never
    /// overwritten. Codex has no auto-generated conversation title, so
    /// this is the tab-title source `CodexAgentStateTracker` reflects
    /// into `Tab.title` (`lastPrompt` would drift off-topic each turn).
    var firstPrompt: String?
    /// ISO-8601 instant the `SessionStart` hook fired for this pane.
    /// Captured once and held verbatim across every later event in the
    /// session. Used by the title selector to pick which pane owns the
    /// tab label when more than one Claude/Codex session is alive — the
    /// most recent SessionStart wins.
    var sessionStartedAt: String?
    /// ISO-8601 instant set by `preserveLiveSessionsOnTerminate` when
    /// Limpid quits while the codex process is still alive. The next
    /// bootstrap's `cleanupDeadSessionsOnLaunch` reads this to give
    /// the session **one** resume attempt, then clears the field so
    /// the cycle can't loop forever — if SessionStart on resume fires
    /// late (Codex TUI quirk), the state is unrecoverable but we
    /// at least don't auto-resume forever after a `/quit`.
    var killedByLimpidAt: String?
    /// Evidence that a known-dead direct runtime already received its one resume attempt.
    var resumeAttemptedAt: String?
    /// `true` while the agent runs inside tmux, whether entered manually or
    /// hosted by Limpid. Drives the mark on the tab column's identity icon.
    var isTmuxHosted: Bool?
    /// Stable tmux endpoint fields. All three are present together.
    var tmuxSocketPath: String?
    var tmuxSessionId: String?
    var tmuxPaneId: String?
    /// Missing on older records; we leave their tmux attachment unresolved.
    var tmuxServerPID: String?
    var tmuxServerStartedAt: String?
}
