// WorktreeOperationAlerts.swift
// Limpid — all five worktree- / container-removal confirmation
// alerts, bundled as one `ViewModifier` so `ContainerSlabView`'s
// body doesn't carry 80+ lines of `.alert` chains. Each alert is
// gated by its own optional state in the parent: when the binding
// is non-nil, the corresponding alert presents.
//
// Why these five live together: they all fire from the container slab,
// all need `session` + `registry`, and they're conceptually one
// "destructive operations" surface. Splitting per-alert would
// scatter the wiring; keeping them inline in `ContainerSlabView`
// drowned the view body.

import SwiftUI

struct WorktreeOperationAlerts: ViewModifier {
    @Environment(WindowSession.self) private var session
    @Environment(\.surfaceRegistry) private var registry

    @Binding var deletingWorktree: ContainerSlabView.DeleteWorktreeTarget?
    @Binding var forceDeleteWorktree: ContainerSlabView.ForceDeleteWorktreeTarget?
    @Binding var removingProject: ContainerSlabView.RemoveProjectTarget?
    @Binding var removingGroup: ContainerSlabView.RemoveGroupTarget?
    @Binding var worktreeOperationError: String?

    func body(content: Content) -> some View {
        content
            .alert(
                "Delete worktree?",
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
                "Force delete?",
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
                    Text("Worktree has uncommitted changes. Force delete anyway? Uncommitted work will be lost.")
                case .initializedSubmodules:
                    Text(
                        """
                        Worktree contains initialized submodules. Force delete anyway? \
                        Any uncommitted work will be lost. Local commits or stashes that exist only \
                        in its submodules may also be lost.
                        """
                    )
                }
            }
            .alert(
                "Close project?",
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
                    withAnimation(LimpidMotion.reorder) {
                        ContainerActions.removeProject(session, registry: registry, projectID: target.projectID)
                    }
                    removingProject = nil
                }
                Button("Cancel", role: .cancel) { removingProject = nil }
            } message: { _ in
                Text("Files on disk are not affected.")
            }
            .alert(
                "Close group?",
                isPresented: Binding(
                    get: { removingGroup != nil },
                    set: {
                        if !$0 {
                            removingGroup = nil
                        }
                    }
                ),
                presenting: removingGroup
            ) { target in
                Button("Close Group", role: .destructive) {
                    withAnimation(LimpidMotion.reorder) {
                        ContainerActions.removeGroup(session, registry: registry, groupID: target.groupID)
                    }
                    removingGroup = nil
                }
                Button("Cancel", role: .cancel) { removingGroup = nil }
            } message: { _ in
                Text("All tabs in this group will be closed.")
            }
            .alert(
                "Delete failed",
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
                Text(msg)
            }
    }

    /// Two-stage delete: try clean first; when Git requires Force, flip
    /// to a reason-specific confirmation so the user can assess what
    /// local work may be lost. Other errors bubble into the shared
    /// error surface.
    private func performDelete(
        _ target: ContainerSlabView.DeleteWorktreeTarget,
        force: Bool
    ) async {
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
            worktreeOperationError = error.localizedDescription
        }
    }
}

extension View {
    func worktreeOperationAlerts(
        deletingWorktree: Binding<ContainerSlabView.DeleteWorktreeTarget?>,
        forceDeleteWorktree: Binding<ContainerSlabView.ForceDeleteWorktreeTarget?>,
        removingProject: Binding<ContainerSlabView.RemoveProjectTarget?>,
        removingGroup: Binding<ContainerSlabView.RemoveGroupTarget?>,
        worktreeOperationError: Binding<String?>
    ) -> some View {
        modifier(WorktreeOperationAlerts(
            deletingWorktree: deletingWorktree,
            forceDeleteWorktree: forceDeleteWorktree,
            removingProject: removingProject,
            removingGroup: removingGroup,
            worktreeOperationError: worktreeOperationError
        ))
    }
}
