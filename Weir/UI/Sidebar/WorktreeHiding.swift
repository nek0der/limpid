// WorktreeHiding.swift
// Weir — hides a worktree's sidebar row at once and offers Undo.

import SwiftUI

/// Hide Worktree: the row goes at once (the sidebar feels responsive) and
/// a toast carries Undo, which shows it again; after 5 s the toast leaves
/// and the row stays hidden, as Apple Mail's deleted message does. A row
/// whose folder is gone has nothing to hide and is removed instead
/// (`removeMissing`).
///
/// In the View layer on purpose: it is UI orchestration (animation and a
/// toast) around two session verbs (`hideWorktree` / `unhideWorktree`).
/// Moving it to `TabActions` would make that enum import SwiftUI and know
/// `ToastCenter`, against its rule of session and registry only.
@MainActor
enum WorktreeHiding {
    static func hide(session: WorkspaceSession, toastCenter: ToastCenter, projectID: UUID, worktree: Worktree) {
        let name = rowName(of: worktree, in: projectID, session: session)
        withAnimation(WeirMotion.reorderUnlessReduced) {
            session.hideWorktree(projectID: projectID, worktreeID: worktree.id)
        }
        toastCenter.showInFrontWindow(ToastItem(
            message: .localized("Hid worktree \u{201C}\(name)\u{201D}."),
            undo: { [session] in
                withAnimation(WeirMotion.reorderUnlessReduced) {
                    session.unhideWorktree(projectID: projectID, worktreeID: worktree.id)
                }
            }
        ))
    }

    /// Move to Other Worktrees: the row moves among the other worktrees at
    /// once, under the pointer too (`ProjectWindowState.releaseHold`), since
    /// the person moved it; the toast's Undo puts it back. `windows` are
    /// every window, as each sidebar lists every project's rows and may
    /// hold this one.
    static func removeFromWorking(
        session: WorkspaceSession,
        windows: [ProjectWindowState],
        toastCenter: ToastCenter,
        projectID: UUID,
        worktree: Worktree
    ) {
        let row = ContainerID.worktree(projectID: projectID, worktreeID: worktree.id)
        let name = rowName(of: worktree, in: projectID, session: session)
        let release: WorktreeRelease? = withAnimation(WeirMotion.reorderUnlessReduced) {
            for window in windows {
                window.releaseHold(on: row)
            }
            return session.releaseWorktree(projectID: projectID, worktreeID: worktree.id)
        }
        guard let release else { return }
        toastCenter.showInFrontWindow(ToastItem(
            message: .localized("Moved \u{201C}\(name)\u{201D} to Other Worktrees."),
            undo: { [session, windows] in
                withAnimation(WeirMotion.reorderUnlessReduced) {
                    for window in windows {
                        window.releaseHold(on: row)
                    }
                    session.readmitWorktree(projectID: projectID, worktreeID: worktree.id, as: release.previous)
                }
            }
        ))
    }

    /// The name the toast gives the row: the one the sidebar shows it by
    /// (`RowName`), so the person reads the row they acted on.
    private static func rowName(of worktree: Worktree, in projectID: UUID, session: WorkspaceSession) -> String {
        session.rowName(of: .worktree(projectID: projectID, worktreeID: worktree.id))?.text ?? worktree.label
    }

    /// Remove from Sidebar, for a worktree whose folder is gone.
    static func removeMissing(session: WorkspaceSession, registry: any SurfaceViewProviding, projectID: UUID, worktreeID: UUID) {
        withAnimation(WeirMotion.reorderUnlessReduced) {
            ContainerActions.removeWorktree(session, registry: registry, projectID: projectID, worktreeID: worktreeID)
        }
    }
}
