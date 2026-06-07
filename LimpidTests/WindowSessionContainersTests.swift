// WindowSessionContainersTests.swift
// Limpid — covers the Group/Project CRUD, palette, single-step move,
// drag-reorder, removal, and container column navigation surface that lives in
// `WindowSession+Containers.swift`. These are all pure data mutations,
// so the suite is in-memory only; the worktree leg is tested in
// `WindowSessionWorktreeTests`.

import Foundation
import Testing
@testable import Limpid

@Suite("WindowSession +Containers")
@MainActor
struct WindowSessionContainersTests {

    // MARK: - Helpers

    /// Unique tmp URL per call. We never touch the filesystem here — the
    /// URL is only stored on Project/Worktree — but using `/tmp/<uuid>`
    /// keeps any accidental file IO out of the user's home.
    private func tmpURL(_ suffix: String = "") -> URL {
        let base = "/tmp/limpid-\(UUID().uuidString)"
        return URL(fileURLWithPath: suffix.isEmpty ? base : "\(base)/\(suffix)")
    }

    /// Append a worktree to the project with the given id. Returns the
    /// worktree so the caller can assert on its id.
    @discardableResult
    private func appendWorktree(
        to projectID: UUID,
        in session: WindowSession,
        isHidden: Bool = false
    ) throws -> Worktree {
        var wt = Worktree(
            label: "wt",
            workingDirectory: tmpURL("wt"),
            origin: .userPinned
        )
        wt.isHidden = isHidden
        let idx = try #require(session.projects.firstIndex(where: { $0.id == projectID }))
        session.projects[idx].worktrees.append(wt)
        return wt
    }

    // MARK: - addOrActivateProject

    @Test("addOrActivateProject appends a new Project and assigns a palette slot")
    func addOrActivateProject_newPath_appendsProject() {
        let session = WindowSession()
        let project = session.addOrActivateProject(rootURL: tmpURL(), suggestedName: "Alpha")
        #expect(session.projects.count == 1)
        #expect(session.projects.first?.id == project.id)
        #expect(project.name == "Alpha")
        #expect(project.paletteIndex == 0)
    }

    @Test("addOrActivateProject defaults the name to the last path component when none is supplied")
    func addOrActivateProject_noName_usesLastPathComponent() {
        let session = WindowSession()
        let project = session.addOrActivateProject(rootURL: tmpURL("myrepo"))
        #expect(project.name == "myrepo")
    }

    @Test("addOrActivateProject is idempotent on the same standardized path")
    func addOrActivateProject_existingPath_noDuplicate() {
        let session = WindowSession()
        let url = tmpURL()
        let first = session.addOrActivateProject(rootURL: url, suggestedName: "A")
        let again = session.addOrActivateProject(rootURL: url, suggestedName: "Renamed")
        #expect(session.projects.count == 1)
        #expect(again.id == first.id)
        // The activate path must not rename — naming is a separate
        // explicit user action via `renameProject`.
        #expect(session.projects.first?.name == "A")
    }

    @Test("addOrActivateProject on an existing project activates it instead of just returning")
    func addOrActivateProject_existingPath_activatesContainer() {
        let session = WindowSession()
        let url = tmpURL()
        let first = session.addOrActivateProject(rootURL: url)
        // The newly-added path does not auto-activate, so we manually
        // park the session elsewhere before re-adding.
        session.setActiveContainer(.loose)
        _ = session.addOrActivateProject(rootURL: url)
        #expect(session.activeContainerID == .project(first.id))
    }

    @Test("addOrActivateProject promotes the URL to the head of recentProjectPaths")
    func addOrActivateProject_promotesRecentPath() {
        let session = WindowSession()
        let a = tmpURL("a")
        let b = tmpURL("b")
        _ = session.addOrActivateProject(rootURL: a)
        _ = session.addOrActivateProject(rootURL: b)
        _ = session.addOrActivateProject(rootURL: a)
        #expect(session.recentProjectPaths.first?.standardizedFileURL == a.standardizedFileURL)
    }

    // MARK: - addGroup

    @Test("addGroup appends a TabGroup and cycles the palette index")
    func addGroup_cyclesPaletteIndex() {
        let session = WindowSession()
        let g0 = session.addGroup(name: "G0")
        let g1 = session.addGroup(name: "G1")
        #expect(session.groups.count == 2)
        #expect(g0.paletteIndex == 0)
        #expect(g1.paletteIndex == 1)
    }

    // MARK: - rename

    @Test("renameGroup updates the matching group's name")
    func renameGroup_knownID_updatesName() {
        let session = WindowSession()
        let g = session.addGroup(name: "Old")
        session.renameGroup(g.id, to: "New")
        #expect(session.groups.first?.name == "New")
    }

    @Test("renameGroup is a no-op when the id is unknown")
    func renameGroup_unknownID_isNoOp() {
        let session = WindowSession()
        let g = session.addGroup(name: "Old")
        session.renameGroup(UUID(), to: "Ignored")
        #expect(session.groups.first?.name == "Old")
        #expect(session.groups.first?.id == g.id)
    }

    @Test("renameProject updates the matching project's name")
    func renameProject_knownID_updatesName() {
        let (session, project) = WindowSessionFixture.withProject(name: "Old")
        session.renameProject(project.id, to: "New")
        #expect(session.projects.first?.name == "New")
    }

    @Test("renameProject is a no-op when the id is unknown")
    func renameProject_unknownID_isNoOp() {
        let (session, _) = WindowSessionFixture.withProject(name: "Keep")
        session.renameProject(UUID(), to: "Ignored")
        #expect(session.projects.first?.name == "Keep")
    }

    // MARK: - palette

    @Test("setGroupPaletteIndex writes the value through")
    func setGroupPaletteIndex_writesValue() {
        let session = WindowSession()
        let g = session.addGroup()
        session.setGroupPaletteIndex(g.id, to: 5)
        #expect(session.groups.first?.paletteIndex == 5)
        session.setGroupPaletteIndex(g.id, to: nil)
        #expect(session.groups.first?.paletteIndex == nil)
    }

    @Test("setGroupPaletteIndex on an unknown id leaves state unchanged")
    func setGroupPaletteIndex_unknownID_isNoOp() {
        let session = WindowSession()
        let g = session.addGroup()
        let before = session.groups.first?.paletteIndex
        session.setGroupPaletteIndex(UUID(), to: 7)
        #expect(session.groups.first?.paletteIndex == before)
    }

    @Test("setProjectPaletteIndex writes the value through")
    func setProjectPaletteIndex_writesValue() {
        let (session, project) = WindowSessionFixture.withProject()
        session.setProjectPaletteIndex(project.id, to: 3)
        #expect(session.projects.first?.paletteIndex == 3)
        session.setProjectPaletteIndex(project.id, to: nil)
        #expect(session.projects.first?.paletteIndex == nil)
    }

    // MARK: - toggleProjectExpanded

    @Test("toggleProjectExpanded flips the expanded flag")
    func toggleProjectExpanded_flipsFlag() throws {
        let (session, project) = WindowSessionFixture.withProject()
        let initial = try #require(session.projects.first?.isExpanded)
        session.toggleProjectExpanded(project.id)
        #expect(session.projects.first?.isExpanded == !initial)
        session.toggleProjectExpanded(project.id)
        #expect(session.projects.first?.isExpanded == initial)
    }

    @Test("toggleProjectExpanded on an unknown id is a no-op")
    func toggleProjectExpanded_unknownID_isNoOp() {
        let (session, _) = WindowSessionFixture.withProject()
        let before = session.projects.first?.isExpanded
        session.toggleProjectExpanded(UUID())
        #expect(session.projects.first?.isExpanded == before)
    }

    // MARK: - move up/down + can-move predicates

    @Test("moveGroupUp swaps the group with its predecessor")
    func moveGroupUp_middle_swapsWithPredecessor() {
        let session = WindowSession()
        let a = session.addGroup(name: "A")
        let b = session.addGroup(name: "B")
        let c = session.addGroup(name: "C")
        session.moveGroupUp(b.id)
        #expect(session.groups.map(\.id) == [b.id, a.id, c.id])
    }

    @Test("moveGroupUp on the first row is a no-op")
    func moveGroupUp_firstRow_isNoOp() {
        let session = WindowSession()
        let a = session.addGroup(name: "A")
        let b = session.addGroup(name: "B")
        session.moveGroupUp(a.id)
        #expect(session.groups.map(\.id) == [a.id, b.id])
    }

    @Test("moveGroupDown swaps the group with its successor")
    func moveGroupDown_middle_swapsWithSuccessor() {
        let session = WindowSession()
        let a = session.addGroup(name: "A")
        let b = session.addGroup(name: "B")
        let c = session.addGroup(name: "C")
        session.moveGroupDown(b.id)
        #expect(session.groups.map(\.id) == [a.id, c.id, b.id])
    }

    @Test("moveGroupDown on the last row is a no-op")
    func moveGroupDown_lastRow_isNoOp() {
        let session = WindowSession()
        let a = session.addGroup(name: "A")
        let b = session.addGroup(name: "B")
        session.moveGroupDown(b.id)
        #expect(session.groups.map(\.id) == [a.id, b.id])
    }

    @Test("canMoveGroupUp / Down report the boundary correctly")
    func canMoveGroup_reportsBoundaries() {
        let session = WindowSession()
        let a = session.addGroup(name: "A")
        let b = session.addGroup(name: "B")
        let c = session.addGroup(name: "C")
        #expect(session.canMoveGroupUp(a.id) == false)
        #expect(session.canMoveGroupUp(b.id) == true)
        #expect(session.canMoveGroupDown(b.id) == true)
        #expect(session.canMoveGroupDown(c.id) == false)
        #expect(session.canMoveGroupUp(UUID()) == false)
        #expect(session.canMoveGroupDown(UUID()) == false)
    }

    @Test("moveProjectUp / Down + canMoveProjectUp / Down mirror the group helpers")
    func moveProject_mirrorsGroupBehaviour() {
        let session = WindowSession()
        let a = session.addOrActivateProject(rootURL: tmpURL("a"))
        let b = session.addOrActivateProject(rootURL: tmpURL("b"))
        let c = session.addOrActivateProject(rootURL: tmpURL("c"))
        session.moveProjectUp(b.id)
        #expect(session.projects.map(\.id) == [b.id, a.id, c.id])
        session.moveProjectDown(a.id)
        #expect(session.projects.map(\.id) == [b.id, c.id, a.id])
        #expect(session.canMoveProjectUp(b.id) == false)
        #expect(session.canMoveProjectDown(a.id) == false)
        #expect(session.canMoveProjectUp(UUID()) == false)
        #expect(session.canMoveProjectDown(UUID()) == false)
    }

    // MARK: - drag reorder

    @Test("reorderGroup(.before) drops the source ahead of the target")
    func reorderGroup_before_dropsAheadOfTarget() {
        let session = WindowSession()
        let a = session.addGroup(name: "A")
        let b = session.addGroup(name: "B")
        let c = session.addGroup(name: "C")
        session.reorderGroup(sourceID: c.id, target: a.id, position: .before)
        #expect(session.groups.map(\.id) == [c.id, a.id, b.id])
    }

    @Test("reorderGroup(.after) drops the source behind the target")
    func reorderGroup_after_dropsBehindTarget() {
        let session = WindowSession()
        let a = session.addGroup(name: "A")
        let b = session.addGroup(name: "B")
        let c = session.addGroup(name: "C")
        session.reorderGroup(sourceID: a.id, target: b.id, position: .after)
        #expect(session.groups.map(\.id) == [b.id, a.id, c.id])
    }

    @Test("reorderGroup is a no-op when source or target is unknown")
    func reorderGroup_unknownID_isNoOp() {
        let session = WindowSession()
        let a = session.addGroup(name: "A")
        let b = session.addGroup(name: "B")
        let before = session.groups.map(\.id)
        session.reorderGroup(sourceID: UUID(), target: a.id, position: .before)
        session.reorderGroup(sourceID: a.id, target: UUID(), position: .after)
        #expect(session.groups.map(\.id) == before)
        #expect(session.groups.count == 2)
        #expect(session.groups.last?.id == b.id)
    }

    @Test("reorderProject(.before) drops the source ahead of the target")
    func reorderProject_before_dropsAheadOfTarget() {
        let session = WindowSession()
        let a = session.addOrActivateProject(rootURL: tmpURL("a"))
        let b = session.addOrActivateProject(rootURL: tmpURL("b"))
        let c = session.addOrActivateProject(rootURL: tmpURL("c"))
        session.reorderProject(sourceID: c.id, target: a.id, position: .before)
        #expect(session.projects.map(\.id) == [c.id, a.id, b.id])
    }

    @Test("reorderProject(.after) drops the source behind the target")
    func reorderProject_after_dropsBehindTarget() {
        let session = WindowSession()
        let a = session.addOrActivateProject(rootURL: tmpURL("a"))
        let b = session.addOrActivateProject(rootURL: tmpURL("b"))
        let c = session.addOrActivateProject(rootURL: tmpURL("c"))
        session.reorderProject(sourceID: a.id, target: b.id, position: .after)
        #expect(session.projects.map(\.id) == [b.id, a.id, c.id])
    }

    @Test("reorderProject is a no-op when source or target is unknown")
    func reorderProject_unknownID_isNoOp() {
        let session = WindowSession()
        let a = session.addOrActivateProject(rootURL: tmpURL("a"))
        let b = session.addOrActivateProject(rootURL: tmpURL("b"))
        let before = session.projects.map(\.id)
        session.reorderProject(sourceID: UUID(), target: a.id, position: .before)
        session.reorderProject(sourceID: a.id, target: UUID(), position: .after)
        #expect(session.projects.map(\.id) == before)
        #expect(session.projects.last?.id == b.id)
    }

    // MARK: - removeGroup

    @Test("removeGroup drops the group + its tabs, leaves other containers' tabs alone, returns the freed pane IDs")
    func removeGroup_dropsGroupAndReturnsLeafIDs() throws {
        let (session, group, tab) = WindowSessionFixture.withGroupAndOneTab()
        // A loose tab + a tab in a second group must survive the removal.
        let survivingLoose = session.openTab(container: .loose)
        let keep = session.addGroup(name: "Keep")
        let survivingInKeep = session.openTab(container: .group(keep.id))

        let leaf = try #require(tab.splitTree.allLeafIDs().first)
        let freed = session.removeGroup(group.id)

        #expect(session.groups.map(\.id) == [keep.id])
        #expect(Set(session.tabs.map(\.id)) == [survivingLoose.id, survivingInKeep.id])
        #expect(freed == [leaf])
    }

    @Test("removeGroup falls back to .loose when the deleted group was active")
    func removeGroup_active_resetsActiveContainerToLoose() {
        let (session, group, _) = WindowSessionFixture.withGroupAndOneTab()
        session.setActiveContainer(.group(group.id))
        _ = session.removeGroup(group.id)
        #expect(session.activeContainerID == .loose)
    }

    @Test("removeGroup leaves the active container alone when a different group was active")
    func removeGroup_nonActive_keepsActiveContainer() {
        let session = WindowSession()
        let keep = session.addGroup(name: "Keep")
        let drop = session.addGroup(name: "Drop")
        session.setActiveContainer(.group(keep.id))
        _ = session.removeGroup(drop.id)
        #expect(session.activeContainerID == .group(keep.id))
    }

    @Test("removeGroup on an unknown id returns an empty list and leaves state untouched")
    func removeGroup_unknownID_returnsEmpty() {
        let session = WindowSession()
        let g = session.addGroup()
        let freed = session.removeGroup(UUID())
        #expect(freed.isEmpty)
        #expect(session.groups.first?.id == g.id)
    }

    // MARK: - removeProject

    @Test("removeProject drops the project + its tabs, leaves other containers' tabs alone, returns the freed pane IDs")
    func removeProject_dropsProjectAndReturnsLeafIDs() throws {
        let (session, project) = WindowSessionFixture.withProject()
        let tab = session.openTab(container: .project(project.id))
        let survivingLoose = session.openTab(container: .loose)

        let leaf = try #require(tab.splitTree.allLeafIDs().first)
        let freed = session.removeProject(project.id)

        #expect(session.projects.isEmpty)
        #expect(session.tabs.map(\.id) == [survivingLoose.id])
        #expect(freed == [leaf])
    }

    @Test("removeProject resets activeContainerID to .loose when the project was active")
    func removeProject_active_resetsActiveContainerToLoose() {
        let (session, project) = WindowSessionFixture.withProject()
        session.setActiveContainer(.project(project.id))
        _ = session.removeProject(project.id)
        #expect(session.activeContainerID == .loose)
    }

    @Test("removeProject leaves the active container alone when a different project was active")
    func removeProject_nonActive_keepsActiveContainer() {
        let session = WindowSession()
        let keep = session.addOrActivateProject(rootURL: tmpURL("keep"))
        let drop = session.addOrActivateProject(rootURL: tmpURL("drop"))
        session.setActiveContainer(.project(keep.id))
        _ = session.removeProject(drop.id)
        #expect(session.activeContainerID == .project(keep.id))
    }

    @Test("removeProject on an unknown id returns an empty list and leaves state untouched")
    func removeProject_unknownID_returnsEmpty() {
        let (session, project) = WindowSessionFixture.withProject()
        let freed = session.removeProject(UUID())
        #expect(freed.isEmpty)
        #expect(session.projects.first?.id == project.id)
    }

    // MARK: - container column navigation

    @Test("topLevelContainers lists loose first, then groups, then projects in order")
    func topLevelContainers_ordersLooseGroupsProjects() {
        let session = WindowSession()
        let g = session.addGroup(name: "G")
        let p = session.addOrActivateProject(rootURL: tmpURL())
        #expect(session.topLevelContainers == [.loose, .group(g.id), .project(p.id)])
    }

    @Test("activateTopLevelContainer(at:) jumps to the indexed container")
    func activateTopLevelContainer_validIndex_setsActive() {
        let session = WindowSession()
        let g = session.addGroup(name: "G")
        session.activateTopLevelContainer(at: 1)
        #expect(session.activeContainerID == .group(g.id))
    }

    @Test("activateTopLevelContainer(at:) clamps out-of-range indices to a no-op")
    func activateTopLevelContainer_outOfRange_isNoOp() {
        let session = WindowSession()
        _ = session.addGroup(name: "G")
        let before = session.activeContainerID
        session.activateTopLevelContainer(at: 99)
        session.activateTopLevelContainer(at: -1)
        #expect(session.activeContainerID == before)
    }

    @Test("cycleTopLevelContainer walks forward and wraps at the end")
    func cycleTopLevelContainer_forward_wrapsAround() {
        let session = WindowSession()
        let g = session.addGroup(name: "G")
        let p = session.addOrActivateProject(rootURL: tmpURL())
        // Starts at .loose.
        session.cycleTopLevelContainer(forward: true)
        #expect(session.activeContainerID == .group(g.id))
        session.cycleTopLevelContainer(forward: true)
        #expect(session.activeContainerID == .project(p.id))
        session.cycleTopLevelContainer(forward: true)
        #expect(session.activeContainerID == .loose)
    }

    @Test("cycleTopLevelContainer walks backward and wraps at the start")
    func cycleTopLevelContainer_backward_wrapsAround() {
        let session = WindowSession()
        let g = session.addGroup(name: "G")
        let p = session.addOrActivateProject(rootURL: tmpURL())
        session.cycleTopLevelContainer(forward: false)
        #expect(session.activeContainerID == .project(p.id))
        session.cycleTopLevelContainer(forward: false)
        #expect(session.activeContainerID == .group(g.id))
        session.cycleTopLevelContainer(forward: false)
        #expect(session.activeContainerID == .loose)
    }

    @Test("flatNavigableContainers interleaves visible worktrees directly after their project, in declaration order")
    func flatNavigableContainers_ordersGroupsThenProjectsWithWorktrees() throws {
        let session = WindowSession()
        let g = session.addGroup(name: "G")
        let p1 = session.addOrActivateProject(rootURL: tmpURL("p1"))
        let p2 = session.addOrActivateProject(rootURL: tmpURL("p2"))
        let wt = try appendWorktree(to: p1.id, in: session)
        #expect(session.flatNavigableContainers == [
            .loose,
            .group(g.id),
            .project(p1.id),
            .worktree(projectID: p1.id, worktreeID: wt.id),
            .project(p2.id)
        ])
    }

    @Test("flatNavigableContainers omits hidden worktrees but keeps the parent project")
    func flatNavigableContainers_skipsHiddenWorktrees() throws {
        let session = WindowSession()
        let p = session.addOrActivateProject(rootURL: tmpURL())
        let wt = try appendWorktree(to: p.id, in: session, isHidden: true)
        #expect(!session.flatNavigableContainers.contains(.worktree(projectID: p.id, worktreeID: wt.id)))
        #expect(session.flatNavigableContainers.contains(.project(p.id)))
    }
}
