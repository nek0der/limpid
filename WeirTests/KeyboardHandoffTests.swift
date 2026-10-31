// KeyboardHandoffTests.swift
// Weir — who keeps the keyboard when a surface closes, and that a surface opening takes it only after two turns.

import Foundation
import Testing
@testable import Weir

@MainActor
struct KeyboardHandoffTests {
    @Test func aTerminal_alwaysKeepsTheKeyboard() {
        #expect(!KeyboardHandoff.returnsKeyboard(from: .terminal, keeper: .terminal))
        #expect(!KeyboardHandoff.returnsKeyboard(from: .terminal, keeper: .terminalOrTextField))
    }

    @Test func aTextField_keepsItOnlyWhereTheClosingSurfaceHadNone() {
        // A dropdown's or sheet's own field, still fading out.
        #expect(KeyboardHandoff.returnsKeyboard(from: .textField, keeper: .terminal))
        // A field the person went to once a rename field was gone.
        #expect(!KeyboardHandoff.returnsKeyboard(from: .textField, keeper: .terminalOrTextField))
    }

    @Test func anythingElse_givesItToTheTerminal() {
        #expect(KeyboardHandoff.returnsKeyboard(from: .other, keeper: .terminal))
        #expect(KeyboardHandoff.returnsKeyboard(from: .other, keeper: .terminalOrTextField))
    }

    @Test func aSurfaceOpening_takesTheKeyboardAfterTwoTurns() async {
        let clock = TurnClock()
        KeyboardHandoff.afterResponderSettles { clock.turnsWhenTaken = clock.turns }
        DispatchQueue.main.async {
            clock.turns += 1
            DispatchQueue.main.async { clock.turns += 1 }
        }
        await KeyboardHandoff.responderSettled()
        await KeyboardHandoff.responderSettled()
        // Queued before the counter's turns, the request runs after the
        // counter's first turn and before its second: two turns in.
        #expect(clock.turnsWhenTaken == 1)
    }
}

/// Counts turns of the main queue, for the handoff test.
@MainActor
private final class TurnClock {
    var turns = 0
    var turnsWhenTaken: Int?
}
