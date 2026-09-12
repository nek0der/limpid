// SearchActionsTests.swift
// Limpid — contracts between screen-order search navigation and libghostty.

import Testing
@testable import Limpid

@Suite("Search actions")
struct SearchActionsTests {
    @Test("screen-order navigation maps onto libghostty's reverse-history directions")
    func navigationDirection_mapsToBindingActions() {
        #expect(PaneSearchDirection.forward.bindingAction == "navigate_search:previous")
        #expect(PaneSearchDirection.backward.bindingAction == "navigate_search:next")
    }

    @Test("match positions are displayed from the top of the screen")
    func displayPosition_convertsReverseHistoryIndex() {
        #expect(PaneSearchDirection.displayPosition(selected: 3, total: 4) == 1)
        #expect(PaneSearchDirection.displayPosition(selected: 0, total: 4) == 4)
        #expect(PaneSearchDirection.displayPosition(selected: -1, total: 4) == nil)
        #expect(PaneSearchDirection.displayPosition(selected: 4, total: 4) == nil)
        #expect(PaneSearchDirection.displayPosition(selected: 0, total: 0) == nil)
    }
}
