// RowRenameTests.swift
// Limpid — a sidebar row's name is kept on the row itself, with a tab's name and the checkout after it.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct RowRenameTests {
    /// A session with one project and one worktree row in it.
    private struct Fixture {
        let session: WorkspaceSession
        let project: Project
        let row: ContainerID
    }

    private static func fixture() throws -> Fixture {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let worktree = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session)
        return Fixture(session: session, project: project, row: .worktree(projectID: project.id, worktreeID: worktree.id))
    }

    /// A worktree with no tab is named as one with tabs is.
    @Test func renameRow_worktreeWithNoTabs_takesTheName() throws {
        let fixture = try Self.fixture()
        let (session, row) = (fixture.session, fixture.row)
        #expect(session.tabs(in: row).isEmpty)

        session.renameRow(row, to: "Release prep", runtimes: [])

        #expect(session.rowName(of: row) == RowName(text: "Release prep", source: .manual))
    }

    /// The project's own folder row keeps its name on the project, apart
    /// from the project's name.
    @Test func renameRow_projectFolder_keepsTheNameApartFromTheProjects() throws {
        let fixture = try Self.fixture()
        let (session, project) = (fixture.session, fixture.project)
        let folder = ContainerID.project(project.id)

        session.renameRow(folder, to: "Main checkout", runtimes: [])

        #expect(session.rowName(of: folder)?.text == "Main checkout")
        #expect(session.project(project.id)?.name == project.name)
        #expect(session.project(project.id)?.rootDisplayName == "Main checkout")
    }

    /// The name is the row's, so closing the tab it was given beside
    /// keeps it.
    @Test func renameRow_survivesClosingTheFirstTab() throws {
        let fixture = try Self.fixture()
        let (session, row) = (fixture.session, fixture.row)
        let first = session.openTab(container: row)
        session.openTab(container: row)

        session.renameRow(row, to: "Release prep", runtimes: [])
        session.closeTab(first.id)

        #expect(session.rowName(of: row)?.text == "Release prep")
    }

    /// The row's own name, then a name a tab was given, then what the
    /// checkout says.
    @Test func rowName_precedence_rowThenTabThenCheckout() throws {
        let fixture = try Self.fixture()
        let (session, row) = (fixture.session, fixture.row)
        let tab = session.openTab(container: row)
        let checkout = try #require(session.rowName(of: row))
        #expect(checkout.source != .manual)

        session.update(tab.id) { $0.rename("Tab name") }
        #expect(session.rowName(of: row) == RowName(text: "Tab name", source: .manual))

        session.renameRow(row, to: "Row name", runtimes: [])
        #expect(session.rowName(of: row) == RowName(text: "Row name", source: .manual))

        session.renameRow(row, to: "", runtimes: [])
        #expect(session.rowName(of: row) == RowName(text: "Tab name", source: .manual))

        session.update(tab.id) { $0.rename("") }
        #expect(session.rowName(of: row) == checkout)
    }

    /// An empty name clears the row's own, and the row goes back to the
    /// name it would have.
    @Test func renameRow_emptyName_clearsIt() throws {
        let fixture = try Self.fixture()
        let (session, project, row) = (fixture.session, fixture.project, fixture.row)
        let before = try #require(session.rowName(of: row))

        session.renameRow(row, to: "Release prep", runtimes: [])
        session.renameRow(row, to: "", runtimes: [])

        #expect(session.rowName(of: row) == before)
        let worktreeID = try #require(row.worktreeID)
        #expect(session.worktree(projectID: project.id, worktreeID: worktreeID)?.displayName == nil)
    }

    /// A row named only by a tab's name, as an earlier build named it,
    /// clears that name when the person clears the row's: the row goes back
    /// to its checkout rather than showing the same name again.
    @Test func renameRow_emptyName_onARowNamedByATab_clearsTheTabsName() throws {
        let fixture = try Self.fixture()
        let (session, row) = (fixture.session, fixture.row)
        let shell = session.openTab(container: row)
        let named = session.openTab(container: row)
        let checkout = try #require(session.rowName(of: row))
        session.update(named.id) { $0.rename("Earlier name") }

        session.renameRow(row, to: "", runtimes: [])

        #expect(session.rowName(of: row) == checkout)
        #expect(session.tab(named.id)?.titleOverride == nil)
        #expect(session.tab(shell.id)?.titleOverride == nil)
    }

    /// A worktree Limpid makes again in a folder whose row it kept is new
    /// work: the old row's name does not carry over to it.
    @Test func attachGitWorktree_onAKeptRow_dropsItsName() throws {
        let fixture = try Self.fixture()
        let (session, project, row) = (fixture.session, fixture.project, fixture.row)
        let worktreeID = try #require(row.worktreeID)
        let folder = try #require(session.worktree(projectID: project.id, worktreeID: worktreeID)?.workingDirectory)
        session.renameRow(row, to: "Old work", runtimes: [])

        let attached = session.attachGitWorktree(projectID: project.id, label: "feat/new", workingDirectory: folder, branchName: "feat/new")

        #expect(attached?.id == worktreeID)
        #expect(attached?.displayName == nil)
    }

    /// The migration rule: a name an earlier build kept on a tab is never
    /// moved or cleared. It still names the row until the row is given
    /// one, and the tab keeps it after.
    @Test func renameRow_leavesTheTabsOwnNameAsItIs() throws {
        let fixture = try Self.fixture()
        let (session, row) = (fixture.session, fixture.row)
        let tab = session.openTab(container: row)
        session.update(tab.id) { $0.rename("Earlier name") }

        session.renameRow(row, to: "New name", runtimes: [])

        #expect(session.tab(tab.id)?.titleOverride == "Earlier name")
        #expect(session.rowName(of: row)?.text == "New name")
    }

    /// The scratch row is named by its own word and takes no name.
    @Test func renameRow_scratch_changesNothing() {
        let (session, _) = WorkspaceSessionFixture.withProject()
        session.renameRow(.loose, to: "Anything", runtimes: [])
        #expect(session.rowName(of: .loose) == nil)
    }

    /// Both names are written with the session and read back.
    @Test func rowNames_surviveASaveAndALoad() throws {
        let fixture = try Self.fixture()
        let (session, project, row) = (fixture.session, fixture.project, fixture.row)
        session.renameRow(row, to: "Release prep", runtimes: [])
        session.renameRow(.project(project.id), to: "Main checkout", runtimes: [])

        try withTempDir { dir in
            SessionStore(directory: dir).saveSynchronously(session.makeSnapshot())
            guard case let .loaded(snapshot) = SessionStore(directory: dir).load() else {
                Issue.record("expected the saved session to load")
                return
            }
            let restored = WorkspaceSession()
            _ = restored.restore(from: snapshot)
            #expect(restored.rowName(of: row)?.text == "Release prep")
            #expect(restored.rowName(of: .project(project.id))?.text == "Main checkout")
        }
    }

    /// A worktree and a project from a file written before rows kept
    /// their own names read as unnamed; one with a name writes the key.
    @Test func worktreeAndProject_withoutTheKey_readAsUnnamed() throws {
        var worktree = WorktreeFixture.make()
        worktree.displayName = "Release prep"
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(worktree)) as? [String: Any])
        #expect(json["displayName"] as? String == "Release prep")
        // As an earlier build of this release carried it, among the keys it
        // did not know: read as the name, and not kept twice.
        let carried = try JSONDecoder().decode(Worktree.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(carried.displayName == "Release prep")
        #expect(carried.unknownFields.isEmpty)
        json["displayName"] = nil
        let decoded = try JSONDecoder().decode(Worktree.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.displayName == nil)
        #expect(decoded.unknownFields.isEmpty)

        var project = Project(name: "p", rootURL: WorkspaceSessionFixture.projectRootURL("row-name"))
        project.rootDisplayName = "Main checkout"
        var projectJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        #expect(projectJSON["rootDisplayName"] as? String == "Main checkout")
        projectJSON["rootDisplayName"] = nil
        let decodedProject = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: projectJSON))
        #expect(decodedProject.rootDisplayName == nil)
    }

    /// A name of another type costs the name, not the row.
    @Test func worktree_nameOfAnotherType_readsAsUnnamed() throws {
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(WorktreeFixture.make(label: "feat"))) as? [String: Any]
        )
        json["displayName"] = 3
        let decoded = try JSONDecoder().decode(Worktree.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.displayName == nil)
        #expect(decoded.label == "feat")
    }
}
