// ChangesPanelStores.swift
// Weir — what the changes panel's actions read and change, handed over by the app.

import Foundation
import WeirDomain

/// The stores and the ways out the changes panel's actions use
/// (`ChangesPanelActions`), and nothing else of the app. The app builds it
/// (`AppState.changesPanelStores`); a test builds one of its own stores.
@MainActor
struct ChangesPanelStores {
    let session: WorkspaceSession
    /// Each session folder's Git top level.
    let repositoryRoots: RepositoryRoots
    /// What each worktree's turns do not account for, and what they changed.
    let worktreeChanges: WorktreeChanges
    /// Every agent's turns, as the projection last reported them.
    let turnHistory: TurnHistory
    let viewedLines: ViewedLineStore
    /// The runtimes, for the conversation each pane runs.
    let attention: AttentionState
    let attentionQueue: AttentionQueueStore
    let toasts: ToastCenter
    /// The identity colors of each session container's conversations,
    /// which the panel, the rail, and the review read here and the pane
    /// strip through the environment, the same store.
    let conversationIdentities: ConversationIdentityStore
    /// Whether Weir is in front, where someone may read the panel.
    let isAppActive: () -> Bool
    /// The turns a restore took back, read once per call.
    let restoredTurnIDs: () -> Set<TurnID>
    /// What the restore gate weighs, read once per call (`RestoreGate`).
    let restoreGateLookup: () -> RestoreGateLookup
    /// The restore of the worktree at a root that may still be undone
    /// (`RestoreActions.record(forRoot:state:)`).
    let restoreRecord: (String) -> RestoreJournal?
    /// Opens the review tab: a row's turn, or the worktree's unviewed turns
    /// (`ReviewTabActions.open`).
    let openReview: (ReviewTabRequest, _ agentPaneID: UUID?, ConversationKey?, ProjectWindowState) async -> Void
    /// The terminals, which "Show Tab" hands the keyboard to.
    let registry: any SurfaceViewProviding
    /// Where a window reports the panes it shows, for "Show Tab" putting
    /// the review behind the tab it brings forward.
    let paneVisibility: (ProjectWindowState) -> PaneVisibilityReporter
}
