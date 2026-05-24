// WorktreeOperationAlerts.swift
// Limpid — all five worktree- / container-removal confirmation
// alerts, bundled as one `ViewModifier` so `ContainerSlabView`'s
// body doesn't carry 80+ lines of `.alert` chains. Each alert is
// gated by its own optional state in the parent: when the binding
// is non-nil, the corresponding alert presents.
//
// Why these five live together: they all fire from the L1 slab,
// all need `session` + `registry`, and they're conceptually one
// "destructive operations" surface. Splitting per-alert would
// scatter the wiring; keeping them inline in `ContainerSlabView`
// drowned the view body.

import SwiftUI

struct WorktreeOperationAlerts: ViewModifier {
    @Environment(WindowSession.self) private var session
    @Environment(\.surfaceRegistry) private var registry

    @Binding var deletingWorktree: ContainerSlabView.DeleteWorktreeTarget?
    @Binding var forceDeleteWorktree: ContainerSlabView.DeleteWorktreeTarget?
    @Binding var removingProject: ContainerSlabView.RemoveProjectTarget?
    @Binding var removingGroup: ContainerSlabView.RemoveGroupTarget?
    @Binding var worktreeOperationError: String?

    func body(content: Content) -> some View {
        content
            .alert(
                "Delete worktree?",
                isPresented: Binding(
                    get: { deletingWorktree != nil },
                    set: { if !$0 { deletingWorktree = nil } }
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
                    set: { if !$0 { forceDeleteWorktree = nil } }
                ),
                presenting: forceDeleteWorktree
            ) { target in
                Button("Force Delete", role: .destructive) {
                    Task { await performDelete(target, force: true) }
                }
                Button("Cancel", role: .cancel) { forceDeleteWorktree = nil }
            } message: { _ in
                Text("Worktree has uncommitted changes. Force delete anyway? Uncommitted work will be lost.")
            }
            .alert(
                "Close project?",
                isPresented: Binding(
                    get: { removingProject != nil },
                    set: { if !$0 { removingProject = nil } }
                ),
                presenting: removingProject
            ) { target in
                Button("Close Project", role: .destructive) {
                    withAnimation(LimpidMotion.reorder) {
                        SessionActions.removeProject(session, registry: registry, projectID: target.projectID)
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
                    set: { if !$0 { removingGroup = nil } }
                ),
                presenting: removingGroup
            ) { target in
                Button("Close Group", role: .destructive) {
                    withAnimation(LimpidMotion.reorder) {
                        SessionActions.removeGroup(session, registry: registry, groupID: target.groupID)
                    }
                    removingGroup = nil
                }
                Button("Cancel", role: .cancel) { removingGroup = nil }
            } message: { _ in
                Text("All sessions in this group will be closed.")
            }
            .alert(
                "Delete failed",
                isPresented: Binding(
                    get: { worktreeOperationError != nil },
                    set: { if !$0 { worktreeOperationError = nil } }
                ),
                presenting: worktreeOperationError
            ) { _ in
                Button("OK", role: .cancel) { worktreeOperationError = nil }
            } message: { msg in
                Text(msg)
            }
    }

    /// Two-stage delete: try clean first; on `dirtyNeedsForce` flip to
    /// the force-confirm alert so the user can decide whether to lose
    /// uncommitted work. Other errors bubble into the shared error
    /// surface.
    private func performDelete(
        _ target: ContainerSlabView.DeleteWorktreeTarget,
        force: Bool
    ) async {
        do {
            try await SessionActions.deleteGitWorktree(
                session,
                registry: registry,
                projectID: target.projectID,
                worktreeID: target.worktreeID,
                force: force
            )
        } catch DeleteWorktreeError.dirtyNeedsForce {
            forceDeleteWorktree = target
        } catch {
            worktreeOperationError = error.localizedDescription
        }
    }
}

extension View {
    func worktreeOperationAlerts(
        deletingWorktree: Binding<ContainerSlabView.DeleteWorktreeTarget?>,
        forceDeleteWorktree: Binding<ContainerSlabView.DeleteWorktreeTarget?>,
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
