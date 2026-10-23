// NotificationHistoryDismissKeyTests.swift
// Limpid — which Escape closes the notification history panel before the terminal under it sees the key.

import AppKit
import Testing
@testable import Limpid

@MainActor
struct NotificationHistoryDismissKeyTests {
    private static let escape: UInt16 = 53

    @Test func escape_plainOrShifted_dismisses() throws {
        let plain = try NSEvent.testKeyDown(keyCode: Self.escape, characters: "\u{1B}")
        let shifted = try NSEvent.testKeyDown(keyCode: Self.escape, modifiers: .shift, characters: "\u{1B}")
        #expect(NotificationHistoryView.isDismissKey(plain))
        #expect(NotificationHistoryView.isDismissKey(shifted))
    }

    @Test func escape_withCommandControlOrOption_isLeftToTheWindow() throws {
        for modifier: NSEvent.ModifierFlags in [.command, .control, .option] {
            let event = try NSEvent.testKeyDown(keyCode: Self.escape, modifiers: modifier, characters: "\u{1B}")
            #expect(!NotificationHistoryView.isDismissKey(event))
        }
    }

    @Test func otherKey_isLeftToTheWindow() throws {
        let event = try NSEvent.testKeyDown(keyCode: 0, characters: "a")
        #expect(!NotificationHistoryView.isDismissKey(event))
    }
}
