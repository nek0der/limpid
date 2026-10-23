// FakeReviewRepository.swift
// Limpid — a repository that answers the review session without Git.

import Foundation
@testable import Limpid

/// Answers `ReviewRepositoryReading` from values a test hands it.
///
/// The point is the answers a real repository cannot be made to give on
/// demand: a file that vanishes between two reads, a diff that fails while its
/// neighbors succeed, a working copy that cannot be read at all.
final class FakeReviewRepository: ReviewRepositoryReading, @unchecked Sendable {
    var files: [ReviewFile] = []
    /// Holds the next file list until the test opens it with the files.
    var nextFilesGate: Gate<[ReviewFile]>?
    /// Holds the next diff until the test opens it, then fails that diff.
    var nextDiffFailureGate: Gate<Void>?
    var stats: [String: ReviewFileStat] = [:]
    var diffs: [String: ReviewDiff] = [:]
    /// Diffs that differ by scope (`ReviewScope.scopeID`, then file id), for
    /// a file two fixed ranges compare differently. Asked before `diffs`.
    var diffsByScope: [String: [String: ReviewDiff]] = [:]
    var fingerprints: [String: String] = [:]
    var unsupportedDiffs: Set<String> = []
    var sources: [String: [String]] = [:]
    var base: String?
    /// File ids whose diff should fail rather than answer.
    var failingDiffs: Set<String> = []
    private(set) var fileCalls = 0
    private(set) var diffScopes: [ReviewScope] = []
    var isFileListFailing = false
    /// Ranges (`ReviewScope.scopeID`) whose snapshots are gone.
    var missingRangeScopeIDs: Set<String> = []

    func files(at _: URL, scope: ReviewScope) async throws -> [ReviewFile] {
        fileCalls += 1
        if isFileListFailing {
            throw ReviewError.gitFailed
        }
        if missingRangeScopeIDs.contains(scope.scopeID) {
            throw ReviewError.rangeSnapshotsMissing
        }
        if let gate = nextFilesGate {
            nextFilesGate = nil
            return await gate.wait()
        }
        return files
    }

    func stats(at _: URL, scope _: ReviewScope) async throws -> [String: ReviewFileStat] {
        stats
    }

    func diff(_ file: ReviewFile, root _: URL, scope: ReviewScope) async throws -> ReviewDiff {
        diffScopes.append(scope)
        if let gate = nextDiffFailureGate {
            nextDiffFailureGate = nil
            await gate.wait()
            throw ReviewError.gitFailed
        }
        if unsupportedDiffs.contains(file.id) {
            throw ReviewError.unsupported
        }
        if failingDiffs.contains(file.id) {
            throw ReviewError.gitFailed
        }
        guard let diff = diffsByScope[scope.scopeID]?[file.id] ?? diffs[file.id] else { throw ReviewError.gitFailed }
        return diff
    }

    func fingerprint(_ file: ReviewFile, root: URL, scope: ReviewScope) async throws -> String {
        if let fingerprint = fingerprints[file.id] {
            return fingerprint
        }
        return try await diff(file, root: root, scope: scope).fingerprint
    }

    /// A work tree that never changes: these tests ask about the open
    /// file's fingerprint, not the stack's read states
    /// (`StackReviewRepository` answers those).
    func indexState(root _: URL, scope _: ReviewScope, paths _: Set<String>) async throws -> ReviewIndexState {
        ReviewIndexState(head: "head", base: nil, entries: [:])
    }

    func fileStats(_ paths: [String], root _: URL) -> [String: ReviewPathStat] {
        Dictionary(paths.map { ($0, ReviewPathStat(kind: .regular, info: "100644:0", size: 0)) }, uniquingKeysWith: { first, _ in first })
    }

    func contentHashes(_ paths: [String], root _: URL) async throws -> [String: String] {
        Dictionary(paths.map { ($0, "hash") }, uniquingKeysWith: { first, _ in first })
    }

    func hasChanges(
        at root: URL,
        scope: ReviewScope,
        comparedTo displayedFiles: [ReviewFile],
        currentDiff: ReviewDiff?
    ) async throws -> Bool {
        guard try await files(at: root, scope: scope) == displayedFiles else { return true }
        guard let currentDiff else { return false }
        return try await fingerprint(currentDiff.file, root: root, scope: scope)
            != currentDiff.fingerprint
    }

    func source(_ file: ReviewFile, root _: URL, scope _: ReviewScope) async -> [String] {
        sources[file.id] ?? []
    }

    func defaultBase(at _: URL) async throws -> String? {
        base
    }
}

extension FakeReviewRepository {
    /// The file `oneFile` lists unless given another: an unstaged edit.
    static let unstagedFile = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)

    /// A repository listing `file` alone, whose diff (`fingerprint`)
    /// changes its one line: what a test reads when it is about the
    /// session rather than the file.
    static func oneFile(_ file: ReviewFile = unstagedFile, fingerprint: String = "f1") throws -> FakeReviewRepository {
        let repository = FakeReviewRepository()
        repository.files = [file]
        repository.diffs[file.id] = try ReviewDiffFixture.diff(of: file, fingerprint: fingerprint)
        return repository
    }
}

/// A session wired to a fake repository, keeping its draft in memory: the
/// root names no folder, since nothing here reads or writes the filesystem.
@MainActor
func fakeReviewSession(git: any ReviewRepositoryReading) -> ReviewSession {
    ReviewSession(
        root: URL(fileURLWithPath: "/tmp/limpid-review-root"),
        git: git,
        drafts: EphemeralReviewDraftStore()
    )
}
