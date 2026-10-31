// LinkBaseDirectoriesTests.swift
// Weir — pins where a relative path printed in a pane is looked up.

import Foundation
import Testing
@testable import Weir

@MainActor
struct LinkBaseDirectoriesTests {
    @Test func paneDirectoryComesBeforeTheProjectRoot() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let tab = session.openTab(container: .project(project.id), workingDirectory: project.rootURL)
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        session.setWorkingDirectory(paneID: paneID, path: "/tmp/weir-elsewhere")

        #expect(
            session.linkBaseDirectories(paneID: paneID)
                == [URL(fileURLWithPath: "/tmp/weir-elsewhere"), project.rootURL]
        )
    }

    /// The tab's launch directory and the project root are usually the same
    /// place, and it is listed once.
    @Test func duplicateDirectoriesAreListedOnce() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let tab = session.openTab(container: .project(project.id))
        let paneID = try #require(tab.splitTree.allLeafIDs().first)

        #expect(session.linkBaseDirectories(paneID: paneID).map(\.standardizedFileURL) == [project.rootURL.standardizedFileURL])
    }

    /// A loose tab has no container directory to fall back on: the pane's
    /// directory, then the one the tab started in, and nothing after them.
    @Test func looseTabUsesOnlyItsOwnDirectories() {
        let (session, tab, paneID) = WorkspaceSessionFixture.withLooseTab()
        session.update(tab.id) { $0.workingDirectory = "/tmp/weir-loose-start" }
        session.setWorkingDirectory(paneID: paneID, path: "/tmp/weir-loose")

        #expect(
            session.linkBaseDirectories(paneID: paneID)
                == [URL(fileURLWithPath: "/tmp/weir-loose"), URL(fileURLWithPath: "/tmp/weir-loose-start")]
        )
    }
}
