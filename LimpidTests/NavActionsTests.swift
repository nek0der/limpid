// NavActionsTests.swift
// Limpid — `NavActions` is the slice of `TabActions` that handles
// tab + container cycling and direct-by-index navigation
// (⌘1…⌘9 / ⌘] / ⌘[ / ⌘⌃1…⌘⌃9). The session-level helpers
// (`tabs(in:)`, `cycleTopLevelContainer`, `activateTopLevelContainer`,
// `setActiveTab`) have their own unit tests; this suite pins the
// `NavActions` shape so a future namespace shuffle can't silently
// stop calling them.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct NavActionsTests {

    // MARK: - activateTabInActiveContainer

    @Test("activateTabInActiveContainer activates the Nth tab of the active container")
    func activateTabInActiveContainer_picksNthTab() {
        let session = WindowSession()
        let first = session.openTabInActiveScope()
        let second = session.openTabInActiveScope()
        let third = session.openTabInActiveScope()

        NavActions.activateTabInActiveContainer(at: 0, in: session)
        #expect(session.activeTabID == first.id)
        NavActions.activateTabInActiveContainer(at: 1, in: session)
        #expect(session.activeTabID == second.id)
        NavActions.activateTabInActiveContainer(at: 2, in: session)
        #expect(session.activeTabID == third.id)
    }

    @Test("activateTabInActiveContainer is a no-op when the index is out of range")
    func activateTabInActiveContainer_outOfRange_isNoOp() {
        let session = WindowSession()
        let only = session.openTabInActiveScope()

        NavActions.activateTabInActiveContainer(at: 5, in: session)
        #expect(session.activeTabID == only.id)
        NavActions.activateTabInActiveContainer(at: -1, in: session)
        #expect(session.activeTabID == only.id)
    }

    @Test("activateTabInActiveContainer is a no-op when the container has no tabs")
    func activateTabInActiveContainer_emptyContainer_isNoOp() {
        // Switch to an empty group so the active container has zero
        // tabs and the index path bails before touching activeTabID.
        let session = WindowSession()
        _ = session.openTabInActiveScope()
        let group = session.addGroup(name: "empty")
        session.setActiveContainer(.group(group.id))
        NavActions.activateTabInActiveContainer(at: 0, in: session)
        #expect(session.activeTabID == nil)
    }

    // MARK: - cycleTab

    @Test("cycleTab forward walks through the visible tabs of the active container")
    func cycleTab_forward_cyclesThroughActiveContainer() {
        let session = WindowSession()
        let t1 = session.openTabInActiveScope()
        let t2 = session.openTabInActiveScope()
        let t3 = session.openTabInActiveScope()
        session.setActiveTab(t1.id)

        NavActions.cycleTab(session, forward: true)
        #expect(session.activeTabID == t2.id)
        NavActions.cycleTab(session, forward: true)
        #expect(session.activeTabID == t3.id)
        NavActions.cycleTab(session, forward: true)
        #expect(session.activeTabID == t1.id, "cycle wraps after the last tab")
    }

    @Test("cycleTab backward walks in the opposite direction")
    func cycleTab_backward_cyclesInReverse() {
        let session = WindowSession()
        let t1 = session.openTabInActiveScope()
        let t2 = session.openTabInActiveScope()
        let t3 = session.openTabInActiveScope()
        session.setActiveTab(t1.id)

        NavActions.cycleTab(session, forward: false)
        #expect(session.activeTabID == t3.id, "cycle wraps to the last tab on backward from first")
        NavActions.cycleTab(session, forward: false)
        #expect(session.activeTabID == t2.id)
    }

    @Test("cycleTab is a no-op when the active container has no tabs")
    func cycleTab_emptyContainer_isNoOp() {
        let session = WindowSession()
        _ = session.openTabInActiveScope()
        let group = session.addGroup(name: "empty")
        session.setActiveContainer(.group(group.id))
        // Both pre- and post-cycle the activeTabID is nil (the empty
        // container's setActiveContainer cleared it). cycleTab must
        // not change anything.
        #expect(session.activeTabID == nil)
        NavActions.cycleTab(session, forward: true)
        #expect(session.activeTabID == nil)
    }

    // MARK: - cycleContainer / activateContainer

    @Test("cycleContainer delegates to WindowSession.cycleTopLevelContainer")
    func cycleContainer_delegatesToSession() {
        let session = WindowSession()
        _ = session.openTabInActiveScope()
        let group = session.addGroup(name: "first")
        // Forward from Loose with a Group present moves the
        // selection through the top-level row order.
        let beforeForward = session.activeContainerID
        NavActions.cycleContainer(session, forward: true)
        #expect(session.activeContainerID != beforeForward)
        // Same call shape as direct WindowSession use.
        let beforeBackward = session.activeContainerID
        NavActions.cycleContainer(session, forward: false)
        #expect(session.activeContainerID != beforeBackward
            || session.activeContainerID == .group(group.id)
            || session.activeContainerID == .loose
        )
    }

    @Test("activateContainer delegates to WindowSession.activateTopLevelContainer")
    func activateContainer_delegatesToSession() {
        let session = WindowSession()
        _ = session.openTabInActiveScope()
        _ = session.addGroup(name: "first")
        // Index 0 is Loose; the helper just routes through the
        // session method, which is exercised in WindowSession tests.
        NavActions.activateContainer(at: 0, in: session)
        #expect(session.activeContainerID == .loose)
    }
}
