// SessionActionsTests.swift
// Pane-level verbs that wrap WindowSession mutations. Registry-coupled
// actions inject the production `NoopSurfaceRegistry` (already used
// by SwiftUI previews) so we exercise the same code path without
// instantiating a real libghostty surface.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("SessionActions")
struct SessionActionsTests {

    // MARK: - Zoom

    @Test("toggleZoom on a single-leaf tab is a no-op")
    func toggleZoom_singleLeaf_doesNothing() {
        let (session, _, _) = WindowSessionFixture.withLooseTab()
        SessionActions.toggleZoom(session)
        #expect(session.activeTab?.zoomedLeafID == nil)
    }

    @Test("toggleZoom on a split tab zooms the focused leaf, then unzooms")
    func toggleZoom_splitTab_togglesFocusedLeaf() throws {
        let (session, tab, paneA) = WindowSessionFixture.withLooseTab()
        // Add a sibling pane so toggleZoom has something to act on.
        SessionActions.split(session, direction: .horizontal)
        let active = try #require(session.tab(tab.id))
        let focused = try #require(active.splitTree.focusedLeafID)
        #expect(focused != paneA) // split focuses the new leaf

        SessionActions.toggleZoom(session)
        #expect(session.tab(tab.id)?.zoomedLeafID == focused)

        SessionActions.toggleZoom(session)
        #expect(session.tab(tab.id)?.zoomedLeafID == nil)
    }

    @Test("splitting while zoomed exits zoom so the new sibling is visible")
    func split_whileZoomed_clearsZoom() {
        let (session, tab, _) = WindowSessionFixture.withLooseTab()
        SessionActions.split(session, direction: .horizontal)
        SessionActions.toggleZoom(session)
        #expect(session.tab(tab.id)?.zoomedLeafID != nil)

        SessionActions.split(session, direction: .vertical)
        #expect(session.tab(tab.id)?.zoomedLeafID == nil)
    }

    @Test("closeActivePane clears zoom when the zoomed leaf is the one removed")
    func closeActivePane_removesZoomedLeaf_clearsZoom() {
        let (session, tab, _) = WindowSessionFixture.withLooseTab()
        let registry = NoopSurfaceRegistry()
        SessionActions.split(session, direction: .horizontal)
        SessionActions.toggleZoom(session) // zooms the focused (new) leaf
        #expect(session.tab(tab.id)?.zoomedLeafID != nil)

        SessionActions.closeActivePane(session, registry: registry)
        #expect(session.tab(tab.id)?.zoomedLeafID == nil)
    }

    // MARK: - Equalize

    @Test("equalizeSplits routes the SplitTree primitive through the active tab")
    func equalizeSplits_drivesSplitTreeEqualize() throws {
        let (session, tab, paneA) = WindowSessionFixture.withLooseTab()
        SessionActions.split(session, direction: .horizontal)
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

        SessionActions.equalizeSplits(session)

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
        SessionActions.split(session, direction: .horizontal)
        // After split, focused leaf is the new pane (right of paneA).
        SessionActions.focusPane(session, registry: registry, direction: .left)
        let focused = try #require(session.tab(tab.id)?.splitTree.focusedLeafID)
        #expect(focused == paneA)
    }

    @Test("focusPane is a no-op on a single-leaf tab")
    func focusPane_singleLeaf_doesNothing() {
        let (session, _, paneA) = WindowSessionFixture.withLooseTab()
        let registry = NoopSurfaceRegistry()
        SessionActions.focusPane(session, registry: registry, direction: .right)
        #expect(session.activeTab?.splitTree.focusedLeafID == paneA)
    }

    @Test("toggleZoom pins focusedLeafID to the zoomed leaf even when focus was nil")
    func toggleZoom_pinsFocusedLeafIDToZoomedLeaf() {
        let (session, tab, _) = WindowSessionFixture.withLooseTab()
        SessionActions.split(session, direction: .horizontal)
        // Wipe focus to force toggleZoom into its fallback path.
        session.update(tab.id) { $0.splitTree.focusedLeafID = nil }
        SessionActions.toggleZoom(session)
        let stored = session.tab(tab.id)
        #expect(stored?.zoomedLeafID != nil)
        #expect(stored?.splitTree.focusedLeafID == stored?.zoomedLeafID)
    }

    @Test("focusPane is a no-op while a pane is zoomed")
    func focusPane_whileZoomed_doesNotMoveFocus() throws {
        let (session, tab, _) = WindowSessionFixture.withLooseTab()
        let registry = NoopSurfaceRegistry()
        SessionActions.split(session, direction: .horizontal)
        let beforeZoom = try #require(session.tab(tab.id)?.splitTree.focusedLeafID)
        SessionActions.toggleZoom(session)

        SessionActions.focusPane(session, registry: registry, direction: .left)
        #expect(session.tab(tab.id)?.splitTree.focusedLeafID == beforeZoom)
    }
}
