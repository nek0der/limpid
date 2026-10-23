// DemoFixture+Git.swift
// Limpid — the Git facts demo mode shows for its worktrees, in place of reading folders that do not exist.

import Foundation

extension DemoFixture {
    /// What each worktree's branch holds, for the session header's chips
    /// and the rows' second line at rest. `AppState` hands them to
    /// `GitFactsStore`, which then reads nothing. They agree with the scene:
    /// the selected worktree's two commits are its first two turns, and its
    /// five uncommitted files are what Claude's T4 and T5 and Codex's T1
    /// changed. A folder left out has no facts, and the staged store reads
    /// it as not a work tree.
    static var gitFacts: [ContainerID: GitFacts] {
        [
            .project(duesmithProjectID): facts("main", commits: 0, unpushed: 0, uncommitted: 0),
            remindersContainer: facts("feat/overdue-reminders", commits: 2, unpushed: 2, uncommitted: 5),
            .worktree(projectID: duesmithProjectID, worktreeID: taxRoundingWorktreeID):
                facts("fix/tax-rounding", commits: 0, unpushed: 0, uncommitted: 2),
            .worktree(projectID: duesmithProjectID, worktreeID: prorationWorktreeID):
                facts("feat/proration", commits: 1, unpushed: 1, uncommitted: 3),
            .worktree(projectID: duesmithProjectID, worktreeID: webhookWorktreeID):
                facts("fix/webhook-timeout", commits: 0, unpushed: 0, uncommitted: 2),
            docsContainer: facts("docs/invoices-api", commits: 1, unpushed: 0, uncommitted: 0),
            // Merged, and nothing left uncommitted: ready to clean up.
            csvExportContainer: facts("fix/csv-export", commits: 0, unpushed: 0, uncommitted: 0),
            batchRenderContainer: facts("feat/batch-render", commits: 3, unpushed: 0, uncommitted: 0)
        ]
    }

    /// Every demo repository has a remote, so the default branch is
    /// origin's.
    private static func facts(_ branch: String, commits: Int, unpushed: Int, uncommitted: Int) -> GitFacts {
        GitFacts(
            branch: branch,
            base: GitFacts.Base(ref: "origin/main"),
            commitsNotOnBase: commits,
            unpushedCommits: unpushed,
            uncommittedFiles: uncommitted
        )
    }
}
