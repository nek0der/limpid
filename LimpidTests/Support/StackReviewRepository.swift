// StackReviewRepository.swift
// Limpid — a repository the review tab's stack can read from several tasks at once.

import Foundation
@testable import Limpid

/// Answers `ReviewRepositoryReading` from values a test sets up front, safely
/// from the several reads the stack runs at once, counting how many run
/// together. `FakeReviewRepository` records every call in plain arrays, which
/// is fine for one read at a time and a race for the stack's.
final class StackReviewRepository: ReviewRepositoryReading, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [ReviewFile] = []
    private var diffs: [String: ReviewDiff] = [:]
    private var fingerprints: [String: String] = [:]
    private var inFlight = 0
    private var mostAtOnce = 0
    private var reads = 0
    private var indexReads = 0
    /// The work tree and the index, by path: what the read states see.
    private var head = "head"
    private var indexEntries: [String: String] = [:]
    private var stats: [String: Int] = [:]
    private var contents: [String: Int] = [:]
    private var failsStateReads = false
    private var fingerprintReads = 0
    private var sources: [String: [String]] = [:]
    /// How long each diff takes to read.
    let delay: Duration
    /// Run while a diff is being read, as an edit landing mid-read.
    private var duringRead: (@Sendable (ReviewFile) -> Void)?

    func onRead(_ action: (@Sendable (ReviewFile) -> Void)?) {
        lock.withLock { duringRead = action }
    }

    init(files: [ReviewFile], diffs: [ReviewDiff], delay: Duration = .zero) {
        self.files = files
        self.diffs = Dictionary(uniqueKeysWithValues: diffs.map { ($0.file.id, $0) })
        self.delay = delay
    }

    /// The most diffs that were being read at once.
    var peak: Int {
        lock.withLock { mostAtOnce }
    }

    var diffReads: Int {
        lock.withLock { reads }
    }

    /// How many times the index was read (for read states and the check).
    var indexStateReads: Int {
        lock.withLock { indexReads }
    }

    var fingerprintCalls: Int {
        lock.withLock { fingerprintReads }
    }

    /// A file's new side, whole, for unfolding.
    func setSource(_ fileID: String, lines: Int) {
        setSource(fileID, text: (0..<lines).map { "line \($0)" })
    }

    func setSource(_ fileID: String, text: [String]) {
        lock.withLock { sources[fileID] = text }
    }

    /// What Git would answer now for a file, as if it had been edited: its
    /// diff's fingerprint and its content both move.
    func change(_ fileID: String, fingerprint: String) {
        lock.withLock {
            fingerprints[fileID] = fingerprint
            if let path = files.first(where: { $0.id == fileID })?.path {
                stats[path, default: 0] += 1
                contents[path, default: 0] += 1
            }
        }
    }

    /// A write of the same content: the stat moves, the content does not.
    func touch(_ path: String) {
        lock.withLock { stats[path, default: 0] += 1 }
    }

    /// A stage: the index entry moves.
    func stage(_ path: String) {
        lock.withLock { indexEntries[path, default: ""] += "+" }
    }

    /// HEAD moves by itself (`reset --soft`, `--amend`).
    func moveHead() {
        lock.withLock { head += "'" }
    }

    /// Whether reading the index fails, as a Git that does not answer.
    func failStateReads(_ fails: Bool) {
        lock.withLock { failsStateReads = fails }
    }

    func replace(_ diff: ReviewDiff) {
        lock.withLock { diffs[diff.file.id] = diff }
    }

    func files(at _: URL, scope _: ReviewScope) async throws -> [ReviewFile] {
        lock.withLock { files }
    }

    func stats(at _: URL, scope _: ReviewScope) async throws -> [String: ReviewFileStat] {
        [:]
    }

    func diff(_ file: ReviewFile, root _: URL, scope _: ReviewScope) async throws -> ReviewDiff {
        lock.withLock {
            reads += 1
            inFlight += 1
            mostAtOnce = max(mostAtOnce, inFlight)
        }
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        lock.withLock { duringRead }?(file)
        return try lock.withLock {
            inFlight -= 1
            guard let diff = diffs[file.id] else { throw ReviewError.gitFailed }
            return diff
        }
    }

    func indexState(root _: URL, scope _: ReviewScope, paths: Set<String>) async throws -> ReviewIndexState {
        try lock.withLock {
            indexReads += 1
            guard !failsStateReads else { throw ReviewError.gitFailed }
            return ReviewIndexState(head: head, base: nil, entries: indexEntries.filter { paths.contains($0.key) })
        }
    }

    func fileStats(_ paths: [String], root _: URL) -> [String: ReviewPathStat] {
        lock.withLock {
            Dictionary(paths.map { path in
                (path, ReviewPathStat(kind: .regular, info: "100644:\(stats[path] ?? 0)", size: 0))
            }, uniquingKeysWith: { first, _ in first })
        }
    }

    func contentHashes(_ paths: [String], root _: URL) async throws -> [String: String] {
        lock.withLock { Dictionary(paths.map { ($0, "content\(contents[$0] ?? 0)") }, uniquingKeysWith: { first, _ in first }) }
    }

    func fingerprint(_ file: ReviewFile, root _: URL, scope _: ReviewScope) async throws -> String {
        try lock.withLock {
            fingerprintReads += 1
            if let fingerprint = fingerprints[file.id] {
                return fingerprint
            }
            guard let diff = diffs[file.id] else { throw ReviewError.gitFailed }
            return diff.fingerprint
        }
    }

    func hasChanges(
        at _: URL,
        scope _: ReviewScope,
        comparedTo _: [ReviewFile],
        currentDiff: ReviewDiff?
    ) async throws -> Bool {
        lock.withLock {
            guard let currentDiff else { return false }
            return fingerprints[currentDiff.file.id].map { $0 != currentDiff.fingerprint } ?? false
        }
    }

    func source(_ file: ReviewFile, root _: URL, scope _: ReviewScope) async -> [String] {
        lock.withLock { sources[file.id] ?? [] }
    }

    func defaultBase(at _: URL) async throws -> String? {
        "main"
    }
}
