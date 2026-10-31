// GitFactsFixture.swift
// Weir — one builder for the Git facts a session's header, sidebar, and pull request button read.

import Foundation
@testable import Weir

enum GitFactsFixture {
    /// A worktree on `feat/x` two commits past `origin/main`, all pushed,
    /// nothing uncommitted: one that can propose a pull request, changed
    /// only where a test says. `base` is the ref, as `ReviewGit.defaultBase`
    /// names it; `nil` for a repository with no default branch.
    static func make(
        branch: String? = "feat/x",
        commits: Int? = 2,
        unpushed: Int? = 0,
        uncommitted: Int = 0,
        base: String? = "origin/main"
    ) -> GitFacts {
        GitFacts(
            branch: branch,
            base: base.map(GitFacts.Base.init(ref:)),
            commitsNotOnBase: commits,
            unpushedCommits: unpushed,
            uncommittedFiles: uncommitted
        )
    }

    /// What the commit and pull request model reads for a worktree with
    /// `facts`, where `gh` is installed.
    static func input(_ facts: GitFacts? = make(), pullRequest: PRInfo? = nil) -> CommitAndPRModel.Input {
        CommitAndPRModel.Input(facts: facts, pullRequest: pullRequest, hasGitHubCLI: true, isWorktree: true)
    }
}
