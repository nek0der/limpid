// WorkspaceSession+Windows.swift
// Weir — the windows past the primary and each project's view: switched in place, saved with the session, made again at launch.

import Foundation
import WeirDomain

@MainActor
extension WorkspaceSession {
    /// Every window, the primary first.
    var windowIDs: [WindowID] {
        orderedWindows { _ in true }
    }

    /// Switches `window` to `projectID` in place, or to no
    /// project (`nil`): the window then shows nothing and offers the
    /// projects to open (`WindowSelection.isChoosingProject`), except one
    /// already on a scratch tab, which stays on it, as what went is the
    /// project it named, not the tab it shows.
    /// What the window showed of the project it leaves is kept as that
    /// project's view while the session still has the project (a removed
    /// one keeps nothing), and the project it takes is put back as a window
    /// last left it (`enterProject`). The window's own state stays: its
    /// frame, its history, and its chrome, the sidebar and the changes
    /// panel as wide and as shown as they were (`ProjectView`).
    ///
    /// The app layer draws the switch as one change
    /// (`ProjectSwitchHandlers.drawsSwitch`): the selection, the view put
    /// back, and what the app layer is told on both sides land together,
    /// with nothing animated between the project left and the next.
    ///
    /// The app layer hears of the switch on both sides
    /// (`projectSwitching`): before, so what the window holds of the
    /// project it leaves goes with it, and after, so what the project kept
    /// while no window showed it comes back.
    ///
    /// The scratch tabs stay where they are drawn (`keepScratch`): the
    /// window gives them up as it leaves them, and does not take them from
    /// another window by coming back to a scratch tab it left.
    ///
    /// A window already showing `projectID` is left as it is. Who asks
    /// decides that no other window shows `projectID`: the person's choice
    /// (`window(for:askedOf:intent:)`), which brings that window forward
    /// instead, and a removal (`removeProject`), which takes only projects
    /// no other window shows.
    func showProject(_ projectID: UUID?, in window: WindowID, intent: SelectionIntent, reason: ProjectSwitchReason) {
        guard let selection = selection(window), selection.shownProjectID != projectID else { return }
        projectSwitching.drawsSwitch { switchProject(of: selection, to: projectID, intent: intent, reason: reason) }
    }

    /// The switch `showProject(_:in:intent:reason:)` draws as one change.
    private func switchProject(of selection: WindowSelection, to projectID: UUID?, intent: SelectionIntent, reason: ProjectSwitchReason) {
        let window = selection.windowID
        let left = selection.shownProjectID
        projectSwitching.willSwitchProject(window, left, projectID, reason)
        let drawer = scratchDrawingWindowID
        if let left, project(left) != nil {
            projectViews[left] = selection.projectView(for: left)
        }
        selection.projectID = projectID
        if let projectID {
            // The project the window takes is listed open, so what it
            // shows of the project is in sight. One the arrangement
            // has not met is left to the sidebar, which meets it in its
            // place and opens the window's project by default: meeting it
            // here would put it above the others not met yet.
            if selection.sidebarArrangement.collapsedProjects.contains(projectID) {
                selection.sidebarArrangement.collapsedProjects.remove(projectID)
            }
            selection.isChoosingProject = false
            enterProject(projectID, in: window, intent: intent)
        } else if selection.activeContainerID != .loose {
            // On the scratch row with no tab, so nothing of the scratch tabs
            // is drawn here until the person chooses them.
            selection.activeContainerID = .loose
            selection.activeTabID = nil
            selection.isChoosingProject = true
        }
        keepScratch(drawnBy: drawer, as: window)
        projectSwitching.didSwitchProject(window, projectID)
    }

    /// Puts `window`, which has just taken `projectID`, on what the project
    /// showed when a window last left it, and forgets that view: the window
    /// holds it from now on (`projectViews`). The window keeps its chrome
    /// (`WindowSelection.apply(_:)`); what the view showed is checked
    /// against the session first, as the tab may have closed or moved
    /// since (`restoreSelection`).
    ///
    /// A project no window has left has no view, and opens as a first
    /// visit: on its last session (`selectProject`), selected
    /// for `intent`, with the sidebar and the changes panel as the window
    /// has them, the panel's filter back on all conversations.
    ///
    /// Every way a window takes a project at run time goes through here,
    /// as a switch (`showProject(_:in:intent:reason:)`), so none leaves a
    /// view beside the window that shows its project. No selection enters
    /// another project before its window has taken that project: the
    /// person's choice switches the window first, and a repair or work
    /// behind lands in the project's view instead. The launch is the one
    /// way around: each window is made from its record, which holds what it
    /// showed (`restoreWindows`), and the views are read after, without
    /// those of the projects the records hold (`restoreProjectViews`).
    func enterProject(_ projectID: UUID, in window: WindowID, intent: SelectionIntent) {
        guard let selection = selection(window) else { return }
        guard let view = projectViews.removeValue(forKey: projectID) else {
            selection.changesPanelFilter = nil
            selectProject(projectID, in: window, intent: intent)
            return
        }
        selection.apply(view)
        restoreSelection(of: window, tabID: view.activeTabID, container: view.activeContainerID, in: projectID)
    }

    /// Puts `window` on the project: its session last used, or the
    /// project's folder with nothing open when it has none (no tab is made
    /// for it).
    func selectProject(_ projectID: UUID, in window: WindowID, intent: SelectionIntent) {
        if tabs.contains(where: { $0.container.projectID == projectID }) {
            activateProject(projectID, in: window, intent: intent)
        } else {
            setActiveContainer(.project(projectID), in: window, intent: intent)
        }
    }

    /// The windows a save writes: the shown ones, minimized ones
    /// included, the primary first; with none shown, the one hidden window
    /// the Dock brings back (the one the person was last in, else the
    /// first). A hidden window beside shown ones is not written: its
    /// project is saved as the project's view instead
    /// (`savedProjectViews`), as it would be had the window closed.
    ///
    /// A window that shows nothing is not written either
    /// (`WindowSelection.isChoosingProject`): it lasts only while the app
    /// runs. With nothing else to write, one of them is, as on the scratch
    /// tabs (`windowRecords`), so the next launch still has a window where
    /// the person left one, on the scratch tabs, as a launch with no saved
    /// window opens.
    var savedWindowIDs: [WindowID] {
        let all = windowIDs
        let ids = all.filter { selection($0)?.isChoosingProject == false }
        let shown = ids.filter { !hiddenWindowIDs.contains($0) }
        guard shown.isEmpty else { return shown }
        let front = lastFrontWindowID
        if ids.contains(front) {
            return [front]
        }
        if let first = ids.first {
            return [first]
        }
        return all.contains(front) ? [front] : Array(all.prefix(1))
    }

    /// Every window a save writes (`savedWindowIDs`), as it is saved. A
    /// window that shows nothing is written on the scratch row, on the tab
    /// choosing that row would open (`tabOpened(choosing:)`), or on the
    /// empty row when there is no scratch tab: what it comes back to
    /// (`restore(from:)`).
    func windowRecords() -> [WindowRecord] {
        let front = lastFrontWindowID
        return savedWindowIDs.compactMap { id in
            selection(id).map { selection in
                var record = WindowRecord(selection, isHidden: hiddenWindowIDs.contains(id), isFront: id == front)
                if selection.isChoosingProject {
                    record.activeTabID = tabOpened(choosing: .loose)
                }
                return record
            }
        }
    }

    /// Adds a window past the primary: New Window, or a project opened
    /// in a new window (⌘-click, ⌘Return). It takes the window's chrome
    /// from `origin`, the window it was asked from: the sidebar and the
    /// changes panel, as wide and as shown, the sidebar's projects in the
    /// same order and folded the same, which it keeps through every
    /// project it shows (`enterProject`), as a new Finder window opens
    /// with the sidebar of the one it came from. It has no frame of its
    /// own: the app layer places it on `origin`'s screen.
    ///
    /// With `projectID`, it takes the project as a window switching to it
    /// does (`showProject(_:in:intent:reason:)`), so the project's view comes
    /// back and is forgotten, and the app layer, told of the window first
    /// (`ProjectSwitchHandlers.didAddWindow`), hands it what else the
    /// project kept (its review tab, its scroll positions). The project is
    /// one no window shows, which the caller decides, and the person's
    /// choice (`noteProjectUsed`). With `nil`, the window shows nothing
    /// (`WindowSelection.isChoosingProject`).
    @discardableResult
    func addWindow(showing projectID: UUID?, layoutFrom origin: WindowID) -> WindowSelection {
        let selection = WindowSelection()
        if let template = self.selection(origin) {
            selection.sidebarWidth = template.sidebarWidth
            selection.sidebarHidden = template.sidebarHidden
            selection.isChangesPanelPresented = template.isChangesPanelPresented
            selection.changesPanelWidth = template.changesPanelWidth
            selection.changesPanelGrouping = template.changesPanelGrouping
            // The projects in the order, and folded as, the window the
            // person opened it from lists them; that window's own project
            // is another window's from here, which a header lists folded
            // (one not met yet folds by the default rule anyway).
            selection.sidebarArrangement = template.sidebarArrangement
            if let shown = template.shownProjectID, shown != projectID, template.sidebarArrangement.knows(shown) {
                selection.sidebarArrangement.setCollapsed(true, shown)
            }
        }
        selection.isChoosingProject = true
        addSelection(selection)
        projectSwitching.didAddWindow(selection)
        if let projectID, project(projectID) != nil {
            showProject(projectID, in: selection.windowID, intent: .person, reason: .person)
            noteProjectUsed(projectID)
        }
        return selection
    }

    /// Makes the windows of `records` again, after `restore(from:)`
    /// has put back the primary's selection and layout from the first
    /// record, which is the primary's. The primary's project is the one its
    /// restored selection is in, and the record's only while that selection
    /// is in none, so the two cannot name different projects.
    ///
    /// A later window whose project is gone, or already shown by an
    /// earlier window, is not made again: it would have nothing to show,
    /// or be a second window for its project. One whose tab is
    /// gone, or is in another project, goes back to its project
    /// (`selectProject`). Each window gets a new ID; nothing that is saved
    /// refers to one.
    ///
    /// `viewedProjects` are the projects with a view to be read next
    /// (`restoreProjectViews`): a primary saved on a scratch tab naming no
    /// project takes none of them, since taking one here would not put its
    /// view back (`enterProject`).
    func restoreWindows(from records: [WindowRecord], viewedProjects: Set<UUID>) {
        removeWindowsPastPrimary()
        guard let first = records.first else { return }
        // A primary saved on a scratch tab names no project. It takes the
        // first project no later record holds and no view remembers, here,
        // before the views are read, so the views are not read for a
        // project it already stands for. A project with a view is one a
        // window left: taking it would lose what that window showed, or
        // move this window off its scratch tab. With none left, it names
        // none.
        let laterProjects = Set(records.dropFirst().compactMap(\.projectID))
        primarySelection.projectID = primarySelection.activeContainerID.projectID
            ?? first.projectID.flatMap { project($0)?.id }
            ?? projects.first { !laterProjects.contains($0.id) && !viewedProjects.contains($0.id) }?.id
        var shownProjects = Set(primarySelection.shownProjectID.map { [$0] } ?? [])
        var restored: [(id: WindowID, record: WindowRecord)] = [(primaryWindowID, first)]
        for record in records.dropFirst() {
            guard let projectID = record.projectID, project(projectID) != nil,
                  !shownProjects.contains(projectID)
            else { continue }
            shownProjects.insert(projectID)
            let selection = WindowSelection(activeContainerID: .project(projectID), sidebarWidth: CGFloat(record.sidebarWidth))
            record.applyLayout(to: selection)
            selection.projectID = projectID
            addSelection(selection)
            restoreSelection(
                of: selection.windowID,
                tabID: record.activeTabID,
                container: record.activeContainerID,
                in: projectID
            )
            restored.append((selection.windowID, record))
        }
        for (id, record) in restored {
            setWindow(id, isHidden: record.isHidden)
        }
        frontWindowID = restored.first { $0.record.isFront }?.id
    }

    /// Puts back what a window showed of `projectID`, a later window's
    /// record or a project's view: its tab, while the tab is still there
    /// and in its project or the scratch tabs; else its container while
    /// that is still one of the project's, as an empty worktree is; else
    /// its project. Written into the selection directly, as a restore is,
    /// so putting a view back is not the person choosing the scratch tabs.
    private func restoreSelection(of window: WindowID, tabID: UUID?, container: ContainerID, in projectID: UUID) {
        guard let selection = selection(window) else { return }
        let tab = tabID.flatMap { id in tabs.first { $0.id == id } }
        if let tab, tab.container == .loose || tab.container.projectID == projectID, containerExists(tab.container) {
            selection.activeTabID = tab.id
            selection.activeContainerID = tab.container
        } else if container.projectID == projectID, containerExists(container), tabs(in: container).isEmpty {
            selection.activeTabID = nil
            selection.activeContainerID = container
        } else {
            selectProject(projectID, in: window, intent: .repair)
        }
    }

    /// The projects whose view a saved window record holds: those of the
    /// windows a save writes (`savedWindowIDs`). A project's view is saved
    /// by its window's record alone, so the two cannot disagree on the next
    /// launch.
    var projectsWithWindowRecords: Set<UUID> {
        Set(savedWindowIDs.compactMap { selection($0)?.shownProjectID })
    }

    /// The views a snapshot saves, in the projects' order so a save does
    /// not reorder them: those of the projects no window record holds, and
    /// what a hidden window a save does not write shows of its project
    /// (`savedWindowIDs`), so quitting then loses nothing it showed.
    func savedProjectViews() -> [ProjectView] {
        let recorded = projectsWithWindowRecords
        let written = Set(savedWindowIDs)
        var unwritten: [UUID: ProjectView] = [:]
        for id in windowIDs where !written.contains(id) {
            guard let selection = selection(id), let projectID = selection.shownProjectID, unwritten[projectID] == nil else {
                continue
            }
            unwritten[projectID] = selection.projectView(for: projectID)
        }
        return projects.compactMap { unwritten[$0.id] ?? projectViews[$0.id] }.filter { !recorded.contains($0.projectID) }
    }

    /// Takes the views a snapshot carried, once its windows are made again,
    /// with those an earlier build's hidden windows became
    /// (`WindowRecord.normalized`), which come first: a view of a project
    /// that is gone, or that a window record holds, is dropped, the record
    /// being what the window showed last. The first of two views of one
    /// project wins. Every view is replaced, so whatever is to be kept is
    /// in `views`.
    func restoreProjectViews(_ views: [ProjectView]) {
        let recorded = projectsWithWindowRecords
        var kept: [UUID: ProjectView] = [:]
        for view in views where project(view.projectID) != nil && !recorded.contains(view.projectID) {
            if kept[view.projectID] == nil {
                kept[view.projectID] = view
            }
        }
        projectViews = kept
    }

    /// The windows other than `window` by the project each shows, hidden
    /// ones included, read from the selections, which know every window as
    /// it is restored, before the app has listed them all. A project
    /// `window` shows is not listed; nor is a second window on one already
    /// listed, since no project is shown by two windows.
    func otherWindowsByProject(than window: WindowID) -> [UUID: WindowID] {
        let own = selection(window)?.shownProjectID
        var shown: [UUID: WindowID] = [:]
        for id in windowIDs where id != window {
            if let projectID = selection(id)?.shownProjectID, projectID != own, shown[projectID] == nil {
                shown[projectID] = id
            }
        }
        return shown
    }
}
