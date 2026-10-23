// ReviewRepositoryReading.swift
// Limpid — the repository questions the review surface asks, as a port.

import Foundation

/// What `ReviewSession` needs from Git, named so it can be answered by something
/// other than Git.
///
/// A port rather than `ReviewGit`'s static methods, so a test need not build
/// a real repository and spawn real processes to reach the review: a slow
/// answer, a partial failure or a repository that changes mid-read can be
/// written down. `GitRunning` answers the same problem for worktree
/// operations; this is the same shape for the read side.
protocol ReviewRepositoryReading: Sendable {
    func files(at root: URL, scope: ReviewScope) async throws -> [ReviewFile]
    func stats(at root: URL, scope: ReviewScope) async throws -> [String: ReviewFileStat]
    func diff(_ file: ReviewFile, root: URL, scope: ReviewScope) async throws -> ReviewDiff
    func fingerprint(_ file: ReviewFile, root: URL, scope: ReviewScope) async throws -> String
    /// HEAD, the scope's base, and the index entries of `paths`, read
    /// together (`ReviewGit.indexState`).
    func indexState(root: URL, scope: ReviewScope, paths: Set<String>) async throws -> ReviewIndexState
    /// Each path as `lstat` sees it (`ReviewGit.pathStat`).
    func fileStats(_ paths: [String], root: URL) -> [String: ReviewPathStat]
    /// Each path's content hash, from batched reads (`ReviewGit.contentHashes`).
    func contentHashes(_ paths: [String], root: URL) async throws -> [String: String]
    /// Whether the repository has moved since this exact displayed snapshot.
    /// The implementation must not replace that snapshot while answering.
    func hasChanges(
        at root: URL,
        scope: ReviewScope,
        comparedTo files: [ReviewFile],
        currentDiff: ReviewDiff?
    ) async throws -> Bool
    /// The new side of a file, whole, for unfolding context. Answers with
    /// nothing rather than throwing: it is an offer, not a requirement.
    func source(_ file: ReviewFile, root: URL, scope: ReviewScope) async -> [String]
    func defaultBase(at root: URL) async throws -> String?
}

/// The live implementation, which is the Git commands themselves.
struct LiveReviewRepository: ReviewRepositoryReading {
    func files(at root: URL, scope: ReviewScope) async throws -> [ReviewFile] {
        try await ReviewGit.files(at: root, scope: scope)
    }

    func stats(at root: URL, scope: ReviewScope) async throws -> [String: ReviewFileStat] {
        try await ReviewGit.stats(at: root, scope: scope)
    }

    func diff(_ file: ReviewFile, root: URL, scope: ReviewScope) async throws -> ReviewDiff {
        try await ReviewGit.diff(file, root: root, scope: scope)
    }

    func fingerprint(_ file: ReviewFile, root: URL, scope: ReviewScope) async throws -> String {
        try await ReviewGit.fingerprint(file, root: root, scope: scope)
    }

    func indexState(root: URL, scope: ReviewScope, paths: Set<String>) async throws -> ReviewIndexState {
        try await ReviewGit.indexState(root: root, scope: scope, paths: paths)
    }

    func fileStats(_ paths: [String], root: URL) -> [String: ReviewPathStat] {
        Dictionary(paths.map { ($0, ReviewGit.pathStat($0, root: root)) }, uniquingKeysWith: { first, _ in first })
    }

    func contentHashes(_ paths: [String], root: URL) async throws -> [String: String] {
        try await ReviewGit.contentHashes(paths, root: root)
    }

    func hasChanges(
        at root: URL,
        scope: ReviewScope,
        comparedTo files: [ReviewFile],
        currentDiff: ReviewDiff?
    ) async throws -> Bool {
        try await ReviewGit.hasChanges(at: root, scope: scope, comparedTo: files, currentDiff: currentDiff)
    }

    func source(_ file: ReviewFile, root: URL, scope: ReviewScope) async -> [String] {
        await ReviewGit.source(file, root: root, scope: scope)
    }

    func defaultBase(at root: URL) async throws -> String? {
        try await ReviewGit.defaultBase(at: root)
    }
}
