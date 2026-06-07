// AgentSpec.swift
// Limpid — protocol + unified data types shared by the Claude and
// Codex agent slices. First sub-phase (2.2a) of Phase 2 #2 from the
// architecture roadmap: this file introduces the type vocabulary so
// the later sub-phases (2.2b–2.2d) can collapse the parallel
// tracker / builder implementations into generics.
//
// Naming: `AgentKind` (in `Limpid/Core/Models/`) is the existing
// runtime tag — a plain `enum { .claude, .codex }` used by
// notifications and UI. `AgentSpec` (in this file) is the type-level
// protocol describing how a generic tracker / builder talks to a
// concrete flavor. The two compose — each `AgentSpec` conformer
// exposes its matching `AgentKind` case via `kind`.
//
// Today the file unifies `AgentBadge` and `AgentSessionInfo` (Claude
// and Codex had structurally identical Codable structs) and declares
// the protocol. `ClaudeAgentBadge` / `CodexAgentBadge` /
// `ClaudeSessionInfo` / `CodexSessionInfo` stay as typealiases so the
// rest of the codebase keeps compiling unchanged.

import Foundation

// MARK: - Unified Badge

/// In-memory mirror of one pane's agent lifecycle. Lives on
/// `Tab.claudeAgentBadges` / `Tab.codexAgentBadges` keyed by
/// split-leaf UUID; the per-pane disk record is the authority and
/// the matching tracker (`Claude*`/`Codex*AgentStateTracker`)
/// rewrites this struct to match on every hook event.
///
/// Codex populates `firstPrompt` (its only meaningful tab title since
/// Codex emits no auto-title and Limpid suppresses its OSC 2 pwd
/// title); Claude leaves it nil and lets `ai-title` / OSC 2 drive the
/// label. All other fields apply to both.
struct AgentBadge: Codable, Equatable, AgentNotificationBadge {
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

    /// Monotonic stamp used to drop out-of-order async hook updates.
    /// Tracker compares incoming `updatedAt` against the in-memory
    /// value and discards anything older.
    var updatedAt: Date

    /// User prompt captured at `UserPromptSubmit` and carried through
    /// every subsequent hook event of the same turn. Used by the
    /// "agent finished" notification body so the user can identify
    /// *which* request just completed. May be `nil` for older records
    /// or when shell extraction missed the field.
    var lastPrompt: String?

    /// Codex-only: the session's opening prompt, captured once at the
    /// first `UserPromptSubmit` and held for the session. Drives the
    /// Codex tab title. Always `nil` for Claude — Claude uses
    /// `ai-title` / OSC 2 instead.
    var firstPrompt: String?

    /// Wall-clock instant the agent session began (`SessionStart`).
    /// `Tab.latestAgentSessionPaneID` compares this across Claude /
    /// Codex panes so the most recent session wins the tab title.
    var sessionStartedAt: Date?
}

// MARK: - Unified SessionInfo

/// In-memory mirror of one pane's resumable agent session. Lives on
/// `Tab.claudeSessions` / `Tab.codexSessions` keyed by split-leaf
/// UUID; the per-pane disk record is the authority and bootstrap
/// rewrites this struct to match.
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

/// Type-level identity for an agent flavor (Claude, Codex, and
/// future agents …). 2.2a only declares the protocol; the generic
/// tracker / builder implementations that consume it land in
/// 2.2b–2.2d. Kept in this file with the unified data types so the
/// next sub-phase is a one-spot reference.
/// `PaneScopedRecord` refined with the lifecycle fields the generic
/// `AgentStateTracker` reads: the agent's pid (so the PID sweep can
/// `kill(_, 0)` it) and the monotonic `updatedAt` stamp used to drop
/// out-of-order async hook writes. Both Claude / Codex
/// `*AgentStateRecord` types already expose these fields; this
/// protocol just promotes them to the type system so the generic
/// tracker can reach them without `Mirror`.
protocol AgentLifecycleRecord: PaneScopedRecord {
    var pid: String? { get }
    var updatedAt: String { get }
}

protocol AgentSpec {
    associatedtype StateRecord: AgentLifecycleRecord
    associatedtype SessionRecord: PaneScopedRecord

    /// Runtime tag for this flavor, shared with the rest of the app.
    /// Composes with the type-level `AgentSpec` so a generic that
    /// only has the type can still emit notifications / log
    /// statements keyed on the runtime `AgentKind` case.
    static var kind: AgentKind { get }

    /// Short identifier used in log categories and diagnostic
    /// strings — `"claude"` / `"codex"`.
    static var label: String { get }

    /// Tab → `[UUID: AgentBadge]` mapping the generic state tracker
    /// reads / writes. Each agent flavor points at its own dict
    /// (`Tab.claudeAgentBadges` vs `Tab.codexAgentBadges`) so the
    /// on-disk Tab schema stays unchanged.
    static var badgesKeyPath: WritableKeyPath<Tab, [UUID: AgentBadge]> { get }

    /// Tab → `[UUID: AgentSessionInfo]` mapping the generic session
    /// tracker reads / writes. Same Tab-schema preservation rationale
    /// as `badgesKeyPath`.
    static var sessionsKeyPath: WritableKeyPath<Tab, [UUID: AgentSessionInfo]> { get }

    /// Interval at which the generic state tracker sweeps for dead
    /// agent PIDs. Claude polls every 30 s (foreground app, gentle
    /// load); Codex polls every 3 s because its sessions can vanish
    /// inside a single tick without firing `Stop`.
    static var pidSweepInterval: TimeInterval { get }

    /// Build a unified `AgentBadge` from an on-disk state record.
    /// Each flavor fills in the fields its hook actually populates;
    /// the others stay `nil`. Returns `nil` when the record's state
    /// string doesn't decode (a forward-compat tolerance: ignore
    /// rather than crash on hook output from a newer Limpid).
    static func makeBadge(from record: StateRecord) -> AgentBadge?

    /// Shell command Limpid types into a freshly-spawned pty when a
    /// pane is resumed at app launch. The Claude flavor emits
    /// `claude --resume <id>`; Codex emits `codex resume <id>`. `cwd`
    /// may be nil — callers handle the fallback at the
    /// command-builder layer.
    static func resumeCommand(sessionId: String, cwd: String?) -> String

    /// Per-flavor priority gate for the auto-resume command builder.
    /// Claude always returns `true`; Codex returns `false` when the
    /// same pane already has a live Claude session so the two don't
    /// race for the pty. Default conformance returns `true`.
    static func shouldResume(in tab: Tab, paneID: UUID) -> Bool

    /// Per-flavor tab-title hook called once per
    /// `applyAllRecordsToSession` pass after the badges dictionary
    /// has been reconciled. Codex uses this to push the focused
    /// pane's `firstPrompt` into `tab.title` (its only tab-title
    /// source). Claude leaves it alone — Claude's hook drives OSC 2
    /// directly. Default conformance is a no-op.
    static func applyTabTitle(_ tab: inout Tab, badges: [UUID: AgentBadge])
}

extension AgentSpec {
    static func shouldResume(in _: Tab, paneID _: UUID) -> Bool {
        true
    }

    static func applyTabTitle(_: inout Tab, badges _: [UUID: AgentBadge]) {}
}

// MARK: - Backward-compat typealiases

typealias ClaudeAgentBadge = AgentBadge
typealias CodexAgentBadge = AgentBadge
typealias ClaudeSessionInfo = AgentSessionInfo
typealias CodexSessionInfo = AgentSessionInfo
