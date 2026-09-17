// TabCapabilitiesTests.swift
// Limpid — checks that a tab reads what it allows from its kind, and that review honors it.

import Foundation
import Testing
@testable import Limpid

@Suite("Tab capabilities")
struct TabCapabilitiesTests {
    /// Rows an action guards on are tested where the behavior lives
    /// (`PaneActionsTests`, `TabActionsMergePaneIntoTabTests`, and the
    /// review cases below).
    @Test("a tab reads its capabilities from its kind")
    func tab_readsFromKind() {
        var tab = Tab(title: "t", workingDirectory: nil, pwd: nil, splitTree: SplitTree(leafID: UUID()), container: .loose)
        #expect(tab.capabilities == TabCapabilities.of(.terminal))
        tab.kind = .tmuxMirror
        #expect(tab.capabilities == TabCapabilities.of(.tmuxMirror))
    }

    /// The rows only AppKit and SwiftUI read: the file drop, the paste
    /// route, the divider tooltip, and the split buttons. No action test
    /// would notice one of them flipping, so their values are pinned here.
    @Test("the rows only the UI reads hold their values for each kind")
    func uiOnlyRows_arePinned() {
        let terminal = TabCapabilities.of(.terminal)
        #expect(terminal.canDropFile)
        #expect(!terminal.pastesThroughTmux)
        #expect(terminal.canEqualizeSubtree)
        #expect(terminal.canSplit)

        // A mirror pane takes a drop too, typed through tmux's paste.
        let mirror = TabCapabilities.of(.tmuxMirror)
        #expect(mirror.canDropFile)
        #expect(mirror.pastesThroughTmux)
        #expect(!mirror.canEqualizeSubtree)
        #expect(mirror.canSplit)
    }

    /// The drop overlay's highlight and the drop handler both ask this, so
    /// a mirror tab lights only the center, which tmux can swap.
    @Test("a pane drop is allowed on the center when the tab swaps and on an edge when it inserts")
    func allowsPaneDrop_followsSwapAndInsert() {
        let edges: [PaneDropZone] = [.left, .right, .top, .bottom]
        let terminal = TabCapabilities.of(.terminal)
        #expect(terminal.allowsPaneDrop(on: .center))
        #expect(edges.allSatisfy { terminal.allowsPaneDrop(on: $0) })

        let mirror = TabCapabilities.of(.tmuxMirror)
        #expect(mirror.allowsPaneDrop(on: .center))
        #expect(!edges.contains { mirror.allowsPaneDrop(on: $0) })

        var custom = terminal
        custom.canSwap = false
        custom.canInsert = false
        #expect(!custom.allowsPaneDrop(on: .center))
        #expect(!edges.contains { custom.allowsPaneDrop(on: $0) })
    }

    /// Review takes a pane implicitly when it follows the user, and a mirror
    /// tab's pane is sized by tmux, so docking it in the strip would resize a
    /// surface tmux is still drawing a window-sized grid into.
    @MainActor
    @Test("review may dock the focused pane only on a tab that lets it open")
    func dockablePane_isTheFocusedPaneOnlyOnTabsReviewMayDock() {
        let pane = UUID()
        var tab = Tab(title: "t", workingDirectory: nil, pwd: nil, splitTree: SplitTree(leafID: pane), container: .loose)
        #expect(ReviewAgents.dockablePaneID(in: tab) == pane)

        tab.kind = .tmuxMirror
        #expect(ReviewAgents.dockablePaneID(in: tab) == nil)
        #expect(ReviewAgents.dockablePaneID(in: nil) == nil)
    }

    /// Following focus onto a tab review may not dock keeps the pane already
    /// docked, so the strip and the destination chip, which both read
    /// `originPaneID`, stay on the same terminal. A transient review still
    /// closes when the focus leaves its owner.
    @MainActor
    @Test("following focus onto a tab review may not dock keeps the docked pane")
    func focusOnAnUndockableTab_keepsTheDockedPane() {
        let presentation = ReviewPresentation()
        let directory = URL(fileURLWithPath: "/tmp/review")
        let opened = UUID()

        presentation.open(directory, originPaneID: opened)
        presentation.focusedPaneChanged(to: UUID(), isDockable: false)
        #expect(presentation.originPaneID == opened)

        let other = URL(fileURLWithPath: "/tmp/other")
        presentation.retarget(other, originPaneID: nil)
        #expect(presentation.originPaneID == nil)
        #expect(presentation.isPresented)

        let owner = UUID()
        presentation.open(
            directory,
            originPaneID: owner,
            initialScope: .turn(baseTree: String(repeating: "c", count: 40), paneID: owner),
            transientOwnerPaneID: owner
        )
        presentation.focusedPaneChanged(to: UUID(), isDockable: false)
        #expect(!presentation.isPresented)
    }
}
