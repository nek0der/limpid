// AgentNotificationEmitter.swift
// Limpid — shared "finished / needs input" macOS notification path
// for both Claude Code and Codex CLI panes. Before this lived as two
// near-identical 80-line emit methods on each tracker; the only
// per-kind differences were the localized title string and which
// badge dict drove the source data. Pulling the logic out behind
// `AgentKind` keeps the trackers focused on disk-watching + state
// reconciliation, and makes adding a third agent (Gemini, etc.) a
// one-case-in-this-enum operation instead of a copy-paste of the
// emit code.

import Foundation

/// Minimum surface a badge needs to expose for the emitter to drive a
/// finished / needs-input notification. Both `ClaudeAgentBadge` and
/// `CodexAgentBadge` conform — they already carry these fields.
protocol AgentNotificationBadge {
    var state: AgentState { get }
    var detail: String? { get }
    var lastPrompt: String? { get }
}

@MainActor
struct AgentNotificationEmitter {
    let kind: AgentKind
    let notificationManager: LimpidNotificationManager

    /// Pane-level transition handler. Called once per leaf per
    /// reconciliation pass with the prior + current badge for that
    /// leaf; decides whether the change warrants a banner and, if so,
    /// builds + sends it. Mirrors the per-tracker logic exactly:
    ///
    /// - `(running|compacting) → finished` → "X finished" with last prompt.
    /// - `* → needsInput` (when previous wasn't already needsInput) →
    ///   "X needs input" with the permission text / question.
    ///
    /// `.error` panes get no banner — the red icon is enough, and
    /// agent-side rate-limit / billing dialogs already cover this.
    func handleTransition(
        tab: Tab,
        paneID: UUID,
        previous: (any AgentNotificationBadge)?,
        current: any AgentNotificationBadge,
        session: WindowSession
    ) {
        if current.state == .needsInput, previous?.state != .needsInput {
            emitNeedsInput(
                tab: tab,
                paneID: paneID,
                badge: current,
                session: session
            )
            return
        }
        guard current.state == .finished,
              let previous,
              previous.state == .running || previous.state == .compacting
        else { return }
        emitFinished(
            tab: tab,
            paneID: paneID,
            previousBadge: previous,
            session: session
        )
    }

    // MARK: - Private

    private func emitFinished(
        tab: Tab,
        paneID: UUID,
        previousBadge: any AgentNotificationBadge,
        session: WindowSession
    ) {
        let containerLabel = session.containerLabel(for: tab.container)
        // Container label (project / worktree path) carries more signal
        // than `tab.displayTitle` — Claude / Codex both set the OSC 0
        // title to a generic "Claude Code" / "codex" string, so we fall
        // back to the localized "{kind} finished" only when there's no
        // container to anchor on.
        let title = containerLabel.isEmpty ? kind.finishedTitle : containerLabel
        let body: String = if let prompt = previousBadge.lastPrompt,
                              let cleaned = Self.truncatedPrompt(prompt)
        {
            cleaned
        } else {
            kind.finishedTitle
        }
        send(tab: tab, paneID: paneID, title: title, body: body, session: session)
    }

    private func emitNeedsInput(
        tab: Tab,
        paneID: UUID,
        badge: any AgentNotificationBadge,
        session: WindowSession
    ) {
        let containerLabel = session.containerLabel(for: tab.container)
        let title = containerLabel.isEmpty ? kind.needsInputTitle : containerLabel
        let body: String = {
            if let detail = badge.detail,
               let cleaned = Self.truncatedPrompt(detail)
            {
                return cleaned
            }
            if let prompt = badge.lastPrompt,
               let cleaned = Self.truncatedPrompt(prompt)
            {
                return cleaned
            }
            return kind.needsInputTitle
        }()
        send(tab: tab, paneID: paneID, title: title, body: body, session: session)
    }

    private func send(
        tab: Tab,
        paneID: UUID,
        title: String,
        body: String,
        session: WindowSession
    ) {
        notificationManager.send(
            title: title,
            body: body,
            paneID: paneID,
            tabID: tab.id,
            containerID: tab.container,
            requireFocus: true,
            kind: .desktop,
            tabTitleSnapshot: tab.displayTitle,
            containerLabel: session.containerLabel(for: tab.container)
        )
        // Agent events fire the macOS banner + history entry (above) but
        // deliberately do NOT bump the per-pane unread count that drives
        // the tab column/container column bell — an agent's attention surface is the lifecycle
        // badge + the Waiting list, not the bell. Routing them through
        // the bell too would double-signal the same event. The bell is
        // reserved for non-agent unread (terminal OSC 9/777, child-exit)
        // handled in GhosttyEventCoordinator.
    }

    /// Collapse whitespace + truncate to ~80 chars. Returns `nil` if
    /// the result would be empty so callers can fall back to a generic
    /// string. The macOS banner only shows a few lines anyway, so an
    /// 80-char window matches what the user actually sees.
    private static func truncatedPrompt(_ raw: String) -> String? {
        let collapsed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        let limit = 80
        if collapsed.count <= limit { return collapsed }
        let cutoff = collapsed.index(collapsed.startIndex, offsetBy: limit - 1)
        return collapsed[..<cutoff] + "…"
    }
}

extension AgentKind {
    /// macOS notification title used when a `(running|compacting) →
    /// finished` transition fires for this agent kind. Each case must use a
    /// string literal so the `Localizable.xcstrings` extractor can
    /// pick up both keys at build time.
    var finishedTitle: String {
        switch self {
        case .claude: String(localized: "Claude finished")
        case .codex: String(localized: "Codex finished")
        }
    }

    /// macOS notification title used when a pane transitions into
    /// `.needsInput` from any non-needsInput state.
    var needsInputTitle: String {
        switch self {
        case .claude: String(localized: "Claude needs input")
        case .codex: String(localized: "Codex needs input")
        }
    }
}
