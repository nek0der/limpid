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
    /// Strict lifecycle; the views derive the state's glyph from it.
    var state: AgentState

    /// Free-form tag used by the hover tooltip: `tool_name`
    /// (PreToolUse), `error_type` (StopFailure), `"permission"` /
    /// permission-request message (Notification / PermissionRequest),
    /// etc. Empty / nil when there is nothing to add.
    var detail: String?

    /// Wall-clock instant `UserPromptSubmit` was observed: set while a
    /// turn is open. Cleared when the turn ends (`Stop`, `StopFailure`, an
    /// interrupt, or the idle prompt after a turn that stopped without a
    /// `Stop`), on `SessionEnd`, and on a session start other than a
    /// compaction, which keeps the turn it came in open. A run shown at work
    /// without it is working outside a turn (ADR 0004, "Work outside a
    /// turn"). The tooltip's elapsed-seconds value is computed at render
    /// time as `Date().timeIntervalSince(runStartedAt)` so it never goes
    /// stale.
    var runStartedAt: Date?

    /// `current_token_count` from the most recent `PreCompact`. Used
    /// for the compacting tooltip; not load-bearing for icon choice.
    var contextTokens: Int?

    /// `true` while the agent runs inside a tmux session Limpid hosts for
    /// it, so the pane strip's tab can mark the pane as one that outlives a quit.
    /// Optional rather than defaulted because synthesized `Codable` applies
    /// no defaults, and a badge persisted before this field existed has to
    /// keep decoding.
    var isTmuxHosted: Bool?

    /// Wall-clock stamp of the record write this badge mirrors. The rules
    /// order writes by `revision` and fall back to this stamp only for records
    /// from before revisions existed; the interface uses it for retention and
    /// as when an attention item arrived.
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
    /// The worktree the run's latest prompt was given in, whether or not
    /// its snapshot was taken: where the restore gate looks for the agent,
    /// as Rust does under the worktree lock.
    var worktreeRoot: String?

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

    /// The prompt cache window the last finished turn left. Optional
    /// because only a provider with the cache window capability reports
    /// one, a turn may leave it unknown, and a badge persisted before this
    /// field existed has to keep decoding.
    var cacheWindow: AgentCacheWindow?

    /// The usage limit the run stopped at, present only while it rests in
    /// error. Optional so a badge persisted before this field existed
    /// keeps decoding.
    var usageLimit: UsageLimit?

    /// What the run waits on, as the projection spells it ("approval",
    /// "question"), present only while it waits. Kept as the word rather
    /// than `PromptWaitKind` so a kind a newer build writes still decodes,
    /// as none (`promptWaitKind`).
    var waitKind: String?

    /// The tool the run waits to use, present only while it waits.
    /// Optional so a badge persisted before these fields existed keeps
    /// decoding.
    var tool: String?

    /// Why the run stopped when no hook said so, as the projection spells
    /// it ("processExited"), present only on the one pass that shows a run
    /// whose process died at work in error before its record is retired,
    /// or ("waitDeclined") while a run whose wait the person declined at
    /// the agent's prompt shows its turn stopped before its record says so,
    /// or ("interrupted") while a run whose work the person stopped with
    /// Esc or Ctrl+C does.
    /// Kept as the word, as `waitKind` is, so a reason a newer build writes
    /// still decodes.
    var stopReason: String?

    /// Whether the session holds a conversation to resume: `false` for one
    /// started anew and never prompted, which has no transcript, so a stop
    /// of it offers no resume. Optional so a badge persisted before
    /// this field existed keeps decoding, and `nil` when the record does
    /// not say.
    var hasPrompt: Bool?

    var promptWaitKind: PromptWaitKind? {
        waitKind.flatMap(PromptWaitKind.init(rawValue:))
    }

    /// Whether the run is in error because its process died at work, which
    /// no hook reports.
    var hasProcessExited: Bool {
        stopReason == Self.processExitedReason
    }

    /// The projection's word for a run whose process died at work.
    static let processExitedReason = "processExited"

    /// Whether the run's turn stopped because the person declined the
    /// question or permission prompt it waited on, which no hook reports:
    /// the projection read it from the agent's transcript, and says so
    /// until the record it asks to be written says the turn stopped.
    var isWaitDeclined: Bool {
        stopReason == Self.waitDeclinedReason
    }

    /// This is the projection's word for a wait the person declined at the
    /// agent's own prompt.
    static let waitDeclinedReason = "waitDeclined"
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

    /// The arguments that resume a session of this flavor (`claude
    /// --resume <id>`, `codex resume <id>`), which "Resume Same
    /// Conversation" and the resume at app launch both type into the
    /// pane's shell: the session's resume alone, with no fresh start
    /// after it and its errors left on screen, so a failure is the person's
    /// to read rather than a new conversation in its place. The id is
    /// checked by `AgentKind.strictResumeCommand`.
    static func strictResumeArguments(sessionId: String) -> String
}

extension AgentKind {
    /// The agent started anew, in `cwd` when one is given: the command a
    /// stop's "Start New Conversation" types. Refused, as the resume
    /// is, for a folder with a control character in its name.
    func newConversationCommand(cwd: String?) -> String? {
        if let cwd, cwd.unicodeScalars.contains(where: \.isTypedControl) {
            return nil
        }
        guard let cwd, !cwd.isEmpty else { return launchCommand }
        return "cd \(ShellQuote.single(cwd)) && \(launchCommand)"
    }

    /// The strict resume of this flavor, in `cwd` when one is known: the
    /// folder the conversation was in, which Claude requires and Codex
    /// would otherwise resume somewhere else. `&&`, so a folder that is
    /// gone starts nothing. `nil` for an id that is not a session's, or a
    /// folder with a control character in its name, which the typed
    /// command would carry to the line editor as a key.
    func strictResumeCommand(sessionId: String, cwd: String? = nil) -> String? {
        guard AgentSessionIDValidator.isStrictlyValid(sessionId) else { return nil }
        if let cwd, cwd.unicodeScalars.contains(where: \.isTypedControl) {
            return nil
        }
        let resume = switch self {
        case .claude: ClaudeAgent.strictResumeArguments(sessionId: sessionId)
        case .codex: CodexAgent.strictResumeArguments(sessionId: sessionId)
        }
        guard let cwd, !cwd.isEmpty else { return resume }
        return "cd \(ShellQuote.single(cwd)) && \(resume)"
    }
}
