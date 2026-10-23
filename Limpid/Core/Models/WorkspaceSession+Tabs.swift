// WorkspaceSession+Tabs.swift
// Limpid — Tab CRUD, derived per-container views, and drag-drop reorder /
// cross-container move. Each window's active-tab pointer lives on its
// `WindowSelection`, and the setters that keep the sidebar-row
// selection invariant (`setActiveTab(_:in:intent:)`,
// `setActiveContainer(_:in:intent:)`) stay in `WorkspaceSession.swift`;
// everything that lives _inside_ the flat `tabs` array belongs here.

import Foundation

extension WorkspaceSession {

    // MARK: - Tab CRUD

    /// Open a tab in a specific container, selected in `window` for
    /// `intent` (`setActiveTab(_:in:intent:)`) when it `selects`.
    ///
    /// A tab that does not select opens behind whatever is shown: no
    /// window or view changes, and the row's last tab becomes it only when
    /// nothing holds the row (`holdsSelection(of:)`). Whoever shows the row
    /// (a shell of it in front, say) keeps it on what they have, and coming
    /// back to the row from elsewhere finds the same tab.
    @discardableResult
    func openTab(
        container: ContainerID,
        title: String? = nil,
        workingDirectory: URL? = nil,
        in window: WindowID,
        intent: SelectionIntent,
        selects: Bool
    ) -> Tab {
        let resolvedWD: URL? = switch container {
        case .loose:
            workingDirectory ?? scratchStartDirectory(in: window)
        case .project, .worktree:
            workingDirectory ?? rootDirectory(of: container)
        }
        // Initial title matches what the shell sets it to (OSC 2) moments
        // later — the working directory as the shell shows it, with $HOME
        // collapsed to "~" (`TitleFormatting.pwdStyle`). Skipping a placeholder ("scratch" / project
        // name) avoids a visible flash when the shell
        // overwrites it.
        let resolvedTitle = title ?? TitleFormatting.pwdStyle(for: resolvedWD)
        let (tab, _) = Tab.newWithSinglePane(
            title: resolvedTitle,
            workingDirectory: resolvedWD?.path,
            container: container
        )
        tabs.append(tab)
        admitWorktree(container, intent: intent)
        if selects {
            setActiveTab(tab.id, in: window, intent: intent)
        } else if !holdsSelection(of: container) {
            rememberLastActive(tabID: tab.id, container: container)
        }
        return tab
    }

    /// The directory a project or worktree container stands for: the
    /// worktree's checkout, falling back to the project root. Scratch
    /// tabs have no directory of their own.
    func rootDirectory(of container: ContainerID) -> URL? {
        switch container {
        case .loose:
            return nil
        case let .project(pid):
            return projects.first(where: { $0.id == pid })?.rootURL
        case let .worktree(pid, wid):
            let project = projects.first(where: { $0.id == pid })
            let worktree = project?.worktrees.first(where: { $0.id == wid })
            return worktree?.workingDirectory ?? project?.rootURL
        }
    }

    /// Where a new scratch tab in `window` starts, as Settings' scratch
    /// folder says; nil leaves it to libghostty, which starts in home.
    func scratchStartDirectory(in window: WindowID) -> URL? {
        let defaults = quickTabDefaultsProvider()
        return resolveCwdMode(defaults.mode, path: defaults.path, in: window)
    }

    /// Resolve a `WorkingDirectoryMode` to a concrete cwd URL, or nil
    /// to fall through to libghostty's home-on-launch default.
    ///   - `.home`            → the user's home directory.
    ///   - `.inheritPrevious` → `window`'s active tab's *live* cwd (the
    ///     window the new tab opens in). We prefer `pwd` (kept current by
    ///     libghostty's PWD action as the shell `cd`s) and fall back to the
    ///     tab's launch `workingDirectory` before the first PWD report. Nil
    ///     when there's no active tab or it has neither (preserves the
    ///     home-on-launch behavior).
    ///   - `.fixed`           → `path` (nil when unset).
    func resolveCwdMode(_ mode: WorkingDirectoryMode, path: URL?, in window: WindowID) -> URL? {
        switch mode {
        case .home:
            FileManager.default.homeDirectoryForCurrentUser
        case .inheritPrevious:
            activeTab(in: window).flatMap { $0.pwd ?? $0.workingDirectory }.map { URL(fileURLWithPath: $0) }
        case .fixed:
            path
        }
    }

    /// What was staged for `paneID`'s first start: the command its shell
    /// types, the file holding the first instruction its agent takes, and
    /// the agent's executable as the new worktree sheet found it. The
    /// shell keeps the variables for as long as the pane is open: the
    /// file is gone after the first take, and the executable is a fallback
    /// the shim reaches only when the shell's `PATH` has no agent
    /// (`Tab.initialAgentExecutables`).
    struct StagedLaunch: Equatable {
        let command: String
        let promptFile: String?
        var agentExecutable: AgentInstallation?

        /// What the pane's shell is given for this launch, beside every
        /// pane's own variables: Limpid's environment has none of these.
        var environment: [String: String] {
            var environment: [String: String] = [:]
            if let promptFile {
                environment[InitialPromptFile.environmentKey] = promptFile
            }
            if let agentExecutable {
                environment[AgentCatalog.entry(for: agentExecutable.kind).foundExecutableVariable] = agentExecutable.executable
            }
            return environment
        }
    }

    /// The launch staged for `paneID`, read without changing anything: it
    /// is read while SwiftUI evaluates a body, where changing the session
    /// would invalidate the view being drawn. `clearStagedLaunch` removes
    /// it once that evaluation is over.
    func stagedLaunch(paneID: UUID) -> StagedLaunch? {
        guard let tab = tab(containing: paneID),
              let command = tab.initialCommands[paneID], !command.isEmpty
        else { return nil }
        return StagedLaunch(
            command: command,
            promptFile: tab.initialPromptFiles[paneID],
            agentExecutable: tab.initialAgentExecutables[paneID]
        )
    }

    /// Stages `installation` beside the agent command already staged for
    /// `paneID`: the shim starts that executable when the pane's own `PATH`
    /// has no agent. Nothing happens for a pane without a staged command:
    /// there would be no launch to carry it.
    func stageAgentExecutable(_ installation: AgentInstallation, paneID: UUID) {
        guard let tab = tab(containing: paneID), tab.initialCommands[paneID] != nil else { return }
        update(tab.id) {
            $0.initialAgentExecutables[paneID] = installation
        }
    }

    /// Removes the staged launch once its surface is made: it runs once.
    /// Left in the saved tab, it would run again at every launch and,
    /// ranking above the resume builders, start a fresh agent where the
    /// pane's conversation should resume.
    func clearStagedLaunch(paneID: UUID) {
        guard let tab = tab(containing: paneID),
              tab.initialCommands[paneID] != nil || tab.initialPromptFiles[paneID] != nil
              || tab.initialAgentExecutables[paneID] != nil
        else { return }
        update(tab.id) {
            $0.initialCommands.removeValue(forKey: paneID)
            $0.initialPromptFiles.removeValue(forKey: paneID)
            $0.initialAgentExecutables.removeValue(forKey: paneID)
        }
    }

    /// Open a tab in the selected row. Honors the sidebar's selection
    /// rather than re-using the active tab's container — important when
    /// the user has navigated into an empty row and hits ⌘T: the new tab should land there,
    /// not in whichever container last had focus. A window the session
    /// does not know has no scope, and opens nothing.
    @discardableResult
    func openTabInActiveScope(in window: WindowID, intent: SelectionIntent) -> Tab? {
        guard let selection = selection(window) else { return nil }
        return openTab(container: selection.activeContainerID, in: selection.windowID, intent: intent, selects: true)
    }

    /// The launch's one rule for tabs: a session with no tab at
    /// all opens one in the primary's row, the scratch row on a first
    /// launch, so the window has a terminal to draw. Put there for the
    /// window, not chosen by the person. A session with any tab opens none,
    /// even with no scratch tab: the primary saved on the scratch row comes
    /// back on the empty row (`restore(from:)`). Returns the tab opened.
    @discardableResult
    func openLaunchTabIfNone() -> Tab? {
        guard tabs.isEmpty else { return nil }
        return openTabInActiveScope(in: primaryWindowID, intent: .repair)
    }

    /// Close the tab. Focus migrates to a neighbor in the same
    /// container, or stays nil if the container is now empty so the session
    /// area can render the empty state.
    func closeTab(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let closing = tabs[index]
        // Position of the closing tab within its container, captured
        // before removal so we can hand focus to its neighbor.
        let positionInContainer = tabs(in: closing.container)
            .firstIndex(where: { $0.id == tabID })
        // Drop any in-pane search state for the panes inside this
        // tab — without this the entries linger in
        // `paneSearchStates` after the SurfaceView is unregistered.
        for leafID in closing.splitTree.allLeafIDs() {
            paneSearchStates.removeValue(forKey: leafID)
            paneTransients.removeValue(forKey: leafID)
        }
        tabs.remove(at: index)

        // Every window that showed it moves on, not only the one that
        // closed it, and so does the view of a project no window shows:
        // the tab is gone for all of them.
        for target in selectionTargets(where: { $1 == tabID }) {
            // Hand focus to the neighbor in the *same* container: the
            // next tab (one down / right), falling back to the
            // previous (one up / left) when we closed the last one.
            // After removal the next tab has shifted into the closing
            // tab's index, so the same position points at it; an
            // out-of-range position means we closed the tail, so use
            // the new last tab. We never jump to a different container
            // — that would silently switch the user out of the
            // container they were looking at.
            let remaining = tabs(in: closing.container)
            let successor: Tab? = if let pos = positionInContainer, pos < remaining.count {
                remaining[pos]
            } else {
                remaining.last
            }
            setActiveTab(successor?.id, at: target, intent: .repair)
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
            if case .loose = $0.container {
                return true
            }
            return false
        }
    }

    /// Tabs directly under a Project, in its root folder rather than in a
    /// worktree.
    func directTabs(in projectID: UUID) -> [Tab] {
        tabs.filter {
            if case let .project(pid) = $0.container, pid == projectID {
                return true
            }
            return false
        }
    }

    /// Tabs under a specific Worktree.
    func tabs(inProject projectID: UUID, worktree worktreeID: UUID) -> [Tab] {
        tabs.filter {
            if case let .worktree(pid, wid) = $0.container,
               pid == projectID, wid == worktreeID
            {
                return true
            }
            return false
        }
    }

    /// Tabs in the given container — single entry point for a row's tab
    /// list. Routes to the specialized filter above.
    func tabs(in container: ContainerID) -> [Tab] {
        switch container {
        case .loose: looseTabs
        case let .project(pid): directTabs(in: pid)
        case let .worktree(pid, wid): tabs(inProject: pid, worktree: wid)
        }
    }

    /// The panes of every tab in `container`.
    func paneIDs(in container: ContainerID) -> Set<UUID> {
        Set(tabs(in: container).flatMap { $0.splitTree.allLeafIDs() })
    }

    /// The panes every tab holds: the ones still alive.
    var allPaneIDs: Set<UUID> {
        Set(tabs.flatMap { $0.splitTree.allLeafIDs() })
    }

    // MARK: - Cross-container move (sidebar drag-drop)

    /// Move the tab into a different container. Used by the sidebar's
    /// drag handler. No-op when the target equals the current container.
    /// Drop semantics:
    ///   1. tab.container is rewritten
    ///   2. tab is moved to the end of `tabs` (appears at the bottom of
    ///      the destination's tab list)
    ///   3. every window or view that showed the tab stays on the source
    ///      container, on the neighbor that slid into its place (or none
    ///      when the source is empty)
    func moveTab(_ tabID: UUID, to target: ContainerID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        if tabs[index].container == target {
            return
        }
        let sourceContainer = tabs[index].container
        // Every window that has it selected, drawn or not: one left on it
        // would draw it once it is no longer a scratch tab. And every view
        // that has it, which would open on it in its new container.
        let holders = selectionTargets(where: { $1 == tabID })
        // Clear the source's `lastActiveTabID` before the tab leaves
        // — otherwise a later `activateProject` sees the stale id
        // and silently jumps to whichever container the tab landed
        // in. `closeTab` already does the equivalent sweep; symmetry
        // here keeps the
        // `lastActiveTabID ∈ tabs(in: thisContainer)` invariant.
        forgetLastActive(tabID: tabID, container: sourceContainer)
        var moved = tabs.remove(at: index)
        moved.container = target
        // A tab moved into a project starts its panes where the tab opened,
        // as a tab moved between projects does; the folder default it kept
        // from a group was for the scratch tabs. Its name prefix and color
        // stay with it.
        if target.projectID != nil {
            moved.cwdMode = nil
            moved.cwdPath = nil
        }
        tabs.append(moved)
        // Stay on the source container — yanking the user across
        // to the destination on every drag feels like a bug. For
        // active-tab drags promote the sibling that slid into the
        // vacated slot (activate the tab to the right); empty
        // source falls through to `setActiveTab(nil)`.
        // Each window or view that showed it stays on the source the same
        // way.
        for target in holders {
            let nextAfter = tabs[index...].first { $0.container == sourceContainer }
            let prevBefore = tabs[..<index].last { $0.container == sourceContainer }
            setActiveTab((nextAfter ?? prevBefore)?.id, at: target, intent: .repair)
        }
    }

    /// Reorder a tab within the same container — `tabID` is moved so it
    /// sits immediately before `beforeID` in the global `tabs` array.
    /// Passing `beforeID == nil` appends to the end.
    func reorderTab(_ tabID: UUID, before beforeID: UUID?) {
        // Dropping before yourself is a no-op. Guard it explicitly:
        // otherwise `remove` drops the source first, `beforeID` is then
        // not found, and we'd `append` it to the very end. Mirrors the
        // `sourceID != targetID` guard in `reorderInPlace`.
        guard beforeID != tabID else { return }
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
        // Dropping after yourself is a no-op — same append-to-end hazard
        // as the `before` overload.
        guard afterID != tabID else { return }
        guard let from = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let moved = tabs.remove(at: from)
        guard let toBase = tabs.firstIndex(where: { $0.id == afterID }) else {
            tabs.append(moved)
            return
        }
        tabs.insert(moved, at: toBase + 1)
    }
}
