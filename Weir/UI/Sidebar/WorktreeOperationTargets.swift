// WorktreeOperationTargets.swift
// Weir — what a removal confirmation is about: a worktree or a project.

import Foundation

/// Target of a "Delete Worktree…" gesture, from a sidebar row or the
/// changes panel's cleanup. Carries enough context for the confirmation
/// alert and the Force retry; the view that owns the alert state holds it.
struct DeleteWorktreeTarget: Identifiable, Equatable {
    let id = UUID()
    let projectID: UUID
    let worktreeID: UUID
    let label: String
    let path: URL
}

/// Target of "Delete Worktrees…" on the line the worktrees ready to clean
/// up fold into: every one of them, named for the confirmation and for
/// the error that lists those Git refused.
struct DeleteWorktreesTarget: Identifiable, Equatable {
    struct Entry: Equatable {
        let worktreeID: UUID
        let label: String
    }

    let id = UUID()
    let projectID: UUID
    let worktrees: [Entry]
}

enum ForceDeleteWorktreeReason: Equatable {
    case uncommittedChanges
    case initializedSubmodules
}

/// A failed clean removal promoted to the destructive Force
/// confirmation, preserving why Git requires the escalation.
struct ForceDeleteWorktreeTarget: Identifiable, Equatable {
    var id: UUID {
        target.id
    }

    let target: DeleteWorktreeTarget
    let reason: ForceDeleteWorktreeReason
}

/// Target of a "Close Project" gesture.
struct RemoveProjectTarget: Identifiable, Equatable {
    let id = UUID()
    let projectID: UUID
    let name: String
}
