// WindowTitleText.swift
// Weir — the supervision window's title, and the branch each checkout is named by.

import Foundation

/// The branch a checkout is known by, wherever Weir names one: the
/// window title, the worktree menu's button, and its rows. One rule, so the
/// three cannot fall back differently.
@MainActor
enum CheckoutName {
    /// The branch checked out in the project's main folder; `nil` for a
    /// folder that is not a repository, or before its first sync.
    nonisolated static func of(_ project: Project) -> String? {
        project.mainBranchName.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Whether the project's folder is a git repository, which can have
    /// worktrees: its main checkout is on a branch, or detached at a commit,
    /// or git listed a worktree of it. The worktree menu is there for one,
    /// detached or not; a folder that is not one has none to offer.
    nonisolated static func isRepository(_ project: Project) -> Bool {
        of(project) != nil
            || project.mainHeadSHA.map { !$0.isEmpty } == true
            || project.worktrees.contains { $0.origin == .gitWorktree }
    }

    /// A worktree's branch, when it is known; `nil` before its first sync,
    /// or with a detached HEAD.
    nonisolated static func branch(of worktree: Worktree) -> String? {
        worktree.gitRef?.branchName.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A worktree's branch, or its label while the branch is not known.
    nonisolated static func of(_ worktree: Worktree) -> String {
        branch(of: worktree) ?? worktree.label
    }

    /// What a project's main checkout is called in the worktree menu: its
    /// branch, or its folder's name when it has none. The window title
    /// leaves the folder's name out instead, since the project's name
    /// already stands there.
    nonisolated static func label(of project: Project) -> String {
        of(project) ?? project.rootURL.lastPathComponent
    }

    /// The branch of the checkout `container` shows, or a worktree's label
    /// while its branch is not known; `nil` outside a project or for a
    /// project with no branch.
    static func of(_ container: ContainerID, in session: WorkspaceSession) -> String? {
        if let branch = knownBranch(of: container, in: session) {
            return branch
        }
        guard case let .worktree(projectID, worktreeID) = container else { return nil }
        return session.worktree(projectID: projectID, worktreeID: worktreeID)?.label
    }

    /// The branch `container` shows when it is known, without the label a
    /// worktree falls back to (`of(_:)`): what tells a name cut in its
    /// middle, as branches are, from one cut at its end.
    static func knownBranch(of container: ContainerID, in session: WorkspaceSession) -> String? {
        switch container {
        case .loose:
            nil
        case let .project(projectID):
            session.project(projectID).flatMap { of($0) }
        case let .worktree(projectID, worktreeID):
            session.worktree(projectID: projectID, worktreeID: worktreeID).flatMap { branch(of: $0) }
        }
    }

    /// Where a tab is, as a place to name: the scratch tabs, or a
    /// workspace by the name its row has.
    enum Place: Equatable, Sendable {
        /// The scratch tabs, outside every project.
        case scratch
        /// A project's folder or one of its worktrees: the checkout's
        /// branch, else a worktree's own label, else the project's main
        /// checkout's label.
        case named(String)
    }

    /// The place `container` is; `nil` for a project the session no longer
    /// has, which has no name to say and is no scratch tab either. A
    /// worktree the session no longer has, or the project's folder with no
    /// branch, falls back to its project's main checkout's label.
    static func place(of container: ContainerID, in session: WorkspaceSession) -> Place? {
        if container == .loose {
            return .scratch
        }
        let name = of(container, in: session) ?? container.projectID.flatMap { session.project($0) }.map(label(of:))
        return name.map(Place.named)
    }
}

/// The supervision window's title.
@MainActor
enum WindowTitleText {
    /// "{project} — {branch}" for a project or one of its worktrees; a
    /// project with no branch shows its name alone. A window on the
    /// scratch tabs shows `shownProjectID`'s name: the scratch row sits in
    /// that project's sidebar, so the window still stands for it.
    /// Only a window that shows nothing is "Weir".
    static func projectAndBranch(
        _ container: ContainerID,
        shownProjectID: UUID? = nil,
        in session: WorkspaceSession
    ) -> String {
        switch container {
        case .loose:
            return shownProjectID.flatMap { session.project($0)?.name } ?? "Weir"
        case let .project(projectID), let .worktree(projectID, _):
            guard let project = session.project(projectID) else { return "Weir" }
            guard let branch = CheckoutName.of(container, in: session) else { return project.name }
            return "\(project.name) — \(branch)"
        }
    }
}
