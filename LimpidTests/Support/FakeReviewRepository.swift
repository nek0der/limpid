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
    var stats: [String: ReviewFileStat] = [:]
    var diffs: [String: ReviewDiff] = [:]
    var fingerprints: [String: String] = [:]
    var unsupportedDiffs: Set<String> = []
    var sources: [String: [String]] = [:]
    var base: String?
    /// File ids whose diff should fail rather than answer.
    var failingDiffs: Set<String> = []
    private(set) var diffCalls: [String] = []
    private(set) var fileCalls = 0

    func files(at _: URL, scope _: ReviewScope) async throws -> [ReviewFile] {
        fileCalls += 1
        if let gate = nextFilesGate {
            nextFilesGate = nil
            return await gate.answer()
        }
        return files
    }

    func stats(at _: URL, scope _: ReviewScope) async throws -> [String: ReviewFileStat] {
        stats
    }

    func diff(_ file: ReviewFile, root _: URL, base _: String?) async throws -> ReviewDiff {
        diffCalls.append(file.id)
        if unsupportedDiffs.contains(file.id) {
            throw ReviewError.unsupported
        }
        if failingDiffs.contains(file.id) {
            throw ReviewError.gitFailed
        }
        guard let diff = diffs[file.id] else { throw ReviewError.gitFailed }
        return diff
    }

    func fingerprint(_ file: ReviewFile, root: URL, base: String?) async throws -> String {
        if let fingerprint = fingerprints[file.id] {
            return fingerprint
        }
        return try await diff(file, root: root, base: base).fingerprint
    }

    func source(_ file: ReviewFile, root _: URL) async -> [String] {
        sources[file.id] ?? []
    }

    func defaultBase(at _: URL) async throws -> String? {
        base
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
    /// Set to fail every save, which is how a caller's rollback is exercised.
    var isFailing = false

    func load(root: URL) throws -> ReviewDraft? {
        lock.withLock { drafts[root] }
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
