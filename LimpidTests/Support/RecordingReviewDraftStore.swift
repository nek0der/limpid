// RecordingReviewDraftStore.swift
// Limpid — a review draft store that keeps what it is given, in memory.

import Foundation
@testable import Limpid

/// A draft store that keeps what it is given, so two stores over the same
/// root can be made to hand a draft between them.
///
/// `EphemeralReviewDraftStore` discards, which is right for demo mode and for
/// tests with nothing to say about persistence — but it cannot answer what a
/// second opening of the review reads back.
final class RecordingReviewDraftStore: ReviewDraftStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var drafts: [URL: ReviewDraft] = [:]
    private var saveCount = 0
    /// What every load throws instead of reading, for a draft that had to be
    /// quarantined, brought forward without a copy, or left where it was.
    var loadError: (any Error)?
    /// Set to fail every save, which is how a caller's rollback is exercised.
    var isFailing = false

    /// How many saves were asked for, including those that failed.
    var saves: Int {
        lock.withLock { saveCount }
    }

    func load(root: URL) throws -> ReviewDraft? {
        if let loadError {
            throw loadError
        }
        return lock.withLock { drafts[root] }
    }

    func save(_ draft: ReviewDraft, root: URL) throws {
        lock.withLock { saveCount += 1 }
        if isFailing {
            throw ReviewError.storageFailed
        }
        lock.withLock { drafts[root] = draft }
    }
}
