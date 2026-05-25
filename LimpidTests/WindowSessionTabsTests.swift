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

        // L1 stays on source; activeTabID falls onto the tab that
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

    @Test("dragging the only tab out of a container clears activeTabID without moving L1")
    func moveTab_lastActiveTab_leavesContainerEmpty() {
        let fx = makeSession(sourceTabCount: 1)
        let target = fx.session.addGroup(name: "Target")

        fx.session.moveTab(fx.tabs[0].id, to: .group(target.id))

        // L1 stays on source so the user keeps the same sidebar
        // selection and sees the empty-state L2 there.
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
}
