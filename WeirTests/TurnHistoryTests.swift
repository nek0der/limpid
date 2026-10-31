// TurnHistoryTests.swift
// Weir — when the turns are known: work that needs them waits for the first pass that reports them.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct TurnHistoryTests {
    @Test func whenLoaded_runsAtOnce_onceTheTurnsAreKnown() {
        let history = TurnHistory()
        history.replace(with: [])
        var runs = 0

        history.whenLoaded { runs += 1 }

        #expect(runs == 1)
    }

    @Test func whenLoaded_waitsForTheFirstPass_andRunsOnce() async {
        let history = TurnHistory()
        var runs = 0
        history.whenLoaded { runs += 1 }
        #expect(runs == 0)

        history.replace(with: [])
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(5)) { runs > 0 }
        history.replace(with: [ConversationTurns(key: TurnSummaryFixture.conversation, turns: [])])
        // A second run would be a main-actor task the pass started; one
        // queued after it runs after it.
        await Task { @MainActor in }.value

        #expect(runs == 1)
    }

    @Test func theHistory_isLoadedOnceAPassReportsIt() {
        let history = TurnHistory()
        #expect(!history.hasLoaded)
        history.replace(with: [])
        #expect(history.hasLoaded, "an empty report is still a report")
    }
}
