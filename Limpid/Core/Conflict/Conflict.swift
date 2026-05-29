// Conflict.swift
// Limpid — the conflict-detection result types (spec §2). The load-
// bearing decision: a Conflict's unit is the *set of involved
// worktrees*, NOT a file. If A and B both touch 30 files, that is ONE
// Conflict with 30 `paths`, not 30 conflicts — otherwise the UI drowns
// in duplicates. `id` is derived deterministically from the worktree
// set so the same overlap dedups across every re-evaluation, and a
// user's "ignore" (which lives on the pair) survives new files joining.

import Foundation

/// A detected overlap between two or more worktrees.
struct Conflict: Identifiable, Equatable {
    let id: ConflictID
    /// Involved worktrees — usually 2, occasionally more.
    let parties: [ConflictParty]
    /// Every file the parties overlap on, aggregated here rather than
    /// spawning one Conflict per file.
    var paths: [ConflictPath]
    let detectedAt: Date
    var status: ConflictStatus

    /// Worst level across files: `.confirmed` if any file is an L2 real
    /// conflict, else `.potential`.
    var topLevel: ConflictLevel {
        paths.contains { $0.level == .confirmed } ? .confirmed : .potential
    }

    var fileCount: Int {
        paths.count
    }

    var confirmedCount: Int {
        paths.count(where: { $0.level == .confirmed })
    }
}

/// One overlapping file within a Conflict. Level is per-file: at L1
/// everything is `.potential`; L2 (a later step) promotes the files
/// that truly conflict at the line level to `.confirmed`.
struct ConflictPath: Identifiable, Equatable {
    var id: String {
        path
    }

    let path: String
    let level: ConflictLevel
    /// Freshest touch time across the involved worktrees — drives sort
    /// order and the staleness filter.
    let lastTouched: Date
}

/// A worktree participating in a conflict, with display metadata. The
/// labels are display-only; detection never reads them.
struct ConflictParty: Equatable {
    let workTreeID: WorktreeID
    let branch: String
    /// Working-tree root — lets the modal's compare view read each
    /// side's copy of a conflicting file (`rootURL` + path).
    let rootURL: URL
    /// When this worktree last touched any of the conflict's files.
    let lastTouched: Date
    let agentLabel: String?
    let taskLabel: String?
}

enum ConflictLevel: Equatable {
    /// L1: the same file is changed (uncommitted) in 2+ worktrees.
    case potential
    /// L2: `git merge-tree` confirmed a line-level conflict.
    case confirmed
}

enum ConflictStatus: Equatable {
    case active
    /// User chose to ignore this pair (e.g. intentional shared edit).
    case ignored
    /// Gone, but inside the grace window — kept to avoid the ⚠️
    /// flickering on save → momentarily-clean → save (spec §5, step 5).
    case resolving(since: Date)
    /// Past the grace window; resolved for good.
    case resolved
}

/// Deterministic id derived from the involved worktree set, so the same
/// overlap always maps to the same Conflict regardless of which / how
/// many files overlap or how often detection runs.
struct ConflictID: Hashable, Identifiable {
    let raw: String
    var id: String {
        raw
    }

    /// Build from a worktree set: sort the raw ids and join. We use the
    /// joined key directly rather than hashing it — it is already a
    /// stable unique identifier, and skipping the hash sidesteps any
    /// collision risk.
    init(members: Set<WorktreeID>) {
        raw = members.map(\.raw).sorted().joined(separator: "|")
    }

    /// Rebuild from a raw value — used to round-trip an id through the
    /// `.limpidShowConflictRequested` notification.
    init(raw: String) {
        self.raw = raw
    }
}
