// HeaderChipOverflowTests.swift
// Weir — which chips fit beside the session name.

import Foundation
import Testing
@testable import Weir

struct HeaderChipOverflowTests {
    private static let cache = HeaderChipOverflow.Chip(kind: .exception, width: 100)
    private static let pullRequest = HeaderChipOverflow.Chip(kind: .git, width: 60)
    private static let commits = HeaderChipOverflow.Chip(kind: .git, width: 70)

    private static func shown(available: CGFloat) -> [Int] {
        HeaderChipOverflow.shown(
            chips: [cache, pullRequest, commits],
            fixedWidth: 200,
            available: available,
            spacing: 8
        )
    }

    @Test func everyChip_staysWhenTheyFit() {
        // 200 + 3 × 8 + 100 + 60 + 70 = 454
        #expect(Self.shown(available: 454) == [0, 1, 2])
    }

    @Test func gitChips_goFirst_fromTheLast_thenTheExceptionChips() {
        #expect(Self.shown(available: 453) == [0, 1])
        #expect(Self.shown(available: 376) == [0, 1])
        #expect(Self.shown(available: 375) == [0])
        #expect(Self.shown(available: 308) == [0])
        #expect(Self.shown(available: 307) == [])
    }

    @Test func theLine_countsOneSpacingAfterTheGlyph_andOnePerChip() {
        let fixed = HeaderChipOverflow.fixedWidth(nameWidth: 100, glyphWidth: 15, horizontalPadding: 14, spacing: 8, slack: 2)
        #expect(fixed == 153)
        // A chip that fits exactly: 153 + 8 + 40.
        let chip = HeaderChipOverflow.Chip(kind: .git, width: 40)
        #expect(HeaderChipOverflow.shown(chips: [chip], fixedWidth: fixed, available: 201, spacing: 8) == [0])
        #expect(HeaderChipOverflow.shown(chips: [chip], fixedWidth: fixed, available: 200, spacing: 8) == [])
    }

    @Test func theFirstChip_keepsTheNamesWiderSpacing() {
        // The header's own spacing: 10 after the glyph and the name, 6
        // between chips. Two chips that fit exactly:
        // 28 + 15 + 10 + 100 + 2 + 10 + 40 + 6 + 40 = 251.
        let fixed = HeaderChipOverflow.fixedWidth(nameWidth: 100, glyphWidth: 15, horizontalPadding: 14, spacing: 10, slack: 2)
        let chips = [HeaderChipOverflow.Chip(kind: .git, width: 40), HeaderChipOverflow.Chip(kind: .git, width: 40)]
        func shown(_ available: CGFloat) -> [Int] {
            HeaderChipOverflow.shown(chips: chips, fixedWidth: fixed, available: available, spacing: 6, leadingSpacing: 10)
        }
        #expect(shown(251) == [0, 1])
        #expect(shown(250) == [0])
        #expect(shown(205) == [0])
        #expect(shown(204) == [])
    }

    @Test func theName_isCutOnlyOnceNoChipIsLeft() {
        // Narrower than the name itself: every chip is gone, and the view
        // cuts the name from its end.
        #expect(Self.shown(available: 120).isEmpty)
    }
}
