// TabActionsTests.swift
// Limpid — tab-level verbs that wrap WindowSession mutations: close,
// reopen (closed-tab stack), and the LRU cap. Pane-level verbs (zoom
// / split / focusPane / equalizeSplits / closeActivePane) live in
// `PaneActionsTests.swift` so the file/suite name tracks the
// namespace it covers.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("TabActions")
struct TabActionsTests {

    // MARK: - Reopen closed tab

    @Test("closeTab pushes a ClosedTab snapshot of the full Tab")
    func closeTab_pushesClosedTabSnapshot() {
        let (session, tab, _) = WindowSessionFixture.withLooseTab()
        let registry = NoopSurfaceRegistry()
        session.update(tab.id) { t in
            t.titleOverride = "build"
            t.workingDirectory = "/tmp/limpid-test-cwd"
        }

        TabActions.closeTab(session, registry: registry, tabID: tab.id)

        #expect(session.closedTabStack.count == 1)
        let closed = session.closedTabStack.last
        #expect(closed?.tab.container == .loose)
        #expect(closed?.tab.displayTitle == "build")
        #expect(closed?.tab.workingDirectory == "/tmp/limpid-test-cwd")
        // No SurfaceView in the noop registry, so no paths captured.
        #expect(closed?.tab.scrollbackPaths.isEmpty == true)
    }

    @Test("reopenClosedTab recreates the tab with a fresh id at the same container + cwd")
    func reopenClosedTab_popsAndRecreates() throws {
        let (session, tab, _) = WindowSessionFixture.withLooseTab()
        let registry = NoopSurfaceRegistry()
        let originalID = tab.id
        session.update(tab.id) { t in
            t.titleOverride = "restore-me"
            t.workingDirectory = "/tmp/limpid-test-cwd"
        }
        TabActions.closeTab(session, registry: registry, tabID: tab.id)
        #expect(session.tab(originalID) == nil)
        #expect(session.closedTabStack.count == 1)

        TabActions.reopenClosedTab(session)

        #expect(session.closedTabStack.isEmpty)
        let revived = try #require(session.activeTab)
        #expect(revived.id != originalID) // new identity, not the same Tab
        #expect(revived.displayTitle == "restore-me")
        #expect(revived.workingDirectory == "/tmp/limpid-test-cwd")
        #expect(revived.container == .loose)
    }

    @Test("reopenClosedTab rebuilds the split tree with remapped pane IDs")
    func reopenClosedTab_splitTab_restoresLayout() throws {
        let (session, tab, _) = WindowSessionFixture.withLooseTab()
        let registry = NoopSurfaceRegistry()
        PaneActions.split(session, direction: .horizontal)
        PaneActions.split(session, direction: .vertical)
        // Snapshot the original split-tree structure before close.
        let originalLeafCount = try #require(session.tab(tab.id)?.splitTree.allLeafIDs().count)
        let originalIsSplit = try #require(session.tab(tab.id)?.splitTree.isSplit)
        let originalLeafIDs = try #require(session.tab(tab.id)?.splitTree.allLeafIDs())

        TabActions.closeTab(session, registry: registry, tabID: tab.id)
        TabActions.reopenClosedTab(session)

        let revived = try #require(session.activeTab)
        #expect(revived.splitTree.allLeafIDs().count == originalLeafCount)
        #expect(revived.splitTree.isSplit == originalIsSplit)
        // None of the new leaf IDs should equal any of the originals —
        // remapping guarantees fresh UUIDs so the registry doesn't
        // collide with whatever the previous SurfaceViews held.
        let revivedLeafIDs = Set(revived.splitTree.allLeafIDs())
        #expect(revivedLeafIDs.isDisjoint(with: Set(originalLeafIDs)))
    }

    @Test("reopenClosedTab preserves the zoomed leaf and remaps it to the new id")
    func reopenClosedTab_zoomedTab_preservesZoomViaRemap() throws {
        let (session, tab, _) = WindowSessionFixture.withLooseTab()
        let registry = NoopSurfaceRegistry()
        PaneActions.split(session, direction: .horizontal)
        PaneActions.toggleZoom(session)
        let zoomedBefore = try #require(session.tab(tab.id)?.zoomedLeafID)

        TabActions.closeTab(session, registry: registry, tabID: tab.id)
        TabActions.reopenClosedTab(session)

        let revived = try #require(session.activeTab)
        let zoomedAfter = try #require(revived.zoomedLeafID)
        // Same logical position (zoomed leaf still present), fresh UUID.
        #expect(zoomedAfter != zoomedBefore)
        #expect(revived.splitTree.allLeafIDs().contains(zoomedAfter))
    }

    @Test("reopenClosedTab preserves paneStates with remapped pane IDs")
    func reopenClosedTab_paneStates_areRemapped() throws {
        let (session, tab, paneA) = WindowSessionFixture.withLooseTab()
        let registry = NoopSurfaceRegistry()
        // Stamp paneA's PaneState with an unread count so we can spot
        // it after the round-trip.
        session.markUnread(paneID: paneA)
        #expect(session.tab(tab.id)?.paneStates[paneA]?.unreadCount == 1)

        TabActions.closeTab(session, registry: registry, tabID: tab.id)
        TabActions.reopenClosedTab(session)

        let revived = try #require(session.activeTab)
        // PaneA's id should have been remapped to a fresh UUID, and
        // the PaneState should have moved to that new key intact.
        let newPaneID = try #require(revived.splitTree.allLeafIDs().first)
        #expect(newPaneID != paneA)
        #expect(revived.paneStates[newPaneID]?.unreadCount == 1)
        #expect(revived.paneStates[paneA] == nil) // old id is gone
    }

    @Test("reopenClosedTab on an empty stack is a no-op")
    func reopenClosedTab_emptyStack_doesNothing() {
        let (session, _, _) = WindowSessionFixture.withLooseTab()
        let tabCountBefore = session.tabs.count
        TabActions.reopenClosedTab(session)
        #expect(session.tabs.count == tabCountBefore)
    }

    @Test("closedTabStack caps at closedTabStackLimit, oldest dropped")
    func closeTab_overLimit_dropsOldest() {
        let session = WindowSession()
        let registry = NoopSurfaceRegistry()
        // Open + close enough tabs to overflow the stack by one.
        let extra = 3
        for i in 0..<(WindowSession.closedTabStackLimit + extra) {
            let tab = session.openTab(container: .loose, title: "tab-\(i)")
            TabActions.closeTab(session, registry: registry, tabID: tab.id)
        }
        #expect(session.closedTabStack.count == WindowSession.closedTabStackLimit)
        #expect(session.closedTabStack.last?.tab.displayTitle == "tab-\(WindowSession.closedTabStackLimit + extra - 1)")
        // And the front is no longer "tab-0" but the first one that survived the cap.
        #expect(session.closedTabStack.first?.tab.displayTitle == "tab-\(extra)")
    }
}
