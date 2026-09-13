// FakeReviewRepository.swift
// Limpid — a repository that answers the review store without Git.

import Foundation
@testable import Limpid

/// Answers `ReviewRepositoryReading` from values a test hands it.
///
/// The point is the answers a real repository cannot be made to give on
/// demand: a file that vanishes between two reads, a diff that fails while its
/// neighbours succeed, a working copy that cannot be read at all.
final class FakeReviewRepository: ReviewRepositoryReading, @unchecked Sendable {
    var files: [ReviewFile] = []
    var nextFilesGate: ReviewFilesGate?
    var nextDiffFailureGate: ReviewDiffFailureGate?
    var stats: [String: ReviewFileStat] = [:]
    var diffs: [String: ReviewDiff] = [:]
    var fingerprints: [String: String] = [:]
    var hasChangesOverride: Bool?
    var unsupportedDiffs: Set<String> = []
    var sources: [String: [String]] = [:]
    var base: String?
    /// File ids whose diff should fail rather than answer.
    var failingDiffs: Set<String> = []
    private(set) var diffCalls: [String] = []
    private(set) var fileCalls = 0
    private(set) var fileScopes: [ReviewScope] = []
    private(set) var diffScopes: [ReviewScope] = []
    var isTurnBaseMissing = false
    var isFileListFailing = false

    func files(at _: URL, scope: ReviewScope) async throws -> [ReviewFile] {
        fileCalls += 1
        fileScopes.append(scope)
        if scope.isTurn, isTurnBaseMissing {
            throw ReviewError.turnBaseMissing
        }
        if isFileListFailing {
            throw ReviewError.gitFailed
        }
        if let gate = nextFilesGate {
            nextFilesGate = nil
            return await gate.answer()
        }
        return files
    }

    func stats(at _: URL, scope _: ReviewScope) async throws -> [String: ReviewFileStat] {
        stats
    }

    func diff(_ file: ReviewFile, root _: URL, scope: ReviewScope) async throws -> ReviewDiff {
        diffCalls.append(file.id)
        diffScopes.append(scope)
        if let gate = nextDiffFailureGate {
            nextDiffFailureGate = nil
            await gate.answer()
            throw ReviewError.gitFailed
        }
        if unsupportedDiffs.contains(file.id) {
            throw ReviewError.unsupported
        }
        if failingDiffs.contains(file.id) {
            throw ReviewError.gitFailed
        }
        guard let diff = diffs[file.id] else { throw ReviewError.gitFailed }
        return diff
    }

    func fingerprint(_ file: ReviewFile, root: URL, scope: ReviewScope) async throws -> String {
        if let fingerprint = fingerprints[file.id] {
            return fingerprint
        }
        return try await diff(file, root: root, scope: scope).fingerprint
    }

    func hasChanges(
        at root: URL,
        scope: ReviewScope,
        comparedTo displayedFiles: [ReviewFile],
        currentDiff: ReviewDiff?
    ) async throws -> Bool {
        if let hasChangesOverride {
            return hasChangesOverride
        }
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

/// Holds one diff request until a newer repository snapshot can overtake it.
actor ReviewDiffFailureGate {
    private var response: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func answer() async {
        await withCheckedContinuation { continuation in
            response = continuation
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilRequested() async {
        guard response == nil else { return }
        await withCheckedContinuation { observer = $0 }
    }

    func resume() {
        response?.resume()
        response = nil
    }
}

/// A draft store that keeps what it is given, so two stores over the same
/// root can be made to hand a draft between them.
///
/// `EphemeralReviewDraftStore` discards, which is right for demo mode and for
/// tests with nothing to say about persistence — but it cannot answer what a
/// second opening of review reads back.
final class RecordingReviewDraftStore: ReviewDraftStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var drafts: [URL: ReviewDraft] = [:]
    /// Set to simulate a draft that had to be quarantined while opening.
    var isLoadFailing = false
    /// Set to fail every save, which is how a caller's rollback is exercised.
    var isFailing = false

    func load(root: URL) throws -> ReviewDraft? {
        if isLoadFailing {
            throw ReviewError.draftUnreadable
        }
        return lock.withLock { drafts[root] }
    }

    func save(_ draft: ReviewDraft, root: URL) throws {
        if isFailing {
            throw ReviewError.storageFailed
        }
        lock.withLock { drafts[root] = draft }
    }
}

/// A store wired to a fake repository, keeping its draft in memory.
///
/// Nothing here has anything to say about the filesystem, and the version that
/// made a temporary directory never removed it — every run left one behind.
@MainActor
func withTempStore(git: any ReviewRepositoryReading) -> ReviewStore {
    ReviewStore(
        root: URL(fileURLWithPath: "/tmp/limpid-review-root"),
        git: git,
        drafts: EphemeralReviewDraftStore()
    )
}

/// The test controls one response without relying on a wall-clock delay.
actor ReviewFilesGate {
    private var response: CheckedContinuation<[ReviewFile], Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func answer() async -> [ReviewFile] {
        await withCheckedContinuation { continuation in
            response = continuation
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilRequested() async {
        guard response == nil else { return }
        await withCheckedContinuation { observer = $0 }
    }

    func resume(with files: [ReviewFile]) {
        response?.resume(returning: files)
        response = nil
    }
}
