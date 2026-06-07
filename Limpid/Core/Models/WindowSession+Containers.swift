// WindowSession+Containers.swift
// Limpid — Group + Project CRUD, palette / expanded toggles, single-step
// reorder helpers, top-level cross-container reorder, and the container column
// navigation list (top-level + flat-with-worktrees). Pulled out of
// `WindowSession.swift` so the main file can stay focused on stored
// state + active-tab semantics.

import Foundation

extension WindowSession {

    // MARK: - Project operations

    /// Add or activate a Project rooted at the given URL. Existing
    /// Projects with the same path are activated instead of duplicated.
    @discardableResult
    func addOrActivateProject(rootURL: URL, suggestedName: String? = nil) -> Project {
        let normalized = rootURL.standardizedFileURL
        promoteRecent(normalized)
        if let existing = projects.first(where: { $0.rootURL.standardizedFileURL == normalized }) {
            activateProject(existing.id)
            return existing
        }
        let project = Project(
            name: suggestedName ?? normalized.lastPathComponent,
            rootURL: normalized,
            paletteIndex: projects.count % 8
        )
        projects.append(project)
        return project
    }

    private func promoteRecent(_ url: URL) {
        recentProjectPaths.removeAll { $0.standardizedFileURL == url }
        recentProjectPaths.insert(url, at: 0)
        if recentProjectPaths.count > Self.recentProjectPathsLimit {
            recentProjectPaths = Array(recentProjectPaths.prefix(Self.recentProjectPathsLimit))
        }
    }

    // MARK: - Group operations

    @discardableResult
    func addGroup(name: String = "New Group") -> TabGroup {
        let group = TabGroup(name: name, paletteIndex: groups.count % 8)
        groups.append(group)
        return group
    }

    // MARK: - Rename helpers

    //
    // Centralized so views don't have to walk the arrays themselves.
    // No-op when the id can't be resolved. Worktree rename lives in
    // `+Worktree` because it bridges into `git worktree move`.

    func renameGroup(_ id: UUID, to name: String) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].name = name
    }

    func renameProject(_ id: UUID, to name: String) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].name = name
    }

    // MARK: - Palette helpers

    func setGroupPaletteIndex(_ id: UUID, to index: Int?) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].paletteIndex = index
    }

    func setProjectPaletteIndex(_ id: UUID, to index: Int?) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].paletteIndex = index
    }

    // MARK: - Group working-directory helpers

    /// Update a group's default working-directory strategy. When the
    /// mode isn't `.fixed` we clear the companion path so a stale fixed
    /// directory can't linger and resurface if the user toggles back.
    func setGroupCwdMode(_ id: UUID, to mode: WorkingDirectoryMode, path: URL? = nil) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].cwdMode = mode
        groups[i].cwdPath = mode == .fixed ? path : nil
    }

    /// Toggle a project header's expanded / collapsed state. Keeps the
    /// mutation out of views so they don't have to index into
    /// `session.projects` directly.
    func toggleProjectExpanded(_ id: UUID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].isExpanded.toggle()
    }

    // MARK: - Single-step reorder helpers (context menu Move Up / Down)

    /// Move the group up one slot if it isn't already first. The
    /// context-menu shortcut is "Move Up" — encapsulating the
    /// boundary check + neighbour-id lookup inside the model means
    /// the view doesn't have to compute indices and call
    /// `reorderGroup(source:target:position:)` itself.
    func moveGroupUp(_ id: UUID) {
        guard let i = groups.firstIndex(where: { $0.id == id }), i > 0 else { return }
        reorderGroup(sourceID: id, target: groups[i - 1].id, position: .before)
    }

    func moveGroupDown(_ id: UUID) {
        guard let i = groups.firstIndex(where: { $0.id == id }), i < groups.count - 1 else { return }
        reorderGroup(sourceID: id, target: groups[i + 1].id, position: .after)
    }

    func moveProjectUp(_ id: UUID) {
        guard let i = projects.firstIndex(where: { $0.id == id }), i > 0 else { return }
        reorderProject(sourceID: id, target: projects[i - 1].id, position: .before)
    }

    func moveProjectDown(_ id: UUID) {
        guard let i = projects.firstIndex(where: { $0.id == id }), i < projects.count - 1 else { return }
        reorderProject(sourceID: id, target: projects[i + 1].id, position: .after)
    }

    func canMoveGroupUp(_ id: UUID) -> Bool {
        groups.firstIndex(where: { $0.id == id }).map { $0 > 0 } ?? false
    }

    func canMoveGroupDown(_ id: UUID) -> Bool {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return false }
        return i < groups.count - 1
    }

    func canMoveProjectUp(_ id: UUID) -> Bool {
        projects.firstIndex(where: { $0.id == id }).map { $0 > 0 } ?? false
    }

    func canMoveProjectDown(_ id: UUID) -> Bool {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return false }
        return i < projects.count - 1
    }

    // MARK: - Top-level container reorder

    /// Move group identified by `sourceID` next to `targetID` per the
    /// drop position. No-op when either id is missing.
    func reorderGroup(sourceID: UUID, target targetID: UUID, position: DropPosition) {
        WindowSession.reorderInPlace(in: &groups, sourceID: sourceID, target: targetID, position: position)
    }

    func reorderProject(sourceID: UUID, target targetID: UUID, position: DropPosition) {
        WindowSession.reorderInPlace(in: &projects, sourceID: sourceID, target: targetID, position: position)
    }

    // MARK: - Container deletion

    /// Delete a Group and **all tabs inside it**. Returns the pane IDs
    /// that lived inside those tabs so the caller can free the
    /// SurfaceViews from the registry.
    @discardableResult
    func removeGroup(_ groupID: UUID) -> [UUID] {
        let leafIDs = tabs
            .filter {
                if case let .group(gid) = $0.container { return gid == groupID }
                return false
            }
            .flatMap { $0.splitTree.allLeafIDs() }
        tabs.removeAll {
            if case let .group(gid) = $0.container { return gid == groupID }
            return false
        }
        groups.removeAll { $0.id == groupID }
        if case let .group(gid) = activeContainerID, gid == groupID {
            setActiveContainer(.loose)
        }
        for leafID in leafIDs {
            paneSearchStates.removeValue(forKey: leafID)
        }
        return leafIDs
    }

    /// Delete a Project (and all its worktrees + tabs inside).
    /// Returns the pane IDs for registry cleanup.
    @discardableResult
    func removeProject(_ projectID: UUID) -> [UUID] {
        let leafIDs = tabs
            .filter { $0.container.projectID == projectID }
            .flatMap { $0.splitTree.allLeafIDs() }
        tabs.removeAll { $0.container.projectID == projectID }
        projects.removeAll { $0.id == projectID }
        if let pid = activeContainerID.projectID, pid == projectID {
            setActiveContainer(.loose)
        }
        for leafID in leafIDs {
            paneSearchStates.removeValue(forKey: leafID)
        }
        return leafIDs
    }

    // MARK: - container navigation

    //
    // `topLevelContainers` is the ordered list for ⌘⌃1…9 (direct jump);
    // worktrees aren't included there because direct jumps are scoped to
    // top-level rows. `flatNavigableContainers` includes worktrees and
    // drives ⌘[ / ⌘] so the user can walk into a project's children.

    var topLevelContainers: [ContainerID] {
        var list: [ContainerID] = [.loose]
        list.append(contentsOf: groups.map { .group($0.id) })
        list.append(contentsOf: projects.map { .project($0.id) })
        return list
    }

    /// Flat traversal order for ⌘[ / ⌘]. Hidden worktrees are skipped;
    /// missing ones are included so the user can still reach them to
    /// recover or remove.
    var flatNavigableContainers: [ContainerID] {
        var list: [ContainerID] = [.loose]
        for group in groups {
            list.append(.group(group.id))
        }
        for project in projects {
            list.append(.project(project.id))
            for worktree in project.worktrees where !worktree.isHidden {
                list.append(.worktree(projectID: project.id, worktreeID: worktree.id))
            }
        }
        return list
    }

    /// Move to the previous / next navigable container, wrapping.
    /// Walks projects' worktree children as well as top-level rows.
    func cycleTopLevelContainer(forward: Bool) {
        let list = flatNavigableContainers
        guard !list.isEmpty else { return }
        let current = list.firstIndex(of: activeContainerID) ?? 0
        let next = forward
            ? (current + 1) % list.count
            : (current - 1 + list.count) % list.count
        setActiveContainer(list[next])
    }

    func activateTopLevelContainer(at index: Int) {
        let list = topLevelContainers
        guard index >= 0, index < list.count else { return }
        setActiveContainer(list[index])
    }

    // MARK: - Order snapshot / restore (live reorder support)

    //
    // Live reorder mutates the model the moment the cursor crosses a
    // neighbour, but the user can still cancel the drag by releasing
    // outside the sidebar. We snapshot the order arrays at drag-start
    // and restore them on cancel so the visual "snap back" matches
    // Finder / Notes semantics. Only orderings are captured — palette
    // edits, expansion toggles, etc. don't run during a drag, so we
    // don't need to roundtrip the whole model.

    /// Frozen snapshot of every order list a sidebar drag can touch.
    /// Restoring it returns the container column (groups / projects), tab column (tabs), and
    /// per-project worktree lists to their pre-drag ordering.
    struct OrderSnapshot: Equatable {
        let groupIDs: [UUID]
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
            groupIDs: groups.map(\.id),
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
        groups = Self.reordered(groups, by: snapshot.groupIDs)
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
            if l != r { return l < r }
            return lhs.0 < rhs.0
        }
        return sorted.map(\.1)
    }
}
