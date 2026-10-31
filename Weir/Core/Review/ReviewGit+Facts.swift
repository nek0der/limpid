// ReviewGit+Facts.swift
// Weir — the Git questions behind a session's facts: its branch, its commits, and its uncommitted files.

import Foundation

/// What `GitFactsStore` asks Git: up to seven short commands a folder,
/// read without writing. They go through the review's runner, which takes
/// no optional lock, so a status read in the background never fails an
/// agent's `git commit` on `index.lock`, and which stops a git that does
/// not answer.
extension ReviewGit {
    /// A status this long lists over a hundred thousand paths. Larger than
    /// a diff's limit: a whole status is read to count it, and a count cut
    /// short would show fewer changes than there are.
    static let factsStatusLimitBytes = 16 * 1024 * 1024

    /// The facts of the work tree at `folder`.
    static func facts(at folder: URL) async -> GitFactsRead {
        do {
            // Untracked files one by one, as the review lists them, rather
            // than a new folder as one entry.
            guard let status = try await answer(
                ["status", "--porcelain=v2", "--branch", "--untracked-files=all"],
                at: folder,
                limit: factsStatusLimitBytes
            ) else { return .notWorkTree }
            let parsed = GitStatus.parse(status)
            // A base that does not resolve leaves the counts unknown rather
            // than the facts missing: the uncommitted files still stand.
            let base = try await defaultBase(at: folder).map(GitFacts.Base.init(ref:))
            let commitsNotOnBase: Int? = if let base {
                try await count(["rev-list", "--count", "\(base.ref)..HEAD", "--"], at: folder)
            } else {
                nil
            }
            // Git names the upstream but gives no counts once the remote
            // branch is gone, as it is after its request merged.
            let isUpstreamGone = parsed.upstream != nil && !parsed.hasAheadBehind
            let unpushedCommits: Int? = if !isUpstreamGone, try await hasRemote(at: folder) {
                try await count(["rev-list", "--count", "HEAD", "--not", "--remotes", "--"], at: folder)
            } else {
                nil
            }
            return .facts(GitFacts(
                branch: parsed.branch,
                base: base,
                commitsNotOnBase: commitsNotOnBase,
                unpushedCommits: unpushedCommits,
                uncommittedFiles: parsed.changedEntries
            ))
        } catch {
            return .unanswered
        }
    }

    /// The number a `rev-list --count` prints; `nil` when Git refuses, as
    /// it does on a branch with no commit yet.
    private static func count(_ args: [String], at folder: URL) async throws -> Int? {
        try await answer(args, at: folder).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func hasRemote(at folder: URL) async throws -> Bool {
        try await !(answer(["remote"], at: folder)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// What `args` printed; `nil` when Git exited with an error. Throws when
    /// Git gave no answer: it ran past its time or printed past `limit`.
    /// Read leniently: a branch name Git prints as it is need not be
    /// UTF-8, and the counts do not depend on it. Latin-1 reads any bytes.
    private static func answer(_ args: [String], at folder: URL, limit: Int = maxDiffBytes) async throws -> String? {
        let data: Data
        do {
            data = try await command(args, root: folder, limit: limit)
        } catch ReviewError.gitFailed {
            return nil
        }
        return String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1)
    }
}
