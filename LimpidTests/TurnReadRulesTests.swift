// TurnReadRulesTests.swift
// Limpid — which ended turns are read by having their pane in sight.

import Foundation
import Testing
@testable import Limpid

@Suite("Turn read rules")
struct TurnReadRulesTests {
    private static let pane = UUID()
    private typealias Fixture = TurnSummaryFixture

    private func runtime(
        panes: Set<UUID> = [pane],
        currentTurn: String? = nil,
        isFinished: Bool = true
    ) -> TurnReadRuntime {
        TurnReadRuntime(
            runID: "R",
            activeAttachmentPaneIDs: panes,
            conversation: Fixture.conversation,
            currentTurnID: currentTurn.map(TurnID.init),
            isFinished: isFinished
        )
    }

    private func read(_ turns: [TurnSummary], inSight panes: Set<UUID> = [pane]) -> Set<TurnID> {
        TurnReadRules.turnsRead(
            inSight: panes,
            runtimes: [runtime()],
            history: [Fixture.conversation: turns]
        )
    }

    @Test func aTurnThatChangedNoFiles_isReadOnceItsPaneIsInSight() throws {
        let turns = try [
            Fixture.turn("answered"),
            Fixture.turn("not taken", changes: #"{"kind":"unavailable","reason":"notGit"}"#),
            Fixture.turn("failed", phase: "failed"),
            Fixture.turn("interrupted", phase: "interrupted"),
            Fixture.turn("overtaken", phase: "unknown", changes: #"{"kind":"unavailable","reason":"endMissing"}"#)
        ]

        #expect(read(turns) == Set(turns.map(\.turnID)))
    }

    @Test func aTurnThatMayHaveChangedFiles_waitsForTheViewedLine() throws {
        let turns = try [
            Fixture.turn("changed", changes: Fixture.changedFiles),
            // A kind this build cannot read may be a change.
            Fixture.turn("newer kind", changes: #"{"kind":"somethingNew"}"#),
            Fixture.turn("still taking", changes: #"{"kind":"pending"}"#),
            Fixture.turn("running", phase: "started", changes: #"{"kind":"pending"}"#)
        ]

        #expect(read(turns).isEmpty)
    }

    @Test func aTurnNobodyPrompted_isReadWhereverItIs() throws {
        let unprompted = try Fixture.turn(
            "unprompted",
            changes: #"{"kind":"unavailable","reason":"beginMissing"}"#,
            hasPrompt: false
        )
        let changedUnprompted = try Fixture.turn("changed unprompted", changes: Fixture.changedFiles, hasPrompt: false)

        #expect(read([unprompted, changedUnprompted], inSight: []) == [unprompted.turnID, changedUnprompted.turnID])
    }

    /// A conversation resumed in a second pane runs there as another run;
    /// each run's turns show in its own pane.
    @Test func aTurnOfARunOutOfSight_isNotReadByAnotherRunOfItsConversation() throws {
        var hiddenRun = Fixture.Extras()
        hiddenRun.runID = "B"
        var goneRun = Fixture.Extras()
        goneRun.runID = "gone"
        let shown = try Fixture.turn("shown", number: 1)
        let hidden = try Fixture.turn("hidden", number: 2, extras: hiddenRun)
        let earlier = try Fixture.turn("earlier", number: 0, extras: goneRun)
        let other = TurnReadRuntime(
            runID: "B",
            activeAttachmentPaneIDs: [UUID()],
            conversation: Fixture.conversation,
            currentTurnID: hidden.turnID,
            isFinished: true
        )

        let read = TurnReadRules.turnsRead(
            inSight: [Self.pane],
            runtimes: [runtime(), other],
            history: [Fixture.conversation: [earlier, shown, hidden]]
        )

        #expect(read == [shown.turnID, earlier.turnID], "a turn whose run is gone shows in the pane that resumed it")
    }

    /// A turn that ended in sight is read as if opened, even when
    /// the person looked away before its end snapshot settled: once it
    /// settles as no change, it is read; as a change, it waits for the line.
    @Test func aTurnThatEndedInSight_isReadOnceItsSnapshotSettlesUnchanged() throws {
        let pending = #"{"kind":"pending"}"#
        var seen: Set<TurnID> = []
        let inSight = try [Fixture.turn("quiet", changes: pending), Fixture.turn("busy", changes: pending)]
        let first = TurnReadRules.turnsRead(
            inSight: [Self.pane],
            runtimes: [runtime()],
            history: [Fixture.conversation: inSight],
            seenWhilePending: &seen
        )
        #expect(first.isEmpty)

        let settled = try [Fixture.turn("quiet"), Fixture.turn("busy", changes: Fixture.changedFiles)]
        let later = TurnReadRules.turnsRead(
            inSight: [UUID()],
            runtimes: [runtime()],
            history: [Fixture.conversation: settled],
            seenWhilePending: &seen
        )
        #expect(later == [TurnID("quiet")])
        // Settled either way, neither is remembered any longer.
        #expect(seen.isEmpty)
    }

    @Test func aPaneOutOfSight_readsNothing() throws {
        let turns = try [Fixture.turn("answered")]

        #expect(read(turns, inSight: [UUID()]).isEmpty)
        // A tmux pane behind another shows nothing of the agent, so the run
        // has no visible pane.
        #expect(TurnReadRules.turnsRead(
            inSight: [Self.pane],
            runtimes: [runtime(panes: [])],
            history: [Fixture.conversation: turns]
        ).isEmpty)
    }

    @Test func aFinishedRunWhoseTurnIsRead_isRead_andOthersAreLeftToTheirMark() throws {
        let history = try [Fixture.conversation: [Fixture.turn("read")]]
        let noConversation = TurnReadRuntime(
            runID: "other",
            activeAttachmentPaneIDs: [],
            conversation: nil,
            currentTurnID: TurnID("unread"),
            isFinished: true
        )
        let isRead: (TurnSummary) -> Bool = { $0.turnID == TurnID("read") }

        #expect(TurnReadRules.isEpisodeRead(runtime(currentTurn: "read"), history: history, isRead: isRead) == true)
        #expect(TurnReadRules.isEpisodeRead(noConversation, history: history, isRead: isRead) == nil)
        #expect(TurnReadRules.isEpisodeRead(runtime(currentTurn: "read", isFinished: false), history: history, isRead: isRead) == nil)
        #expect(TurnReadRules.isEpisodeRead(runtime(currentTurn: "read"), history: [:], isRead: isRead) == nil, "before the history")
    }

    @Test func aStopNobodyPrompted_doesNotReadTheTurnBeforeIt() throws {
        // The background task's answer is read and is the run's current
        // turn, but the episode is still the changed turn before it.
        let history = try [Fixture.conversation: [
            Fixture.turn("changed", changes: Fixture.changedFiles),
            Fixture.turn("unprompted", changes: #"{"kind":"unavailable","reason":"beginMissing"}"#, hasPrompt: false)
        ]]
        let read = TurnReadRules.turnsRead(inSight: [], runtimes: [runtime()], history: history)

        #expect(read == [TurnID("unprompted")])
        #expect(TurnReadRules.isEpisodeRead(runtime(currentTurn: "unprompted"), history: history) { read.contains($0.turnID) } == false)
    }

    @Test func aChangedTurn_isReadOnlyAsTheLineSays() throws {
        let history = try [Fixture.conversation: [Fixture.turn("changed", changes: Fixture.changedFiles)]]
        let run = runtime(currentTurn: "changed")

        #expect(TurnReadRules.isEpisodeRead(run, history: history) { _ in false } == false)
        #expect(TurnReadRules.isEpisodeRead(run, history: history) { _ in true } == true)
        // Without a turn for the episode, its own mark decides.
        #expect(TurnReadRules.isEpisodeRead(run, history: [:]) { _ in true } == nil)
        #expect(TurnReadRules.isEpisodeRead(runtime(currentTurn: "changed", isFinished: false), history: history) { _ in true } == nil)
    }

    @Test func aLaterAnswer_doesNotHideAnEarlierChange() throws {
        // T1 changed files and was never marked; T2 only answered, in sight.
        let changed = try Fixture.turn("T1", changes: Fixture.changedFiles, number: 1)
        let answered = try Fixture.turn("T2", number: 2)
        let history = [Fixture.conversation: [changed, answered]]

        #expect(TurnReadRules.isEpisodeRead(runtime(currentTurn: "T2"), history: history) { $0.turnID == answered.turnID } == false)
        #expect(TurnReadRules.isEpisodeRead(runtime(currentTurn: "T2"), history: history) { _ in true } == true)
    }

    @Test func aTurnStillRunning_standsForNoEpisode() throws {
        let running = try Fixture.turn("running", phase: "started", changes: #"{"kind":"pending"}"#, hasPrompt: false)

        #expect(TurnReadRules.episodeTurns(of: runtime(currentTurn: "running"), history: [Fixture.conversation: [running]]) == nil)
    }
}
