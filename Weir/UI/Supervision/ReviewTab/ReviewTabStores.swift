// ReviewTabStores.swift
// Weir — what the review tab's actions read and change, handed over by the app.

import Foundation
import WeirDomain

/// The stores and the ways out the review tab's actions use
/// (`ReviewTabActions`), and nothing else of the app. The app builds it
/// (`AppState.reviewTabStores`); a test builds one of its own stores, with
/// its own answer for the worktree's top level.
@MainActor
struct ReviewTabStores {
    /// What the review shares with the changes panel: the worktree's turns,
    /// conversations, and viewed lines, read the same way.
    let changes: ChangesPanelStores
    let windows: WindowRegistry
    let registry: any SurfaceViewProviding
    /// The draft pool every review of a worktree shares.
    let reviewWriters: ReviewDraftWriterPool
    let primaryKeyHint: PrimaryKeyHint
    /// The language the toasts the review raises are named in.
    let locale: () -> Locale
    /// The Git top level of a folder, which the review opens on
    /// (`ReviewGit.root(at:)`). It throws, in Git's own words, outside a
    /// repository.
    let gitRoot: (URL) async throws -> URL
    /// What the hunks' discards and their undos use.
    let hunks: ReviewHunkDiscardStores

    var session: WorkspaceSession {
        changes.session
    }

    var toasts: ToastCenter {
        changes.toasts
    }

    var attention: AttentionState {
        changes.attention
    }

    var attentionQueue: AttentionQueueStore {
        changes.attentionQueue
    }

    var turnHistory: TurnHistory {
        changes.turnHistory
    }

    var repositoryRoots: RepositoryRoots {
        changes.repositoryRoots
    }

    var viewedLines: ViewedLineStore {
        changes.viewedLines
    }

    var worktreeChanges: WorktreeChanges {
        changes.worktreeChanges
    }

    func restoredTurnIDs() -> Set<TurnID> {
        changes.restoredTurnIDs()
    }
}

/// What the review's hunk discards read and change (`ReviewHunkDiscardActions`).
@MainActor
struct ReviewHunkDiscardStores {
    let session: WorkspaceSession
    let windows: WindowRegistry
    let toasts: ToastCenter
    let turnHistory: TurnHistory
    /// Each worktree path's spelling with its links followed.
    let worktreePaths: WorktreePathResolver
    /// The restores and discards, and their journals.
    let restores: RestoreCoordinator
    /// What the restore gate weighs for a turn, read afresh
    /// (`AppState.restoreGateInput(for:)`).
    let restoreGateInput: (TurnSummary) -> RestoreGate.Input
    /// This keeps what turns say after each range, per history revision,
    /// for every window's review tab.
    let laterTurns: ReviewLaterTurns
}
