// WindowSession.swift
// Limpid — top-level @Observable state for a single window. Hosts the
// container catalog (groups / projects) and the flat tab list. The
// sidebar derives its three sections from this data; the active tab is
// the single source of truth for "what is the user looking at".

import Foundation
import Observation

@MainActor
@Observable
final class WindowSession {
    /// Labeled buckets ("Groups" section). No path, no git.
    var groups: [TabGroup]

    /// Path-anchored projects ("Projects" section). Optional worktrees.
    var projects: [Project]

    /// All open tabs as a flat list. The L2 list is derived by
    /// filtering on `Tab.container`. Array order = user-visible order
    /// (drag-reorder mutates the array in place).
    var tabs: [Tab]

    /// Currently active tab. L3 detail view follows this. May be nil
    /// when the active container has zero tabs (empty L2 state).
    var activeTabID: UUID?

    /// L1 selection. Drives which container's tab list is shown in L2.
    /// Independent of `activeTabID` so the L2 can show an "empty
    /// container" state. Invariant: when `activeTabID` is non-nil, the
    /// referenced tab's container equals this value.
    var activeContainerID: ContainerID = .loose

    /// VS Code-style ⌘[ / ⌘] back/forward history of (container, tab)
    /// pairs the user has visited. Pushed automatically on every
    /// `activeTabID` change driven by user input; cleared on
    /// `navigateBack` and rewritten when the user steps off the
    /// history tail (forward stack truncates). Transient — not
    /// persisted across launches.
    var navBackStack: [NavTarget] = []
    var navForwardStack: [NavTarget] = []

    /// Capped stack of tabs the user has closed since launch, ordered
    /// oldest-first. ⌘⇧T pops the back of the stack to bring a tab
    /// back at its old container + cwd, with the captured scrollback
    /// replayed into the fresh surface (the shell itself is a new
    /// process — there's nothing to revive). Transient: not persisted
    /// across launches, so a quit-restart wipes the history.
    var closedTabStack: [ClosedTab] = []
    static let closedTabStackLimit = 20

    /// L1 section fold state. The chevron lives on the section header
    /// ("GROUPS" / "PROJECTS"); individual rows don't expose their own.
    var groupsSectionExpanded: Bool = true
    var projectsSectionExpanded: Bool = true

    /// Sidebar (L1) width in points; persisted.
    var sidebarWidth: CGFloat

    /// L2 column width in points; persisted. Drag-resizable via the
    /// divider; double-click resets to `LimpidLayout.l2Width`.
    var l2Width: CGFloat = LimpidLayout.l2Width

    /// Whether the sidebar is collapsed.
    var sidebarHidden: Bool = false

    /// Last-known `NSWindow` frame in screen coordinates.
    var windowFrame: CGRect?

    /// Most-recently-opened Project rootURLs. Drives the "+" menu's
    /// Recent section so the user doesn't re-pick paths via the file
    /// picker every time.
    var recentProjectPaths: [URL] = []

    static let recentProjectPathsLimit = 10

    /// Worktrees whose on-disk identity is currently being mutated by
    /// a Limpid-initiated git operation. Read-only from the outside —
    /// callers go through `withWorktreeMutationGated(_:_:)` to enter /
    /// leave the set so the contract is grep-able. GitSyncCoordinator
    /// is the consumer (skips reconciliation for in-flight ids).
    @ObservationIgnored private(set) var worktreeMutationsInFlight: Set<UUID> = []

    /// Per-pane in-pane search state (⌘F). Non-nil entry = overlay
    /// visible for that pane. Transient — not Codable, not persisted.
    /// Keyed by pane (split-tree leaf) id.
    var paneSearchStates: [UUID: PaneSearchState] = [:]

    /// Per-pane transient UI state (bell ringing, child exit code).
    /// Lives here, *not* on `Tab.paneStates`, so flipping a bell flash
    /// or stamping a child-exit code doesn't reassign `tabs[idx]` —
    /// which would otherwise trip the autosave observation hook on
    /// every bell ring. UI observes this dict directly through the
    /// `@Observable` parent, so SwiftUI still re-renders on change.
    var paneTransients: [UUID: PaneTransients] = [:]

    /// Total unread across every pane in the window. Maintained
    /// incrementally by the unread mutators (`markUnread` /
    /// `clearUnread` / `clearAllUnread` / `restore(from:)`) so
    /// DockBadgeSync and the chrome bell badge can react to the
    /// scalar directly without re-walking every pane on every
    /// mutation. Kept observation-visible — consumers Observe this
    /// instead of `tabs`, so unrelated tab edits (split tree, title
    /// rename) don't fan out to badge recomputes.
    var cachedWindowUnreadCount: Int = 0

    /// Run an async pipeline that mutates a worktree's on-disk
    /// identity (rename, delete). Adds to the in-flight set on entry
    /// and removes on exit — even on throw — so GitSync's reconcile
    /// loop knows to skip this row while the operation is racing
    /// against its own refetch.
    ///
    /// This is the single grep-able contract for "Limpid-initiated
    /// worktree git operations": every async git CLI call that
    /// mutates `Worktree.workingDirectory` should be wrapped in this.
    func withWorktreeMutationGated<T>(
        _ worktreeID: UUID,
        _ work: () async throws -> T
    ) async rethrows -> T {
        worktreeMutationsInFlight.insert(worktreeID)
        defer { worktreeMutationsInFlight.remove(worktreeID) }
        return try await work()
    }

    init(
        groups: [TabGroup] = [],
        projects: [Project] = [],
        tabs: [Tab] = [],
        activeTabID: UUID? = nil,
        activeContainerID: ContainerID = .loose,
        sidebarWidth: CGFloat = LimpidLayout.l1Width,
        recentProjectPaths: [URL] = []
    ) {
        self.groups = groups
        self.projects = projects
        self.tabs = tabs
        self.activeTabID = activeTabID
        self.activeContainerID = activeContainerID
        self.sidebarWidth = sidebarWidth
        self.recentProjectPaths = recentProjectPaths
    }

    var activeTab: Tab? {
        guard let id = activeTabID else { return nil }
        return tabs.first(where: { $0.id == id })
    }

    // MARK: - Container lookups (shared across views)

    /// Find a Project by id. Centralised so call sites don't sprinkle
    /// `session.projects.first(where: …)` everywhere.
    func project(_ id: UUID) -> Project? {
        projects.first(where: { $0.id == id })
    }

    /// Find a Group by id.
    func group(_ id: UUID) -> TabGroup? {
        groups.first(where: { $0.id == id })
    }

    /// Find a Worktree inside a Project by ids.
    func worktree(projectID: UUID, worktreeID: UUID) -> Worktree? {
        project(projectID)?.worktrees.first(where: { $0.id == worktreeID })
    }

    /// Find a Tab by id. Centralised so drop targets / actions don't
    /// sprinkle `session.tabs.first(where: …)` across the codebase.
    func tab(_ id: UUID) -> Tab? {
        tabs.first(where: { $0.id == id })
    }

    /// `true` when the container is still reachable from the current
    /// session graph. `.loose` is always reachable; the others have
    /// to resolve through `groups` / `projects` / `worktrees` because
    /// a stale `ContainerID` (notification fired before a group or
    /// worktree was removed) would otherwise point the sidebar at a
    /// phantom row.
    func containerExists(_ container: ContainerID) -> Bool {
        switch container {
        case .loose:
            return true
        case let .group(gid):
            return group(gid) != nil
        case let .project(pid):
            return project(pid) != nil
        case let .worktree(pid, wid):
            return worktree(projectID: pid, worktreeID: wid) != nil
        }
    }

    /// Human-friendly label for the container. Used by the
    /// NotificationHistoryView and snapshotted onto entries so closed
    /// panes still surface "Servers" / "myapp / main".
    func containerLabel(for container: ContainerID) -> String {
        switch container {
        case .loose:
            return String(localized: "Quick Tabs")
        case let .group(gid):
            return group(gid)?.name ?? "Group"
        case let .project(pid):
            return project(pid)?.name ?? "Project"
        case let .worktree(pid, wid):
            let p = project(pid)?.name ?? "Project"
            let w = worktree(projectID: pid, worktreeID: wid)?.label ?? ""
            return w.isEmpty ? p : "\(p) / \(w)"
        }
    }

    /// The Project the active tab lives in (if any). Derived.
    var activeProject: Project? {
        guard let pid = activeTab?.container.projectID else { return nil }
        return projects.first(where: { $0.id == pid })
    }

    /// The Group the active tab lives in (if any). Derived.
    var activeGroup: TabGroup? {
        guard let gid = activeTab?.container.groupID else { return nil }
        return groups.first(where: { $0.id == gid })
    }

    // MARK: - Active tab selection

    /// Single entry point for changing the active tab. Updates the
    /// owning Project's / Group's `lastActiveTabID` so re-entering the
    /// container restores the same tab.
    func setActiveTab(_ tabID: UUID?) {
        activeTabID = tabID
        guard let tabID,
              let tab = tabs.first(where: { $0.id == tabID })
        else { return }
        // Keep L1 selection in sync with the active tab's container so
        // the two never disagree.
        activeContainerID = tab.container
        rememberLastActive(tabID: tabID, container: tab.container)
    }

    /// Stamp the lastActive pointer of whichever group/project owns
    /// `container`. Loose has no parent to remember, so it's a no-op.
    func rememberLastActive(tabID: UUID, container: ContainerID) {
        switch container {
        case .loose:
            return
        case let .group(gid):
            if let i = groups.firstIndex(where: { $0.id == gid }) {
                groups[i].lastActiveTabID = tabID
            }
        case let .project(pid), let .worktree(pid, _):
            if let i = projects.firstIndex(where: { $0.id == pid }) {
                projects[i].lastActiveTabID = tabID
            }
        }
    }

    /// Clear lastActive on whichever group/project owns `container` if
    /// it currently points at `tabID`. Mirror of `rememberLastActive`
    /// used by `closeTab`.
    func forgetLastActive(tabID: UUID, container: ContainerID) {
        switch container {
        case .loose:
            return
        case let .group(gid):
            if let i = groups.firstIndex(where: { $0.id == gid }),
               groups[i].lastActiveTabID == tabID
            {
                groups[i].lastActiveTabID = nil
            }
        case let .project(pid), let .worktree(pid, _):
            if let i = projects.firstIndex(where: { $0.id == pid }),
               projects[i].lastActiveTabID == tabID
            {
                projects[i].lastActiveTabID = nil
            }
        }
    }

    // Navigation history (back / forward) lives in
    // `WindowSession+Navigation.swift`.

    /// Switch L1 selection. If the target container has tabs, activate
    /// its `lastActiveTabID` (or the first one); if empty, leave
    /// `activeTabID` nil so the L2 shows the empty state.
    func setActiveContainer(_ container: ContainerID) {
        activeContainerID = container
        let candidates = tabs(in: container)
        if candidates.isEmpty {
            activeTabID = nil
            return
        }
        // Try the container's own lastActive pointer first.
        if let last = lastActiveTabID(for: container),
           candidates.contains(where: { $0.id == last })
        {
            setActiveTab(last)
        } else {
            setActiveTab(candidates.first!.id)
        }
    }

    func lastActiveTabID(for container: ContainerID) -> UUID? {
        switch container {
        case .loose:
            nil
        case let .group(gid):
            groups.first(where: { $0.id == gid })?.lastActiveTabID
        case let .project(pid), let .worktree(pid, _):
            projects.first(where: { $0.id == pid })?.lastActiveTabID
        }
    }

    // MARK: - Activate a Project / Group

    /// Click a Project header → activate its lastActiveTabID (or first
    /// existing tab in any of its containers), or auto-create a
    /// project-direct tab if the project is empty.
    @discardableResult
    func activateProject(_ projectID: UUID) -> Tab? {
        if let lastID = projects.first(where: { $0.id == projectID })?.lastActiveTabID,
           tabs.contains(where: { $0.id == lastID })
        {
            setActiveTab(lastID)
            return tabs.first(where: { $0.id == lastID })
        }
        if let first = tabs.first(where: { $0.container.projectID == projectID }) {
            setActiveTab(first.id)
            return first
        }
        return openTab(container: .project(projectID))
    }

    /// Click a Group header → activate or auto-create.
    @discardableResult
    func activateGroup(_ groupID: UUID) -> Tab? {
        if let lastID = groups.first(where: { $0.id == groupID })?.lastActiveTabID,
           tabs.contains(where: { $0.id == lastID })
        {
            setActiveTab(lastID)
            return tabs.first(where: { $0.id == lastID })
        }
        if let first = tabs(in: groupID).first {
            setActiveTab(first.id)
            return first
        }
        return openTab(container: .group(groupID))
    }

    static func reorderInPlace<T: Identifiable>(
        in array: inout [T],
        sourceID: T.ID,
        target targetID: T.ID,
        position: DropPosition
    ) where T.ID == UUID {
        guard sourceID != targetID,
              let from = array.firstIndex(where: { $0.id == sourceID }),
              array.firstIndex(where: { $0.id == targetID }) != nil
        else { return }
        let moved = array.remove(at: from)
        var insertAt = array.firstIndex(where: { $0.id == targetID }) ?? from
        if position == .after { insertAt += 1 }
        array.insert(moved, at: insertAt)
    }

}
