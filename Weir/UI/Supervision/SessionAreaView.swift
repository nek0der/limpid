// SessionAreaView.swift
// Weir — the supervision window's body beside the sidebar: the session header, its tabs, and the terminal.

import SwiftUI

/// The selected session: its header, the strip of its tabs, and
/// the terminal of the selected tab (or the review standing where it
/// was). Panes here draw the attention frame.
struct SessionAreaView: View {
    let state: AppState
    let app: GhosttyApp
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.paneVisibilityReporter) private var paneVisibility
    @Environment(SessionLaunchStore.self) private var launches

    private var session: WorkspaceSession {
        state.session
    }

    var body: some View {
        // No fill of its own: it stands on the window's surface for the
        // session, which fills it as it does the sidebar and the panel.
        VStack(spacing: 0) {
            SessionHeaderView()
            PaneStripView(container: window.selection.activeContainerID)
            SessionTerminalView(ghosttyApp: app)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // A new session between its worktree and its agent: its
                // setup, or the stage that failed.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let launch = launches.launch(in: window.selection.activeContainerID) {
                        SessionLaunchBar(launch: launch)
                    }
                }
        }
        // The commands for this window's body: the review's open and close.
        // The review is this window's tab: ⌥⌘R opens it on the
        // unviewed turns or closes it, ⌥⌘J opens the latest turn.
        .onWindowCommand(of: window, takeCommand)
        // Any other way to another terminal tab (a new tab, a session's row,
        // a notification) puts the review behind it, as picking it does.
        .onChange(of: window.selection.activeTabID) { oldTabID, _ in
            guard ReviewTabActions.activeTabChangePutsReviewBehind(from: oldTabID, window: window, session: session) else { return }
            ReviewTabActions.putBehind(window: window, session: session, registry: state.registry, paneVisibility: paneVisibility)
        }
        // The review reads the session it was opened in; another session's
        // strip has no place for it. A comment being written keeps it open
        // behind, back in its own strip when the person returns. On any
        // row, a review waiting for that row comes back behind
        // (`WindowRegistry.takeParkedReview(arrivingAt:in:)`).
        // Also as the view first appears: a new window can be moved on
        // before then (the all projects sheet opens its card's session), and
        // a review tab it took must follow that move as any window's would.
        .onChange(of: window.selection.activeContainerID, initial: true) { _, _ in
            ReviewTabActions.rowChanged(
                window: window,
                session: session,
                windows: state.windowRegistry,
                registry: state.registry,
                paneVisibility: paneVisibility
            )
        }
    }

    /// Carries out the commands for the window's body, and says whether
    /// `command` was one.
    private func takeCommand(_ command: WindowCommand) -> Bool {
        switch command {
        case .review:
            Task { await ReviewTabActions.toggle(window: window, stores: state.reviewTabStores, paneVisibility: paneVisibility) }
        case .reviewLatestTurn:
            // The agent the review in front follows, else the focused pane.
            let paneID = window.review?.isShown == true
                ? window.review?.agentPaneID
                : session.activeTab(in: window.id)?.splitTree.effectiveFocusedLeafID
            Task { await ReviewTabActions.open(.latestTurn, agentPaneID: paneID, window: window, stores: state.reviewTabStores) }
        default:
            return false
        }
        return true
    }
}
