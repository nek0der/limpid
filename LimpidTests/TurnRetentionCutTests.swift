// TurnRetentionCutTests.swift
// Limpid — a narrower turn history asks first, only when it deletes records.

import Foundation
import Testing
@testable import Limpid

struct TurnRetentionCutTests {
    private let saved = TurnRetentionSettings(days: 14, turns: 200)

    @Test func onlyADecreaseThatDeletesRecords_needsConfirmation() {
        let fewerDays = TurnRetentionSettings(days: 7, turns: 200)
        let fewerTurns = TurnRetentionSettings(days: 14, turns: 100)
        let wider = TurnRetentionSettings(days: 30, turns: 300)

        #expect(TurnRetentionCut.needsConfirmation(from: saved, to: fewerDays, removing: 3))
        #expect(TurnRetentionCut.needsConfirmation(from: saved, to: fewerTurns, removing: 1))
        #expect(!TurnRetentionCut.needsConfirmation(from: saved, to: wider, removing: 0))
        // A wider limit deletes nothing, whatever the count says.
        #expect(!TurnRetentionCut.needsConfirmation(from: saved, to: wider, removing: 5))
        // A narrower one that deletes nothing yet is saved as it is made.
        #expect(!TurnRetentionCut.needsConfirmation(from: saved, to: fewerDays, removing: 0))
        // One number down and the other up is still a decrease.
        let mixed = TurnRetentionSettings(days: 7, turns: 300)
        #expect(TurnRetentionCut.needsConfirmation(from: saved, to: mixed, removing: 2))
    }
}
