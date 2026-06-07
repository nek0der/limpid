// ClaudeAgent.swift
// Limpid — concrete `AgentSpec` for the Claude flavour. Wires the
// type-level associatedtypes, key-paths, and the small per-flavour
// helpers (`makeBadge`, `resumeCommand`) that let the generic
// tracker / builder implementations stay agent-agnostic.

import Foundation

enum ClaudeAgent: AgentSpec {
    typealias StateRecord = ClaudeAgentStateRecord
    typealias SessionRecord = ClaudeSessionRecord

    static var kind: AgentKind {
        .claude
    }

    static var label: String {
        "claude"
    }

    static var badgesKeyPath: WritableKeyPath<Tab, [UUID: AgentBadge]> {
        \Tab.claudeAgentBadges
    }

    static var sessionsKeyPath: WritableKeyPath<Tab, [UUID: AgentSessionInfo]> {
        \Tab.claudeSessions
    }

    /// 30s — Claude's lifecycle is gentler; finished / error transitions
    /// arrive via the shim, and the PID sweep is only a defence against
    /// processes that died without firing `Stop`.
    static var pidSweepInterval: TimeInterval {
        30
    }

    static func makeBadge(from record: ClaudeAgentStateRecord) -> AgentBadge? {
        guard let state = AgentState(rawValue: record.state) else { return nil }
        let detail = (record.detail?.isEmpty == false) ? record.detail : nil
        let updatedAt = AgentDateParsing.parseISO8601(record.updatedAt) ?? Date()
        let lastPrompt = (record.lastPrompt?.isEmpty == false) ? record.lastPrompt : nil
        // Claude leaves `firstPrompt` nil — its tab title comes from
        // `ai-title` / OSC 2 instead.
        return AgentBadge(
            state: state,
            detail: detail,
            runStartedAt: AgentDateParsing.parseOptional(record.runStartedAt),
            contextTokens: record.contextTokens,
            updatedAt: updatedAt,
            lastPrompt: lastPrompt,
            firstPrompt: nil,
            sessionStartedAt: AgentDateParsing.parseOptional(record.sessionStartedAt)
        )
    }

    /// Shell command that tries the persisted session first, then
    /// falls back to a fresh `claude` if the id is stale or pruned
    /// (Claude rotates them, and the default 30-day cleanup eventually
    /// drops the on-disk JSONL). We deliberately do *not* chain
    /// `claude --continue` in between: it picks the cwd's most recent
    /// session, which means several panes in the same cwd would all
    /// land on the same conversation and silently collapse into one.
    ///
    /// When `cwd` is non-nil and non-empty, we prepend `cd '<cwd>' && …`
    /// so `claude --resume` runs in the same dir the session was
    /// captured in — Claude rejects resume otherwise.
    static func resumeCommand(sessionId: String, cwd: String?) -> String {
        // `sessionId` is restored from on-disk state; a tampered value
        // would inject shell when interpolated below. Resume only for
        // the id shape Claude emits; fall back to a fresh `claude`.
        let base = AgentSessionIDValidator.isValid(sessionId)
            ? "claude --resume \(sessionId) 2>/dev/null || claude"
            : "claude"
        guard let cwd, !cwd.isEmpty else { return base }
        return "cd \(ShellQuote.single(cwd)) && \(base)"
    }
}
