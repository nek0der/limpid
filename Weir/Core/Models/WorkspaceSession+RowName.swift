// WorkspaceSession+RowName.swift
// Weir — a project row's name, read from the row, its tabs, and its checkout by the one rule.

import Foundation

extension WorkspaceSession {
    /// The name `container`'s row goes by (`RowName`), in the sidebar and
    /// everywhere the row is named: the name the person gave the row, then
    /// a name the person gave one of its tabs, then its branch, then the
    /// row's first conversation, then its folder. `nil` for the
    /// scratch row, which is named by its own word, and for a row the
    /// session no longer has.
    ///
    /// A tab's name still names the row because a row was once renamed by
    /// naming its first tab, and those names stay on the tabs: nothing
    /// moves them, so nothing can lose them. A row the person names again
    /// takes the new name on the row itself, ahead of them; one the person
    /// clears drops the tab's name it showed (`renameRow`).
    func rowName(of container: ContainerID) -> RowName? {
        guard let row = folderAndGivenName(of: container) else { return nil }
        let tabs = tabs(in: container)
        return RowName.make(
            manual: row.given.flatMap { $0.isEmpty ? nil : $0 }
                ?? tabs.lazy.compactMap(\.titleOverride).first { !$0.isEmpty },
            conversation: Tab.firstConversationName(in: tabs),
            branch: CheckoutName.knownBranch(of: container, in: self),
            folder: row.folder
        )
    }

    /// Returns the checkout `container`'s row is shown with beside its
    /// name (`RowName.checkoutBeside`) when the person labeled the row: its
    /// branch, or with no branch known, the worktree's folder less a
    /// leading "<project's folder name>-", or the project's folder. Every
    /// place that offers the row as a choice reads it here, so they all
    /// show the same checkout by the same rule. It is `nil` for any other
    /// row, the scratch row included.
    ///
    /// The project's folder row shows its folder only when the folder is
    /// not the project's name: the header right above it says that name,
    /// and the row's tag says it is the repository.
    /// We compare that folder with the name the header shows; a worktree's
    /// folder is instead shortened by the project's folder name, the start
    /// Weir gave it.
    ///
    /// `name` is the row's name when the caller has already read it
    /// (`rowName(of:)`), so a sidebar row reads its name once.
    func rowCheckout(of container: ContainerID, named name: RowName? = nil) -> RowCheckout? {
        guard let folder = rowFolderName(of: container), let name = name ?? rowName(of: container) else { return nil }
        let branch = CheckoutName.knownBranch(of: container, in: self)
        switch container {
        case .loose:
            return nil
        case let .project(projectID):
            guard let project = project(projectID) else { return nil }
            let isProjectsName = folder.compare(project.name, options: .caseInsensitive) == .orderedSame
            return name.checkoutBeside(branch: branch, folder: isProjectsName ? nil : folder)
        case let .worktree(projectID, _):
            return name.checkoutBeside(branch: branch, folder: folder, repository: project(projectID)?.rootURL.lastPathComponent)
        }
    }

    /// The last path component of `container`'s folder, which all projects'
    /// filter finds a card by whatever the card is named; `nil` for the
    /// scratch row and for a row the session no longer has.
    func rowFolderName(of container: ContainerID) -> String? {
        folderAndGivenName(of: container)?.folder
    }

    /// Returns the last path component of the row's folder and the name the
    /// person gave the row itself. It is `nil` for the scratch row and for a
    /// row the session no longer has.
    private func folderAndGivenName(of container: ContainerID) -> (folder: String, given: String?)? {
        switch container {
        case .loose:
            nil
        case let .project(projectID):
            project(projectID).map { ($0.rootURL.lastPathComponent, $0.rootDisplayName) }
        case let .worktree(projectID, worktreeID):
            worktree(projectID: projectID, worktreeID: worktreeID).map { ($0.workingDirectory.lastPathComponent, $0.displayName) }
        }
    }

    /// Names `container`'s row as the person typed it, on the row itself
    /// (the worktree, or the project for its own folder), so a row with no
    /// tab can be named and closing a tab keeps the name. A name leaves the
    /// tabs' own names as they are: one may be the name the pane strip
    /// shows, and the row's name now goes ahead of it.
    ///
    /// An empty name clears the name the row showed, and the row goes back
    /// to the name it would have. That is the row's own name when it has
    /// one. When it has none, the row showed a tab's name (an earlier build
    /// kept a row's name there), and that name is the one the person
    /// cleared: left on the tab, it would name the row again at once. The
    /// scratch row has no name to give.
    func renameRow(_ container: ContainerID, to name: String, runtimes: [AgentRuntimePresentation]) {
        let given: String? = name.isEmpty ? nil : name
        switch container {
        case .loose:
            return
        case let .project(projectID):
            guard let pi = projects.firstIndex(where: { $0.id == projectID }) else { return }
            if given == nil, projects[pi].rootDisplayName.map({ !$0.isEmpty }) != true {
                clearTabNameNamingRow(container, runtimes: runtimes)
            }
            projects[pi].rootDisplayName = given
        case let .worktree(projectID, worktreeID):
            guard let pi = projects.firstIndex(where: { $0.id == projectID }),
                  let wi = projects[pi].worktrees.firstIndex(where: { $0.id == worktreeID })
            else { return }
            if given == nil, projects[pi].worktrees[wi].displayName.map({ !$0.isEmpty }) != true {
                clearTabNameNamingRow(container, runtimes: runtimes)
            }
            projects[pi].worktrees[wi].displayName = given
        }
    }

    /// Clears the tab name `rowName(of:)` names the row by when the row has
    /// no name of its own: the first one given, as that reads it. As the
    /// person clearing the tab's own name would (`renameTab`), so the
    /// conversation the tab stands for lets go of the name too.
    private func clearTabNameNamingRow(_ container: ContainerID, runtimes: [AgentRuntimePresentation]) {
        guard let tab = tabs(in: container).first(where: { $0.titleOverride.map { !$0.isEmpty } == true }) else { return }
        renameTab(tab.id, to: "", runtimes: runtimes)
    }
}
