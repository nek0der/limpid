// AppState+AgentIntegration.swift
// Limpid — coordinates approval routing with service reconciliation readiness.

import AppKit

extension AppState {
    func startAgentIntegration() {
        // Requests are placed through the run they came from, wherever it is
        // attached now (a tmux run included).
        approvalPresentation.runtimes = { [attention] in attention.allRuntimes }
        // Each window keeps its own approval card; the requests it shows are
        // shared, and every window's card follows them as they settle.
        approvalPresentation.onRequestsChanged = { [weak windowRegistry, weak approvalPresentation] in
            guard let windowRegistry, let approvalPresentation else { return }
            windowRegistry.settleApprovalCards(against: approvalPresentation)
        }
        // The time left on a held request is read against the service clock,
        // and read again after the Mac wakes rather than assumed to have
        // survived the sleep.
        approvalPresentation.refreshServiceClock(
            onEvery: NSWorkspace.didWakeNotification,
            in: NSWorkspace.shared.notificationCenter
        )
        agentIntegrationServiceRegistrar.start { [weak approvalPresentation] isReady in
            if isReady {
                approvalPresentation?.start()
            } else {
                approvalPresentation?.stop()
            }
        }
        connectWindowOverlays()
        startApprovalHandOff()
        startAttentionQueue()
        startNotificationRouting()
        // Before the first reading of the journals, so none goes unheard.
        connectRestoreMoves()
        recoverRestores()
    }

    /// Tells the toast center which window a toast with no window of its
    /// own is drawn in, as each window owns its overlays. Connected before
    /// any toast can be shown.
    func connectWindowOverlays() {
        // A toast whose caller knows no window shows in the one commands
        // act on, as a command's own result would.
        toastCenter.frontWindow = { [weak self] in
            self?.windowRegistry.backgroundCommandTarget.id
        }
    }

    /// Hands a held request to the TUI once its pane is seen, whichever
    /// changed: what the person can see, the requests, where the agents run,
    /// or the hidden setting. Here rather than in the store because the
    /// facts about windows live in the window registry, which Core cannot
    /// name.
    private func startApprovalHandOff() {
        observeRepeatedly { [weak self] in
            guard let self else { return }
            _ = windowRegistry.attention
            _ = approvalPresentation.pending
            _ = approvalPresentation.ledger.entries
            _ = session.tabs
            _ = settingsStore.settings.advanced.holdsApprovalsWhileHidden
        } onChange: { [weak self] in
            self?.handOffSeenApprovals()
        }
        // Which tmux pane is in front changes without touching anything
        // observed above: the projection pass is what reads it, so the
        // hand-off runs again after every pass. We wrap the handler `init`
        // set (the release of stale approvals) rather than replace it;
        // anything that assigns the handler after this point must keep
        // calling the wrapped one, or the hand-off silently stops.
        let afterProjection = agentProjection.onProjectionApplied
        agentProjection.onProjectionApplied = { [weak self] session in
            afterProjection?(session)
            self?.handOffSeenApprovals()
        }
        handOffSeenApprovals()
    }

    private func handOffSeenApprovals() {
        approvalPresentation.handOffSeenRequests(
            attention: windowRegistry.attention,
            session: session,
            holdsWhileHidden: settingsStore.settings.advanced.holdsApprovalsWhileHidden
        )
    }
}
