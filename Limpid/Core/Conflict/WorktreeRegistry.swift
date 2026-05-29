// WorktreeRegistry.swift
// Limpid — owns the live set of `WorktreeWatcher`s and keeps it in step
// with the desired worktree set (spec §12.3). An actor so watcher
// creation / teardown and snapshot gathering serialize cleanly.
//
// Unlike the spec's reference, `sync` takes the desired `[WatchedWorktree]`
// rather than re-running `git worktree list` itself: the sidebar's
// `GitSyncCoordinator` already enumerates worktrees into the session
// model, and `ConflictWorktreeBridge` maps that to `[WatchedWorktree]`.
// Re-listing here would duplicate that work (review concern 4).

import Foundation

actor WorktreeRegistry {
    private var watchers: [WorktreeID: WorktreeWatcher] = [:]
    private let coordinator: any FSEventCoordinating
    private let git: any GitInspecting

    init(coordinator: any FSEventCoordinating, git: any GitInspecting) {
        self.coordinator = coordinator
        self.git = git
    }

    func watcher(for id: WorktreeID) -> WorktreeWatcher? {
        watchers[id]
    }

    /// A snapshot of every watched worktree's current changes — the
    /// detector's input. `workTree` is an immutable Sendable `let`, so it
    /// reads without an extra hop; `current` is actor state and is
    /// awaited per watcher.
    func snapshot() async -> [WorktreeSnapshot] {
        var result: [WorktreeSnapshot] = []
        for watcher in watchers.values {
            await result.append(
                WorktreeSnapshot(worktree: watcher.workTree, changeSet: watcher.current)
            )
        }
        return result
    }

    /// Reconcile the watched set to `desired`: start watching newcomers
    /// (and immediately refresh them so pre-existing on-disk changes are
    /// caught without waiting for the next save), stop watching the ones
    /// that are gone. Worktrees still present are left untouched — note
    /// their `WatchedWorktree` (incl. `branch`) is NOT refreshed here, so
    /// a branch switch won't propagate until the worktree is re-added.
    /// Fine for L1 (branch is display-only); revisit before L2 merge-tree
    /// (review concern 3).
    func sync(to desired: [WatchedWorktree]) async {
        let desiredByID = Dictionary(desired.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let desiredIDs = Set(desiredByID.keys)
        let knownIDs = Set(watchers.keys)

        for id in knownIDs.subtracting(desiredIDs) {
            coordinator.unwatch(id)
            watchers[id] = nil
        }
        for id in desiredIDs.subtracting(knownIDs) {
            guard let workTree = desiredByID[id] else { continue }
            let watcher = WorktreeWatcher(workTree: workTree, git: git)
            watchers[id] = watcher
            coordinator.watch(workTree)
            _ = await watcher.refresh()
        }
    }
}
