// ReviewStore+Lifecycle.swift
// Limpid — lifecycle operations that do not depend on a live review snapshot.

import Foundation

extension ReviewStore {
    /// `nonisolated` so off-actor prompt and persistence helpers share the
    /// exact limits enforced by the main-actor store.
    nonisolated static let maxComments = 100
    nonisolated static let maxCommentBytes = 4096
    nonisolated static let maxCodeExcerpt = 2048

    /// Forget the draft written against a worktree that is being deleted.
    ///
    /// Only on the explicit delete. A worktree that is merely unreachable — an
    /// external volume that is not mounted — comes back, and its comments
    /// should come back with it. Without this, a new worktree made at the same
    /// path inherited comments written about code that is gone.
    nonisolated static func removeDraft(root: URL, directory: URL = ReviewStorePool.defaultDirectory) {
        ReviewDraftWriteCoordinator.shared.remove(root: root.resolvingSymlinksInPath(), directory: directory)
    }
}
