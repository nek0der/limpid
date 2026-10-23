// SidebarPresentedSections.swift
// Limpid — which section each of a project's rows is listed in, and in what order.

import Foundation

/// The section each row is listed in, every project's rows, as the
/// window's sidebar shows them: what it draws, and, of the window's
/// project, what ⌃⌘1…9 and ⌘[ ⌘] count. A row the value does
/// not name (a row just made, or one of another project) is a working one.
struct SidebarPresentedSections: Equatable {
    var sections: [ContainerID: SidebarSection] = [:]

    func section(of row: ContainerID) -> SidebarSection {
        sections[row] ?? .working
    }

    /// `project`'s rows the sidebar lists, in the order it lists them: the
    /// working worktrees in the project's order, then the folder, which
    /// closes the working rows rather than repeat the project's name under
    /// its heading; then the rows ready to clean up, then the others.
    func ordered(_ project: Project) -> [(row: ContainerID, section: SidebarSection)] {
        let rows = SessionSidebarModel.containers(of: project)
        let worktrees = rows.filter { $0.worktreeID != nil }
        let folder = rows.filter { $0.worktreeID == nil }
        let working = (worktrees + folder).filter { section(of: $0) == .working }
        let rest = [SidebarSection.cleanable, .other].flatMap { kind in
            worktrees.filter { section(of: $0) == kind }.map { ($0, kind) }
        }
        return working.map { ($0, SidebarSection.working) } + rest
    }

    /// Each row of `project` placed by what it holds now (`SidebarSectionRule`).
    /// The window's selected row counts as working. `pullRequest` and
    /// `gitFacts` are the stores' lookups; `queue` is the attention list,
    /// read once into a lookup rather than once per row.
    @MainActor
    static func computed( // swiftlint:disable:this function_parameter_count
        project: Project,
        session: WorkspaceSession,
        window: WindowID,
        queue: AttentionQueue,
        pullRequest: (ContainerID) -> PRInfo?,
        gitFacts: (ContainerID) -> GitFacts?
    ) -> Self {
        computed(
            project: project,
            session: session,
            window: window,
            index: SidebarRowIndex(session: session, queue: queue),
            pullRequest: pullRequest,
            gitFacts: gitFacts
        )
    }

    /// As above, from an index of the rows built once for every project
    /// placed (`computed(projectsOf:…)`).
    @MainActor
    static func computed( // swiftlint:disable:this function_parameter_count
        project: Project,
        session: WorkspaceSession,
        window: WindowID,
        index: SidebarRowIndex,
        pullRequest: (ContainerID) -> PRInfo?,
        gitFacts: (ContainerID) -> GitFacts?
    ) -> Self {
        let selected = session.selection(window).flatMap { $0.isChoosingProject ? nil : $0.activeContainerID }
        var sections: [ContainerID: SidebarSection] = [:]
        for row in SessionSidebarModel.containers(of: project) {
            let worktree = row.worktreeID.flatMap { id in project.worktrees.first { $0.id == id } }
            let tabs = index.tabs(in: row)
            sections[row] = SidebarSectionRule.section(SidebarSectionRule.Facts(
                isMainFolder: row.worktreeID == nil,
                admission: worktree?.admission,
                hasTabs: !tabs.isEmpty,
                // By the pane an item is in, or, for a session that stopped
                // before a pane opened, by the row's folder.
                hasItems: index.hasItems(
                    inPanes: tabs.lazy.flatMap { $0.splitTree.allLeafIDs() },
                    root: session.rootDirectory(of: row)
                ),
                isSelected: row == selected,
                prState: pullRequest(row)?.state,
                uncommittedFiles: gitFacts(row)?.uncommittedFiles ?? 0,
                isMissing: worktree?.isMissing ?? false
            ))
        }
        return Self(sections: sections)
    }
}

extension ProjectWindowState {
    /// Returns the sections this window's sidebar shows every project's rows in:
    /// where each belongs now (`SidebarPresentedSections.computed(projectsOf:…)`),
    /// unless the pointer, the keyboard, or a drag holds them where they
    /// are. The sidebar draws this and ⌃⌘1…9 and ⌘[ ⌘] count from it, so
    /// both build it here and cannot drift apart. `others` is which other
    /// window shows each project (`WorkspaceSession.otherWindowsByProject(than:)`);
    /// it is passed in because the sidebar reads it once for its rows too.
    func presentedSections( // swiftlint:disable:this function_parameter_count
        session: WorkspaceSession,
        others: [UUID: WindowID],
        queue: AttentionQueue,
        pullRequest: (ContainerID) -> PRInfo?,
        gitFacts: (ContainerID) -> GitFacts?,
        isDragging: Bool
    ) -> SidebarPresentedSections {
        presentedSections(
            computed: .computed(
                projectsOf: session,
                window: id,
                windowShowing: { others[$0] },
                queue: queue,
                pullRequest: pullRequest,
                gitFacts: gitFacts
            ),
            isDragging: isDragging
        )
    }
}
