// WorkspaceSessionContainersTests.swift
// Limpid — covers the Project CRUD, palette, and removal that live in
// `WorkspaceSession+Containers.swift`. These are all pure data mutations,
// so the suite is in-memory only; the worktree leg is tested in
// `WorkspaceSessionWorktreeTests`.

import Foundation
import Testing
@testable import Limpid

@Suite("WorkspaceSession +Containers")
@MainActor
struct WorkspaceSessionContainersTests {
    private typealias Fixture = WorkspaceSessionFixture

    // MARK: - addOrActivateProject

    @Test("addOrActivateProject appends a new Project and assigns a palette slot")
    func addOrActivateProject_newPath_appendsProject() {
        let session = WorkspaceSession()
        let project = session.addOrActivateProject(rootURL: Fixture.projectRootURL("containers"), suggestedName: "Alpha")
        #expect(session.projects.count == 1)
        #expect(session.projects.first?.id == project.id)
        #expect(project.name == "Alpha")
        #expect(project.paletteIndex == 0)
    }

    @Test("addOrActivateProject defaults the name to the last path component when none is supplied")
    func addOrActivateProject_noName_usesLastPathComponent() {
        let session = WorkspaceSession()
        let project = session.addOrActivateProject(rootURL: Fixture.projectRootURL("containers").appendingPathComponent("myrepo"))
        #expect(project.name == "myrepo")
    }

    @Test("addOrActivateProject is idempotent on the same standardized path")
    func addOrActivateProject_existingPath_noDuplicate() {
        let session = WorkspaceSession()
        let url = Fixture.projectRootURL("containers")
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
        let session = WorkspaceSession()
        let url = Fixture.projectRootURL("containers")
        let first = session.addOrActivateProject(rootURL: url)
        // The newly-added path does not auto-activate, so we manually
        // park the session elsewhere before re-adding.
        session.setActiveContainer(.loose)
        _ = session.addOrActivateProject(rootURL: url)
        #expect(session.primarySelection.activeContainerID == .project(first.id))
    }

    @Test("addOrActivateProject promotes the URL to the head of recentProjectPaths")
    func addOrActivateProject_promotesRecentPath() {
        let session = WorkspaceSession()
        let a = Fixture.projectRootURL("containers").appendingPathComponent("a")
        let b = Fixture.projectRootURL("containers").appendingPathComponent("b")
        _ = session.addOrActivateProject(rootURL: a)
        _ = session.addOrActivateProject(rootURL: b)
        _ = session.addOrActivateProject(rootURL: a)
        #expect(session.recentProjectPaths.first?.standardizedFileURL == a.standardizedFileURL)
    }

    // MARK: - Tabs by container

    @Test("directTabs(in:) returns only tabs anchored directly to that project")
    func directTabsInProject_returnsOnlyProjectTabs() {
        let (s, p) = WorkspaceSessionFixture.withProject()
        let direct = s.openTab(container: .project(p.id))
        #expect(s.directTabs(in: p.id).map(\.id) == [direct.id])
    }

    @Test("looseTabs returns only tabs in the loose container")
    func looseTabs_returnsOnlyLooseTabs() {
        let (s, p) = WorkspaceSessionFixture.withProject()
        let a = s.openTab(container: .loose)
        _ = s.openTab(container: .project(p.id))
        #expect(s.looseTabs.map(\.id) == [a.id])
    }

    @Test("setActiveContainer to an empty container leaves activeTabID nil")
    func setActiveContainer_emptyContainer_leavesActiveTabNil() {
        let (s, p) = WorkspaceSessionFixture.withProject()
        s.setActiveContainer(.project(p.id))
        #expect(s.primarySelection.activeContainerID == .project(p.id))
        #expect(s.primarySelection.activeTabID == nil)
    }

    @Test("setActiveContainer to a populated container activates its first tab")
    func setActiveContainer_populatedContainer_activatesFirstTab() {
        let (s, p) = WorkspaceSessionFixture.withProject()
        let tab = s.openTab(container: .project(p.id))
        s.primarySelection.activeTabID = nil
        s.setActiveContainer(.project(p.id))
        #expect(s.primarySelection.activeTabID == tab.id)
    }

    // MARK: - rename

    @Test("renameProject updates the matching project's name")
    func renameProject_knownID_updatesName() {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "Old")
        session.renameProject(project.id, to: "New")
        #expect(session.projects.first?.name == "New")
    }

    @Test("renameProject is a no-op when the id is unknown")
    func renameProject_unknownID_isNoOp() {
        let (session, _) = WorkspaceSessionFixture.withProject(name: "Keep")
        session.renameProject(UUID(), to: "Ignored")
        #expect(session.projects.first?.name == "Keep")
    }

    // MARK: - palette

    @Test("setProjectPaletteIndex writes the value through")
    func setProjectPaletteIndex_writesValue() {
        let (session, project) = WorkspaceSessionFixture.withProject()
        session.setProjectPaletteIndex(project.id, to: 3)
        #expect(session.projects.first?.paletteIndex == 3)
        session.setProjectPaletteIndex(project.id, to: nil)
        #expect(session.projects.first?.paletteIndex == nil)
    }

    // MARK: - removeProject

    @Test("removeProject drops the project + its tabs, leaves other containers' tabs alone, returns the freed pane IDs")
    func removeProject_dropsProjectAndReturnsLeafIDs() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
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
        let (session, project) = WorkspaceSessionFixture.withProject()
        session.setActiveContainer(.project(project.id))
        _ = session.removeProject(project.id)
        #expect(session.primarySelection.activeContainerID == .loose)
    }

    @Test("removeProject leaves the active container alone when a different project was active")
    func removeProject_nonActive_keepsActiveContainer() {
        let session = WorkspaceSession()
        let keep = session.addOrActivateProject(rootURL: Fixture.projectRootURL("containers").appendingPathComponent("keep"))
        let drop = session.addOrActivateProject(rootURL: Fixture.projectRootURL("containers").appendingPathComponent("drop"))
        session.setActiveContainer(.project(keep.id))
        _ = session.removeProject(drop.id)
        #expect(session.primarySelection.activeContainerID == .project(keep.id))
    }

    @Test("removeProject on an unknown id returns an empty list and leaves state untouched")
    func removeProject_unknownID_returnsEmpty() {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let freed = session.removeProject(UUID())
        #expect(freed.isEmpty)
        #expect(session.projects.first?.id == project.id)
    }
}
