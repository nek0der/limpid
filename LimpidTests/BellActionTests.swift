// BellActionTests.swift
// Limpid — each bell choice: its stored string, its two checkboxes, its feedback, and when a bell marks a pane.

import Testing
@testable import Limpid

struct BellActionTests {
    /// The stored strings are the ones earlier builds wrote, and the two
    /// checkboxes write the same value the four-way pop-up did.
    @Test(arguments: [
        (BellAction.none, "none", false, false, BellFeatures()),
        (BellAction.visual, "visual", true, false, BellFeatures([.attention, .paneFlash])),
        (BellAction.audio, "audio", false, true, BellFeatures([.system])),
        (BellAction.both, "both", true, true, BellFeatures([.system, .attention, .paneFlash]))
    ])
    func eachChoice_storesItsName_comesFromItsTwoParts_andPerformsItsChannels(
        action: BellAction,
        rawValue: String,
        flashes: Bool,
        sounds: Bool,
        features: BellFeatures
    ) {
        #expect(action.rawValue == rawValue)
        #expect(action.flashes == flashes)
        #expect(action.sounds == sounds)
        #expect(BellAction(flashes: flashes, sounds: sounds) == action)
        #expect(BellFeatures.forAction(action) == features)
    }

    /// The table above names every choice, so a new one cannot go untested.
    @Test func everyChoice_isInTheTable() {
        #expect(BellAction.allCases == [.none, .visual, .audio, .both])
    }

    /// A bell leaves an unread mark only when one of its features is on,
    /// nobody is looking at the pane that rang, and the pane is not already
    /// marked.
    @Test(arguments: [
        // features on, source focused, already unread → leaves a mark
        (BellFeatures.system, false, false, true),
        (BellFeatures.paneFlash, true, false, false),
        (BellFeatures.attention, false, true, false),
        (BellFeatures(), false, false, false)
    ])
    func aBell_leavesAMarkOnlyWhereNobodyLooks(
        _ features: BellFeatures,
        _ isFocused: Bool,
        _ isUnread: Bool,
        _ leaves: Bool
    ) {
        #expect(features.leavesUnreadMark(isSourceFocused: isFocused, isAlreadyUnread: isUnread) == leaves)
    }
}
