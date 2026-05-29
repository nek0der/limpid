// ConflictWorktreeBridge.swift
// Limpid — maps the persisted sidebar model (`Project` / `Worktree`,
// Core/Models/SidebarItem.swift) onto the conflict domain's
// `WatchedWorktree`. This is the one place the two "worktree" types
// meet; everything downstream speaks only `WatchedWorktree`.
//
// Identity: we reuse the model's stable persisted UUIDs (project id for
// the primary checkout, worktree id for linked ones) rather than the
// spec's git-internal name. The UUIDs are already stable across moves
// and restarts, which is exactly the property the spec wanted, without a
// `rev-parse --git-dir` round-trip.

import Foundation

enum ConflictWorktreeBridge {
    /// Build the worktrees worth watching. A project contributes its
    /// primary checkout plus every visible, on-disk linked worktree —
    /// but only when that yields 2+ trees, since a lone tree can't
    /// conflict with anything (no point spending an FSEventStream +
    /// `git status` on it).
    static func watchedWorktrees(from projects: [Project]) -> [WatchedWorktree] {
        projects.flatMap { project -> [WatchedWorktree] in
            let projectID = ProjectID(raw: project.id.uuidString)
            let primary = WatchedWorktree(
                id: WorktreeID(raw: project.id.uuidString),
                rootURL: project.rootURL.standardizedFileURL,
                projectID: projectID,
                branch: project.mainBranchName ?? "",
                isPrimary: true,
                writerTabID: nil
            )
            let linked = project.worktrees
                .filter { !$0.isHidden && !$0.isMissing }
                .map { worktree in
                    WatchedWorktree(
                        id: WorktreeID(raw: worktree.id.uuidString),
                        rootURL: worktree.workingDirectory.standardizedFileURL,
                        projectID: projectID,
                        branch: worktree.gitRef?.branchName ?? worktree.label,
                        isPrimary: false,
                        writerTabID: nil
                    )
                }

            let trees = [primary] + linked
            return trees.count >= 2 ? trees : []
        }
    }

    /// `WorktreeID` for a project's primary checkout (the project header
    /// row). Mirrors the id minted in `watchedWorktrees`.
    static func id(forProject projectID: UUID) -> WorktreeID {
        WorktreeID(raw: projectID.uuidString)
    }

    /// `WorktreeID` for a linked worktree row.
    static func id(forWorktree worktreeID: UUID) -> WorktreeID {
        WorktreeID(raw: worktreeID.uuidString)
    }
}
