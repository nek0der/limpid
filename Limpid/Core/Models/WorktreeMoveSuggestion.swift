// WorktreeMoveSuggestion.swift
// Limpid — value type describing the suggestion a `CwdChanged` event
// produced. Surfaced through `WorktreeMoveSuggester.current` so a
// SwiftUI banner can render the confirmation; the suggester resolves
// the action when the user accepts or dismisses.

import Foundation

/// Single pending "move to worktree" prompt. Identifiable so a banner
/// view can drive id-keyed transitions.
struct WorktreeMoveSuggestion: Identifiable, Equatable {
    let id = UUID()
    /// The pane the cwd change happened in. `accept()` walks back to
    /// this pane's owning tab and reparents it under the target
    /// worktree, which is what makes the running agent "follow" the
    /// cd without a pty respawn.
    let paneID: UUID
    /// New directory the agent moved into (verbatim from the hook,
    /// not symlink-resolved).
    let newCwd: URL
    /// What the user is being asked to confirm.
    let kind: Kind

    enum Kind: Equatable {
        /// Target worktree is already registered in Limpid. Accept
        /// reparents the source tab; the worktree row in container column lights up
        /// automatically because its container now matches.
        case reparentToRegistered(projectID: UUID, worktreeID: UUID, label: String)

        /// `git worktree list` discovered a worktree we don't track
        /// yet. Accept attaches the row first, then reparents the
        /// source tab into it.
        case reparentAfterAttach(projectID: UUID, path: URL, branchName: String?, label: String)
    }

    /// Display label shared across kinds — used by the banner title.
    var displayLabel: String {
        switch kind {
        case let .reparentToRegistered(_, _, label),
             let .reparentAfterAttach(_, _, _, label):
            label
        }
    }

    static func == (lhs: WorktreeMoveSuggestion, rhs: WorktreeMoveSuggestion) -> Bool {
        lhs.id == rhs.id
    }
}
