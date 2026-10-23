// WorktreeOperationAlerts.swift
// Limpid — the worktree and project removal confirmations. Each alert
// is gated by its own optional state in the parent: when the binding is
// non-nil, the corresponding alert presents.
//
// The worktree and project alerts live together: they all need
// `session` + `registry`, and they're conceptually one "destructive
// operations" surface.

import SwiftUI

struct WorktreeOperationAlerts: ViewModifier {
    @Environment(WorkspaceSession.self) private var session
    @Environment(\.surfaceRegistry) private var registry
    @Environment(SessionLaunchStore.self) private var launches

    @Binding var deletingWorktree: DeleteWorktreeTarget?
    @Binding var forceDeleteWorktree: ForceDeleteWorktreeTarget?
    @Binding var removingProject: RemoveProjectTarget?
    @Binding var worktreeOperationError: DisplayText?

    func body(content: Content) -> some View {
        content
            .alert(
                // Named, as the Human Interface Guidelines ask of a confirmation's title.
                Text("Delete the worktree “\(deletingWorktree?.label ?? "")”?"),
                isPresented: Binding(
                    get: { deletingWorktree != nil },
                    set: {
                        if !$0 {
                            deletingWorktree = nil
                        }
                    }
                ),
                presenting: deletingWorktree
            ) { target in
                Button("Delete", role: .destructive) {
                    Task { await performDelete(target, force: false) }
                }
                Button("Cancel", role: .cancel) { deletingWorktree = nil }
            } message: { target in
                // Prose first so the consequence is visually anchored
                // to the title, then the path on its own line — keeps
                // long /Users/... paths from breaking the sentence.
                Text("Runs `git worktree remove`. The folder is removed from disk.\n\n\(target.path.path)")
            }
            .alert(
                Text("Force delete the worktree “\(forceDeleteWorktree?.target.label ?? "")”?"),
                isPresented: Binding(
                    get: { forceDeleteWorktree != nil },
                    set: {
                        if !$0 {
                            forceDeleteWorktree = nil
                        }
                    }
                ),
                presenting: forceDeleteWorktree
            ) { pending in
                Button("Force Delete", role: .destructive) {
                    Task { await performDelete(pending.target, force: true) }
                }
                Button("Cancel", role: .cancel) { forceDeleteWorktree = nil }
            } message: { pending in
                switch pending.reason {
                case .uncommittedChanges:
                    Text("The worktree has uncommitted changes, which will be lost.")
                case .initializedSubmodules:
                    Text(
                        """
                        The worktree contains initialized submodules. Any uncommitted work will be lost, \
                        and local commits or stashes that exist only in its submodules may also be lost.
                        """
                    )
                }
            }
            .alert(
                // Named, since the palette reaches it with no row in sight.
                Text("Close “\(removingProject?.name ?? "")”?"),
                isPresented: Binding(
                    get: { removingProject != nil },
                    set: {
                        if !$0 {
                            removingProject = nil
                        }
                    }
                ),
                presenting: removingProject
            ) { target in
                Button("Close Project", role: .destructive) {
                    withAnimation(LimpidMotion.reorderUnlessReduced) {
                        ContainerActions.removeProject(session, registry: registry, projectID: target.projectID)
                    }
                    removingProject = nil
                }
                Button("Cancel", role: .cancel) { removingProject = nil }
            } message: { target in
                // The tabs skip Close Tab's confirmation and its record, so
                // ⌘⇧T cannot bring them back: this is the one warning.
                if session.hasLiveAgent(inProject: target.projectID) {
                    Text("All of its tabs close, and the agents running in them stop. Files on disk aren’t affected.")
                } else {
                    Text("All of its tabs close. Files on disk aren’t affected.")
                }
            }
            .alert(
                "Couldn’t Delete the Worktree",
                isPresented: Binding(
                    get: { worktreeOperationError != nil },
                    set: {
                        if !$0 {
                            worktreeOperationError = nil
                        }
                    }
                ),
                presenting: worktreeOperationError
            ) { _ in
                Button("OK", role: .cancel) { worktreeOperationError = nil }
            } message: { msg in
                Text(display: msg)
            }
    }

    /// Two-stage delete: try clean first; when Git requires Force, flip
    /// to a reason-specific confirmation so the user can assess what
    /// local work may be lost. Other errors bubble into the shared
    /// error surface.
    private func performDelete(
        _ target: DeleteWorktreeTarget,
        force: Bool
    ) async {
        // A setup still running would keep writing into the folder.
        await launches.cancelSetup(worktreeID: target.worktreeID)
        do {
            try await ContainerActions.deleteGitWorktree(
                session,
                registry: registry,
                projectID: target.projectID,
                worktreeID: target.worktreeID,
                force: force
            )
        } catch DeleteWorktreeError.dirtyNeedsForce {
            forceDeleteWorktree = .init(target: target, reason: .uncommittedChanges)
        } catch DeleteWorktreeError.submodulesNeedForce {
            forceDeleteWorktree = .init(target: target, reason: .initializedSubmodules)
        } catch {
            worktreeOperationError = DisplayText(error: error)
        }
    }
}

extension View {
    func worktreeOperationAlerts(
        deletingWorktree: Binding<DeleteWorktreeTarget?>,
        forceDeleteWorktree: Binding<ForceDeleteWorktreeTarget?>,
        removingProject: Binding<RemoveProjectTarget?>,
        worktreeOperationError: Binding<DisplayText?>
    ) -> some View {
        modifier(WorktreeOperationAlerts(
            deletingWorktree: deletingWorktree,
            forceDeleteWorktree: forceDeleteWorktree,
            removingProject: removingProject,
            worktreeOperationError: worktreeOperationError
        ))
    }
}
