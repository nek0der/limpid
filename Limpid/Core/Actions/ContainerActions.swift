// ContainerActions.swift
// Limpid — destructive verbs over Projects / Worktrees that also unregister the freed `SurfaceView`s so the registry doesn't leak.

import Foundation

@MainActor
enum ContainerActions {
    /// Delete a Project (worktrees + project-direct tabs) and free
    /// every `SurfaceView` that lived inside.
    static func removeProject(
        _ session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        projectID: UUID
    ) {
        let leafIDs = session.removeProject(projectID)
        for id in leafIDs {
            registry.unregister(id)
        }
    }

    /// Drop a single worktree row + close every tab in it. Used for
    /// orphan / missing rows and after a successful
    /// `git worktree remove`. Hide-from-sidebar uses `hideWorktree`
    /// instead because that flow needs to keep tabs alive.
    static func removeWorktree(
        _ session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        projectID: UUID,
        worktreeID: UUID
    ) {
        let leafIDs = session.removeWorktree(projectID: projectID, worktreeID: worktreeID)
        for id in leafIDs {
            registry.unregister(id)
        }
    }

    /// Prune all `isMissing` rows under a project and free their
    /// `SurfaceView`s.
    static func pruneMissingWorktrees(
        _ session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        projectID: UUID
    ) {
        let leafIDs = session.pruneMissingWorktrees(projectID: projectID)
        for id in leafIDs {
            registry.unregister(id)
        }
    }

    /// Async wrapper around `WorkspaceSession.deleteGitWorktree` that
    /// also frees the affected `SurfaceView`s on success.
    static func deleteGitWorktree(
        _ session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        projectID: UUID,
        worktreeID: UUID,
        force: Bool
    ) async throws {
        let leafIDs = try await session.deleteGitWorktree(
            projectID: projectID,
            worktreeID: worktreeID,
            force: force
        )
        for id in leafIDs {
            registry.unregister(id)
        }
    }

    /// Delete Worktrees, on the line the worktrees ready to clean up fold
    /// into: `git worktree remove` on each in turn, forced only when
    /// `force` is set. A worktree Git refuses (changes it holds after all,
    /// a lock, a submodule) keeps its row and is returned with why, so the
    /// caller can ask for Force for those alone. Branches stay: a closed
    /// request's branch may hold the only copy of its commits.
    static func deleteGitWorktrees(
        _ session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        projectID: UUID,
        worktreeIDs: [UUID],
        force: Bool,
        git: any GitRunning = LiveGit()
    ) async -> [(worktreeID: UUID, error: any Error)] {
        var refused: [(worktreeID: UUID, error: any Error)] = []
        for worktreeID in worktreeIDs {
            do {
                let leafIDs = try await session.deleteGitWorktree(
                    projectID: projectID,
                    worktreeID: worktreeID,
                    force: force,
                    git: git
                )
                for id in leafIDs {
                    registry.unregister(id)
                }
            } catch {
                refused.append((worktreeID, error))
            }
        }
        return refused
    }
}
