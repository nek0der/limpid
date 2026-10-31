// AppState+AgentTracking.swift
// Weir — starts the projection and connects what leaves it to the rest of
// the application.

import Foundation
import WeirDomain

/// Where what leaves the projection goes: notifications, worktree move
/// suggestions, and the approval requests a notification can name.
struct AgentTrackingHandlers {
    let notifications: WeirNotificationManager
    let suggester: WorktreeMoveSuggester
    let approvals: ApprovalPresentationStore
}

extension AppState {
    /// A finished turn's notification leads with its receipt ("T7 · 2 files
    /// +94 −2 · ✓ Tests"). Only the run's current turn, once it has ended:
    /// an earlier turn's receipt would report the wrong one. Under the
    /// receipt, what the agent said as the turn ended, which tells whether
    /// to look; the prompt it answered is then `answered`, which the
    /// subtitle names beside the place. A turn with no reply has the prompt
    /// under its receipt instead, and `answered` is `nil`. The prompt is the
    /// payload's, longer than the turn keeps, unless the harness wrote it:
    /// the projection then quotes none, and the turn's kind words it
    /// (`TurnPromptText`).
    static func finishedText(
        _ payload: AgentNotifyPayload,
        runtimes: [AgentRuntimePresentation],
        history: [ConversationKey: [TurnSummary]],
        locale: Locale
    ) -> (body: String?, answered: String?) {
        guard let turn = finishedTurn(payload, runtimes: runtimes, history: history) else { return (payload.body, nil) }
        let receipt = ReceiptText.receipt(UnreadTurnRules.receipt(of: turn), locale: locale)
        let prompt = TurnPromptText.instruction(TurnPrompt(kind: turn.promptKind, head: payload.body), locale: locale)
        guard let reply = turn.reply else {
            return ([receipt, prompt].compactMap(\.self).joined(separator: "\n"), nil)
        }
        return ([receipt, reply].compactMap(\.self).joined(separator: "\n"), prompt)
    }

    /// The turn a finished notification reports: the run's current turn,
    /// once it has ended and someone prompted it. `nil` otherwise, as an
    /// earlier turn would report the wrong one.
    static func finishedTurn(
        _ payload: AgentNotifyPayload,
        runtimes: [AgentRuntimePresentation],
        history: [ConversationKey: [TurnSummary]]
    ) -> TurnSummary? {
        guard let runtime = runtimes.first(where: { $0.id == payload.runtimeID }),
              let conversation = runtime.conversation,
              let current = runtime.currentTurnID,
              let turn = history[conversation]?.last(where: { $0.turnID == current }),
              turn.phase != .started, turn.hasPrompt
        else { return nil }
        return turn
    }

    /// The wait a notification announces, from the run's record as the
    /// attention list reads it: the body the projection hands over is cut
    /// to a banner's length, or is the last prompt when the wait has no
    /// words, so it cannot say which wait it is. `nil` when the run is not
    /// known here, or no longer waits: its record then describes something
    /// else, and the wait is worded as one we cannot name.
    static func waitOf(_ payload: AgentNotifyPayload, runtimes: [AgentRuntimePresentation]) -> PromptWait? {
        runtimes.first(where: { $0.id == payload.runtimeID }).flatMap { waitOf($0.badge) }
    }

    /// The wait a badge describes, only while its run waits.
    static func waitOf(_ badge: AgentBadge) -> PromptWait? {
        guard badge.state == .needsInput else { return nil }
        return PromptWait(detail: badge.detail, kind: badge.promptWaitKind, tool: badge.tool)
    }

    static func bootstrapAgentTracking(
        projection: AgentProjectionAdapter,
        session: WorkspaceSession,
        attention: AttentionState,
        terminal: (tmux: TmuxPanePresence, registry: any SurfaceViewProviding),
        handlers: AgentTrackingHandlers
    ) {
        let (tmux, registry) = terminal
        let notifications = handlers.notifications
        let suggester = handlers.suggester
        let approvals = handlers.approvals
        projection.onCwdChanged = { [weak suggester] pane, newCwd, oldCwd in
            suggester?.handleEvent(paneID: pane, newCwd: newCwd, oldCwd: oldCwd)
        }
        projection.onGitSyncRequested = gitSyncRefetch(for: session)
        projection.onNotify = { [weak projection] payload, tab in
            guard let kind = AgentKind(rawValue: payload.provider) else { return false }
            var payload = payload
            // The history keeps the turn as values, with the prompt the
            // projection quoted, before the banner's body replaces it.
            var finished: NotificationEvent?
            var answered: String?
            if payload.kind == .finished, let history = projection?.turnHistory.conversations {
                let turn = finishedTurn(payload, runtimes: attention.allRuntimes, history: history)
                finished = .finished(agent: kind, turn: turn, head: payload.body)
                (payload.body, answered) = finishedText(
                    payload,
                    runtimes: attention.allRuntimes,
                    history: history,
                    locale: notifications.appLocale()
                )
            }
            // A request in that pane posts its own banner as it arrives
            // (`AttentionEffect.notify`); the hook's wait would announce the
            // same thing again, without the request.
            if payload.kind == .needsInput,
               approvals.isWaitOfRequest(runtimeID: payload.runtimeID, episodeToken: payload.episodeToken, in: session)
            {
                return true
            }
            AgentNotificationEmitter(
                kind: kind,
                notificationManager: notifications,
                suppressWhenPaneFocused: payload.suppressWhenPaneFocused,
                runtimeID: payload.runtimeID,
                eventToken: payload.eventToken
            ).deliver(
                payload,
                wait: payload.kind == .needsInput ? waitOf(payload, runtimes: attention.allRuntimes) : nil,
                finished: finished,
                answered: answered,
                tab: tab,
                session: session
            )
            return true
        }

        // Before the first pass, because a run this retires must not be
        // offered for resume by the pass that follows it.
        projection.prepareForLaunch()
        projection.bootstrap(into: session, attention: attention, tmuxPresence: tmux)
        projection.startWatching()

        tmux.onBindingsChanged = { [weak tmux, weak session, weak projection] in
            guard let tmux, let session else { return }
            session.captureTmuxBindings(
                surfaces: tmux.surfaces,
                bindings: tmux.bindingsByPaneID,
                observedAt: tmux.topology.observedAt,
                now: ProcessInfo.processInfo.systemUptime,
                detachedPaneIDs: tmux.detachedPaneIDs
            )
            projection?.requestPass()
        }
        attention.onRuntimeAttentionChanged = { [weak projection] in
            // Defer until the current pass completes: marking a newly finished
            // visible run viewed must not re-enter the projection.
            Task { @MainActor in projection?.requestPass() }
        }
        tmux.start(surfaces: { [weak session, weak registry] in
            guard let session, let registry else { return [] }
            return session.tabs.flatMap { $0.splitTree.allLeafIDs() }.map { paneID in
                let view = registry.view(for: paneID)
                let pid = view?.surface.flatMap { GhosttyFFI.surfaceForegroundPID($0) }
                return TmuxSurfaceSnapshot(
                    paneID: paneID,
                    tty: view?.ttyName,
                    foregroundPID: pid,
                    foregroundName: pid.flatMap(TmuxPanePresence.processName)
                )
            }
        }, candidates: { [weak session, weak projection] in
            let restored = session?.tabs.flatMap { $0.tmuxBindings.values.map(\.socketPath) } ?? []
            return (projection?.socketPaths ?? []).union(restored)
        })
    }

    /// Asks GitSync to refetch the repository a worktree was just created in.
    ///
    /// The projection reports the repository root and nothing else, because
    /// which project that is depends on the session, which is this side's to
    /// know. Paths are compared after standardizing and trimming the trailing
    /// slash, since the agent's `cwd` and the stored root are written by
    /// different producers.
    private static func gitSyncRefetch(for session: WorkspaceSession) -> (String) -> Void {
        { [weak session] repoRoot in
            guard let session else { return }
            let wanted = URL(fileURLWithPath: repoRoot).standardizedFileURL.path
                .trimmedTrailingSlash
            guard let target = session.projects.first(where: {
                $0.rootURL.standardizedFileURL.path.trimmedTrailingSlash == wanted
            }) else { return }
            NotificationCenter.default.post(name: .weirGitSyncRequested, object: target.id)
        }
    }
}
