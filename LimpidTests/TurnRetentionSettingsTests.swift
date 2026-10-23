// TurnRetentionSettingsTests.swift
// Limpid — how long turns are kept: the days and turns held to their range, and the limits they make.

import Foundation
import Testing
@testable import Limpid

@Suite(.tags(.persistence))
struct TurnRetentionSettingsTests {
    /// Days stay within one to ninety, and turns within twenty to five
    /// hundred, however the file wrote them.
    @Test(arguments: [(0, 5, 1, 20), (1, 20, 1, 20), (90, 500, 90, 500), (365, 10000, 90, 500)])
    func retention_staysWithinItsRange(writtenDays: Int, writtenTurns: Int, readDays: Int, readTurns: Int) throws {
        var object = try LimpidSettingsJSON.object(.default)
        var advanced = try #require(object["advanced"] as? [String: Any])
        advanced["turnRetention"] = ["days": writtenDays, "turns": writtenTurns]
        object["advanced"] = advanced

        let retention = try LimpidSettingsJSON.decode(object).advanced.turnRetention
        #expect(retention.days == readDays)
        #expect(retention.turns == readTurns)
    }

    @Test func settingARetentionOutOfRange_isHeldToTheRange() {
        var retention = TurnRetentionSettings()
        retention.days = 0
        retention.turns = 9999

        #expect(retention.days == 1)
        #expect(retention.turns == 500)
    }

    @Test func theLimits_changeOnlyTheDaysAndTurns() {
        let limits = TurnRetentionSettings(days: 3, turns: 40).limits

        #expect(limits.maxRepositoryBytes == TurnRetentionLimits.standard.maxRepositoryBytes)
        #expect(limits.maxTurns == TurnRetentionLimits.standard.maxTurns)
        #expect(limits.maxAgeSeconds == 3 * 24 * 60 * 60)
        #expect(limits.maxPerConversation == 40)
    }

    @Test func narrowing_isAnyLimitKeepingFewerTurns() {
        let standard = TurnRetentionLimits.standard
        let fewerDays = TurnRetentionSettings(days: 7, turns: 200).limits
        let moreTurnsFewerDays = TurnRetentionSettings(days: 7, turns: 400).limits
        let wider = TurnRetentionSettings(days: 30, turns: 300).limits

        #expect(TurnRetentionLimits.isNarrowing(from: standard, to: fewerDays))
        #expect(TurnRetentionLimits.isNarrowing(from: standard, to: moreTurnsFewerDays))
        #expect(!TurnRetentionLimits.isNarrowing(from: standard, to: wider))
        // More days but fewer turns, or fewer turns alone, still narrows.
        let moreDaysFewerTurns = TurnRetentionSettings(days: 30, turns: 100).limits
        let fewerTurns = TurnRetentionSettings(days: 14, turns: 100).limits
        #expect(TurnRetentionLimits.isNarrowing(from: standard, to: moreDaysFewerTurns))
        #expect(TurnRetentionLimits.isNarrowing(from: standard, to: fewerTurns))
        #expect(!TurnRetentionLimits.isNarrowing(from: standard, to: standard))
    }
}
