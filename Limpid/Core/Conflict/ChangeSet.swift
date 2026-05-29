// ChangeSet.swift
// Limpid — a snapshot of one worktree's uncommitted changes (spec §2),
// the raw material the L1 detector intersects across worktrees. Built
// from `git status`, so `.gitignore`d paths (node_modules, build output)
// are already excluded — we never have to re-implement ignore rules.

import Foundation

struct ChangeSet: Equatable {
    let workTreeID: WorktreeID
    /// Repository-root-relative paths with uncommitted changes. Renames
    /// contribute both the old and new path so an overlap is caught on
    /// either name.
    let changedPaths: Set<String>
    /// Per-path last-modified time, for the staleness filter (spec §5,
    /// step 5). Falls back to the capture time when a path has no
    /// on-disk mtime (e.g. a deleted file or a rename's old name).
    let lastTouched: [String: Date]
    /// When this snapshot was taken.
    let capturedAt: Date

    /// A worktree with no changes yet. `capturedAt` is `.distantPast` so
    /// the first real refresh always reads as "changed".
    static func empty(_ id: WorktreeID) -> ChangeSet {
        ChangeSet(workTreeID: id, changedPaths: [], lastTouched: [:], capturedAt: .distantPast)
    }
}

/// A worktree paired with its current changes — the per-worktree unit
/// the detector evaluates. The metadata (branch, labels) rides along so
/// the detector can build display-ready `ConflictParty` values without a
/// second lookup. Produced by the registry from its watchers (a later
/// step); supplied to `ConflictDetector.reevaluate` via its provider.
struct WorktreeSnapshot {
    let worktree: WatchedWorktree
    let changeSet: ChangeSet
}
