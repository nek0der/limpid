// UnreadTurnRulesTests.swift
// Limpid — which unread items a conversation's turn records ask for, and which run lists them.

import Foundation
import Testing
@testable import Limpid

@Suite("Unread turn rules")
struct UnreadTurnRulesTests {
    private typealias Fixture = TurnSummaryFixture
    private static let passed = #"{"command":"make test","isFiltered":true,"exitCode":0}"#

    private func entries(_ turns: [TurnSummary], read: Set<String> = []) -> [UnreadTurnEntry] {
        UnreadTurnRules.entries(of: Fixture.conversation, turns: turns) { read.contains($0.turnID.rawValue) }
    }

    @Test func turnsThatChangedFiles_belowTheLine_makeOneItem_withTheirChangesSummed() throws {
        let turns = try [
            Fixture.turn("T5", changes: Fixture.changedFiles, number: 5),
            Fixture.turn("T6", changes: Fixture.changedFiles, number: 6, extras: .init(finishedAt: "2026-10-12T01:00:00Z")),
            Fixture.turn("T7", changes: Fixture.changedFiles, number: 7, extras: .init(check: Self.passed))
        ]

        let items = entries(turns, read: ["T5"])

        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.turn.turnID == TurnID("T6"), "named by its first turn, so a later one updates it")
        #expect(item.turn.numbers == 6...7)
        #expect(item.turn.changes == .changed(files: 4, added: 6, removed: 2))
        #expect(item.turn.check?.command == "make test", "the latest turn's check")
        #expect(item.turn.conversation == Fixture.conversation)
        #expect(item.arrivedAt == UnreadTurnRules.date("2026-10-12T01:00:00Z"))
    }

    @Test func aTurnThatChangedNothing_isItsOwnItem() throws {
        let turns = try [
            Fixture.turn("T3", number: 3),
            Fixture.turn("T4", changes: #"{"kind":"unavailable","reason":"notGit"}"#, number: 4),
            Fixture.turn("T5", changes: Fixture.changedFiles, number: 5)
        ]

        let items = entries(turns).map(\.turn)

        #expect(items.map(\.numbers) == [5...5, 3...3, 4...4])
        #expect(items.map(\.mayHaveChangedFiles) == [true, false, false])
    }

    /// ⌘J opens the review on a turn that changed files, or will say so
    /// once its end snapshot lands; a turn with no record would open an
    /// empty review.
    @Test func onlyATurnKnownToChangeFiles_opensTheReviewOnJump() {
        let changes: [ChangeSummary] = [
            .changed(files: 1, added: 1, removed: 0), .pending, .unknown, .unchanged, .unavailable(reason: "notGit")
        ]
        #expect(changes.map(\.opensReviewOnJump) == [true, true, false, false, false])
    }

    @Test func aRunningTurn_anEndNobodyPrompted_andAReadTurn_listNothing() throws {
        let turns = try [
            Fixture.turn("read", changes: Fixture.changedFiles, number: 1),
            Fixture.turn("unprompted", changes: Fixture.changedFiles, hasPrompt: false, number: 2),
            Fixture.turn("running", phase: "started", changes: #"{"kind":"pending"}"#, number: 3)
        ]

        #expect(entries(turns, read: ["read"]).isEmpty)
    }

    @Test func aRunStillBeingTaken_orOfAKindThisBuildCannotRead_isNotSummedShort() {
        let changed = ChangeSummary.changed(files: 1, added: 2, removed: 3)

        #expect(UnreadTurnRules.summed([changed, .pending, .unknown]) == .pending)
        #expect(UnreadTurnRules.summed([changed, .unknown]) == .unknown)
        #expect(UnreadTurnRules.summed([changed, changed]) == .changed(files: 2, added: 4, removed: 6))
    }

    @Test func aConversationsItems_goToItsLatestRun() throws {
        let history = try [Fixture.conversation: [Fixture.turn("T1", changes: Fixture.changedFiles)]]
        func run(_ id: String, _ conversation: ConversationKey?, at seconds: TimeInterval) -> UnreadTurnRules.Run {
            UnreadTurnRules.Run(
                runtimeID: id,
                runID: id,
                conversation: conversation,
                hasPane: true,
                updatedAt: Date(timeIntervalSince1970: seconds)
            )
        }
        let old = run("claude:old", Fixture.conversation, at: 1)
        let resumed = run("claude:new", Fixture.conversation, at: 2)
        let elsewhere = run("claude:elsewhere", ConversationKey(provider: .claude, conversationID: "s2", isFallback: false), at: 3)
        let unknown = run("codex:x", nil, at: 4)

        let byRuntime = UnreadTurnRules.byRuntime([old, resumed, elsewhere, unknown], history: history) { _ in false }

        #expect(byRuntime["claude:new"]?.count == 1)
        #expect(byRuntime["claude:old"] == [], "listed once, and not as its episode either")
        #expect(byRuntime["claude:elsewhere"] == nil, "no history yet: the episode decides")
        #expect(byRuntime["codex:x"] == nil)
    }

    @Test func theOwner_isARunInAPane_thenTheLatestTurnsRun_thenTheLastUpdated() throws {
        let history = try [Fixture.conversation: [Fixture.turn("T1", changes: Fixture.changedFiles)]]
        func run(_ id: String, runID: String = "other", hasPane: Bool = true, at seconds: TimeInterval = 1) -> UnreadTurnRules.Run {
            UnreadTurnRules.Run(
                runtimeID: id,
                runID: runID,
                conversation: Fixture.conversation,
                hasPane: hasPane,
                updatedAt: Date(timeIntervalSince1970: seconds)
            )
        }
        func owner(_ runs: [UnreadTurnRules.Run]) -> [String] {
            UnreadTurnRules.byRuntime(runs, history: history) { _ in false }.filter { !$0.value.isEmpty }.map(\.key)
        }

        #expect(owner([run("in a pane", at: 1), run("no pane", hasPane: false, at: 9)]) == ["in a pane"])
        // The fixture's turns name run "R".
        #expect(owner([run("latest turn's", runID: "R", at: 1), run("newer", at: 9)]) == ["latest turn's"])
        #expect(owner([run("older", at: 1), run("newer", at: 9)]) == ["newer"])
        #expect(owner([run("b", at: 1), run("a", at: 1)]) == ["b"], "a tie goes the same way every pass")
    }

    @Test func recordTimes_readWithOrWithoutFractions() {
        #expect(UnreadTurnRules.date("2026-10-11T21:18:21Z") != nil)
        #expect(UnreadTurnRules.date("2026-10-11T21:18:21.250Z") != nil)
        #expect(UnreadTurnRules.date("yesterday") == nil)
        #expect(UnreadTurnRules.date(nil) == nil)
    }
}
