// TerminalScrollbarStateTests.swift
// Limpid — validates the row-to-native-scroll geometry bridge.

import Testing
@testable import Limpid

@Suite("Terminal scrollbar state")
struct TerminalScrollbarStateTests {
    @Test("normalization keeps the viewport inside the reported history")
    func normalization_clampsMalformedMetrics() {
        #expect(TerminalScrollbarState(total: 10, offset: 20, length: 4) == .init(total: 10, offset: 6, length: 4))
        #expect(TerminalScrollbarState(total: 10, offset: 5, length: 20) == .init(total: 10, offset: 0, length: 10))
    }

    @Test("a history viewport produces proportional native scroll geometry")
    func geometry_tracksViewportProportionAndOffset() {
        let top = TerminalScrollbarState(total: 100, offset: 0, length: 20)
        let middle = TerminalScrollbarState(total: 100, offset: 40, length: 20)
        let bottom = TerminalScrollbarState(total: 100, offset: 80, length: 20)

        #expect(top.documentHeight(for: 200) == 1000)
        #expect(top.documentOriginY(for: 200) == 800)
        #expect(middle.documentOriginY(for: 200) == 400)
        #expect(bottom.documentOriginY(for: 200) == 0)
    }

    @Test("native scroll positions map back to terminal row offsets")
    func rowOffset_invertsAppKitCoordinates() {
        let state = TerminalScrollbarState(total: 100, offset: 0, length: 20)

        #expect(state.rowOffset(forDocumentOriginY: 800, viewportHeight: 200) == 0)
        #expect(state.rowOffset(forDocumentOriginY: 400, viewportHeight: 200) == 40)
        #expect(state.rowOffset(forDocumentOriginY: 0, viewportHeight: 200) == 80)
    }

    @Test("a terminal without scrollback stays at one viewport")
    func emptyHistory_hasNoScrollableGeometry() {
        let state = TerminalScrollbarState(total: 24, offset: 0, length: 24)

        #expect(!state.isScrollable)
        #expect(state.documentHeight(for: 480) == 480)
        #expect(state.documentOriginY(for: 480) == 0)
        #expect(state.rowOffset(forDocumentOriginY: 200, viewportHeight: 480) == 0)
    }
}
