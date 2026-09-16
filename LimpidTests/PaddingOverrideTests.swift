// PaddingOverrideTests.swift
// Limpid — pins which sides a pane keeps configured padding on and which it zeroes.

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

    @Test("a mirror pane keeps the config on outer edges and zeroes the sides that meet another pane")
    func mirrorTab_zeroesInnerEdges() {
        // Left pane of a side-by-side split: its right edge faces the divider.
        #expect(
            PaddingOverride.forEdges([.top, .bottom, .left], isMirror: true)
                == PaddingOverride(top: nil, bottom: nil, left: nil, right: 0)
        )
        // Lower-right pane of a main-vertical layout: top and left face other panes.
        #expect(
            PaddingOverride.forEdges([.bottom, .right], isMirror: true)
                == PaddingOverride(top: 0, bottom: nil, left: 0, right: nil)
        )
    }

    @Test("a mirror pane that fills the tab, or is zoomed, pins nothing on any side")
    func mirrorTab_fullBoundsKeepsEveryEdge() {
        #expect(
            PaddingOverride.forEdges(.all, isMirror: true)
                == PaddingOverride(top: nil, bottom: nil, left: nil, right: nil)
        )
    }

    @Test("the C arguments map nil to -1 (keep config) and clamp pinned sides at zero, in top/bottom/left/right order")
    func cSides_mapsToTheSetterContract() {
        #expect(PaddingOverride.cSides(of: nil) == [-1, -1, -1, -1])
        #expect(PaddingOverride.cSides(of: PaddingOverride(top: nil, bottom: 0, left: 8, right: nil)) == [-1, 0, 8, -1])
        // A negative pin is not a "keep config" request; it is clamped to zero.
        #expect(PaddingOverride.cSides(of: PaddingOverride(top: -3, bottom: nil, left: nil, right: nil)) == [0, -1, -1, -1])
    }
}
