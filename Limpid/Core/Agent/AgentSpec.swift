// AgentSpec.swift
// Limpid — the per-provider identity and resume command the Swift side
// still needs, plus the badge / session structs the interface holds.
//
// The lifecycle rules live in Rust behind `AgentProjectionAdapter`, so
// nothing here reads or reasons about an on-disk record. What is left is
// what only this side can answer: which `AgentKind` a provider is, what to
// call it in a log line, and the shell command that resumes one of its
// sessions in a freshly spawned pty.
//
// Naming: `AgentKind` (in `Limpid/Core/Models/`) is the runtime tag used by
// notifications and the interface. `AgentSpec` is the type-level protocol
// `AgentResumeCommandBuilder` is generic over; each conformer exposes its
// matching `AgentKind` case via `kind`.
//
// `ClaudeAgentBadge` / `CodexAgentBadge` / `ClaudeSessionInfo` /
// `CodexSessionInfo` stay as typealiases of the unified structs so the rest
// of the codebase keeps compiling unchanged.

import Foundation

// MARK: - Unified Badge

/// In-memory mirror of one pane's agent lifecycle. Lives on
/// `Tab.agentBadges` keyed by provider and then by split-leaf UUID; the
/// projection is the authority and rewrites this struct to match on every
/// pass.
///
/// Codex populates `firstPrompt`; Claude also supplies its provider title
/// observations so the Rust reducer can select the automatic tab label.
/// All other fields apply to both.
struct AgentBadge: Codable, Equatable {
    /// Strict lifecycle. The icon shape + tint come from
    /// `state.iconName` / `state.iconColor`.
    var state: AgentState

    /// Free-form tag used by the hover tooltip: `tool_name`
    /// (PreToolUse), `error_type` (StopFailure), `"permission"` /
    /// permission-request message (Notification / PermissionRequest),
    /// etc. Empty / nil when there is nothing to add.
    var detail: String?

    /// Wall-clock instant `UserPromptSubmit` was observed. Cleared on
    /// `Stop` / `SessionStart` / `SessionEnd`. The tooltip's elapsed-
    /// seconds value is computed at render time as
    /// `Date().timeIntervalSince(runStartedAt)` so it never goes stale.
    var runStartedAt: Date?

    /// `current_token_count` from the most recent `PreCompact`. Used
    /// for the compacting tooltip; not load-bearing for icon choice.
    var contextTokens: Int?

    /// `true` while the agent runs inside a tmux session Limpid hosts for
    /// it, so the tab column can mark the pane as one that outlives a quit.
    /// Optional rather than defaulted because synthesized `Codable` applies
    /// no defaults, and a badge persisted before this field existed has to
    /// keep decoding.
    var isTmuxHosted: Bool?

    /// Wall-clock stamp of the record write this badge mirrors. The rules
    /// order writes by `revision` and fall back to this stamp only for records
    /// from before revisions existed; the interface uses it for retention and
    /// Waiting-list order.
    var updatedAt: Date

    /// User prompt captured at `UserPromptSubmit` and carried through every
    /// subsequent hook event of the same turn. Used by the "agent finished"
    /// notification body so the user can identify *which* request just
    /// completed. May be `nil` when the hook missed the field.
    var lastPrompt: String?

    /// Base for showing what changed since the prompt was sent. Both values
    /// are optional because older runs and prompts outside Git repositories
    /// have no turn comparison to offer.
    var turnBaseTree: String?
    var turnRoot: String?

    /// Session opening prompt, captured once and held as the lowest-priority
    /// agent title. Both providers pass it through Rust.
    var firstPrompt: String?

    /// Provider conversation ID associated with the title observations.
    /// Missing for runs that started before formal title integration.
    var conversationID: String?

    /// Latest explicit provider title. For Claude this is the documented
    /// `SessionStart.session_title` or a later transcript compatibility
    /// observation of `customTitle`.
    var providerSessionTitle: String?

    /// Latest provider-generated title. Claude transcript parsing supplies
    /// this only as a compatibility fallback.
    var providerGeneratedTitle: String?

    /// Wall-clock instant the agent session began (`SessionStart`).
    /// `Tab.latestAgentSessionPaneID` compares this across Claude /
    /// Codex panes so the most recent session wins the tab title.
    var sessionStartedAt: Date?
}

// MARK: - Unified SessionInfo

/// In-memory mirror of one pane's resumable agent session. Lives on
/// `Tab.agentSessions` keyed by provider and then by split-leaf UUID; the
/// projection is the authority and rewrites this struct to match.
///
/// The resume builders consume both fields: `sessionId` plugs into
/// the agent's own `resume`/`--resume` flag; `cwd` lets the builder
/// prepend `cd '<cwd>' && …` so the agent finds the original
/// rollout (Claude rejects mismatched cwd; Codex resolves by cwd
/// when `--last` is implied).
struct AgentSessionInfo: Codable, Equatable {
    /// Agent's own session id, suitable for `claude --resume <id>` or
    /// `codex resume <id>`.
    var sessionId: String

    /// Working directory at the time the session was captured. `nil`
    /// (or empty after normalization) means "no usable cwd recorded"
    /// — callers fall back to the surface's cwd.
    var cwd: String?
}

// MARK: - AgentSpec protocol

/// Type-level identity for an agent flavor (Claude, Codex, and future
/// agents). `AgentResumeCommandBuilder` is generic over it so the resume
/// path has one implementation rather than one per provider.
protocol AgentSpec {
    /// Runtime tag for this flavor, shared with the rest of the app.
    /// Composes with the type-level `AgentSpec` so a generic that only has
    /// the type can still index the per-provider maps on `Tab` by the runtime
    /// `AgentKind` case.
    static var kind: AgentKind { get }

    /// Shell command Limpid types into a freshly-spawned pty when a pane is
    /// resumed at app launch. The Claude flavor emits `claude --resume <id>`;
    /// Codex emits `codex resume <id>`. `cwd` may be nil — callers handle the
    /// fallback at the command-builder layer.
    static func resumeCommand(sessionId: String, cwd: String?) -> String
}

// MARK: - Backward-compat typealiases

typealias ClaudeAgentBadge = AgentBadge
typealias CodexAgentBadge = AgentBadge
typealias ClaudeSessionInfo = AgentSessionInfo
typealias CodexSessionInfo = AgentSessionInfo
