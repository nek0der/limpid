// WindowSessionTabsTests.swift
// Limpid — covers the tab-level mutation surface that lives in
// `WindowSession+Tabs.swift` (open, close, move, reorder). Pure
// in-memory mutations; no filesystem or libghostty involvement.

import Foundation
import Testing
@testable import Limpid

@Suite("WindowSession +Tabs")
@MainActor
struct WindowSessionTabsTests {

    // MARK: - Helpers

    /// Three-piece test setup; struct rather than tuple so swiftlint's
    /// `large_tuple` rule stays happy.
    private struct Fixture {
        let session: WindowSession
        let sourceID: UUID
        let tabs: [Tab]
    }

    /// Build a session with a source group containing `count` tabs.
    /// Tabs are returned in insertion order; the last one is active
    /// because `openTab` activates whatever it creates.
    private func makeSession(sourceTabCount: Int) -> Fixture {
        let session = WindowSession()
        let source = session.addGroup(name: "Source")
        var madeTabs: [Tab] = []
        for _ in 0..<sourceTabCount {
            madeTabs.append(session.openTab(container: .group(source.id)))
        }
        return Fixture(session: session, sourceID: source.id, tabs: madeTabs)
    }

    // MARK: - moveTab

    @Test("non-active tab drag leaves activeContainerID and activeTabID untouched")
    func moveTab_nonActiveDrag_leavesViewUnchanged() {
        let fx = makeSession(sourceTabCount: 2)
        let target = fx.session.addGroup(name: "Target")
        // openTab activates each newly-created tab, so we rewind to
        // the first one so the second one is the *non-active* one we
        // want to drag.
        fx.session.setActiveTab(fx.tabs[0].id)
        let nonActive = fx.tabs[1]

        fx.session.moveTab(nonActive.id, to: .group(target.id))

        #expect(fx.session.activeContainerID == .group(fx.sourceID))
        #expect(fx.session.activeTabID == fx.tabs[0].id)
        #expect(fx.session.tab(nonActive.id)?.container == .group(target.id))
    }

    @Test("active tab drag promotes the right-hand sibling in the source container")
    func moveTab_activeDrag_promotesRightNeighbor() {
        let fx = makeSession(sourceTabCount: 3)
        let target = fx.session.addGroup(name: "Target")
        fx.session.setActiveTab(fx.tabs[0].id)

        fx.session.moveTab(fx.tabs[0].id, to: .group(target.id))

        // Container column stays on source; activeTabID falls onto the tab that
        // slid into the vacated slot — fx.tabs[1].
        #expect(fx.session.activeContainerID == .group(fx.sourceID))
        #expect(fx.session.activeTabID == fx.tabs[1].id)
    }

    @Test("active tab drag from the end of the container falls back to the predecessor")
    func moveTab_activeDragFromEnd_promotesPredecessor() {
        let fx = makeSession(sourceTabCount: 2)
        let target = fx.session.addGroup(name: "Target")
        // openTab leaves the most recently created tab active, so
        // the second one is already the active end-of-list candidate.

        fx.session.moveTab(fx.tabs[1].id, to: .group(target.id))

        #expect(fx.session.activeContainerID == .group(fx.sourceID))
        #expect(fx.session.activeTabID == fx.tabs[0].id)
    }

    @Test("dragging the only tab out of a container clears activeTabID without moving container column")
    func moveTab_lastActiveTab_leavesContainerEmpty() {
        let fx = makeSession(sourceTabCount: 1)
        let target = fx.session.addGroup(name: "Target")

        fx.session.moveTab(fx.tabs[0].id, to: .group(target.id))

        // Container column stays on source so the user keeps the same sidebar
        // selection and sees the empty-state tab column there.
        #expect(fx.session.activeContainerID == .group(fx.sourceID))
        #expect(fx.session.activeTabID == nil)
    }

    @Test("moving a tab to its own container is a no-op")
    func moveTab_sameContainer_isNoOp() {
        let fx = makeSession(sourceTabCount: 2)
        fx.session.setActiveTab(fx.tabs[0].id)
        let snapshotBefore = fx.session.tabs.map(\.id)

        fx.session.moveTab(fx.tabs[1].id, to: .group(fx.sourceID))

        #expect(fx.session.tabs.map(\.id) == snapshotBefore)
        #expect(fx.session.activeTabID == fx.tabs[0].id)
    }

    // MARK: - reorderTab

    // `performDrop` re-fires `onDrop` for a same-list reorder when the
    // dragged row has slid under the cursor, calling
    // `reorderTab(src, before/after: src)`. Without the self-guard the
    // source is removed first, the target ID is then not found, and the
    // tab is appended to the very end — so a drag to the top silently
    // bounced back to the bottom. These pin that guard.

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

    // MARK: - Project / worktree tab-count cache

    /// Sanity-check the per-project tab count cache through the full
    /// CRUD lifecycle: open, move in, move out, close. The cache lets
    /// the Project header skip an N-tab linear walk per body re-eval,
    /// so a regression here would silently regress sidebar perf
    /// without any observable failure beyond a slower render.
    @Test("project tab-count cache tracks open / move / close")
    func tabCount_inProject_tracksAcrossCRUD() {
        let session = WindowSession()
        let project = session.addOrActivateProject(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("limpid-tabcount-\(UUID().uuidString)"),
            suggestedName: "P"
        )
        let baseline = session.tabCount(inProject: project.id)

        // Open two more tabs inside the project.
        let t1 = session.openTab(container: .project(project.id))
        let t2 = session.openTab(container: .project(project.id))
        #expect(session.tabCount(inProject: project.id) == baseline + 2)

        // Move one tab out to .loose — the project count drops by 1.
        session.moveTab(t1.id, to: .loose)
        #expect(session.tabCount(inProject: project.id) == baseline + 1)

        // Close the remaining opened tab.
        session.closeTab(t2.id)
        #expect(session.tabCount(inProject: project.id) == baseline)
    }
}
