// PaddingOverrideTests.swift
// Limpid — pins which sides a pane keeps padding on and which it zeroes.

import Testing
@testable import Limpid

@Suite("Padding override")
struct PaddingOverrideTests {
    @Test("an ordinary pane never pins padding, whatever edges it touches")
    func ordinaryTab_pinsNothing() {
        #expect(PaddingOverride.forEdges(.all, isMirror: false) == nil)
        #expect(PaddingOverride.forEdges([], isMirror: false) == nil)
        #expect(PaddingOverride.forEdges([.left, .top], isMirror: false) == nil)
    }

    @Test("a mirror pane pins Limpid's padding on outer edges and zeroes the sides that meet another pane")
    func mirrorTab_zeroesInnerEdges() {
        let x = GhosttyConfigBridge.windowPaddingX
        let y = GhosttyConfigBridge.windowPaddingY
        // Left pane of a side-by-side split: its right edge faces the divider.
        #expect(
            PaddingOverride.forEdges([.top, .bottom, .left], isMirror: true)
                == PaddingOverride(top: y, bottom: y, left: x, right: 0)
        )
        // Lower-right pane of a main-vertical layout: top and left face other panes.
        #expect(
            PaddingOverride.forEdges([.bottom, .right], isMirror: true)
                == PaddingOverride(top: 0, bottom: y, left: 0, right: x)
        )
    }

    @Test("a mirror pane that fills the tab, or is zoomed, pins the outer padding on every side")
    func mirrorTab_fullBoundsPinsEveryEdge() {
        let x = GhosttyConfigBridge.windowPaddingX
        let y = GhosttyConfigBridge.windowPaddingY
        #expect(
            PaddingOverride.forEdges(.all, isMirror: true)
                == PaddingOverride(top: y, bottom: y, left: x, right: x)
        )
        // The values are what the generated config carries, so a mirror pane
        // looks exactly like an ordinary one on its outer edges.
        #expect(x == 8)
        #expect(y == 2)
    }

    @Test("the C arguments map nil to -1 (keep config) and clamp pinned sides at zero, in top/bottom/left/right order")
    func cSides_mapsToTheSetterContract() {
        #expect(PaddingOverride.cSides(of: nil) == [-1, -1, -1, -1])
        #expect(PaddingOverride.cSides(of: PaddingOverride(top: nil, bottom: 0, left: 8, right: nil)) == [-1, 0, 8, -1])
        // A negative pin is not a "keep config" request; it is clamped to zero.
        #expect(PaddingOverride.cSides(of: PaddingOverride(top: -3, bottom: nil, left: nil, right: nil)) == [0, -1, -1, -1])
    }
}
