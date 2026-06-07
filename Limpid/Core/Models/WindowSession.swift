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

    /// All open tabs as a flat list. The tab column list is derived by
    /// filtering on `Tab.container`. Array order = user-visible order
    /// (drag-reorder mutates the array in place).
    var tabs: [Tab]

    /// Currently active tab. The terminal column detail view follows
    /// this. May be nil when the active container has zero tabs (empty
    /// tab column state). Together with `activeContainerID` it forms
    /// the **active-selection invariant** — see that property's doc.
    /// Mutate via `setActiveTab(_:)` so the invariant stays intact;
    /// direct assignment is only used by `init`, `restore(from:)`, and
    /// transient close-paths that immediately re-establish the pair.
    var activeTabID: UUID?

    /// Container column selection. Drives which container's tab list
    /// is shown in tab column. Independent of `activeTabID` so the tab
    /// column can show an "empty container" state.
    ///
    /// **Active-selection invariant**: when `activeTabID` is non-nil,
    /// `tabs.first(where: { $0.id == activeTabID })?.container` must
    /// equal `activeContainerID`. `setActiveTab(_:)` enforces it by
    /// mirroring the tab's container into this field whenever a non-nil
    /// id is assigned; `setActiveContainer(_:)` enforces it by either
    /// activating one of the container's tabs (forwarding through
    /// `setActiveTab`) or by clearing `activeTabID` to nil (vacuous
    /// invariant for an empty container). The only legitimate
    /// "intermediate" violation is during multi-step close paths
    /// (`closeTab`, `closeTabs(where:)`) that null out `activeTabID`
    /// before the caller picks the next active container.
    var activeContainerID: ContainerID = .loose

    /// Browser-style ⌘[ / ⌘] back/forward history of (container, tab)
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

    /// Container column section fold state. The chevron lives on the section header
    /// ("GROUPS" / "PROJECTS"); individual rows don't expose their own.
    var groupsSectionExpanded: Bool = true
    var projectsSectionExpanded: Bool = true

    /// Sidebar (container column) width in points; persisted.
    var sidebarWidth: CGFloat

    /// Tab column width in points; persisted. Drag-resizable via the
    /// divider; double-click resets to `LimpidLayout.tabColumnWidth`.
    var tabColumnWidth: CGFloat = LimpidLayout.tabColumnWidth

    /// Height of the container column Waiting region as a fraction of the slab
    /// height; persisted. Drag-resizable via the divider above it;
    /// double-click resets to `LimpidLayout.attentionHeightFraction`.
    /// A fraction (not points) so it keeps its proportion across window
    /// resizes. Clamped to `attentionMinFraction ... attentionMaxFraction`.
    var attentionHeightFraction: CGFloat = LimpidLayout.attentionHeightFraction

    /// Whether the sidebar is collapsed.
    var sidebarHidden: Bool = false

    /// Tab column tab orientation. When true the tab list renders as a
    /// horizontal bar above terminal column instead of the default vertical column.
    var tabColumnHorizontal: Bool = false

    /// Last-known `NSWindow` frame in screen coordinates.
    var windowFrame: CGRect?

    /// Whether the hosting window is in native fullscreen. Transient —
    /// not Codable, not persisted. Maintained by `WindowFullScreenSync`.
    /// The window base fill reads this to neutralize the backdrop in
    /// fullscreen: a fullscreen Space sits directly on the desktop
    /// wallpaper, so the desktop-tinted `.underWindowBackground` vibrancy
    /// floods the backdrop with the wallpaper's color. We drain the
    /// saturation there (swapping the material doesn't help — `.behindWindow`
    /// pulls the wallpaper pixels in regardless), keeping the translucent
    /// blur while collapsing the hue to neutral.
    var isFullScreen: Bool = false

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

    /// Live read of the Quick Tabs working-directory defaults. Injected
    /// by the app layer so `WindowSession` (Core) doesn't have to import
    /// the UI-side `SettingsStore`; left at a home-on-launch-preserving
    /// default for tests and any caller that hasn't wired it up. Read at
    /// `openTab` time so settings changes take effect on the next tab
    /// without re-plumbing the closure.
    @ObservationIgnored
    var quickTabDefaultsProvider: () -> (mode: WorkingDirectoryMode, path: URL?) = {
        (.inheritPrevious, nil)
    }

    /// Per-pane in-pane search state (⌘F). Non-nil entry = overlay
    /// visible for that pane. Transient — not Codable, not persisted.
    /// Keyed by pane (split-tree leaf) id.
    var paneSearchStates: [UUID: PaneSearchState] = [:]

    /// Command palette visibility state. Non-nil = overlay shown.
    /// Transient — not Codable, not persisted.
    var commandPaletteState: CommandPaletteState?

    /// Global frame of the palette search field, used to anchor the
    /// dropdown. Updated by ToolbarPaletteField via onGeometryChange.
    /// Excluded from observation so window resizes don't fan out to
    /// every WindowSession observer.
    @ObservationIgnored var paletteFieldFrame: CGRect = .zero

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
    /// DockBadgeSync and the toolbar bell badge can react to the
    /// scalar directly without re-walking every pane on every
    /// mutation. Kept observation-visible — consumers Observe this
    /// instead of `tabs`, so unrelated tab edits (split tree, title
    /// rename) don't fan out to badge recomputes.
    var cachedWindowUnreadCount: Int = 0

    /// projectID → number of tabs whose container points at the
    /// project (project-direct OR any of its worktrees). Maintained
    /// incrementally by `openTab` / `closeTab` / `moveTab` / `restore`
    /// / `removeProject` so the Project header row gets `tabCount(in:)`
    /// in O(1) instead of an N-tab linear walk per body re-eval.
    /// `@ObservationIgnored` because the count is observed via the
    /// owning `Project` row through `session.tabs` mutations.
    @ObservationIgnored
    var cachedProjectTabCount: [UUID: Int] = [:]

    /// (projectID, worktreeID) → number of tabs in this specific
    /// worktree. Same pattern as `cachedProjectTabCount` but at
    /// worktree granularity so individual worktree rows skip the
    /// per-render scan.
    @ObservationIgnored
    var cachedWorktreeTabCount: [WorktreeTabCountKey: Int] = [:]

    /// paneID → tabID reverse index used by `tab(containing:)` and the
    /// per-pane state mutators it funnels through. Without it, every
    /// libghostty event (focus, occlusion, action) walks every tab's
    /// splitTree once — O(N tabs × L leaves) on the hottest event
    /// path. The cache rebuilds lazily when the signature (tab count
    /// + leaf count) changes. `@ObservationIgnored` so cache reads
    /// don't propagate as mutation notifications.
    @ObservationIgnored
    var paneToTabIndexCache: (signature: Int, map: [UUID: UUID])?

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
        sidebarWidth: CGFloat = LimpidLayout.containerColumnWidth,
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

    /// Find a Project by id. Centralized so call sites don't sprinkle
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

    /// Find a Tab by id. Centralized so drop targets / actions don't
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
            true
        case let .group(gid):
            group(gid) != nil
        case let .project(pid):
            project(pid) != nil
        case let .worktree(pid, wid):
            worktree(projectID: pid, worktreeID: wid) != nil
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

    /// Single entry point for changing the active tab. Maintains the
    /// active-selection invariant on `activeContainerID` by mirroring
    /// the resolved tab's container into it (non-nil case) and updates
    /// the owning Group's / Project's / Worktree's `lastActiveTabID`
    /// so re-entering the container restores the same tab.
    ///
    /// Passing `nil` clears `activeTabID` and **leaves
    /// `activeContainerID` alone** — used by close paths that intend
    /// to keep the sidebar selection on the now-empty container and
    /// let the caller decide the next active state.
    func setActiveTab(_ tabID: UUID?) {
        activeTabID = tabID
        guard let tabID,
              let tab = tabs.first(where: { $0.id == tabID })
        else { return }
        activeContainerID = tab.container
        rememberLastActive(tabID: tabID, container: tab.container)
    }

    /// Stamp the lastActive pointer of whichever group/project/worktree
    /// owns `container`. Loose has no parent to remember, so it's a no-op.
    func rememberLastActive(tabID: UUID, container: ContainerID) {
        switch container {
        case .loose:
            return
        case let .group(gid):
            if let i = groups.firstIndex(where: { $0.id == gid }) {
                groups[i].lastActiveTabID = tabID
            }
        case let .project(pid):
            if let i = projects.firstIndex(where: { $0.id == pid }) {
                projects[i].lastActiveTabID = tabID
            }
        case let .worktree(pid, wid):
            if let pi = projects.firstIndex(where: { $0.id == pid }),
               let wi = projects[pi].worktrees.firstIndex(where: { $0.id == wid })
            {
                projects[pi].worktrees[wi].lastActiveTabID = tabID
            }
        }
    }

    /// Clear lastActive on whichever group/project/worktree owns
    /// `container` if it currently points at `tabID`. Mirror of
    /// `rememberLastActive` used by `closeTab`.
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
        case let .project(pid):
            if let i = projects.firstIndex(where: { $0.id == pid }),
               projects[i].lastActiveTabID == tabID
            {
                projects[i].lastActiveTabID = nil
            }
        case let .worktree(pid, wid):
            if let pi = projects.firstIndex(where: { $0.id == pid }),
               let wi = projects[pi].worktrees.firstIndex(where: { $0.id == wid }),
               projects[pi].worktrees[wi].lastActiveTabID == tabID
            {
                projects[pi].worktrees[wi].lastActiveTabID = nil
            }
        }
    }

    // Navigation history (back / forward) lives in
    // `WindowSession+Navigation.swift`.

    /// Switch container column selection. If the target container has
    /// tabs, activate its `lastActiveTabID` (or the first one); if
    /// empty, leave `activeTabID` nil so the tab column shows the empty
    /// state. Either way the active-selection invariant on
    /// `activeContainerID` holds on return.
    func setActiveContainer(_ container: ContainerID) {
        let candidates = tabs(in: container)
        if candidates.isEmpty {
            // Empty container: this is the only place that mutates
            // `activeContainerID` without going through `setActiveTab`.
            // `activeTabID = nil` keeps the invariant vacuous.
            activeContainerID = container
            activeTabID = nil
            return
        }
        // Non-empty: `setActiveTab` will mirror the chosen tab's
        // container into `activeContainerID`, which equals
        // `container` because the candidate was taken from
        // `tabs(in: container)`.
        if let last = lastActiveTabID(for: container),
           candidates.contains(where: { $0.id == last })
        {
            setActiveTab(last)
        } else if let first = candidates.first {
            // `candidates` is non-empty here (guarded above), but
            // pattern-match instead of force-unwrap so a future shape
            // change can't introduce a silent crash on the hot
            // container-switch path.
            setActiveTab(first.id)
        }
    }

    func lastActiveTabID(for container: ContainerID) -> UUID? {
        switch container {
        case .loose:
            nil
        case let .group(gid):
            groups.first(where: { $0.id == gid })?.lastActiveTabID
        case let .project(pid):
            projects.first(where: { $0.id == pid })?.lastActiveTabID
        case let .worktree(pid, wid):
            projects.first(where: { $0.id == pid })?
                .worktrees.first(where: { $0.id == wid })?.lastActiveTabID
        }
    }

    // MARK: - Activate a Project / Group

    /// Click a Project header → activate its lastActiveTabID (or first
    /// existing tab in any of its containers), or auto-create a
    /// project-direct tab if the project is empty.
    @discardableResult
    func activateProject(_ projectID: UUID) -> Tab? {
        // `lastActiveTabID` is sticky and outlives `moveTab`, so a tab
        // that was once in this project but has since been dragged
        // elsewhere still passes a naive `tabs.contains` check —
        // `setActiveTab(lastID)` would then jump the user into the
        // destination container instead of the project they clicked.
        // Filter on the tab's CURRENT container before honoring it.
        if let lastID = projects.first(where: { $0.id == projectID })?.lastActiveTabID,
           tabs.contains(where: { $0.id == lastID && $0.container.projectID == projectID })
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
        // Same `lastActiveTabID` membership trap as `activateProject`
        // (see comment there) — gate on the tab's current container,
        // not just its existence in the tabs array.
        if let lastID = groups.first(where: { $0.id == groupID })?.lastActiveTabID,
           tabs.contains(where: { $0.id == lastID && $0.container.groupID == groupID })
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

/// Composite key for `cachedWorktreeTabCount`. A worktree is uniquely
/// identified by its `(projectID, worktreeID)` pair — the worktree
/// UUID alone is enough for lookup, but pairing with the project keeps
/// the invalidation path (project delete → drop every nested entry)
/// trivial.
struct WorktreeTabCountKey: Hashable {
    let projectID: UUID
    let worktreeID: UUID
}
