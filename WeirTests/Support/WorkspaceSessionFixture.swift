// WorkspaceSessionFixture.swift
// Weir — reusable builders for the most common WorkspaceSession test setups.
// One place for the `WorkspaceSession() + addOrActivateProject(...)` setup,
// so a call site stays focused on the assertion.

import Foundation
import Testing
@testable import Weir

@MainActor
enum WorkspaceSessionFixture {

    /// A unique root for a project, under the temporary directory and
    /// never created: the tests that take one only name a project by it,
    /// so the recent-projects list and Codable round-trips don't leak
    /// between runs. `name` keeps the folders told apart in a failure.
    nonisolated static func projectRootURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("weir-\(name)-\(UUID().uuidString)")
    }

    /// A blank session with one project pre-attached. The project's
    /// rootURL points at a unique tmp path (never `NSHomeDirectory()`)
    /// so the recent-projects list and Codable round-trips don't leak
    /// between runs.
    static func withProject(
        name: String = "test",
        rootURL: URL? = nil
    ) -> (session: WorkspaceSession, project: Project) {
        let session = WorkspaceSession()
        let url = rootURL ?? projectRootURL("fixture")
        let project = session.addOrActivateProject(rootURL: url, suggestedName: name)
        return (session, project)
    }

    // Tuple returns keep test destructuring idiomatic; swiftlint's
    // 2-tuple ceiling is too tight for fixture return shapes here.
    // swiftlint:disable large_tuple

    /// A blank session with a single loose tab. Convenient for tests
    /// that need a real pane ID to mutate state against.
    static func withLooseTab() -> (session: WorkspaceSession, tab: Tab, paneID: UUID) {
        let session = WorkspaceSession()
        let tab = session.openTab(container: .loose)
        // `Tab.newWithSinglePane` always seeds exactly one leaf, so the
        // force-unwrap is sound here. Tests still get a clear failure
        // (`fatal error`) rather than a silent nil propagation if the
        // invariant ever breaks.
        let paneID = tab.splitTree.allLeafIDs().first!
        return (session, tab, paneID)
    }

    /// A blank session with two loose tabs. The first is active; the
    /// second is left in place so cross-tab registry invariants (e.g.
    /// `PaneActions.closeActivePane` must NOT sweep surfaces in
    /// inactive tabs) have something to assert against.
    static func withTwoLooseTabs() -> (
        session: WorkspaceSession, tabA: Tab, paneA: UUID, tabB: Tab, paneB: UUID
    ) {
        let session = WorkspaceSession()
        let tabB = session.openTab(container: .loose) // opened first
        let tabA = session.openTab(container: .loose) // opened last → active
        let paneA = tabA.splitTree.allLeafIDs().first!
        let paneB = tabB.splitTree.allLeafIDs().first!
        return (session, tabA, paneA, tabB, paneB)
    }

    // swiftlint:enable large_tuple

    /// Adds a worktree row to `projectID`'s project directly, as a sync
    /// that found one would, with no `git` run: for the suites about what
    /// the rows do, not how they are found. The fields are
    /// `WorktreeFixture.make`'s.
    @discardableResult
    static func appendWorktree(
        to projectID: UUID,
        in session: WorkspaceSession,
        origin: WorktreeOrigin = .gitWorktree,
        isHidden: Bool = false,
        isMissing: Bool = false,
        admission: WorktreeAdmission? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Worktree {
        let worktree = WorktreeFixture.make(origin: origin, isHidden: isHidden, isMissing: isMissing, admission: admission)
        let index = try #require(session.projects.firstIndex { $0.id == projectID }, sourceLocation: sourceLocation)
        session.projects[index].worktrees.append(worktree)
        return worktree
    }

    /// Adds a window beside the primary, with a selection of its own on
    /// the scratch tabs, as each project's window has.
    static func addWindow(to session: WorkspaceSession) -> WindowID {
        let selection = WindowSelection()
        session.addSelection(selection)
        return selection.windowID
    }
}
