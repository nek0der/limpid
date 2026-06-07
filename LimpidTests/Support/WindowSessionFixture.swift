// WindowSessionFixture.swift
// Limpid — reusable builders for the most common WindowSession test setups.
// Per-test `WindowSession() + addOrActivateProject(...)` boilerplate
// was duplicated across half a dozen suites; this folds it into one
// place so the call-site stays focused on the assertion.

import Foundation
@testable import Limpid

@MainActor
enum WindowSessionFixture {

    /// A blank session with one project pre-attached. The project's
    /// rootURL points at a unique tmp path (never `NSHomeDirectory()`)
    /// so the recent-projects list and Codable round-trips don't leak
    /// between runs.
    static func withProject(
        name: String = "test",
        rootURL: URL? = nil
    ) -> (session: WindowSession, project: Project) {
        let session = WindowSession()
        let url = rootURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("limpid-fixture-\(UUID().uuidString)")
        let project = session.addOrActivateProject(rootURL: url, suggestedName: name)
        return (session, project)
    }

    // Tuple returns keep test destructuring idiomatic; swiftlint's
    // 2-tuple ceiling is too tight for fixture return shapes here.
    // swiftlint:disable large_tuple

    /// A blank session with one group + one tab inside it. Returns the
    /// IDs callers most often need.
    static func withGroupAndOneTab(
        groupName: String = "Group"
    ) -> (session: WindowSession, group: TabGroup, tab: Tab) {
        let session = WindowSession()
        let group = session.addGroup(name: groupName)
        let tab = session.openTab(container: .group(group.id))
        return (session, group, tab)
    }

    /// A blank session with a single loose tab. Convenient for tests
    /// that need a real pane ID to mutate state against.
    static func withLooseTab() -> (session: WindowSession, tab: Tab, paneID: UUID) {
        let session = WindowSession()
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
        session: WindowSession, tabA: Tab, paneA: UUID, tabB: Tab, paneB: UUID
    ) {
        let session = WindowSession()
        let tabB = session.openTab(container: .loose) // opened first
        let tabA = session.openTab(container: .loose) // opened last → active
        let paneA = tabA.splitTree.allLeafIDs().first!
        let paneB = tabB.splitTree.allLeafIDs().first!
        return (session, tabA, paneA, tabB, paneB)
    }

    // swiftlint:enable large_tuple
}
