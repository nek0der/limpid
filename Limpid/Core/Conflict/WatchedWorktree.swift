// WatchedWorktree.swift
// Limpid — the conflict-detection domain's view of a working tree, plus
// its stable identity types (spec §2).
//
// Naming: this is `WatchedWorktree`, deliberately NOT the spec's
// `WorkTree`. The persisted sidebar model is already `Worktree`
// (Core/Models/SidebarItem.swift); a second type differing only by one
// capital letter (`WorkTree` vs `Worktree`) is a maintenance footgun in
// review and autocomplete. We keep the spec's field semantics but a
// distinct name. The two are bridged at the registry boundary (a later
// step): each `Project.rootURL` becomes a primary `WatchedWorktree` and
// each `Worktree` row becomes a linked one.

import Foundation

/// Stable identifier for a watched working tree. The raw value is the
/// git-internal worktree name (`.git/worktrees/<name>`, or the project's
/// own id for the primary checkout) rather than the path, so it survives
/// the directory being moved on disk (spec §12.3).
struct WorktreeID: Hashable { let raw: String }

/// Identity of the owning project. Bridged from `Project.id`.
struct ProjectID: Hashable { let raw: String }

/// Identity of a tab. Used to mark the "writer" tab for completion
/// detection (spec §6); display-only for detection itself.
struct TabID: Hashable { let raw: String }

/// A working tree the conflict pipeline watches. Unifies the project's
/// primary checkout (`isPrimary == true`) and each linked git worktree
/// into one shape so the detector can treat them identically — the
/// "is anyone else touching the same files" question doesn't care which
/// is the clone origin.
struct WatchedWorktree: Identifiable, Hashable {
    let id: WorktreeID
    /// Absolute path to the working tree root.
    let rootURL: URL
    let projectID: ProjectID
    /// Currently checked-out branch (display + L2 merge-tree input).
    let branch: String
    /// `true` for the clone origin (main checkout), `false` for linked
    /// worktrees.
    let isPrimary: Bool
    /// Tab marked as the "writer" for completion detection (spec §6).
    /// nil until the user marks one.
    var writerTabID: TabID?
}
