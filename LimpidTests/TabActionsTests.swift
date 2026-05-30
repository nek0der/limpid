// TabActionsTests.swift
// Pane-level verbs that wrap WindowSession mutations. Registry-coupled
// actions inject the production `NoopSurfaceRegistry` (already used
// by SwiftUI previews) so we exercise the same code path without
// instantiating a real libghostty surface.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("TabActions")
struct TabActionsTests {

    // MARK: - Zoom

    @Test("toggleZoom on a single-leaf tab is a no-op")
    func toggleZoom_singleLeaf_doesNothing() {
        let (session, _, _) = WindowSessionFixture.withLooseTab()
        TabActions.toggleZoom(session)
        #expect(session.activeTab?.zoomedLeafID == nil)
    }

    @Test("toggleZoom on a split tab zooms the focused leaf, then unzooms")
    func toggleZoom_splitTab_togglesFocusedLeaf() throws {
        let (session, tab, paneA) = WindowSessionFixture.withLooseTab()
        // Add a sibling pane so toggleZoom has something to act on.
        TabActions.split(session, direction: .horizontal)
        let active = try #require(session.tab(tab.id))
        let focused = try #require(active.splitTree.focusedLeafID)
        #expect(focused != paneA) // split focuses the new leaf

        TabActions.toggleZoom(session)
        #expect(session.tab(tab.id)?.zoomedLeafID == focused)

        TabActions.toggleZoom(session)
        #expect(session.tab(tab.id)?.zoomedLeafID == nil)
    }

    @Test("splitting while zoomed exits zoom so the new sibling is visible")
    func split_whileZoomed_clearsZoom() {
        let (session, tab, _) = WindowSessionFixture.withLooseTab()
        TabActions.split(session, direction: .horizontal)
        TabActions.toggleZoom(session)
        #expect(session.tab(tab.id)?.zoomedLeafID != nil)

        TabActions.split(session, direction: .vertical)
        #expect(session.tab(tab.id)?.zoomedLeafID == nil)
    }

    @Test("closeActivePane clears zoom when the zoomed leaf is the one removed")
    func closeActivePane_removesZoomedLeaf_clearsZoom() {
        let (session, tab, _) = WindowSessionFixture.withLooseTab()
        let registry = NoopSurfaceRegistry()
        TabActions.split(session, direction: .horizontal)
        TabActions.toggleZoom(session) // zooms the focused (new) leaf
        #expect(session.tab(tab.id)?.zoomedLeafID != nil)

        TabActions.closeActivePane(session, registry: registry)
        #expect(session.tab(tab.id)?.zoomedLeafID == nil)
    }

    // MARK: - Equalize

    @Test("equalizeSplits routes the SplitTree primitive through the active tab")
    func equalizeSplits_drivesSplitTreeEqualize() throws {
        let (session, tab, paneA) = WindowSessionFixture.withLooseTab()
        TabActions.split(session, direction: .horizontal)
        // Drift the ratio off-center so equalize has work to do.
        session.update(tab.id) { t in
            t.splitTree = t.splitTree.resize(
                node: paneA,
                by: 200,
                direction: .horizontal,
                bounds: CGSize(width: 800, height: 600),
                minSize: 80
            )
        }
        let root = try #require(session.tab(tab.id)?.splitTree.root)
        guard case let .split(beforeData) = root else {
            Issue.record("Expected a split node before equalize")
            return
        }
        #expect(beforeData.ratio != 0.5)

        TabActions.equalizeSplits(session)

        let afterRoot = try #require(session.tab(tab.id)?.splitTree.root)
        guard case let .split(afterData) = afterRoot else {
            Issue.record("Expected a split node after equalize")
            return
        }
        #expect(afterData.ratio == 0.5)
    }

    // MARK: - Directional focus

    @Test("focusPane moves the focused leaf to the immediate neighbor")
    func focusPane_splitTab_movesFocus() throws {
        let (session, tab, paneA) = WindowSessionFixture.withLooseTab()
        let registry = NoopSurfaceRegistry()
        TabActions.split(session, direction: .horizontal)
        // After split, focused leaf is the new pane (right of paneA).
        TabActions.focusPane(session, registry: registry, direction: .left)
        let focused = try #require(session.tab(tab.id)?.splitTree.focusedLeafID)
        #expect(focused == paneA)
    }

    @Test("focusPane is a no-op on a single-leaf tab")
    func focusPane_singleLeaf_doesNothing() {
        let (session, _, paneA) = WindowSessionFixture.withLooseTab()
        let registry = NoopSurfaceRegistry()
        TabActions.focusPane(session, registry: registry, direction: .right)
        #expect(session.activeTab?.splitTree.focusedLeafID == paneA)
    }

    @Test("toggleZoom pins focusedLeafID to the zoomed leaf even when focus was nil")
    func toggleZoom_pinsFocusedLeafIDToZoomedLeaf() {
        let (session, tab, _) = WindowSessionFixture.withLooseTab()
        TabActions.split(session, direction: .horizontal)
        // Wipe focus to force toggleZoom into its fallback path.
        session.update(tab.id) { $0.splitTree.focusedLeafID = nil }
        TabActions.toggleZoom(session)
        let stored = session.tab(tab.id)
        #expect(stored?.zoomedLeafID != nil)
        #expect(stored?.splitTree.focusedLeafID == stored?.zoomedLeafID)
    }

    @Test("focusPane is a no-op while a pane is zoomed")
    func focusPane_whileZoomed_doesNotMoveFocus() throws {
        let (session, tab, _) = WindowSessionFixture.withLooseTab()
        let registry = NoopSurfaceRegistry()
        TabActions.split(session, direction: .horizontal)
        let beforeZoom = try #require(session.tab(tab.id)?.splitTree.focusedLeafID)
        TabActions.toggleZoom(session)

        TabActions.focusPane(session, registry: registry, direction: .left)
        #expect(session.tab(tab.id)?.splitTree.focusedLeafID == beforeZoom)
    }

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
        TabActions.split(session, direction: .horizontal)
        TabActions.split(session, direction: .vertical)
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
        TabActions.split(session, direction: .horizontal)
        TabActions.toggleZoom(session)
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
