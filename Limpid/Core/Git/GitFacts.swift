// GitFacts.swift
// Limpid — what a session's branch holds toward a pull request: commits not on the default branch, unpushed commits, uncommitted files.

import Foundation

/// The Git facts of one session's folder: the chips beside the
/// session's name, the sidebar row's second line at rest, and what the
/// changes panel says before "Create PR". Facts, not states: none of them
/// is something to answer.
struct GitFacts: Equatable, Sendable {
    /// The branch a pull request goes into: the name the person knows it
    /// by ("main") and the ref the counts are taken against
    /// ("origin/main", or "main" in a repository with no remote).
    struct Base: Equatable, Sendable {
        let name: String
        let ref: String

        /// `ref` as `ReviewGit.defaultBase` names it. Only origin's prefix
        /// comes off: that is the one remote the base is read from.
        init(ref: String) {
            self.ref = ref
            name = ref.hasPrefix("origin/") ? String(ref.dropFirst("origin/".count)) : ref
        }
    }

    /// `nil` on a detached HEAD.
    var branch: String?
    /// `nil` when neither origin's default nor a local main or master
    /// resolves: there is nothing to count against.
    var base: Base?
    /// Commits on HEAD that the base does not have: what a pull request
    /// would carry. `nil` without a base.
    var commitsNotOnBase: Int?
    /// Commits on HEAD that no remote has. Not the upstream's count: a
    /// branch made from origin/main tracks origin/main and would read as
    /// unpushed after a plain `git push origin <branch>`. `nil` in a
    /// repository with no remote, where every commit would count and none
    /// could be pushed, and when the upstream is gone from the remote
    /// (deleted as its request merged), which would count every commit of
    /// a branch whose work is already in.
    var unpushedCommits: Int?
    /// The paths changed and not committed, staged, unstaged, or
    /// untracked, each once. The review lists a path both staged and
    /// unstaged in each of its layers, so it can show more rows.
    var uncommittedFiles: Int

    /// Whether HEAD is the branch a pull request would go into.
    var isOnBase: Bool {
        guard let base, let branch else { return false }
        return branch == base.name
    }

    /// The commits a pull request from this branch would carry, for the
    /// "3 Commits" chip and the row's second line: none on the default
    /// branch itself, whose own commits ahead of origin are no proposal.
    var proposedCommits: Int {
        isOnBase ? 0 : commitsNotOnBase ?? 0
    }
}

/// What a reading of a folder's `GitFacts` came to.
enum GitFactsRead: Equatable, Sendable {
    case facts(GitFacts)
    /// Git answered that the folder is not a work tree: there are no facts.
    case notWorkTree
    /// Git did not answer in time, or said more than the reader takes: the
    /// facts are not known now, which is not the same as there being none.
    case unanswered
}
