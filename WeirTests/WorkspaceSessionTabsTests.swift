// WorkspaceSessionTabsTests.swift
// Weir — covers the tab-level mutation surface that lives in
// `WorkspaceSession+Tabs.swift` (open, find, close, move, reorder). Pure
// in-memory mutations; no filesystem or libghostty involvement.

import Foundation
import Testing
@testable import Weir

@Suite("WorkspaceSession +Tabs")
@MainActor
struct WorkspaceSessionTabsTests {

    // MARK: - Helpers

    /// Three-piece test setup; struct rather than tuple so swiftlint's
    /// `large_tuple` rule stays happy.
    private struct Fixture {
        let session: WorkspaceSession
        let sourceID: UUID
        let tabs: [Tab]
    }

    /// Build a session with a source project containing `count` tabs.
    /// Tabs are returned in insertion order; the last one is active
    /// because `openTab` activates whatever it creates.
    private func makeSession(sourceTabCount: Int) -> Fixture {
        let session = WorkspaceSession()
        let source = Self.addProject(to: session, name: "Source")
        var madeTabs: [Tab] = []
        for _ in 0..<sourceTabCount {
            madeTabs.append(session.openTab(container: .project(source.id)))
        }
        return Fixture(session: session, sourceID: source.id, tabs: madeTabs)
    }

    /// A project at a path of its own, never touched on disk.
    private static func addProject(to session: WorkspaceSession, name: String) -> Project {
        session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL(name), suggestedName: name)
    }

    // MARK: - openTab / tab(containing:)

    @Test("openTab(.loose) adds the tab and activates it")
    func openTab_loose_addsAndActivates() {
        let s = WorkspaceSession()
        let tab = s.openTab(container: .loose)
        #expect(s.tabs.count == 1)
        #expect(s.primarySelection.activeTabID == tab.id)
        guard case .loose = tab.container else {
            Issue.record("expected .loose")
            return
        }
    }

    @Test("openTab(.project) anchors the tab to that project and leaves the worktree empty")
    func openTab_project_anchorsProjectAndOmitsWorktree() {
        let (s, p) = WorkspaceSessionFixture.withProject()
        let tab = s.openTab(container: .project(p.id))
        #expect(tab.projectID == p.id)
        #expect(tab.worktreeID == nil)
    }

    @Test("tab(containing:) finds the tab that owns a given pane")
    func tabContaining_knownPane_returnsOwningTab() throws {
        let s = WorkspaceSession()
        let tab = s.openTab(container: .loose)
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        #expect(s.tab(containing: paneID)?.id == tab.id)
    }

    @Test("tab(containing:) follows a pane merged into another tab when the totals stay the same")
    func tabContaining_afterMergeKeepingCounts_returnsNewTab() throws {
        let s = WorkspaceSession()
        let source = s.openTab(container: .loose)
        let target = s.openTab(container: .loose)
        s.setActiveTab(source.id)
        PaneActions.split(s, direction: .horizontal)
        let moved = try #require(s.tab(source.id)?.splitTree.allLeafIDs().last)
        // Prime the index before the move, the way any earlier lookup would.
        #expect(s.tab(containing: moved)?.id == source.id)

        // Two tabs holding 2 + 1 leaves before and 1 + 2 after.
        TabActions.mergePaneIntoTab(s, paneID: moved, into: target.id)

        #expect(s.tab(containing: moved)?.id == target.id)
    }

    @Test("tab(containing:) returns nil for an unknown pane id")
    func tabContaining_unknownPane_returnsNil() {
        let s = WorkspaceSession()
        _ = s.openTab(container: .loose)
        #expect(s.tab(containing: UUID()) == nil)
    }

    // MARK: - closeTab

    @Test("closeTab removes the tab from the list")
    func closeTab_removesFromList() {
        let s = WorkspaceSession()
        let a = s.openTab(container: .loose)
        let b = s.openTab(container: .loose)
        let paneID = a.splitTree.allLeafIDs()[0]
        s.setWorkingDirectory(paneID: paneID, path: "/tmp/transient")
        s.closeTab(a.id)
        #expect(s.tabs.count == 1)
        #expect(s.tabs.first?.id == b.id)
        #expect(s.workingDirectory(paneID: paneID) == nil)
    }

    @Test("closeTab focuses the next tab (one down/right)")
    func closeTab_active_focusesNext() {
        let s = WorkspaceSession()
        s.openTab(container: .loose)
        let b = s.openTab(container: .loose)
        let c = s.openTab(container: .loose)
        s.setActiveTab(b.id)
        s.closeTab(b.id)
        // Closing the middle tab hands focus to the next one (c),
        // not the container's last tab.
        #expect(s.primarySelection.activeTabID == c.id)
    }

    @Test("closeTab on the last tab falls back to the previous one")
    func closeTab_active_lastFallsBackToPrevious() {
        let s = WorkspaceSession()
        s.openTab(container: .loose)
        let b = s.openTab(container: .loose)
        let c = s.openTab(container: .loose)
        s.setActiveTab(c.id)
        s.closeTab(c.id)
        // No next tab exists, so focus moves to the previous (b).
        #expect(s.primarySelection.activeTabID == b.id)
    }

    // MARK: - moveTab

    @Test("non-active tab drag leaves activeContainerID and activeTabID untouched")
    func moveTab_nonActiveDrag_leavesViewUnchanged() {
        let fx = makeSession(sourceTabCount: 2)
        let target = Self.addProject(to: fx.session, name: "Target")
        // openTab activates each newly-created tab, so we rewind to
        // the first one so the second one is the *non-active* one we
        // want to drag.
        fx.session.setActiveTab(fx.tabs[0].id)
        let nonActive = fx.tabs[1]

        fx.session.moveTab(nonActive.id, to: .project(target.id))

        #expect(fx.session.primarySelection.activeContainerID == .project(fx.sourceID))
        #expect(fx.session.primarySelection.activeTabID == fx.tabs[0].id)
        #expect(fx.session.tab(nonActive.id)?.container == .project(target.id))
    }

    @Test("active tab drag promotes the right-hand sibling in the source container")
    func moveTab_activeDrag_promotesRightNeighbor() {
        let fx = makeSession(sourceTabCount: 3)
        let target = Self.addProject(to: fx.session, name: "Target")
        fx.session.setActiveTab(fx.tabs[0].id)

        fx.session.moveTab(fx.tabs[0].id, to: .project(target.id))

        // The selection stays on the source container; activeTabID falls
        // onto the tab that slid into the vacated slot, fx.tabs[1].
        #expect(fx.session.primarySelection.activeContainerID == .project(fx.sourceID))
        #expect(fx.session.primarySelection.activeTabID == fx.tabs[1].id)
    }

    @Test("active tab drag from the end of the container falls back to the predecessor")
    func moveTab_activeDragFromEnd_promotesPredecessor() {
        let fx = makeSession(sourceTabCount: 2)
        let target = Self.addProject(to: fx.session, name: "Target")
        // openTab leaves the most recently created tab active, so
        // the second one is already the active end-of-list candidate.

        fx.session.moveTab(fx.tabs[1].id, to: .project(target.id))

        #expect(fx.session.primarySelection.activeContainerID == .project(fx.sourceID))
        #expect(fx.session.primarySelection.activeTabID == fx.tabs[0].id)
    }

    @Test("dragging the only tab out of a container clears activeTabID without moving container column")
    func moveTab_lastActiveTab_leavesContainerEmpty() {
        let fx = makeSession(sourceTabCount: 1)
        let target = Self.addProject(to: fx.session, name: "Target")

        fx.session.moveTab(fx.tabs[0].id, to: .project(target.id))

        // The selection stays on the source container so the user keeps the
        // same sidebar row and sees its empty state there.
        #expect(fx.session.primarySelection.activeContainerID == .project(fx.sourceID))
        #expect(fx.session.primarySelection.activeTabID == nil)
    }

    @Test("moving a tab to its own container is a no-op")
    func moveTab_sameContainer_isNoOp() {
        let fx = makeSession(sourceTabCount: 2)
        fx.session.setActiveTab(fx.tabs[0].id)
        let snapshotBefore = fx.session.tabs.map(\.id)

        fx.session.moveTab(fx.tabs[1].id, to: .project(fx.sourceID))

        #expect(fx.session.tabs.map(\.id) == snapshotBefore)
        #expect(fx.session.primarySelection.activeTabID == fx.tabs[0].id)
    }

    // MARK: - reorderTab

    // `performDrop` fires `onDrop` for a same-list reorder again once the
    // dragged row has slid under the cursor, calling
    // `reorderTab(src, before/after: src)`: a tab placed against itself
    // stays where it is, and a drag to the top lands at the top.

    @Test("reordering a tab before itself leaves the order unchanged")
    func reorderTab_beforeSelf_isNoOp() {
        let fx = makeSession(sourceTabCount: 3)
        let before = fx.session.tabs.map(\.id)

        fx.session.reorderTab(fx.tabs[2].id, before: fx.tabs[2].id)

        #expect(fx.session.tabs.map(\.id) == before)
    }

    @Test("reordering a tab after itself leaves the order unchanged")
    func reorderTab_afterSelf_isNoOp() {
        let fx = makeSession(sourceTabCount: 3)
        let before = fx.session.tabs.map(\.id)

        fx.session.reorderTab(fx.tabs[2].id, after: fx.tabs[2].id)

        #expect(fx.session.tabs.map(\.id) == before)
    }

    @Test("dragging the bottom tab to the top lands it at the front, not the end")
    func reorderTab_bottomToTop_movesToFront() {
        let fx = makeSession(sourceTabCount: 3)
        // [0, 1, 2] — drop 2 before 0 — expect [2, 0, 1], not [0, 1, 2].
        fx.session.reorderTab(fx.tabs[2].id, before: fx.tabs[0].id)

        #expect(fx.session.tabs.map(\.id) == [fx.tabs[2].id, fx.tabs[0].id, fx.tabs[1].id])
    }

    @Test("a scratch tab moved into a project keeps its prefix and color, not its group's folder")
    func moveTab_intoAProject_dropsTheGroupFolderDefault() {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let tab = session.openTab(container: .loose)
        session.update(tab.id) { t in
            t.namePrefix = "prod"
            t.paletteIndex = 2
            t.cwdMode = .fixed
            t.cwdPath = URL(fileURLWithPath: "/tmp/servers")
        }

        session.moveTab(tab.id, to: .project(project.id))

        let moved = session.tab(tab.id)
        #expect(moved?.namePrefix == "prod")
        #expect(moved?.paletteIndex == 2)
        #expect(moved?.cwdMode == nil)
        #expect(moved?.cwdPath == nil)
    }

    @Test("a scratch tab moved into a worktree drops the group folder too")
    func moveTab_intoAWorktree_dropsTheGroupFolderDefault() {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let worktree = ContainerID.worktree(projectID: project.id, worktreeID: UUID())
        let intoWorktree = session.openTab(container: .loose)
        session.update(intoWorktree.id) { t in
            t.cwdMode = .fixed
            t.cwdPath = URL(fileURLWithPath: "/tmp/servers")
        }

        session.moveTab(intoWorktree.id, to: worktree)

        #expect(session.tab(intoWorktree.id)?.cwdMode == nil)
        #expect(session.tab(intoWorktree.id)?.cwdPath == nil)
    }
}
