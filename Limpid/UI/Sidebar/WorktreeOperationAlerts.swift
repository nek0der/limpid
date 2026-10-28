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
    @Environment(\.locale) private var locale

    @Binding var deletingWorktree: DeleteWorktreeTarget?
    @Binding var deletingWorktrees: DeleteWorktreesTarget?
    /// The worktrees of a Delete Worktrees that Git would remove only with
    /// Force, while the Force confirmation for them shows.
    @State private var forceDeletingWorktrees: DeleteWorktreesTarget?
    /// The names of the worktrees a Delete Worktrees left in place for a
    /// reason Force does not answer, while the error naming them shows.
    @State private var undeletedWorktrees: [String]?
    /// Those names while the Force confirmation shows: one alert at a
    /// time, so the error waits until the Force confirmation is answered.
    @State private var undeletedBehindForce: [String] = []
    @Binding var forceDeleteWorktree: ForceDeleteWorktreeTarget?
    @Binding var removingProject: RemoveProjectTarget?
    @Binding var worktreeOperationError: DisplayText?

    func body(content: Content) -> some View {
        deleteAllAlerts(content)
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

extension WorktreeOperationAlerts {
    /// Delete Worktrees' own alerts: its confirmation, its Force
    /// confirmation, and its error.
    private func deleteAllAlerts(_ content: Content) -> some View {
        content
            .alert(
                Text("Delete \(deletingWorktrees?.worktrees.count ?? 0) worktrees?"),
                isPresented: Binding(
                    get: { deletingWorktrees != nil },
                    set: {
                        if !$0 {
                            deletingWorktrees = nil
                        }
                    }
                ),
                presenting: deletingWorktrees
            ) { target in
                Button("Delete", role: .destructive) {
                    Task { await performDeleteAll(target, force: false) }
                }
                Button("Cancel", role: .cancel) { deletingWorktrees = nil }
            } message: { _ in
                Text("Runs `git worktree remove` on all of them. Their folders are removed from disk; their branches stay.")
            }
            .alert(
                Text("Force delete \(forceDeletingWorktrees?.worktrees.count ?? 0) worktrees?"),
                isPresented: Binding(
                    get: { forceDeletingWorktrees != nil },
                    set: {
                        if !$0 {
                            forceDeletingWorktrees = nil
                        }
                    }
                ),
                presenting: forceDeletingWorktrees
            ) { target in
                Button("Force Delete", role: .destructive) {
                    Task { await performDeleteAll(target, force: true) }
                }
                Button("Cancel", role: .cancel) {
                    forceDeletingWorktrees = nil
                    showUndeleted([])
                }
            } message: { target in
                // The names one to a line, as the single worktree's
                // confirmation sets its path apart from the sentence.
                Text(
                    """
                    These worktrees have uncommitted changes or initialized submodules, which will be lost.

                    \(WorktreeOperationText.lines(target.worktrees.map(\.label), locale: locale))
                    """
                )
            }
            .alert(
                Text("Couldn’t Delete \(undeletedWorktrees?.count ?? 0) Worktrees"),
                isPresented: Binding(
                    get: { undeletedWorktrees != nil },
                    set: {
                        if !$0 {
                            undeletedWorktrees = nil
                        }
                    }
                ),
                presenting: undeletedWorktrees
            ) { _ in
                Button("OK", role: .cancel) { undeletedWorktrees = nil }
            } message: { names in
                // Laid out as the Force confirmation is: the sentence, then
                // the names one to a line.
                Text(
                    """
                    Git didn’t delete these worktrees. Delete each from its row to see why.

                    \(WorktreeOperationText.lines(names, locale: locale))
                    """
                )
            }
    }

    /// Delete Worktrees, in two stages as one row's Delete Worktree is:
    /// each removed cleanly first (`ContainerActions.deleteGitWorktrees`);
    /// those Git would remove only with Force go to one Force confirmation
    /// that names them, and those it refused for another reason keep their
    /// rows and are named in an error of their own, which counts them.
    private func performDeleteAll(_ target: DeleteWorktreesTarget, force: Bool) async {
        // A setup still running would keep writing into a folder.
        for entry in target.worktrees {
            await launches.cancelSetup(worktreeID: entry.worktreeID)
        }
        let refused = await ContainerActions.deleteGitWorktrees(
            session,
            registry: registry,
            projectID: target.projectID,
            worktreeIDs: target.worktrees.map(\.worktreeID),
            force: force
        )
        let needsForce = refused.filter { refusal in
            switch refusal.error as? DeleteWorktreeError {
            case .dirtyNeedsForce?, .submodulesNeedForce?: !force
            default: false
            }
        }
        let failed = refused.filter { refusal in !needsForce.contains { $0.worktreeID == refusal.worktreeID } }
        let entries = { (refusals: [(worktreeID: UUID, error: any Error)]) in
            refusals.compactMap { refusal in target.worktrees.first { $0.worktreeID == refusal.worktreeID } }
        }
        let failedNames = entries(failed).map(\.label)
        if needsForce.isEmpty {
            showUndeleted(failedNames)
        } else {
            undeletedBehindForce += failedNames
            forceDeletingWorktrees = DeleteWorktreesTarget(projectID: target.projectID, worktrees: entries(needsForce))
        }
    }

    /// Shows the error for `names` with those kept behind the Force
    /// confirmation, if any.
    private func showUndeleted(_ names: [String]) {
        let all = undeletedBehindForce + names
        undeletedBehindForce = []
        undeletedWorktrees = all.isEmpty ? nil : all
    }
}

/// The worktree names a Delete Worktrees confirmation or error lists.
enum WorktreeOperationText {
    /// The worktrees' names in the language's quotes, one to a line.
    static func lines(_ names: [String], locale: Locale) -> String {
        names.map { quoted($0, locale: locale) }.joined(separator: "\n")
    }

    private static func quoted(_ name: String, locale: Locale) -> String {
        locale.language.languageCode == .japanese ? "\u{300C}\(name)\u{300D}" : "\u{201C}\(name)\u{201D}"
    }
}

extension View {
    func worktreeOperationAlerts(
        deletingWorktree: Binding<DeleteWorktreeTarget?>,
        deletingWorktrees: Binding<DeleteWorktreesTarget?> = .constant(nil),
        forceDeleteWorktree: Binding<ForceDeleteWorktreeTarget?>,
        removingProject: Binding<RemoveProjectTarget?>,
        worktreeOperationError: Binding<DisplayText?>
    ) -> some View {
        modifier(WorktreeOperationAlerts(
            deletingWorktree: deletingWorktree,
            deletingWorktrees: deletingWorktrees,
            forceDeleteWorktree: forceDeleteWorktree,
            removingProject: removingProject,
            worktreeOperationError: worktreeOperationError
        ))
    }
}
