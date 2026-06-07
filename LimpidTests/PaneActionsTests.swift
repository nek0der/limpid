// PaneActionsTests.swift
// Limpid — tests for the pane-level verbs that wrap WindowSession mutations.
//
// Registry-coupled actions inject the production `NoopSurfaceRegistry`
// (already used by SwiftUI previews) so we exercise the same code path
// without instantiating a real libghostty surface.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("PaneActions")
struct PaneActionsTests {

    // MARK: - Zoom

    @Test("toggleZoom on a single-leaf tab is a no-op")
    func toggleZoom_singleLeaf_doesNothing() {
        let (session, _, _) = WindowSessionFixture.withLooseTab()
        PaneActions.toggleZoom(session)
        #expect(session.activeTab?.zoomedLeafID == nil)
    }

    @Test("toggleZoom on a split tab zooms the focused leaf, then unzooms")
    func toggleZoom_splitTab_togglesFocusedLeaf() throws {
        let (session, tab, paneA) = WindowSessionFixture.withLooseTab()
        // Add a sibling pane so toggleZoom has something to act on.
        PaneActions.split(session, direction: .horizontal)
        let active = try #require(session.tab(tab.id))
        let focused = try #require(active.splitTree.focusedLeafID)
        #expect(focused != paneA)

        PaneActions.toggleZoom(session)
        #expect(session.tab(tab.id)?.zoomedLeafID == focused)

        PaneActions.toggleZoom(session)
        #expect(session.tab(tab.id)?.zoomedLeafID == nil)
    }

    @Test("splitting while zoomed exits zoom so the new sibling is visible")
    func split_whileZoomed_clearsZoom() {
        let (session, tab, _) = WindowSessionFixture.withLooseTab()
        PaneActions.split(session, direction: .horizontal)
        PaneActions.toggleZoom(session)
        #expect(session.tab(tab.id)?.zoomedLeafID != nil)

        PaneActions.split(session, direction: .vertical)
        #expect(session.tab(tab.id)?.zoomedLeafID == nil)
    }

    @Test("closeActivePane clears zoom when the zoomed leaf is the one removed")
    func closeActivePane_removesZoomedLeaf_clearsZoom() {
        let (session, tab, _) = WindowSessionFixture.withLooseTab()
        let registry = NoopSurfaceRegistry()
        PaneActions.split(session, direction: .horizontal)
        PaneActions.toggleZoom(session)
        #expect(session.tab(tab.id)?.zoomedLeafID != nil)

        PaneActions.closeActivePane(session, registry: registry)
        #expect(session.tab(tab.id)?.zoomedLeafID == nil)
    }

    /// Regression guard for the pre-`5dcea48` bug where the registry
    /// reconcile passed only the *active* tab's leaves, silently
    /// sweeping every other tab's `SurfaceView`. Without the fix the
    /// next visit to an inactive tab would spawn a fresh shell over
    /// the still-running pty.
    @Test("closeActivePane keeps inactive tabs' surfaces in the reconcile set")
    func closeActivePane_doesNotSweepInactiveTabsSurfaces() throws {
        let (session, tabA, _, _, paneB) = WindowSessionFixture.withTwoLooseTabs()
        let registry = RecordingSurfaceRegistry()
        PaneActions.split(session, direction: .horizontal)
        // After the split, tabA holds two leaves; the focused one is the
        // newly-spawned sibling. Capture the surviving leaf so we can
        // confirm it remains alongside paneB after the close.
        let liveLeavesBefore = try #require(session.tab(tabA.id))
            .splitTree.allLeafIDs()
        #expect(liveLeavesBefore.count == 2)

        PaneActions.closeActivePane(session, registry: registry)

        let lastReconcile = try #require(registry.lastReconcileIDs)
        // paneB must still appear — the bug would have evicted it.
        #expect(lastReconcile.contains(paneB))
        // The closed leaf is the only one missing from the reconcile.
        let expectedSurvivor = liveLeavesBefore
            .first { $0 != registry.unregisteredIDs.first }
        #expect(expectedSurvivor != nil)
        #expect(try lastReconcile.contains(#require(expectedSurvivor)))
        #expect(lastReconcile.count == 2)
    }

    // MARK: - Equalize

    @Test("equalizeSplits routes the SplitTree primitive through the active tab")
    func equalizeSplits_drivesSplitTreeEqualize() throws {
        let (session, tab, paneA) = WindowSessionFixture.withLooseTab()
        PaneActions.split(session, direction: .horizontal)
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

        PaneActions.equalizeSplits(session)

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
        PaneActions.split(session, direction: .horizontal)
        // After split, focused leaf is the new pane (right of paneA).
        PaneActions.focusPane(session, registry: registry, direction: .left)
        let focused = try #require(session.tab(tab.id)?.splitTree.focusedLeafID)
        #expect(focused == paneA)
    }

    @Test("focusPane is a no-op on a single-leaf tab")
    func focusPane_singleLeaf_doesNothing() {
        let (session, _, paneA) = WindowSessionFixture.withLooseTab()
        let registry = NoopSurfaceRegistry()
        PaneActions.focusPane(session, registry: registry, direction: .right)
        #expect(session.activeTab?.splitTree.focusedLeafID == paneA)
    }

    @Test("toggleZoom pins focusedLeafID to the zoomed leaf even when focus was nil")
    func toggleZoom_pinsFocusedLeafIDToZoomedLeaf() {
        let (session, tab, _) = WindowSessionFixture.withLooseTab()
        PaneActions.split(session, direction: .horizontal)
        // Wipe focus to force toggleZoom into its fallback path.
        session.update(tab.id) { $0.splitTree.focusedLeafID = nil }
        PaneActions.toggleZoom(session)
        let stored = session.tab(tab.id)
        #expect(stored?.zoomedLeafID != nil)
        #expect(stored?.splitTree.focusedLeafID == stored?.zoomedLeafID)
    }

    @Test("focusPane is a no-op while a pane is zoomed")
    func focusPane_whileZoomed_doesNotMoveFocus() throws {
        let (session, tab, _) = WindowSessionFixture.withLooseTab()
        let registry = NoopSurfaceRegistry()
        PaneActions.split(session, direction: .horizontal)
        let beforeZoom = try #require(session.tab(tab.id)?.splitTree.focusedLeafID)
        PaneActions.toggleZoom(session)

        PaneActions.focusPane(session, registry: registry, direction: .left)
        #expect(session.tab(tab.id)?.splitTree.focusedLeafID == beforeZoom)
    }
}
