// ReviewStore+Lifecycle.swift
// Limpid — lifecycle operations that do not depend on a live review snapshot.

import Foundation

struct ReviewLoadedDiff {
    let diff: ReviewDiff?
    let source: [String]
    let error: (any Error)?
}

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

    /// A stored comment carries its layer but not the selector parameters.
    /// The store retains those parameters separately so validation reads the
    /// same snapshot even after the visible scope changes.
    func scopeForFile(_ file: ReviewFile) -> ReviewScope {
        switch file.layer {
        case .turn: turnScope ?? scope
        case .branch: base.map { .branch(base: $0) } ?? scope
        case .staged, .unstaged, .untracked: .uncommitted
        }
    }
}

/// Serialized with a lock rather than by isolating the type. The one method
/// hands back a `@MainActor` store and is only called from view code, but the
/// pool is an `@Entry` default value, which SwiftUI builds outside any actor —
/// so the type itself cannot be `@MainActor`.
final class ReviewStorePool: @unchecked Sendable {
    /// Where the stores this pool hands out keep their drafts. In demo mode
    /// that is nowhere: `DemoFixture` is an app-level fact, so which one it is
    /// arrives from above rather than being read here.
    private let drafts: any ReviewDraftStoring

    /// Demo mode keeps its comments in memory: the fixture is a stage set, and
    /// writing its review into the reader's own draft directory would outlive
    /// the demo.
    init(shouldPersist: Bool = true, directory: URL? = nil) {
        drafts = shouldPersist
            ? FileReviewDraftStore(directory: directory ?? Self.defaultDirectory)
            : EphemeralReviewDraftStore()
    }

    private final class WeakStore {
        weak var value: ReviewStore?
        init(_ value: ReviewStore) {
            self.value = value
        }
    }

    /// Where drafts live. Named here rather than at each use so the deletion
    /// path and the pool cannot end up looking in two places.
    static var defaultDirectory: URL {
        LimpidPaths.applicationSupportDirectory().appendingPathComponent("reviews")
    }

    private let lock = NSLock()
    private var openStores: [String: WeakStore] = [:]

    @MainActor
    func store(root: URL) -> ReviewStore {
        if let existing = lock.withLock({
            openStores = openStores.filter { $0.value.value != nil }
            return openStores[root.path]?.value
        }) {
            return existing
        }
        let store = ReviewStore(root: root, drafts: drafts)
        lock.withLock { openStores[root.path] = WeakStore(store) }
        return store
    }
}
