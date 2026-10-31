// NewSessionKeyTests.swift
// Weir — what Return does in the new worktree sheet, by its modifiers and an input method's uncommitted text.

import Foundation
import Testing
@testable import Weir

struct NewSessionKeyTests {
    /// A key press in the sheet, and what the sheet does with it.
    struct KeyCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        var isReturn = true
        var modifiers: KeyModifiers = []
        var hasMarkedText = false
        let expected: NewSessionKey.Action
    }

    @Test(arguments: [
        KeyCase(testDescription: "⌘Return", modifiers: .command, expected: .create),
        KeyCase(testDescription: "Return", expected: .create),
        // The field editor would submit the branch field and select its name.
        KeyCase(testDescription: "Shift-Return", modifiers: .shift, expected: .swallow),
        // Passed on, the window's key equivalent would create with the
        // branch short of the text the input method still holds.
        KeyCase(testDescription: "⌘Return with uncommitted text", modifiers: .command, hasMarkedText: true, expected: .swallow),
        // Return commits the uncommitted text.
        KeyCase(testDescription: "an input method's Return", hasMarkedText: true, expected: .pass),
        KeyCase(testDescription: "Option-Return", modifiers: .option, expected: .pass),
        KeyCase(testDescription: "Control-Return", modifiers: .control, expected: .pass),
        KeyCase(testDescription: "⌘ with another key", isReturn: false, modifiers: .command, expected: .pass)
    ])
    func action_followsTheKey(_ key: KeyCase) {
        #expect(NewSessionKey.action(isReturn: key.isReturn, modifiers: key.modifiers, hasMarkedText: key.hasMarkedText) == key.expected)
    }
}
