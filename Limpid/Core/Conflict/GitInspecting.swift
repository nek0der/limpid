// GitInspecting.swift
// Limpid — read-only git surface the conflict-detection pipeline reads
// from. Deliberately separate from `GitRunning` (Core/Git): that one
// *mutates* worktrees (add / remove) and is consumed by the sidebar
// CRUD pipeline; this one only *observes* git state so the detector can
// compute which worktrees touch the same files. Keeping the two
// protocols apart means a test can fake "what does git status say"
// without dragging in worktree-mutation machinery, and vice versa.
//
// The production implementation is `ShellGit`, which forwards to the
// existing `GitProcess` subprocess wrapper. Step 1 of the conflict
// detection spec covers only `status`; the protocol grows with each
// later step (merge-base / merge-tree for L2, worktree enumeration for
// the registry) rather than landing unused surface up front.

import Foundation

protocol GitInspecting: Sendable {
    /// The working tree's changed files, from
    /// `git status --porcelain=v1 -z --untracked-files=all`. Paths are
    /// relative to the repository root. `.gitignore`d files
    /// (node_modules, build output) are absent because git excludes
    /// them — that is what keeps detector noise down without us
    /// re-implementing ignore rules. Returns `[]` for a path that
    /// isn't a working tree.
    func status(at root: URL) async throws -> [GitStatusEntry]
}

/// One changed path from `git status`. For renames and copies, `path`
/// is the destination (new) path and `renamedFrom` is the original —
/// the conflict detector folds both into a worktree's changed-file set
/// so a rename collides on either name.
struct GitStatusEntry: Equatable {
    /// Repository-root-relative path. For a rename/copy, the new path.
    let path: String
    /// The original path when this entry is a rename/copy, else nil.
    let renamedFrom: String?
    /// `true` when the change is staged in the index (the X column is a
    /// real status, not space or `?`). Untracked files are never
    /// staged.
    let staged: Bool
}
