// SidebarPinnedLineTests.swift
// Weir — how much of a sidebar line the pinned project header cuts.

import Foundation
import Testing
@testable import Weir

@Suite("SidebarPinnedLine")
struct SidebarPinnedLineTests {
    private func hidden(top: CGFloat) -> CGFloat {
        SidebarPinnedLine.hiddenHeight(lineTop: top, lineHeight: 46, pinnedBottom: 28)
    }

    @Test func aLineBelowTheHeader_isWhole() {
        #expect(hidden(top: 30) == 0)
        #expect(hidden(top: 28) == 0)
    }

    @Test func aLineCrossingTheHeader_losesOnlyWhatIsUnderIt() {
        #expect(hidden(top: 18) == 10)
    }

    @Test func aLineGonePast_isCutWhole() {
        #expect(hidden(top: -40) == 46)
    }
}
