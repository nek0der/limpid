// PaneRunLedgerTests.swift
// Limpid — which panes the agent runs moved on in from one pass to the next, and each pane's epoch.

import Foundation
import Testing
@testable import Limpid

struct PaneRunLedgerTests {
    @Test func aTurnStarting_movesItsPaneOn_andTheSameTurnDoesNot() {
        var ledger = PaneRunLedger()
        let pane = UUID()
        _ = ledger.note([PaneRunLedger.Run.test("a", in: [pane], turn: "t1")])
        let first = ledger.epoch(inPane: pane)

        #expect(ledger.note([PaneRunLedger.Run.test("a", in: [pane], turn: "t1", state: .running)]).isEmpty)
        #expect(ledger.epoch(inPane: pane) == first)
        #expect(ledger.note([PaneRunLedger.Run.test("a", in: [pane], turn: "t2", state: .running)]) == [pane])
        #expect(ledger.epoch(inPane: pane) != first)
    }

    @Test func theAgentLeaving_movesItsPaneOn_andTheEpochGoes() {
        var ledger = PaneRunLedger()
        let ended = UUID()
        let gone = UUID()
        _ = ledger.note([PaneRunLedger.Run.test("a", in: [ended], turn: "t1"), PaneRunLedger.Run.test("b", in: [gone], turn: nil)])

        // One run reports its session ended; the other is no longer listed.
        #expect(ledger.note([PaneRunLedger.Run.test("a", in: [ended], turn: "t1", state: .unknown)]) == [ended, gone])
        #expect(ledger.epoch(inPane: ended) == nil)
        #expect(ledger.epoch(inPane: gone) == nil)
    }

    @Test func aStop_movesItsPaneOn_itsNextTurnToo_butNotItsGoing() {
        var ledger = PaneRunLedger()
        let pane = UUID()
        _ = ledger.note([PaneRunLedger.Run.test("a", in: [pane], turn: "t1", state: .running)])

        // A usage limit: the agent is still in the pane, but what was said
        // before the stop is past.
        #expect(ledger.note([PaneRunLedger.Run.test("a", in: [pane], turn: "t1", state: .error)]) == [pane])
        #expect(ledger.epoch(inPane: pane) != nil)
        #expect(ledger.note([PaneRunLedger.Run.test("a", in: [pane], turn: "t1", state: .error)]).isEmpty)
        // The person typed on in the same run.
        #expect(ledger.note([PaneRunLedger.Run.test("a", in: [pane], turn: "t2", state: .running)]) == [pane])

        // A stop's record cleaned up after the conversation came back in a
        // new run says nothing about the new one.
        _ = ledger.note([
            PaneRunLedger.Run.test("a", in: [pane], turn: "t2", state: .error),
            PaneRunLedger.Run.test("b", in: [pane], turn: nil)
        ])
        #expect(ledger.note([PaneRunLedger.Run.test("b", in: [pane], turn: nil)]).isEmpty)
    }

    @Test func aStopsNextTurn_inErrorStill_movesItsPaneOn() {
        var ledger = PaneRunLedger()
        let pane = UUID()
        _ = ledger.note([PaneRunLedger.Run.test("a", in: [pane], turn: "t1", state: .error)])
        #expect(ledger.note([PaneRunLedger.Run.test("a", in: [pane], turn: "t2", state: .error)]) == [pane])
    }

    @Test func aRunNamingNoPaneForAMoment_staysInItsPane() {
        var ledger = PaneRunLedger()
        let pane = UUID()
        _ = ledger.note([PaneRunLedger.Run.test("a", in: [pane], turn: "t1")])
        let epoch = ledger.epoch(inPane: pane)

        // A tmux client between attachments.
        #expect(ledger.note([PaneRunLedger.Run.test("a", in: [], turn: "t1")]).isEmpty)
        #expect(ledger.epoch(inPane: pane) == epoch)
        #expect(ledger.note([PaneRunLedger.Run.test("a", in: [pane], turn: "t1")]).isEmpty)
        #expect(ledger.epoch(inPane: pane) == epoch)

        // Attached elsewhere only: it left this pane.
        let elsewhere = UUID()
        #expect(ledger.note([PaneRunLedger.Run.test("a", in: [elsewhere], turn: "t1")]) == [pane])
    }

    @Test func aRunArriving_movesNothingOn_andRunsInOnePaneAreComparedEach() {
        var ledger = PaneRunLedger()
        let pane = UUID()
        #expect(ledger.note([PaneRunLedger.Run.test("a", in: [pane], turn: nil)]).isEmpty)
        // A second run attached in the same pane says nothing about the first.
        #expect(ledger.note([PaneRunLedger.Run.test("b", in: [pane], turn: nil), PaneRunLedger.Run.test("a", in: [pane], turn: nil)])
            .isEmpty)
        #expect(ledger
            .note([PaneRunLedger.Run.test("a", in: [pane], turn: nil), PaneRunLedger.Run.test("b", in: [pane], turn: "t1")]) == [pane])
    }

    @Test func anEpochIsNeverTakenTwice_evenAfterThePaneEmpties() {
        var ledger = PaneRunLedger()
        let pane = UUID()
        _ = ledger.note([PaneRunLedger.Run.test("a", in: [pane], turn: nil)])
        let before = ledger.epoch(inPane: pane)
        _ = ledger.note([])
        _ = ledger.note([PaneRunLedger.Run.test("b", in: [pane], turn: nil)])
        #expect(ledger.epoch(inPane: pane) != nil)
        #expect(ledger.epoch(inPane: pane) != before)
    }
}
