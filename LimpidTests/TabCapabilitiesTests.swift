// TabCapabilitiesTests.swift
// Limpid — checks that a tab reads what it allows from its kind, and that review honors it.

import AppKit
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

    /// The rows only AppKit and SwiftUI read, or only the title path reads:
    /// the file drop, the input route, the Clear item, the divider tooltip,
    /// the split buttons, and whether the pane's title names the tab. No action test
    /// would notice one of them flipping, so their values are pinned here.
    @Test("the rows only the UI reads hold their values for each kind")
    func uiOnlyRows_arePinned() {
        let terminal = TabCapabilities.of(.terminal)
        #expect(terminal.canDropFile)
        #expect(!terminal.sendsInputThroughTmux)
        #expect(terminal.canClearScreen)
        #expect(terminal.canEqualizeSubtree)
        #expect(terminal.canSplit)
        #expect(terminal.titleFollowsPaneTitle)
        #expect(!terminal.titleFollowsWindowName)

        // A mirror pane takes a drop too, typed through tmux's paste.
        let mirror = TabCapabilities.of(.tmuxMirror)
        #expect(mirror.canDropFile)
        #expect(mirror.sendsInputThroughTmux)
        // libghostty would clear only its own copy of a tmux pane.
        #expect(!mirror.canClearScreen)
        #expect(!mirror.canEqualizeSubtree)
        #expect(mirror.canSplit)
        // Named after its tmux window, never after a pane's OSC title.
        #expect(!mirror.titleFollowsPaneTitle)
        #expect(mirror.titleFollowsWindowName)
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

    /// The table is only worth having if the UI asks it. `canDropFile` and
    /// `sendsInputThroughTmux` are read one level under `performDragOperation`,
    /// where a `TabCapabilities` value alone decides whether a drop is taken
    /// and which route types it — so a row that changes value changes the
    /// answer, and a drop handler that stopped asking fails here.
    @MainActor
    @Test("a file drop is refused, typed, or pasted through tmux by what the table says")
    func fileDropRoute_followsTheTable() {
        #expect(SurfaceView.fileDropRoute(TabCapabilities.of(.terminal)) == .surfaceText)
        #expect(SurfaceView.fileDropRoute(TabCapabilities.of(.tmuxMirror)) == .tmuxPaste)
        // No tab claims the view yet.
        #expect(SurfaceView.fileDropRoute(nil) == nil)

        var refuses = TabCapabilities.of(.tmuxMirror)
        refuses.canDropFile = false
        #expect(SurfaceView.fileDropRoute(refuses) == nil)

        var typed = TabCapabilities.of(.tmuxMirror)
        typed.sendsInputThroughTmux = false
        #expect(SurfaceView.fileDropRoute(typed) == .surfaceText)
    }

    /// The same for the right-click menu: `validateMenuItem` asks this for
    /// the items the tab may refuse, so flipping a row flips the item. A
    /// mirror tab's Clear Screen is the one that matters — libghostty would
    /// clear only its own copy — and it is off because of the row, not
    /// because of the kind.
    @MainActor
    @Test("the right-click items a tab may refuse read their rows")
    func menuValidation_followsTheTable() {
        let clear = #selector(SurfaceView.clearScreen(_:))
        let split = #selector(SurfaceView.splitRight(_:))
        #expect(SurfaceView.capabilityAllows(clear, capabilities: TabCapabilities.of(.terminal)) == true)
        #expect(SurfaceView.capabilityAllows(clear, capabilities: TabCapabilities.of(.tmuxMirror)) == false)
        #expect(SurfaceView.capabilityAllows(split, capabilities: TabCapabilities.of(.tmuxMirror, origin: .user)) == true)
        #expect(SurfaceView.capabilityAllows(split, capabilities: TabCapabilities.of(.tmuxMirror, origin: .agent)) == false)
        #expect(SurfaceView.capabilityAllows(clear, capabilities: nil) == false)

        var mirror = TabCapabilities.of(.tmuxMirror)
        mirror.canClearScreen = true
        mirror.canSplit = false
        #expect(SurfaceView.capabilityAllows(clear, capabilities: mirror) == true)
        #expect(SurfaceView.capabilityAllows(split, capabilities: mirror) == false)

        // Items the table has no say over are left to `validateMenuItem`.
        #expect(SurfaceView.capabilityAllows(#selector(SurfaceView.scrollToTop(_:)), capabilities: mirror) == nil)
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
