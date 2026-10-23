// SupervisionSpacingTests.swift
// Limpid — the supervision UI's spacing roles: where a list's headings stand.

import SwiftUI
import Testing
@testable import Limpid

struct SupervisionSpacingTests {
    private typealias Layout = LimpidLayout.Supervision

    @Test func aListsFirstHeading_standsAsAPopoversHeading_andLaterOnesAStepFurther() {
        // The first heading sits right under what is above the list: 12pt
        // from a popover's edge, as the title bar dropdowns' heading does.
        #expect(Layout.popoverInset + Layout.headingInsets(isFirst: true).top == 12)
        // A heading after rows starts a group: 12pt above it.
        #expect(Layout.headingInsets(isFirst: false).top == 12)
        // Every heading's words line up with the rows' (16pt from the edge).
        for isFirst in [true, false] {
            #expect(Layout.popoverInset + Layout.headingInsets(isFirst: isFirst).leading == Layout.popoverWordsInset)
        }
        #expect(Layout.popoverInset + Layout.popoverRowInsets.leading == Layout.popoverWordsInset)
        #expect(Layout.paletteHeadingInsets(isFirst: true) == Layout.headingInsets(isFirst: true))
        #expect(Layout.notificationDayInsets(isFirst: false) == Layout.headingInsets(isFirst: false))
    }

    @Test func aPopoversField_keepsItsFocusRingClearOfTheEdge() {
        // The ring stands 3pt outside the field (`supervisionFocusRing`).
        let ringReach = Layout.keyboardRingWidth + 1
        #expect(Layout.popoverInset + Layout.popoverFieldMargins.leading - ringReach >= 9)
        #expect(Layout.popoverInset + Layout.popoverFieldMargins.leading == Layout.popoverFieldInset)
    }
}
