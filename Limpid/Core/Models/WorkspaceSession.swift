// WorkspaceSession.swift
// Limpid — top-level @Observable state shared by every window. Hosts the
// projects, the flat tab list, and each window's selection. It holds the
// state of every project and every window, not of one sidebar row: a
// "workspace" is a single worktree row. The sidebar derives
// its rows from this data; each window's active tab is the single source
// of truth for "what is the user looking at".

import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceSession {
    /// Path-anchored projects, each with its worktrees.
    var projects: [Project]

    /// All open tabs as a flat list. A row's tabs are derived by
    /// filtering on `Tab.container`. Array order = user-visible order
    /// (drag-reorder mutates the array in place).
    var tabs: [Tab]

    /// The primary window's selection. Held here as well as in
    /// `selections` so what stands for the primary by name (the launch, a
    /// restore, the projection's stand-in when the front window is hidden)
    /// needs no lookup and no optional.
    ///
    /// A role rather than a window: the first window has it at
    /// launch, and closing it hands it to a window left
    /// (`makePrimary`), so the session always has one.
    private(set) var primarySelection: WindowSelection

    var primaryWindowID: WindowID {
        primarySelection.windowID
    }

    /// Every window's selection, by window: the primary's, and one for each
    /// project window opened since (`addSelection`).
    private(set) var selections: [WindowID: WindowSelection]

    /// The windows hidden (closed): they draw nothing. Reported by the
    /// app layer, which owns the windows. Not the attention list's "seen", which also
    /// leaves out minimized and covered windows and is decided by
    /// `AttentionVisibility`; this only says what each window draws.
    private(set) var hiddenWindowIDs: Set<WindowID> = []

    /// The main window the person was last in, for what follows the
    /// keyboard (the projection's focus). Reported by the app layer; `nil`
    /// until a window reports it (`lastFrontWindowID`).
    @ObservationIgnored var frontWindowID: WindowID?

    /// The window the person was last in: the one reported
    /// (`frontWindowID`), or the primary until one is. Read where a window
    /// stands for the keyboard, not where a caller names a window to act in.
    var lastFrontWindowID: WindowID {
        frontWindowID ?? primaryWindowID
    }

    /// The root fields of `state.json` this build does not know, as the
    /// restored snapshot carried them (`SessionSnapshot.unknownFields`).
    /// Written back by `makeSnapshot`, so a newer build's root fields
    /// survive a Sparkle rollback to this one: every save goes through the
    /// session. They stay as the newer build
    /// wrote them and follow nothing this run changes, so that build reads
    /// them back allowing for what has gone since (a removed project, a
    /// closed tab).
    @ObservationIgnored var carriedRootFields: [String: LimpidJSONValue] = [:]

    /// What each project showed when a window last left it, by
    /// project, put back when a window shows the project again.
    ///
    /// Invariant, one way: a project with a view here is shown by no
    /// window, hidden ones included. A window that shows the project holds
    /// its view in its own selection, so the two cannot disagree: a view is
    /// forgotten as a window takes the project (`enterProject`), and made
    /// only when a window the person used leaves it. The converse does not
    /// hold: a project no window has left yet has no view, and opens on
    /// its last session.
    ///
    /// While no window shows the project, its view is what a window would
    /// be: what went away under it is repaired here, and work that ends
    /// behind lands here (`SelectionTarget.memory`). Neither makes a view
    /// for a project that has none: that would stop the first window to
    /// show it from taking the layout it comes from.
    ///
    /// Saved at the root of `state.json` (`SessionSnapshot.projectViews`),
    /// so it is observed: a change here schedules a save even when nothing
    /// else changes.
    var projectViews: [UUID: ProjectView] = [:]

    /// Records whether `window` is hidden. Written only on a change: what
    /// is shown is read by the attention list.
    func setWindow(_ window: WindowID, isHidden: Bool) {
        guard hiddenWindowIDs.contains(window) != isHidden else { return }
        if isHidden {
            hiddenWindowIDs.insert(window)
        } else {
            hiddenWindowIDs.remove(window)
        }
    }

    /// The window that keeps the scratch tabs. A terminal draws in
    /// one window at a time, and the scratch tabs belong to no project, so
    /// any window can choose them. Two things record it: a person's choice
    /// (`SelectionIntent.claimsScratch`), and a switch of project, which
    /// makes the window drawing the scratch tabs their keeper when another
    /// window comes onto them, back to a scratch tab it left or moved
    /// there because its project was removed, so the tabs stay where they
    /// are drawn (`keepScratch`). Never a window moved because a tab closed
    /// under it. `nil` until one of those records it, and once the keeper
    /// leaves them in a switch. Who draws them is `scratchDrawingWindowID`.
    private(set) var scratchOwnerWindowID: WindowID?

    /// What the app layer does as a window switches to another project in
    /// place, or as the window that shows it is brought forward instead.
    /// Set by the app layer
    /// (`WindowRegistry.connectProjectSwitching`). Only what the app layer
    /// is told: the session switches its windows by the same rule before
    /// one connects (`ProjectSwitchHandlers.unconnected`), so no session
    /// can show a project in two windows.
    @ObservationIgnored var projectSwitching = ProjectSwitchHandlers.unconnected

    /// Lets the scratch tabs go from `window` as it switches projects,
    /// or keeps them where they were drawn: `drawer` is the window
    /// that drew them before the switch. The window that chose them and
    /// leaves them gives them up, so a window that has them selected
    /// draws them; one that comes onto them, back to a scratch tab it left
    /// or moved there because its project was removed, does not take them
    /// from the window drawing them, as neither is choosing them.
    func keepScratch(drawnBy drawer: WindowID?, as window: WindowID) {
        if scratchOwnerWindowID == window, selections[window]?.activeContainerID != .loose {
            scratchOwnerWindowID = nil
        }
        if let drawer, drawer != window, scratchDrawingWindowID != drawer,
           selections[drawer]?.activeContainerID == .loose
        {
            scratchOwnerWindowID = drawer
        }
    }

    /// The window that draws the scratch tabs: the one that last chose
    /// them while it still has them selected and is shown, else the first
    /// shown window that has them selected (the primary first), so a
    /// window that moves on or is hidden leaves them to another rather
    /// than to no one. A window that shows nothing stands on the scratch
    /// row without having them (`WindowSelection.isChoosingProject`), and
    /// never draws them until the person chooses them there.
    var scratchDrawingWindowID: WindowID? {
        if let owner = scratchOwnerWindowID, let selection = selections[owner], isOnScratch(selection),
           !hiddenWindowIDs.contains(owner)
        {
            return owner
        }
        return orderedWindows { isOnScratch($0) && !hiddenWindowIDs.contains($0.windowID) }.first
    }

    /// Whether `selection` has the scratch tabs selected: on their row,
    /// and not a window that shows nothing standing there.
    private func isOnScratch(_ selection: WindowSelection) -> Bool {
        selection.activeContainerID == .loose && !selection.isChoosingProject
    }

    /// Whether `window` draws the scratch tabs (`scratchDrawingWindowID`).
    /// A window with them not selected draws none, and says nothing.
    /// A window the session does not know draws nothing.
    func showsScratch(in window: WindowID) -> Bool {
        guard let selection = selection(window) else { return false }
        return selection.activeContainerID != .loose || scratchDrawingWindowID == selection.windowID
    }

    /// The tab `window`'s pane area draws: its active tab, unless that is a
    /// scratch tab another window draws, where this one shows a notice
    /// instead. One answer for the pane area and for whatever lines itself
    /// up with what the pane area shows (the changes panel's foot).
    func drawnTab(in window: WindowID) -> Tab? {
        guard let tab = activeTab(in: window) else { return nil }
        return isScratchElsewhere(tab, in: window) ? nil : tab
    }

    /// Whether `window` has the scratch tabs selected while another window
    /// draws them: a terminal draws in one window at a time.
    func isScratchElsewhere(in window: WindowID) -> Bool {
        activeTab(in: window).map { isScratchElsewhere($0, in: window) } ?? false
    }

    private func isScratchElsewhere(_ tab: Tab, in window: WindowID) -> Bool {
        tab.container == .loose && !showsScratch(in: window)
    }

    /// Moves the scratch tabs to `window`: it chose them, or asked to show
    /// them here from the window that had them. A window the session does
    /// not know takes nothing.
    /// A window that showed nothing shows them from then on
    /// (`WindowSelection.isChoosingProject`).
    func claimScratch(for window: WindowID) {
        guard let selection = selection(window) else { return }
        if selection.isChoosingProject {
            selection.isChoosingProject = false
        }
        if scratchOwnerWindowID != selection.windowID {
            scratchOwnerWindowID = selection.windowID
        }
    }

    /// The windows whose selection meets `condition`, the primary first and
    /// the others by ID, so whoever asks gets the same answer.
    func orderedWindows(where condition: (WindowSelection) -> Bool) -> [WindowID] {
        selections.values
            .filter(condition)
            .map(\.windowID)
            .sorted { lhs, rhs in
                lhs == primaryWindowID || (rhs != primaryWindowID && lhs.rawValue.uuidString < rhs.rawValue.uuidString)
            }
    }

    /// Where a selection of `container` lands when asked of `window` for
    /// `intent`. Every selection goes through here, so no way into another
    /// project (a reopened tab, going back, a jump, the palette, a repair,
    /// work that ends behind) can make a window a second one for a project,
    /// and only the person's choice moves a window they see.
    ///
    /// - `.person`: `window`'s selection while it shows the project
    ///   `container` is in (or `container` is in none). Of another
    ///   project: the window that shows it, hidden or not, brought forward
    ///   (`projectSwitching`); else
    ///   `window`, switched to it in place
    ///   (`showProject(_:in:intent:reason:)`). Nothing else switches a
    ///   window or brings one forward. Either way the project is the one
    ///   the person used last (`noteProjectUsed`).
    /// - `.repair`: `window`'s selection, the one that held what went away,
    ///   while the write keeps it in the project it shows (or `container`
    ///   is in none). One that would take it to another project lands in
    ///   that project's view instead: a window moved on is not one the
    ///   person sent there.
    /// - `.behind`: never a shown window's selection. The hidden window
    ///   that shows the project `container` is in, else the project's
    ///   view: a hidden window is treated as the project's view, since
    ///   keys don't reach it. Either takes the write by the
    ///   same rule (`setActiveTab(_:at:intent:)`). A scratch tab is in no
    ///   project, and has nowhere to land.
    ///
    /// A window the session does not know has no target for the person or
    /// a repair, so what was asked of it lands nowhere rather than in
    /// another window.
    private func window(for container: ContainerID, askedOf window: WindowID, intent: SelectionIntent) -> SelectionTarget? {
        switch intent {
        case .person:
            guard let target = personTarget(for: container, askedOf: window) else { return nil }
            // What the person chose is in sight: its project's header in
            // that window's sidebar opens, a folded section's row being
            // listed among the working ones already. Only for a row
            // they move to: another tab of the row they are on (⌘1…9, ⌘T, a
            // review tab) leaves a header they folded as it is. Only theirs:
            // a repair or work behind them unfolds nothing.
            if let projectID = container.projectID, target.activeContainerID != container,
               target.sidebarArrangement.collapsedProjects.contains(projectID)
            {
                target.sidebarArrangement.collapsedProjects.remove(projectID)
            }
            return .window(target)
        case .repair:
            guard let asked = selection(window) else { return nil }
            guard let projectID = container.projectID, asked.shownProjectID != projectID else { return .window(asked) }
            return .memory(projectID: projectID)
        case .behind:
            guard let projectID = container.projectID else { return nil }
            let hidden = orderedWindows { hiddenWindowIDs.contains($0.windowID) && $0.shownProjectID == projectID }
            return hidden.first.flatMap(selection).map(SelectionTarget.window) ?? .memory(projectID: projectID)
        }
    }

    /// The window a selection the person asked of `window` lands in
    /// (`window(for:askedOf:intent:)`).
    private func personTarget(for container: ContainerID, askedOf window: WindowID) -> WindowSelection? {
        guard let asked = selection(window) else { return nil }
        guard let projectID = container.projectID, asked.shownProjectID != projectID else { return asked }
        // One window shows a project at a time: the one that
        // shows it already, hidden ones included, comes forward.
        let other = orderedWindows { $0.windowID != asked.windowID && $0.shownProjectID == projectID }
        if let shown = other.first.flatMap(selection) {
            projectSwitching.onRaiseWindow(shown.windowID)
            noteProjectUsed(projectID)
            return shown
        }
        // A project the session no longer has is shown nowhere.
        guard project(projectID) != nil else { return nil }
        showProject(projectID, in: asked.windowID, intent: .person, reason: .person)
        noteProjectUsed(projectID)
        return asked
    }

    /// The person chose `projectID` in `window`, as every
    /// way to a project does first (`WindowRegistry.show(project:in:from:intent:)`):
    /// the window that shows it, hidden or not, brought forward, else
    /// `window`, switched to it in place (`window(for:askedOf:intent:)`).
    /// Returns that window; `nil` for a window or project the session does
    /// not know, where nothing changes.
    func chooseProject(_ projectID: UUID, in window: WindowID) -> WindowID? {
        guard case let .window(selection)? = self.window(for: .project(projectID), askedOf: window, intent: .person) else {
            return nil
        }
        return selection.windowID
    }

    /// Every place a selection meeting `condition` (on its row and tab) is
    /// held: the windows, hidden ones included, in `orderedWindows` order,
    /// then the views of the projects no window shows, in the projects'
    /// order. The places to move on when what they hold goes away, so a
    /// project shown again does not open on a tab that is gone.
    func selectionTargets(where condition: (ContainerID, UUID?) -> Bool) -> [SelectionTarget] {
        let windows = orderedWindows { condition($0.activeContainerID, $0.activeTabID) }
            .compactMap { selection($0).map(SelectionTarget.window) }
        let views = projects.compactMap { projectViews[$0.id] }
            .filter { condition($0.activeContainerID, $0.activeTabID) }
            .map { SelectionTarget.memory(projectID: $0.projectID) }
        return windows + views
    }

    /// Whether some window, hidden ones included, or a project's view has
    /// `container` selected. Its last tab is then the one that window or
    /// view shows, and a tab that opens behind leaves it so: coming back to
    /// the row shows what was there, not the tab opened meanwhile. A
    /// window that shows nothing holds no row: it stands on the scratch row
    /// without showing it (`WindowSelection.isChoosingProject`), as the
    /// scratch tabs' drawer leaves it out (`scratchDrawingWindowID`).
    func holdsSelection(of container: ContainerID) -> Bool {
        selections.values.contains { $0.activeContainerID == container && !$0.isChoosingProject }
            || container.projectID.flatMap { projectViews[$0] }?.activeContainerID == container
    }

    /// The selection of the window `id` names, or `nil` when the session
    /// does not know it. A window is made with its selection, so an ID
    /// without one names a window that is gone or was never made, and
    /// whatever is asked of it is asked of no window: it is not the
    /// primary's to answer. A caller that wants the primary says so
    /// (`primarySelection`).
    func selection(_ id: WindowID) -> WindowSelection? {
        selections[id]
    }

    /// The tab each window draws: a scratch tab only in the window that
    /// draws it, and nothing of a hidden window. For what follows the tabs
    /// in front (the pane a runtime is shown in, which unread marks clear);
    /// the attention list's "seen" is `AttentionVisibility`'s.
    var shownTabIDs: Set<UUID> {
        Set(selections.values.filter(isDrawing).compactMap(\.activeTabID))
    }

    /// The session each shown window shows: what is in front somewhere. A
    /// window that shows nothing shows no session
    /// (`WindowSelection.isChoosingProject`).
    var shownContainerIDs: Set<ContainerID> {
        Set(selections.values.filter { !hiddenWindowIDs.contains($0.windowID) && !$0.isChoosingProject }.map(\.activeContainerID))
    }

    /// Whether the window draws its selection: it is shown, and draws the
    /// scratch tabs when they are what it has selected.
    private func isDrawing(_ selection: WindowSelection) -> Bool {
        !hiddenWindowIDs.contains(selection.windowID) && showsScratch(in: selection.windowID)
    }

    /// The windows that draw nothing of their selection: hidden, or on a
    /// scratch tab another window draws. One that leaves arrives at its
    /// tab then (`ActiveTabChanges`), so what it was not drawing is seen
    /// once it is.
    var undrawnWindowIDs: Set<WindowID> {
        Set(selections.values.filter { !isDrawing($0) }.map(\.windowID))
    }

    /// The shown windows that draw `tabID`, the primary first and the
    /// others by ID, so whoever asks which one gets the same answer. A
    /// scratch tab is shown only by the window that draws it.
    func windows(showing tabID: UUID) -> [WindowID] {
        orderedWindows { $0.activeTabID == tabID && isDrawing($0) }
    }

    /// The window that shows `paneID`'s tab (`windows(showing:)`), or `nil`
    /// when none does: where a drag of the pane, or a request that comes
    /// from the pane (goto_tab, the clipboard's confirmation), lands. A
    /// right-click or the pane's header acts in the window drawing the pane
    /// instead, which the pane's view names (`PaneHostRepresentable.window`).
    func window(showingPane paneID: UUID) -> WindowID? {
        tab(containing: paneID).flatMap { windows(showing: $0.id).first }
    }

    /// The windows whose selection has `tabID`, whether or not they draw it
    /// (`windows(showing:)` counts only those that do): the ones to move on
    /// when the tab leaves.
    func windows(selecting tabID: UUID) -> [WindowID] {
        orderedWindows { $0.activeTabID == tabID }
    }

    /// Adds the selection of a window past the primary.
    func addSelection(_ selection: WindowSelection) {
        selections[selection.windowID] = selection
    }

    /// Hands the primary's role to `window`, as the primary is
    /// about to close. The one place it changes, with
    /// `WindowRegistry.makePrimary`, which calls this. A window the session
    /// does not know takes nothing.
    func makePrimary(_ window: WindowID) {
        guard let selection = selections[window], selection !== primarySelection else { return }
        primarySelection = selection
    }

    /// Forgets a window that closed. What it showed of its project is
    /// kept as the project's view, so the project comes back as it was in
    /// whichever window shows it next (`projectViews`); a project the
    /// session no longer has keeps nothing. Whatever named the window lets
    /// it go: the window the person was last in, the scratch tabs' owner,
    /// the palette open in it.
    ///
    /// Work that still names the window once it is gone (a setup, an
    /// awaited open) finds no selection under it, and lands where work
    /// behind the person does (`intentAfterWait(from:)`). The primary is
    /// not removed: its role goes to another window first (`makePrimary`).
    func removeWindow(_ window: WindowID) {
        guard window != primaryWindowID, let selection = selections.removeValue(forKey: window) else { return }
        if let projectID = selection.shownProjectID, project(projectID) != nil,
           !selections.values.contains(where: { $0.shownProjectID == projectID })
        {
            projectViews[projectID] = selection.projectView(for: projectID)
        }
        if hiddenWindowIDs.contains(window) {
            hiddenWindowIDs.remove(window)
        }
        if frontWindowID == window {
            frontWindowID = nil
        }
        // The window that draws the scratch tabs is then the first shown
        // one that has them selected (`scratchDrawingWindowID`).
        if scratchOwnerWindowID == window {
            scratchOwnerWindowID = nil
        }
        if commandPaletteState?.windowID == window {
            commandPaletteState = nil
        }
    }

    /// Leaves the primary window alone, as a session is before its windows
    /// are made again (`restoreWindows`).
    func removeWindowsPastPrimary() {
        if selections.count > 1 {
            selections = [primaryWindowID: primarySelection]
        }
        if !hiddenWindowIDs.isEmpty {
            hiddenWindowIDs = []
        }
        scratchOwnerWindowID = nil
        frontWindowID = nil
    }

    /// Capped stack of tabs the user has closed since launch, ordered
    /// oldest-first. ⌘⇧T pops the back of the stack to bring a tab
    /// back at its old container + cwd, with the captured scrollback
    /// replayed into the fresh surface (the shell itself is a new
    /// process — there's nothing to revive). Transient: not persisted
    /// across launches, so a quit-restart wipes the history.
    var closedTabStack: [ClosedTab] = []
    static let closedTabStackLimit = 20

    /// The Project rootURLs used most recently (`noteProjectUsed`): the
    /// recent projects of the "+" menu and the palette, and the project a
    /// window takes when the one it shows is removed.
    var recentProjectPaths: [URL] = []

    static let recentProjectPathsLimit = 10

    /// Worktrees whose on-disk identity is currently being mutated by
    /// a Limpid-initiated git operation. Read-only from the outside —
    /// callers go through `withWorktreeMutationGated(_:_:)` to enter /
    /// leave the set so the contract is grep-able. GitSyncCoordinator
    /// is the consumer (skips reconciliation for in-flight ids).
    @ObservationIgnored private(set) var worktreeMutationsInFlight: Set<UUID> = []

    /// Live read of the scratch tabs' working-directory defaults. Injected
    /// by the app layer so `WorkspaceSession` (Core) doesn't have to import
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

    /// Per-pane transient UI state (bell ringing, child exit code).
    /// Lives here, *not* on `Tab.paneStates`, so flipping a bell flash
    /// or stamping a child-exit code doesn't reassign `tabs[idx]` —
    /// which would otherwise trip the autosave observation hook on
    /// every bell ring. UI observes this dict directly through the
    /// `@Observable` parent, so SwiftUI still re-renders on change.
    var paneTransients: [UUID: PaneTransients] = [:]

    /// Bumped whenever any surface reports a new cell size. A
    /// view that sizes itself to the grid reads it to re-render and then asks
    /// the surface for the live value: a surface off screen has no window to
    /// convert its pixels with, so a recorded value could go stale while the
    /// pane sat in another tab. Not persisted, and not in the autosave block.
    var cellSizeGeneration = 0
    /// Bumped when a pane's frame gives its terminal another grid, so a view
    /// showing columns × rows reads the surface again (the status band).
    /// Not persisted, and not in the autosave block.
    var terminalGridGeneration = 0
    /// Whether this run may write the person's files, as the app decided
    /// once at launch (false in demo mode). Read where the session writes
    /// outside its own snapshot: the scrollback files and their prune, and
    /// the record directories a pane's agent is told to write to.
    @ObservationIgnored var writesUserFiles = true
    /// The folder the panes' scrollback is saved in and replayed from, as
    /// the app hands it over at launch. Optional because a session made
    /// without one (a test, a preview) saves no scrollback and replays none,
    /// rather than reaching for the app's own folder.
    @ObservationIgnored var scrollbackFiles: ScrollbackFiles?

    /// paneID → tabID reverse index used by `tab(containing:)` and the
    /// per-pane state mutators it funnels through. Without it, every
    /// libghostty event (focus, occlusion, action) walks every tab's
    /// splitTree once — O(N tabs × L leaves) on the hottest event
    /// path. The cache rebuilds lazily when the signature (a hash of
    /// which leaves each tab holds, `paneIndexSignature`) changes. `@ObservationIgnored` so cache reads
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
        projects: [Project] = [],
        tabs: [Tab] = [],
        activeTabID: UUID? = nil,
        activeContainerID: ContainerID = .loose,
        sidebarWidth: CGFloat = SessionLayoutDefaults.sidebarWidth,
        recentProjectPaths: [URL] = []
    ) {
        self.projects = projects
        self.tabs = tabs
        let primary = WindowSelection(
            activeTabID: activeTabID,
            activeContainerID: activeContainerID,
            sidebarWidth: sidebarWidth
        )
        primarySelection = primary
        selections = [primary.windowID: primary]
        self.recentProjectPaths = recentProjectPaths
    }

    /// The tab `window` shows. A window the session does not know shows
    /// none.
    func activeTab(in window: WindowID) -> Tab? {
        guard let id = selection(window)?.activeTabID else { return nil }
        return tabs.first(where: { $0.id == id })
    }

    // MARK: - Container lookups (shared across views)

    /// Find a Project by id. Centralized so call sites don't sprinkle
    /// `session.projects.first(where: …)` everywhere.
    func project(_ id: UUID) -> Project? {
        projects.first(where: { $0.id == id })
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
    /// to resolve through `projects` / `worktrees` because a stale
    /// `ContainerID` (notification fired before a project or worktree
    /// was removed) would otherwise point the sidebar at a phantom row.
    func containerExists(_ container: ContainerID) -> Bool {
        switch container {
        case .loose:
            true
        case let .project(pid):
            project(pid) != nil
        case let .worktree(pid, wid):
            worktree(projectID: pid, worktreeID: wid) != nil
        }
    }

    /// Human-friendly label for the container. Used by the
    /// NotificationHistoryView and snapshotted onto entries so closed
    /// panes still surface "myapp / main". Scratch is the one name we
    /// supply, resolved in `locale`: the window's for a view, the app
    /// locale for a notification.
    func containerLabel(for container: ContainerID, locale: Locale) -> String {
        switch container {
        case .loose:
            return LocalizedStringResource("Scratch").resolved(in: locale)
        case let .project(pid):
            // The project's own folder by the project alone: the place line
            // and the history's groups name a project's items by it, and
            // the folder's row name is most often the project's own
            // folder name over again.
            return project(pid)?.name ?? "Project"
        case let .worktree(pid, _):
            // The worktree by its row's name (`RowName`), as the sidebar
            // shows it, so a notification names the row the person finds.
            let p = project(pid)?.name ?? "Project"
            let w = rowName(of: container)?.text ?? ""
            return w.isEmpty ? p : "\(p) / \(w)"
        }
    }

    // MARK: - Active tab selection

    /// Single entry point for changing the active tab. Maintains the
    /// active-selection invariant on `activeContainerID` by mirroring
    /// the resolved tab's container into it (non-nil case) and updates
    /// the owning Project's / Worktree's `lastActiveTabID`
    /// so re-entering the container restores the same tab.
    ///
    /// Passing `nil` clears `activeTabID` and **leaves
    /// `activeContainerID` alone** — used by close paths that intend
    /// to keep the sidebar selection on the now-empty container and
    /// let the caller decide the next active state.
    ///
    /// Writes `window`'s selection (switched to another project's tab's
    /// project), the window that shows that project, or a project's view,
    /// as `intent` decides
    /// (`window(for:askedOf:intent:)`). Every selection-changing entry
    /// point below takes the window and the intent the same way, both named
    /// by the caller, so none falls back to a window or a reason it was not
    /// given. A choice or a repair asked of a window the session does not
    /// know is written nowhere, not even as its container's last tab: no
    /// window that is there made it. Work behind does not land in the
    /// window it names, so it lands the same whether that window is gone
    /// or not. Only the person's choice moves the scratch tabs to the
    /// window (`SelectionIntent.claimsScratch`).
    ///
    /// Clearing the tab (`nil`) is a window's own: it stays in `window`,
    /// and is no work that ends behind.
    func setActiveTab(_ tabID: UUID?, in window: WindowID, intent: SelectionIntent) {
        let tab = tabID.flatMap { id in tabs.first { $0.id == id } }
        guard tab != nil || intent != .behind else { return }
        let target = if let tab {
            self.window(for: tab.container, askedOf: window, intent: intent)
        } else {
            selection(window).map(SelectionTarget.window)
        }
        guard let target else { return }
        setActiveTab(tabID, at: target, intent: intent)
    }

    /// Writes `tabID` as selected at `target`, already decided: a window's
    /// selection as `setActiveTab(_:in:intent:)` describes, or a project's
    /// view. A view is written as the window that left it would be: a
    /// repair always (what it held went away), work behind only over a row
    /// that shows no tab, as `SessionLaunchStore` leaves a window. A project
    /// with no view gets none (`SelectionTarget.memory`).
    ///
    /// `target` is one `window(for:askedOf:intent:)` or
    /// `selectionTargets(where:)` decided, never one a caller makes up:
    /// those two are where the switch and the protection of shown windows
    /// live. Work behind lands in a hidden window as in a view, by the same
    /// rule, and never in a shown one, so a shown window target for it is a
    /// mistake, and writes nothing.
    ///
    /// The row's last tab follows whatever shows it; when nothing does, it
    /// becomes the tab, so the row opens on it later.
    func setActiveTab(_ tabID: UUID?, at target: SelectionTarget, intent: SelectionIntent) {
        let tab = tabID.flatMap { id in tabs.first { $0.id == id } }
        switch target {
        case let .window(selection):
            if intent == .behind {
                guard hiddenWindowIDs.contains(selection.windowID) else {
                    assertionFailure("work behind written to a shown window's selection")
                    return
                }
                guard Self.place(on: selection.activeContainerID, showing: selection.activeTabID, takes: tab, for: intent) else {
                    if let tab, !holdsSelection(of: tab.container) {
                        rememberLastActive(tabID: tab.id, container: tab.container)
                    }
                    return
                }
            }
            selection.activeTabID = tabID
            guard let tabID, let tab else { return }
            selection.activeContainerID = tab.container
            if tab.container == .loose, intent.claimsScratch {
                claimScratch(for: selection.windowID)
            }
            rememberLastActive(tabID: tabID, container: tab.container)
        case let .memory(projectID):
            guard var view = projectViews[projectID],
                  Self.place(on: view.activeContainerID, showing: view.activeTabID, takes: tab, for: intent)
            else {
                if let tab, !holdsSelection(of: tab.container) {
                    rememberLastActive(tabID: tab.id, container: tab.container)
                }
                return
            }
            view.activeTabID = tab?.id
            if let tab {
                view.activeContainerID = tab.container
                rememberLastActive(tabID: tab.id, container: tab.container)
            }
            projectViews[projectID] = view
        }
    }

    /// Whether a project's view, or a hidden window, on `container` and
    /// `tabID` takes `tab` (`nil`: no tab) written for `intent`: a repair
    /// always; work behind only when it shows the tab's row with no tab in
    /// front, which is when a shown window would bring the tab forward
    /// (`SessionLaunchStore`).
    private static func place(on container: ContainerID, showing tabID: UUID?, takes tab: Tab?, for intent: SelectionIntent) -> Bool {
        guard intent == .behind else { return true }
        guard let tab else { return false }
        return container == tab.container && tabID == nil
    }

    /// Stamp the lastActive pointer of whichever project/worktree owns
    /// `container`. Loose has no parent to remember, so it's a no-op.
    func rememberLastActive(tabID: UUID, container: ContainerID) {
        switch container {
        case .loose:
            return
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

    /// Clear lastActive on whichever project/worktree owns `container`
    /// if it currently points at `tabID`. Mirror of
    /// `rememberLastActive` used by `closeTab`.
    func forgetLastActive(tabID: UUID, container: ContainerID) {
        switch container {
        case .loose:
            return
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
    // `WorkspaceSession+Navigation.swift`.

    /// Switch the selected container. If the target container has
    /// tabs, activate its `lastActiveTabID` (or the first one); if
    /// empty, leave `activeTabID` nil so the window shows the empty
    /// state. Either way the active-selection invariant on
    /// `activeContainerID` holds on return.
    ///
    /// Lands where `setActiveTab(_:in:intent:)` would (`window(for:askedOf:intent:)`).
    func setActiveContainer(_ container: ContainerID, in window: WindowID, intent: SelectionIntent) {
        guard let target = self.window(for: container, askedOf: window, intent: intent) else { return }
        admitWorktree(container, intent: intent)
        setActiveContainer(container, at: target, intent: intent)
    }

    /// Selects `container` at `target`, already decided as for
    /// `setActiveTab(_:at:intent:)`: a window's selection, or a project's
    /// view.
    ///
    /// A view, or a hidden window, takes an empty row for any intent, work
    /// behind included: a row asked for while the person was
    /// elsewhere (a worktree made while its window closed) is new, and the
    /// project should open on it. So an empty row passed with `.behind`
    /// must be one just made: an older empty row would pull the view or
    /// the hidden window off what it showed. A row with tabs is left to
    /// its tab, and work behind takes the tab only over a row that shows
    /// none, as a shown window would.
    func setActiveContainer(_ container: ContainerID, at target: SelectionTarget, intent: SelectionIntent) {
        if case let .window(selection) = target, intent == .behind, !hiddenWindowIDs.contains(selection.windowID) {
            assertionFailure("work behind written to a shown window's selection")
            return
        }
        let candidates = tabs(in: container)
        if candidates.isEmpty {
            // Empty container: this is the only place that mutates
            // `activeContainerID` without going through `setActiveTab`.
            // `activeTabID = nil` keeps the invariant vacuous.
            switch target {
            case let .window(selection):
                selection.activeContainerID = container
                selection.activeTabID = nil
                if container == .loose, intent.claimsScratch {
                    claimScratch(for: selection.windowID)
                }
            case let .memory(projectID):
                guard var view = projectViews[projectID] else { return }
                view.activeContainerID = container
                view.activeTabID = nil
                projectViews[projectID] = view
            }
            return
        }
        // Non-empty: `setActiveTab` will mirror the chosen tab's
        // container into `activeContainerID`, which equals
        // `container` because the candidate was taken from
        // `tabs(in: container)`.
        if let tabID = tabOpened(choosing: container) {
            setActiveTab(tabID, at: target, intent: intent)
        }
    }

    /// The tab choosing `container` opens on: its last tab while that is
    /// still in it, else its first; `nil` for a row with no tab. What a
    /// selection of the row lands on (`setActiveContainer(_:at:intent:)`),
    /// and what a window that shows nothing is saved on
    /// (`windowRecords`), since choosing the scratch row there opens it.
    func tabOpened(choosing container: ContainerID) -> UUID? {
        let candidates = tabs(in: container)
        if let last = lastActiveTabID(for: container), candidates.contains(where: { $0.id == last }) {
            return last
        }
        return candidates.first?.id
    }

    func lastActiveTabID(for container: ContainerID) -> UUID? {
        switch container {
        case .loose:
            nil
        case let .project(pid):
            projects.first(where: { $0.id == pid })?.lastActiveTabID
        case let .worktree(pid, wid):
            projects.first(where: { $0.id == pid })?
                .worktrees.first(where: { $0.id == wid })?.lastActiveTabID
        }
    }

    // MARK: - Activate a Project

    /// Click a Project header → activate its lastActiveTabID (or first
    /// existing tab in any of its containers), or auto-create a
    /// project-direct tab if the project is empty.
    @discardableResult
    func activateProject(_ projectID: UUID, in window: WindowID, intent: SelectionIntent) -> Tab? {
        // `lastActiveTabID` is sticky and outlives `moveTab`, so a tab
        // that was once in this project but has since been dragged
        // elsewhere still passes a naive `tabs.contains` check —
        // `setActiveTab(lastID)` would then jump the user into the
        // destination container instead of the project they clicked.
        // Filter on the tab's CURRENT container before honoring it.
        if let lastID = projects.first(where: { $0.id == projectID })?.lastActiveTabID,
           tabs.contains(where: { $0.id == lastID && $0.container.projectID == projectID })
        {
            setActiveTab(lastID, in: window, intent: intent)
            return tabs.first(where: { $0.id == lastID })
        }
        if let first = tabs.first(where: { $0.container.projectID == projectID }) {
            setActiveTab(first.id, in: window, intent: intent)
            return first
        }
        return openTab(container: .project(projectID), in: window, intent: intent, selects: true)
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
        if position == .after {
            insertAt += 1
        }
        array.insert(moved, at: insertAt)
    }

}
