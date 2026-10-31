// AppState+ActionStores.swift
// Weir — the narrow sets of stores the changes panel's and the review tab's actions are handed.

import Foundation

/// The closures hold the app state itself, which lives as long as the app,
/// so each reads it afresh when called.
extension AppState {
    /// What the changes panel's actions use (`ChangesPanelActions`): the
    /// app's own stores, and the review tab as the panel's rows open it.
    var changesPanelStores: ChangesPanelStores {
        ChangesPanelStores(
            session: session,
            repositoryRoots: repositoryRoots,
            worktreeChanges: worktreeChanges,
            turnHistory: agentProjection.turnHistory,
            viewedLines: viewedLines,
            attention: attention,
            attentionQueue: attentionQueue,
            toasts: toastCenter,
            conversationIdentities: conversationIdentities,
            isAppActive: { [windowRegistry] in windowRegistry.attention.isAppActive },
            restoredTurnIDs: { self.restoredTurnIDs() },
            restoreGateLookup: { self.restoreGateLookup() },
            restoreRecord: { RestoreActions.record(forRoot: $0, state: self) },
            openReview: { request, pane, conversation, window in
                await ReviewTabActions.open(
                    request,
                    agentPaneID: pane,
                    conversation: conversation,
                    window: window,
                    stores: self.reviewTabStores
                )
            },
            registry: registry,
            paneVisibility: { [windowRegistry] window in
                PaneVisibilityReporter(windowID: window.id, registry: windowRegistry)
            }
        )
    }

    /// What the review tab's actions use (`ReviewTabActions`).
    var reviewTabStores: ReviewTabStores {
        ReviewTabStores(
            changes: changesPanelStores,
            windows: windowRegistry,
            registry: registry,
            reviewWriters: reviewWriters,
            primaryKeyHint: primaryKeyHint,
            locale: { [settingsStore] in settingsStore.appLocale },
            gitRoot: { try await ReviewGit.root(at: $0) },
            hunks: ReviewHunkDiscardStores(
                session: session,
                windows: windowRegistry,
                toasts: toastCenter,
                turnHistory: agentProjection.turnHistory,
                worktreePaths: worktreePaths,
                restores: restores,
                restoreGateInput: { self.restoreGateInput(for: $0) },
                laterTurns: reviewLaterTurns
            )
        )
    }
}
