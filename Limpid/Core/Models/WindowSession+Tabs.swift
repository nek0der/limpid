// WindowSession+Tabs.swift
// Limpid — Tab CRUD, derived per-container views, and drag-drop reorder /
// cross-container move. The active-tab pointer (`activeTabID`,
// `setActiveTab`, `setActiveContainer`) stays in `WindowSession.swift`
// because it touches the L1 selection invariant; everything that lives
// _inside_ the flat `tabs` array belongs here.

import Foundation

extension WindowSession {

    // MARK: - Tab CRUD

    /// Open a tab in a specific container.
    @discardableResult
    func openTab(container: ContainerID, title: String? = nil, workingDirectory: URL? = nil) -> Tab {
        let resolvedWD: URL?
        switch container {
        case .loose:
            let defaults = quickTabDefaultsProvider()
            resolvedWD = workingDirectory ?? resolveCwdMode(defaults.mode, path: defaults.path)
        case let .group(gid):
            let group = groups.first(where: { $0.id == gid })
            resolvedWD = workingDirectory ?? resolveCwdMode(
                group?.cwdMode ?? .inheritPrevious,
                path: group?.cwdPath
            )
        case let .project(pid):
            let project = projects.first(where: { $0.id == pid })
            resolvedWD = workingDirectory ?? project?.rootURL
        case let .worktree(pid, wid):
            let project = projects.first(where: { $0.id == pid })
            let wt = project?.worktrees.first(where: { $0.id == wid })
            resolvedWD = workingDirectory ?? wt?.workingDirectory ?? project?.rootURL
        }
        // Initial title matches what the shell's OSC 7 will set it to
        // moments later — the working-directory basename, with $HOME
        // collapsed to "~". Skipping a placeholder ("scratch" / group
        // name / project name) avoids a visible flash when the shell
        // overwrites it.
        let resolvedTitle = title ?? TitleFormatting.pwdStyle(for: resolvedWD)
        let (tab, _) = Tab.newWithSinglePane(
            title: resolvedTitle,
            workingDirectory: resolvedWD?.path,
            container: container
        )
        tabs.append(tab)
        setActiveTab(tab.id)
        return tab
    }

    /// Resolve a `WorkingDirectoryMode` to a concrete cwd URL, or nil
    /// to fall through to libghostty's home-on-launch default.
    ///   - `.home`            → the user's home directory.
    ///   - `.inheritPrevious` → the active tab's *live* cwd. We prefer
    ///     `pwd` (kept current by libghostty's PWD action as the shell
    ///     `cd`s) and fall back to the tab's launch `workingDirectory`
    ///     before the first PWD report. Nil when there's no active tab
    ///     or it has neither (preserves the home-on-launch behaviour).
    ///   - `.fixed`           → `path` (nil when unset).
    func resolveCwdMode(_ mode: WorkingDirectoryMode, path: URL?) -> URL? {
        switch mode {
        case .home:
            FileManager.default.homeDirectoryForCurrentUser
        case .inheritPrevious:
            (activeTab?.pwd ?? activeTab?.workingDirectory).map { URL(fileURLWithPath: $0) }
        case .fixed:
            path
        }
    }

    /// Open a tab in the currently-selected container (L1). Honours
    /// the user's actual L1 selection rather than re-using the active
    /// tab's container — important when the user has navigated into
    /// an empty container and hits ⌘T: the new tab should land there,
    /// not in whichever container last had focus.
    @discardableResult
    func openTabInActiveScope() -> Tab {
        openTab(container: activeContainerID)
    }

    /// Close the tab. Focus migrates to a neighbor in the same
    /// container, or stays nil if the container is now empty so L2
    /// can render the empty state.
    func closeTab(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let closing = tabs[index]
        // Drop any in-pane search state for the panes inside this
        // tab — without this the entries linger in
        // `paneSearchStates` after the SurfaceView is unregistered.
        for leafID in closing.splitTree.allLeafIDs() {
            paneSearchStates.removeValue(forKey: leafID)
        }
        tabs.remove(at: index)

        if activeTabID == tabID {
            // Pick the last remaining tab in the *same* container, or
            // nil if it now has none. We never jump to a different
            // container — that would silently switch the user out of
            // the container they were looking at.
            let successor = tabs.last(where: { $0.container == closing.container })
            setActiveTab(successor?.id)
        }
        forgetLastActive(tabID: tabID, container: closing.container)
    }

    /// In-place mutate a tab. Skips the writeback when `transform`
    /// leaves the tab unchanged — without this short-circuit every
    /// no-op mutation (e.g. `clearUnread` on a tab whose pane is
    /// already at zero) reassigns `tabs[index]` and trips the
    /// autosave observation hook.
    ///
    /// - Returns: `true` if `tabID` matched a tab (whether or not the
    ///   transform produced an actual change), `false` if it didn't.
    @discardableResult
    func update(_ tabID: UUID, transform: (inout Tab) -> Void) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return false }
        var tab = tabs[index]
        transform(&tab)
        if tab != tabs[index] {
            tabs[index] = tab
        }
        return true
    }

    // MARK: - Sidebar derived views

    /// Tabs in the implicit Loose container.
    var looseTabs: [Tab] {
        tabs.filter {
            if case .loose = $0.container { return true }
            return false
        }
    }

    func tabs(in groupID: UUID) -> [Tab] {
        tabs.filter {
            if case let .group(gid) = $0.container, gid == groupID { return true }
            return false
        }
    }

    /// Tabs directly under a Project header (the "general" leaf).
    func directTabs(in projectID: UUID) -> [Tab] {
        tabs.filter {
            if case let .project(pid) = $0.container, pid == projectID { return true }
            return false
        }
    }

    /// Tabs under a specific Worktree.
    func tabs(inProject projectID: UUID, worktree worktreeID: UUID) -> [Tab] {
        tabs.filter {
            if case let .worktree(pid, wid) = $0.container,
               pid == projectID, wid == worktreeID { return true }
            return false
        }
    }

    /// Tabs in the given container — single entry point used by L2 to
    /// derive its row list. Routes to the specialised filter above.
    func tabs(in container: ContainerID) -> [Tab] {
        switch container {
        case .loose: looseTabs
        case let .group(gid): tabs(in: gid)
        case let .project(pid): directTabs(in: pid)
        case let .worktree(pid, wid): tabs(inProject: pid, worktree: wid)
        }
    }

    // MARK: - Cross-container move (L2 → L1 drag-drop)

    /// Move the tab into a different container. Used by the L2 → L1
    /// drag handler. No-op when the target equals the current container.
    /// Drop semantics (per spec §5.6.2 case A):
    ///   1. tab.container is rewritten
    ///   2. tab is moved to the end of `tabs` (appears at the bottom of
    ///      the destination L2 list)
    ///   3. active container switches to the destination so the user
    ///      sees the moved tab immediately, with that tab still active
    func moveTab(_ tabID: UUID, to target: ContainerID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        if tabs[index].container == target { return }
        let sourceContainer = tabs[index].container
        let wasActive = (activeTabID == tabID)
        var moved = tabs.remove(at: index)
        moved.container = target
        tabs.append(moved)
        // Stay on the source container — yanking the user across
        // to the destination on every drag feels like a bug. For
        // active-tab drags promote the sibling that slid into the
        // vacated slot (Chrome/VSCode "tab to the right"); empty
        // source falls through to `setActiveTab(nil)`.
        if wasActive {
            let nextAfter = tabs[index...].first { $0.container == sourceContainer }
            let prevBefore = tabs[..<index].last { $0.container == sourceContainer }
            setActiveTab((nextAfter ?? prevBefore)?.id)
        }
    }

    /// Reorder a tab within the same container — `tabID` is moved so it
    /// sits immediately before `beforeID` in the global `tabs` array.
    /// Passing `beforeID == nil` appends to the end.
    func reorderTab(_ tabID: UUID, before beforeID: UUID?) {
        guard let from = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let moved = tabs.remove(at: from)
        if let beforeID,
           let to = tabs.firstIndex(where: { $0.id == beforeID })
        {
            tabs.insert(moved, at: to)
        } else {
            tabs.append(moved)
        }
    }

    /// Reorder a tab so it sits immediately *after* `afterID` in the
    /// global `tabs` array. Mirror of `reorderTab(_:before:)`.
    func reorderTab(_ tabID: UUID, after afterID: UUID) {
        guard let from = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let moved = tabs.remove(at: from)
        guard let toBase = tabs.firstIndex(where: { $0.id == afterID }) else {
            tabs.append(moved)
            return
        }
        tabs.insert(moved, at: toBase + 1)
    }
}
