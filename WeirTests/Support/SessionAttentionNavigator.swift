// SessionAttentionNavigator.swift
// Weir — goes to attention items as the app does, over a session and its windows, for suites with no app behind them.

import Foundation
@testable import Weir

/// Goes to items as the app does (`AppState.presentWindow(for:from:)`,
/// `AppState.go(to:opensTurnReview:in:)`): the window the registry presents for the item's
/// project, then the agent's pane selected there as the person's choice,
/// in front of the window's review tab (`ReviewTargetMove`). A runtime is
/// gone to through its item alone.
@MainActor
final class SessionAttentionNavigator: AttentionNavigating {
    let session: WorkspaceSession
    let registry: WindowRegistry
    /// No runtime is known to it: focusing a pane selects no tmux pane.
    let attention = AttentionState()

    init(session: WorkspaceSession, registry: WindowRegistry) {
        self.session = session
        self.registry = registry
    }

    func projectID(of window: ProjectWindowState) -> UUID? {
        session.selection(window.id)?.shownProjectID
    }

    func presentWindow(for item: AttentionItem, from window: ProjectWindowState?) -> ProjectWindowState? {
        registry.present(project: item.subject.projectID, in: session, from: window)
    }

    func presentNewWindow(for item: AttentionItem, from window: ProjectWindowState?) -> ProjectWindowState? {
        guard let projectID = item.subject.projectID else { return presentWindow(for: item, from: window) }
        return registry.openInNewWindow(project: projectID, in: session, from: window)
    }

    func go(to item: AttentionItem, opensTurnReview _: Bool, in window: ProjectWindowState?) {
        guard let window, case let .runtime(runtimeID, _, paneID, tabID, _) = item.subject,
              let tabID = tabID ?? session.tab(containing: paneID)?.id
        else { return }
        ReviewTargetMove(session: session, registry: RecordingSurfaceRegistry(), windows: registry)
            .toAgentPane(tabID: tabID, paneID: paneID, runtimeID: runtimeID, attention: attention, in: window)
    }

    func go(toRuntime _: String, in _: ProjectWindowState?) -> Bool {
        false
    }
}
