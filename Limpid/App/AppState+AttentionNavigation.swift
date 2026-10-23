// AppState+AttentionNavigation.swift
// Limpid — takes the person to an attention item: its pane, or the approval card.

import Foundation

extension AppState: AttentionNavigating {
    /// The window's project, kept while a scratch tab is selected, so ⌘J
    /// starts from the project the window lists (`WindowSelection.projectID`).
    func projectID(of window: ProjectWindowState) -> UUID? {
        session.selections[window.id]?.shownProjectID
    }

    /// Shows the window `item` is gone to, and returns it: the window that
    /// shows its project, brought forward and back if hidden, else the
    /// window used, switched to the item's project in place and brought
    /// back if hidden. An item of no project (a request no pane is known
    /// for, a scratch tab) stays in the window used, brought back
    /// (`WindowRegistry.present(project:in:from:)`).
    func presentWindow(for item: AttentionItem, from window: ProjectWindowState?) -> ProjectWindowState? {
        windowRegistry.present(project: item.subject.projectID, in: session, from: window)
    }

    /// An item ⌘-clicked in the Needs Attention list: one of another
    /// project opens in a new window, or the window that shows its project
    /// comes forward (`WindowRegistry.openInNewWindow`). One of the window's
    /// own project, or of none, goes as without ⌘.
    func presentNewWindow(for item: AttentionItem, from window: ProjectWindowState?) -> ProjectWindowState? {
        guard let projectID = item.subject.projectID else { return presentWindow(for: item, from: window) }
        return windowRegistry.openInNewWindow(project: projectID, in: session, from: window)
    }

    /// Opens the item's pane. A request no pane is known for opens its card
    /// instead, the one place it can be answered from.
    func go(to item: AttentionItem, opensTurnReview: Bool, in window: ProjectWindowState?) {
        // `presentWindow(for:from:)` returns none only for a window that
        // closed or a project gone, where the list falls back to the window
        // it was used in, which may be `nil`; the window commands act on
        // stands in.
        let target = window ?? windowRegistry.backgroundCommandTarget
        switch item.subject {
        case let .runtime(runtimeID, _, paneID, tabID, _):
            guard let tabID = tabID ?? session.tab(containing: paneID)?.id else { return }
            // The pane gone to is in front, even when its tab was the one
            // behind the review tab; then the review opens, if asked.
            reviewTargetMove.toAgentPane(tabID: tabID, paneID: paneID, runtimeID: runtimeID, attention: attention, in: target)
            if opensTurnReview, case let .unread(turn) = item.kind {
                openReviewTab(for: turn, paneID: paneID, in: target)
            }
        case .unplaced:
            switch item.id {
            case let .approval(key), let .question(key):
                if let approval = approvalPresentation.ledger.entries[key]?.presentation {
                    target.approvalCard.present(approval, from: approvalPresentation)
                }
            case .prompt, .stop, .unread:
                break
            }
        case let .sessionRow(projectID, _):
            // The row of the new session that stopped: its decision line
            // under the terminal says what failed and offers the retry.
            guard let projectID,
                  let worktree = session.project(projectID)?.worktrees.first(where: {
                      item.subject.isSessionRow(at: $0.workingDirectory)
                  })
            else { return }
            // The row's line under its terminal is in front, not a review.
            reviewTargetMove.toContainer(.worktree(projectID: projectID, worktreeID: worktree.id), in: target)
        }
    }

    /// "Open review when moving to an unread turn": the window's review
    /// tab on the agent's unviewed turns.
    /// In the window the pane was gone to (`go(to:opensTurnReview:in:)`'s
    /// target), so a list used from no window opens it too.
    private func openReviewTab(for turn: UnreadTurn, paneID: UUID, in window: ProjectWindowState) {
        guard settingsStore.settings.jumpOpensTurnReview, turn.changes.opensReviewOnJump else { return }
        Task {
            await ReviewTabActions.open(
                .unviewedTurns,
                agentPaneID: paneID,
                conversation: turn.conversation,
                window: window,
                stores: reviewTabStores
            )
        }
    }

    func go(toRuntime runtimeID: String, in window: ProjectWindowState?) -> Bool {
        guard let location = runtimeLocation(runtimeID) else { return false }
        // The window of the project the runtime's tab is in, switched
        // to it in place unless another window shows it.
        guard let shown = windowRegistry.present(
            project: session.tab(location.tabID)?.container.projectID,
            in: session,
            from: window
        ) else { return false }
        reviewTargetMove.toAgentPane(
            tabID: location.tabID,
            paneID: location.paneID,
            runtimeID: runtimeID,
            attention: attention,
            in: shown
        )
        return true
    }

    /// How an entry that carries a target (⌘J, the lists, a card, a
    /// notification, a menu bar row) shows it: selected,
    /// then in front of the window's review tab, which goes behind it,
    /// still open. Where the entry switched the window to another project,
    /// the review tab that came back with it goes behind too, even on the
    /// place the person left it
    /// (`ProjectWindowState.resolveParkedReviewArrival`).
    var reviewTargetMove: ReviewTargetMove {
        ReviewTargetMove(session: session, registry: registry, windows: windowRegistry)
    }

    /// Lets Core's shortcut dispatch and command palette reach the list,
    /// which lives above it. Without a window to name, they act on the
    /// command target, as menu commands do: the window the person was last
    /// in, which is the palette's own when they used the palette.
    func connectAttentionNavigation() {
        attentionQueue.navigator = self
        attention.walkAttention = { [weak self] forward in
            guard let self else { return }
            attentionQueue.jump(forward: forward, in: windowRegistry.backgroundCommandTarget)
        }
        attention.hasAttentionItems = { [weak self] in
            self?.attentionQueue.hasItems ?? false
        }
        // A notification opens what it announced through the list, now that
        // the list is up; before this the delegate only brings Limpid
        // forward.
        LimpidNotificationDelegate.onTap = { [weak self] payload in
            self?.openNotificationTarget(NotificationTarget(payload))
        }
    }
}
