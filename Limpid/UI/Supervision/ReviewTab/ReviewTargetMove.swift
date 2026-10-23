// ReviewTargetMove.swift
// Limpid — takes a window to the target an entry asked for, then puts the review tab behind it.

import Foundation

/// What an entry that carries a target (⌘J, the Needs Attention list, a
/// card's item, a notification, a menu bar row) does in
/// the window it shows the target in: it selects the target first, then
/// puts the window's review tab behind it, so the target is on screen. The
/// order matters: a review tab a switch to the project just brought back
/// settles where the window stands once the target is selected
/// (`ProjectWindowState.resolveParkedReviewArrival`), and the row the
/// target is on does not close it. The app's entries go through it
/// (`AppState.reviewTargetMove`).
@MainActor
struct ReviewTargetMove {
    let session: WorkspaceSession
    let registry: any SurfaceViewProviding
    let windows: WindowRegistry

    /// A notification's tab.
    func toTab(_ tabID: UUID, in window: ProjectWindowState) {
        session.setActiveTab(tabID, in: window.id, intent: .person)
        putReviewBehind(in: window)
    }

    /// A notification's row, or the row of a new session that stopped,
    /// whose line under the terminal says what failed.
    func toContainer(_ containerID: ContainerID, in window: ProjectWindowState) {
        session.setActiveContainer(containerID, in: window.id, intent: .person)
        putReviewBehind(in: window)
    }

    /// A notification's pane.
    func toPane(_ paneID: UUID, in window: ProjectWindowState) {
        jumpToPane(paneID, session: session, registry: registry, in: window.id, intent: .person)
        putReviewBehind(in: window)
    }

    /// An agent's pane, with its tmux pane selected (`AttentionState
    /// .focusAttention`): ⌘J, the lists, a card's item, a notification of
    /// a runtime.
    func toAgentPane(tabID: UUID, paneID: UUID, runtimeID: String, attention: AttentionState, in window: ProjectWindowState) {
        attention.focusAttention(
            in: session,
            registry: registry,
            tabID: tabID,
            paneID: paneID,
            runtimeID: runtimeID,
            window: window.id,
            intent: .person
        )
        putReviewBehind(in: window)
    }

    /// The target is in front of the window's review tab, which goes
    /// behind it, still open (`ReviewTabActions.putBehind`).
    func putReviewBehind(in window: ProjectWindowState) {
        ReviewTabActions.putBehind(
            window: window,
            session: session,
            registry: registry,
            paneVisibility: PaneVisibilityReporter(windowID: window.id, registry: windows)
        )
    }
}
