// WindowRegistry+ReviewRecords.swift
// Limpid — what the windows' reviews hold on to across projects: the turn ranges the sweep keeps, and the discards let go of.

import Foundation

extension WindowRegistry {
    /// Lets go of the discards of the worktrees of projects `removed`: a
    /// record whose worktree is one of their folders or worktrees, in one,
    /// or holds one (a project can be a folder of repositories, or a folder
    /// inside one), unless a project the session still has meets it the
    /// same way, or a review open or kept reads it. Any other record (a
    /// scratch pane's worktree, one outside every project) stays while the
    /// app runs: nothing says it is gone, and there are no more of them
    /// than hunks discarded. Paths are spelled as the records spell them
    /// (`WorktreePathResolver`), which then lets go of the removed folders'
    /// spellings too.
    func forgetDiscards(of removed: [Project], in session: WorkspaceSession) {
        let folders = { (projects: [Project]) in
            projects.flatMap { [$0.rootURL] + $0.worktrees.map(\.workingDirectory) }.map { self.worktreePaths.resolved($0.path) }
        }
        let removedFolders = folders(removed)
        let keptFolders = folders(session.projects)
        let parked = parkedReviews.values.flatMap(\.tabs) + (parkedScratchReview?.tabs ?? [])
        let reviewed = Set(
            (windows.compactMap(\.review) + parked.map(\.review))
                .map { worktreePaths.resolved($0.root) }
        )
        reviewDiscards.forget { spelled in
            let root = worktreePaths.resolved(spelled)
            return removedFolders.contains { RepositoryPath.overlaps(root, $0) }
                && !keptFolders.contains { RepositoryPath.overlaps(root, $0) }
                && !reviewed.contains(root)
        }
        worktreePaths.forget(removedFolders.filter { removed in
            !keptFolders.contains { RepositoryPath.overlaps(removed, $0) }
        })
    }

    /// The turn ranges the reviews read, which the sweep keeps:
    /// each window's review tab's, each parked tab's while its project is
    /// still the session's, and each scratch pane's tab kept for a scratch
    /// tab (`parkedScratchReview`).
    func reviewTurnRanges(in session: WorkspaceSession) -> [ReviewTurnRange] {
        let open = windows.compactMap(\.review?.scope)
        let ofProjects = parkedReviews.filter { session.project($0.key) != nil }.flatMap(\.value.tabs)
        let parked = (ofProjects + (parkedScratchReview?.tabs ?? [])).compactMap(\.review.scope)
        return (open + parked).compactMap { scope in
            if case let .turns(range) = scope {
                return range
            }
            return nil
        }
    }
}
