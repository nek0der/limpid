// CodexAgent.swift
// Limpid — concrete `AgentSpec` for the Codex flavour. Mirror of
// `ClaudeAgent` with the Codex-specific PID-sweep cadence, the
// `firstPrompt` capture that drives Codex tab titles, the
// `codex resume` command shape, and the priority gate that keeps
// Codex from racing Claude on a shared pane.

import Foundation

enum CodexAgent: AgentSpec {
    typealias StateRecord = CodexAgentStateRecord
    typealias SessionRecord = CodexSessionRecord

    static var kind: AgentKind {
        .codex
    }

    static var label: String {
        "codex"
    }

    static var badgesKeyPath: WritableKeyPath<Tab, [UUID: AgentBadge]> {
        \Tab.codexAgentBadges
    }

    static var sessionsKeyPath: WritableKeyPath<Tab, [UUID: AgentSessionInfo]> {
        \Tab.codexSessions
    }

    /// 3s — Codex sessions can vanish inside a single tick without
    /// firing `Stop` (TUI quirk), so the PID sweep runs much hotter
    /// than Claude's. The lower wakeup cost is acceptable because
    /// only foreground panes carry the timer.
    static var pidSweepInterval: TimeInterval {
        3
    }

    static func makeBadge(from record: CodexAgentStateRecord) -> AgentBadge? {
        guard let state = AgentState(rawValue: record.state) else { return nil }
        let detail = (record.detail?.isEmpty == false) ? record.detail : nil
        let updatedAt = AgentDateParsing.parseISO8601(record.updatedAt) ?? Date()
        let lastPrompt = (record.lastPrompt?.isEmpty == false) ? record.lastPrompt : nil
        let firstPrompt = (record.firstPrompt?.isEmpty == false) ? record.firstPrompt : nil
        return AgentBadge(
            state: state,
            detail: detail,
            runStartedAt: AgentDateParsing.parseOptional(record.runStartedAt),
            contextTokens: record.contextTokens,
            updatedAt: updatedAt,
            lastPrompt: lastPrompt,
            firstPrompt: firstPrompt,
            sessionStartedAt: AgentDateParsing.parseOptional(record.sessionStartedAt)
        )
    }

    /// Shell command that tries `codex resume <id>` first then falls
    /// back to a fresh `codex` if the session is gone (e.g. user
    /// purged `~/.codex/sessions/`). We use the explicit id rather
    /// than `--last` because two panes in the same cwd both want
    /// their own sessions; `--last` would collapse them.
    static func resumeCommand(sessionId: String, cwd: String?) -> String {
        // `sessionId` is restored from on-disk state; a tampered value
        // would inject shell when interpolated below. Resume only for
        // the id shape Codex emits; fall back to a fresh `codex`.
        let base = AgentSessionIDValidator.isValid(sessionId)
            ? "codex resume \(sessionId) 2>/dev/null || codex"
            : "codex"
        guard let cwd, !cwd.isEmpty else { return base }
        return "cd \(ShellQuote.single(cwd)) && \(base)"
    }

    /// Skip auto-resume when the pane already has a live Claude
    /// session — Claude takes precedence because it was launched
    /// first historically. If both somehow exist, the Claude resume
    /// wins and Codex stays dormant.
    static func shouldResume(in tab: Tab, paneID: UUID) -> Bool {
        guard let claude = tab.claudeSessions[paneID] else { return true }
        return claude.sessionId.isEmpty
    }

    /// Name the tab after the Codex conversation's opening prompt.
    /// Codex emits no auto-title and Limpid suppresses its OSC 2 pwd
    /// title, so the pane's `firstPrompt` is the only meaningful
    /// label this pane produces. Only the pane whose Codex/Claude
    /// session started most recently (`Tab.latestAgentSessionPaneID`)
    /// is allowed to push a title — without this guard, an older
    /// session typing another turn would re-emit its own
    /// `firstPrompt` and clobber a newer pane's label.
    static func applyTabTitle(_ tab: inout Tab, badges: [UUID: AgentBadge]) {
        guard let owner = tab.latestAgentSessionPaneID,
              let prompt = badges[owner]?.firstPrompt,
              !prompt.isEmpty,
              tab.title != prompt
        else { return }
        tab.title = prompt
    }
}
