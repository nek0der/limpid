// WorkspaceSession+Containers.swift
// Weir — project CRUD, a project's palette color, and the order snapshot a drag restores.

import Foundation

extension WorkspaceSession {

    // MARK: - Project operations

    /// Open a folder as a Project and put the user in it, in `window`: the
    /// shared dispatch of the palette's recent projects. The window's own
    /// ways to open a folder add it with `addProject(at:)` and open its
    /// window.
    ///
    /// A linked worktree path is promoted to its main checkout first;
    /// otherwise the Project would list itself inside its own
    /// `git worktree list`. A Project with no tab gets one,
    /// because `addOrActivateProject` appends a new Project without
    /// activating it and there would be nothing to switch to.
    ///
    /// `resolveMainCheckout` is injectable so tests can pin the
    /// resolution without spawning `git`; production uses the default.
    ///
    /// `intent` is the ask's. The person's lands as theirs only while
    /// `window` still shows the row it showed when they asked: the folder
    /// is resolved first, and one who moved on meanwhile is left where they
    /// went, the project opening behind them (`intentAfterWait`).
    @discardableResult
    func openProject(
        at url: URL,
        in window: WindowID,
        intent: SelectionIntent,
        resolveMainCheckout: (URL) async -> URL = GitProcess.resolveMainCheckout(of:)
    ) async -> Project {
        let asked = waitOrigin(in: window)
        let rootURL = await resolveMainCheckout(url)
        let intent = intent == .person ? intentAfterWait(from: asked) : intent
        let project = addOrActivateProject(rootURL: rootURL, in: window, intent: intent)
        if !tabs.contains(where: { $0.projectID == project.id }) {
            openTab(container: .project(project.id), in: window, intent: intent, selects: true)
        }
        return project
    }

    /// Adds the folder as a Project, or finds the one it is, and moves no
    /// window: the supervision window shows it once the folder is resolved,
    /// in the window it was asked from unless the person has moved on
    /// meanwhile. The same resolution as `openProject(at:in:intent:)`.
    @discardableResult
    func addProject(
        at url: URL,
        resolveMainCheckout: (URL) async -> URL = GitProcess.resolveMainCheckout(of:)
    ) async -> Project {
        let rootURL = await resolveMainCheckout(url)
        return findOrAddProject(rootURL: rootURL).project
    }

    /// Add or activate a Project rooted at the given URL. Existing
    /// Projects with the same path are activated instead of duplicated.
    /// This is the bare model operation: it resolves no linked worktree
    /// and opens no tab for a new Project. User gestures go through
    /// `openProject(at:)` instead.
    @discardableResult
    func addOrActivateProject(
        rootURL: URL,
        suggestedName: String? = nil,
        in window: WindowID,
        intent: SelectionIntent
    ) -> Project {
        let (project, isExisting) = findOrAddProject(rootURL: rootURL, suggestedName: suggestedName)
        if isExisting {
            activateProject(project.id, in: window, intent: intent)
        }
        return project
    }

    /// The Project rooted at `rootURL`, appended when there is none, with
    /// the folder put first among the recent ones either way.
    private func findOrAddProject(rootURL: URL, suggestedName: String? = nil) -> (project: Project, isExisting: Bool) {
        let normalized = rootURL.standardizedFileURL
        promoteRecent(normalized)
        if let existing = projects.first(where: { $0.rootURL.standardizedFileURL == normalized }) {
            return (existing, true)
        }
        let project = Project(
            name: suggestedName ?? normalized.lastPathComponent,
            rootURL: normalized,
            paletteIndex: projects.count % 8
        )
        projects.append(project)
        return (project, false)
    }

    /// Puts `projectID`'s folder first among the recent ones: the person
    /// switched a window to it, or brought forward the window that shows
    /// it. Written only when it moves, so a project chosen
    /// again does not save the session for nothing.
    func noteProjectUsed(_ projectID: UUID) {
        guard let url = project(projectID)?.rootURL.standardizedFileURL,
              recentProjectPaths.first?.standardizedFileURL != url
        else { return }
        promoteRecent(url)
    }

    /// Puts `url` first, and keeps the list to its cap
    /// (`recentProjectPathsLimit`). Past the cap, the oldest folder of a
    /// project still open goes before any other: an open project is
    /// reached from the project lists, while a removed one is reopened
    /// only from here (the palette and the "+" menu offer only folders no
    /// project stands for). Switching windows between open projects
    /// promotes them over and over (`noteProjectUsed`), and would
    /// otherwise push a removed project's folder off the end. With no open
    /// project's folder left to drop, the oldest goes. `url` itself, just
    /// used, always stays.
    private func promoteRecent(_ url: URL) {
        var paths = recentProjectPaths.filter { $0.standardizedFileURL != url }
        paths.insert(url, at: 0)
        let open = Set(projects.map(\.rootURL.standardizedFileURL))
        while paths.count > Self.recentProjectPathsLimit {
            let oldestOpen = paths.indices.dropFirst().last { open.contains(paths[$0].standardizedFileURL) }
            paths.remove(at: oldestOpen ?? paths.count - 1)
        }
        recentProjectPaths = paths
    }

    // MARK: - Rename and palette helpers

    //
    // Centralized so views don't have to walk the arrays themselves.
    // No-op when the id can't be resolved. Worktree rename lives in
    // `+Worktree` because it bridges into `git worktree move`.

    func renameProject(_ id: UUID, to name: String) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].name = name
    }

    func setProjectPaletteIndex(_ id: UUID, to index: Int?) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].paletteIndex = index
    }

    // MARK: - Project removal

    /// Delete a Project (and all its worktrees + tabs inside).
    /// Returns the pane IDs for registry cleanup.
    ///
    /// Each window that showed the project, on a scratch tab or hidden
    /// alike, switches to another at once: the project no other
    /// window shows that was used most recently, put back as a window
    /// last left it. Nothing of the removed project is kept, neither its
    /// view nor, in the app layer, its review (`ProjectSwitchReason`). With
    /// no project left to take, the window goes to the scratch tabs. Only
    /// the windows that showed the project move, and none comes forward.
    @discardableResult
    func removeProject(_ projectID: UUID) -> [UUID] {
        let leafIDs = tabs
            .filter { $0.container.projectID == projectID }
            .flatMap { $0.splitTree.allLeafIDs() }
        tabs.removeAll { $0.container.projectID == projectID }
        projects.removeAll { $0.id == projectID }
        // Its view goes with it; no other view holds anything of it.
        projectViews.removeValue(forKey: projectID)
        // Nor does any window's sidebar list it any longer.
        for selection in selections.values where selection.sidebarArrangement.knows(projectID) {
            selection.sidebarArrangement = selection.sidebarArrangement.removing(projectID)
        }
        for window in orderedWindows(where: { $0.shownProjectID == projectID }) {
            showProject(projectAfterRemoval(in: window), in: window, intent: .repair, reason: .projectRemoved)
        }
        for leafID in leafIDs {
            paneSearchStates.removeValue(forKey: leafID)
            paneTransients.removeValue(forKey: leafID)
        }
        return leafIDs
    }

    /// The project `window` goes to once the project it showed is removed:
    /// the first of the projects no other window shows
    /// (`projectsNoWindowShows(besides:)`). `nil` when every project left
    /// is shown elsewhere.
    private func projectAfterRemoval(in window: WindowID) -> UUID? {
        projectsNoWindowShows(besides: window).first?.id
    }

    /// The projects no window shows, hidden ones included, `besides` left
    /// out: those used most recently first (`recentProjectPaths`),
    /// then the others in the projects' order, which the recent list,
    /// capped, may have let go. The one order for the projects a window can
    /// take: where a window whose project was removed goes, and what a
    /// window that shows nothing offers (`EmptyWindowModel`).
    func projectsNoWindowShows(besides window: WindowID?) -> [Project] {
        let shown = Set(selections.values.filter { $0.windowID != window }.compactMap(\.shownProjectID))
        let free = projects.filter { !shown.contains($0.id) }
        let recent = recentProjectPaths.map(\.standardizedFileURL)
        let rank = { (project: Project) in recent.firstIndex(of: project.rootURL.standardizedFileURL) ?? recent.count }
        return free.indices
            .sorted { lhs, rhs in
                let (left, right) = (rank(free[lhs]), rank(free[rhs]))
                return left != right ? left < right : lhs < rhs
            }
            .map { free[$0] }
    }

    // MARK: - Order snapshot / restore (live reorder support)

    //
    // Live reorder mutates the model the moment the cursor crosses a
    // neighbor, but the user can still cancel the drag by releasing
    // outside the sidebar. We snapshot the order arrays at drag-start
    // and restore them on cancel so the visual "snap back" matches
    // Finder / Notes semantics. Only orderings are captured — palette
    // edits, expansion toggles, etc. don't run during a drag, so we
    // don't need to roundtrip the whole model.

    /// Frozen snapshot of every order list a sidebar drag can touch.
    /// Restoring it returns the projects, the tabs, and each project's
    /// worktrees to their pre-drag ordering.
    struct OrderSnapshot: Equatable {
        let projectIDs: [UUID]
        let tabIDs: [UUID]
        let worktreeIDsByProject: [UUID: [UUID]]
    }

    func captureOrderSnapshot() -> OrderSnapshot {
        var wt: [UUID: [UUID]] = [:]
        for project in projects {
            wt[project.id] = project.worktrees.map(\.id)
        }
        return OrderSnapshot(
            projectIDs: projects.map(\.id),
            tabIDs: tabs.map(\.id),
            worktreeIDsByProject: wt
        )
    }

    /// Restore the order arrays to the given snapshot. Stable-sorts
    /// each backing array by the snapshot's index lookup; any rows
    /// added since the snapshot (shouldn't happen mid-drag, but be
    /// defensive) sink to the end in their current relative order.
    func restoreOrder(_ snapshot: OrderSnapshot) {
        projects = Self.reordered(projects, by: snapshot.projectIDs)
        tabs = Self.reordered(tabs, by: snapshot.tabIDs)
        for i in projects.indices {
            if let order = snapshot.worktreeIDsByProject[projects[i].id] {
                projects[i].worktrees = Self.reordered(projects[i].worktrees, by: order)
            }
        }
    }

    private static func reordered<T: Identifiable>(_ array: [T], by order: [UUID]) -> [T]
        where T.ID == UUID
    {
        let rank: [UUID: Int] = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        // Stable sort: unseen rows keep their relative order at the tail.
        let indexed = array.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { lhs, rhs in
            let l = rank[lhs.1.id] ?? Int.max
            let r = rank[rhs.1.id] ?? Int.max
            if l != r {
                return l < r
            }
            return lhs.0 < rhs.0
        }
        return sorted.map(\.1)
    }
}
