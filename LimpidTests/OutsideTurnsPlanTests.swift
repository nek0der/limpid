// OutsideTurnsPlanTests.swift
// Limpid — the gaps no agent's turn accounts for, across every agent of a worktree.

import Foundation
import Testing
@testable import Limpid

@Suite("Outside turns plan")
struct OutsideTurnsPlanTests {
    /// A turn of `conversation` from minute `start` to `end` (`nil` while it
    /// runs), in the work tree at `root`, with trees named after it unless
    /// `beginTree` or `endTree` names another. A turn whose end time is not
    /// recorded still ended at its end tree.
    private static func turn(
        _ id: String,
        conversation: String = "a",
        number: Int,
        start: Int,
        end: Int?,
        isEndTimeRecorded: Bool = true,
        root: String = "/repo",
        beginTree: String? = nil,
        endTree: String? = nil
    ) throws -> TurnSummary {
        var extras = TurnSummaryFixture.Extras()
        extras.conversationID = conversation
        extras.startedAt = String(format: "2026-10-12T00:%02d:00Z", start)
        extras.finishedAt = isEndTimeRecorded ? end.map { String(format: "2026-10-12T00:%02d:00Z", $0) } : nil
        extras.beginTree = SnapshotTree(tree: beginTree ?? tree("b", id), root: root)
        return try TurnSummaryFixture.turn(
            id,
            phase: end == nil ? "started" : "finished",
            changes: TurnSummaryFixture.changedFiles,
            number: number,
            endTree: end.map { _ in SnapshotTree(tree: endTree ?? tree("e", id), root: root) },
            extras: extras
        )
    }

    private static func tree(_ kind: String, _ id: String) -> String {
        "\(kind)-\(id)"
    }

    private static func plan(_ turns: [TurnSummary]) -> OutsideTurnsPlan {
        OutsideTurnsPlan.make(turns: turns) { $0.root == "/repo" }
    }

    @Test func theGapsBetweenTurns_andSinceTheLast_areOutsideTurns() throws {
        let plan = try Self.plan([
            Self.turn("A1", number: 1, start: 0, end: 10),
            Self.turn("A2", number: 2, start: 20, end: 30)
        ])

        #expect(plan.gaps == [OutsideTurnsPlan.Gap(end: "e-A1", begin: "b-A2")])
        #expect(plan.since == "e-A2")
    }

    @Test func anotherAgentsTurn_coversTheTimeItRan() throws {
        // B1 runs across A1's end: no gap until B1 ends too, and the gap
        // starts from the tree B1 left.
        let plan = try Self.plan([
            Self.turn("A1", conversation: "a", number: 1, start: 0, end: 10),
            Self.turn("B1", conversation: "b", number: 1, start: 5, end: 15),
            Self.turn("A2", conversation: "a", number: 2, start: 20, end: 30)
        ])

        #expect(plan.gaps == [OutsideTurnsPlan.Gap(end: "e-B1", begin: "b-A2")])
        #expect(plan.since == "e-A2")
    }

    @Test func aTurnRunningNow_leavesNothingSince_andTheGapBeforeItCounts() throws {
        let plan = try Self.plan([
            Self.turn("A1", conversation: "a", number: 1, start: 0, end: 10),
            Self.turn("B1", conversation: "b", number: 1, start: 20, end: nil)
        ])

        #expect(plan.gaps == [OutsideTurnsPlan.Gap(end: "e-A1", begin: "b-B1")])
        #expect(plan.since == nil, "what changes now is the running agent's")
    }

    @Test func beforeTheFirstTurn_andInAnotherWorkTree_nothingCounts() throws {
        let away = try Self.turn("X", conversation: "s1", number: 2, start: 20, end: 30, root: "/other")

        let plan = try Self.plan([Self.turn("A1", number: 1, start: 0, end: 10), away])

        #expect(plan.gaps.isEmpty, "a tree taken elsewhere says nothing of here")
        #expect(plan.since == nil)
        #expect(Self.plan([]).since == nil)
    }

    /// Two agents' overlapping turns ended in one second at different
    /// trees: which was left last is not known, and taking the older would
    /// count the other agent's last writes as done outside turns.
    @Test func turnsOfTwoConversationsEndedInOneSecond_atOtherTrees_leaveTheCountIncomplete() throws {
        let gapAfter = try Self.plan([
            Self.turn("A1", conversation: "a", number: 1, start: 0, end: 10),
            Self.turn("B1", conversation: "b", number: 1, start: 5, end: 10),
            Self.turn("A2", conversation: "a", number: 2, start: 20, end: 30)
        ])
        #expect(gapAfter.gaps.isEmpty)
        #expect(gapAfter.since == "e-A2", "a later end is known again")
        #expect(!gapAfter.isComplete)

        let sinceLast = try Self.plan([
            Self.turn("A1", conversation: "a", number: 1, start: 0, end: 10),
            Self.turn("B1", conversation: "b", number: 1, start: 5, end: 10)
        ])
        #expect(sinceLast.since == nil)
        #expect(!sinceLast.isComplete)
    }

    @Test func turnsEndedInOneSecond_ofOneConversation_orAtOneTree_areInOrder() throws {
        let complete = try Self.plan([
            Self.turn("A1", conversation: "a", number: 1, start: 0, end: 10),
            Self.turn("A2", conversation: "a", number: 2, start: 10, end: 10),
            Self.turn("A3", conversation: "a", number: 3, start: 20, end: 30)
        ])
        #expect(complete.gaps == [
            OutsideTurnsPlan.Gap(end: "e-A1", begin: "b-A2"),
            OutsideTurnsPlan.Gap(end: "e-A2", begin: "b-A3")
        ])
        #expect(complete.isComplete)

        let sameTree = try Self.turn("B1", conversation: "b", number: 1, start: 5, end: 10, endTree: "e-A1")
        let plan = try Self.plan([Self.turn("A1", conversation: "a", number: 1, start: 0, end: 10), sameTree])
        #expect(plan.since == "e-A1")
        #expect(plan.isComplete)
    }

    /// Two agents' turns began in one second from different trees: which
    /// began first, and so which tree the gap runs to, is not known, and
    /// taking the later would count the earlier agent's first writes as
    /// done outside turns.
    @Test func turnsOfTwoConversationsBegunInOneSecond_fromOtherTrees_leaveTheCountIncomplete() throws {
        let plan = try Self.plan([
            Self.turn("A1", conversation: "a", number: 1, start: 0, end: 10),
            Self.turn("A2", conversation: "a", number: 2, start: 20, end: 30),
            Self.turn("B1", conversation: "b", number: 1, start: 20, end: 25)
        ])

        #expect(plan.gaps.isEmpty)
        #expect(plan.since == "e-A2", "the end is known")
        #expect(!plan.isComplete)
    }

    /// Turns that began in one second from one tree leave one gap, read in
    /// the timeline's order whatever order the records come in.
    @Test func turnsBegunInOneSecond_fromOneTree_openOneGap_inTheTimelinesOrder() throws {
        let turns = try [
            Self.turn("A1", conversation: "a", number: 1, start: 0, end: 10),
            Self.turn("A2", conversation: "a", number: 2, start: 20, end: 30),
            Self.turn("B1", conversation: "b", number: 1, start: 20, end: 25, beginTree: "b-A2")
        ]

        for order in [turns, turns.reversed()] {
            let plan = Self.plan(order)
            #expect(plan.gaps == [OutsideTurnsPlan.Gap(end: "e-A1", begin: "b-A2")])
            #expect(plan.since == "e-A2")
            #expect(plan.isComplete)
        }
    }

    @Test func aTurnInsideAnother_leavesTheLongerOnesEndAsTheGapsStart() throws {
        let plan = try Self.plan([
            Self.turn("A1", conversation: "a", number: 1, start: 0, end: 10),
            Self.turn("B1", conversation: "b", number: 1, start: 5, end: 8),
            Self.turn("A2", conversation: "a", number: 2, start: 20, end: 30)
        ])

        #expect(plan.gaps == [OutsideTurnsPlan.Gap(end: "e-A1", begin: "b-A2")])
    }

    @Test func aTurnBegunWhileAnotherRuns_opensNoGap() throws {
        let plan = try Self.plan([
            Self.turn("A1", conversation: "a", number: 1, start: 0, end: nil),
            Self.turn("B1", conversation: "b", number: 1, start: 5, end: 10)
        ])

        #expect(plan.gaps.isEmpty)
        #expect(plan.since == nil, "A1 still runs")
    }

    @Test func aTurnBegunAsTheLastEnded_isAGap_unlessNothingChanged() throws {
        let plan = try Self.plan([
            Self.turn("A1", conversation: "a", number: 1, start: 0, end: 10),
            Self.turn("B1", conversation: "b", number: 1, start: 10, end: 20)
        ])
        #expect(plan.gaps == [OutsideTurnsPlan.Gap(end: "e-A1", begin: "b-B1")], "equal times are not overlap")

        // Nothing changed between them: the next begin is the same tree.
        let same = try Self.turn("A2", conversation: "s1", number: 2, start: 20, end: 30, beginTree: "e-A1")
        #expect(try Self.plan([Self.turn("A1", number: 1, start: 0, end: 10), same]).gaps.isEmpty)
    }

    @Test func aRecordWithoutItsEndTime_endedWhenItBegan() throws {
        let old = try Self.turn("A1", conversation: "s1", number: 1, start: 0, end: 0, isEndTimeRecorded: false)

        let plan = try Self.plan([old, Self.turn("A2", number: 2, start: 20, end: 30)])

        #expect(plan.gaps == [OutsideTurnsPlan.Gap(end: "e-A1", begin: "b-A2")])
        #expect(plan.since == "e-A2")
    }

    @Test func aGapAcrossADeletedTurn_isUnknown_notOutsideTurns() throws {
        // A2 was deleted by the retention sweep: what it changed lies in the
        // gap from A1 to A3. B1, another conversation's, still opens its gap.
        let turns = try [
            Self.turn("A1", conversation: "a", number: 1, start: 0, end: 10),
            Self.turn("A3", conversation: "a", number: 3, start: 30, end: 40),
            Self.turn("B1", conversation: "b", number: 1, start: 50, end: 60)
        ]
        let recorded: Set = ["a1", "a3", "b1"]

        let plan = OutsideTurnsPlan.make(
            turns: turns,
            isHere: { $0.root == "/repo" },
            isRecorded: { recorded.contains("\($0.conversationID)\($1)") }
        )

        #expect(plan.gaps == [OutsideTurnsPlan.Gap(end: "e-A3", begin: "b-B1")])
        #expect(Self.plan(turns).gaps.count == 2, "a turn recorded in another worktree leaves the gap counted")
    }

    @Test func aGapADeletedTurnFellIn_isLeftOut_whateverItsConversation_andTheOthersStay() throws {
        // A1, then B1 of another conversation, then A2, then A3; B1 was
        // deleted, and B has no turn left here to show a number missing.
        let turns = try [
            Self.turn("A1", conversation: "a", number: 1, start: 0, end: 10),
            Self.turn("A2", conversation: "a", number: 2, start: 40, end: 50),
            Self.turn("A3", conversation: "a", number: 3, start: 55, end: 58)
        ]
        let deleted = try [Self.interval(20, 30)]

        let plan = OutsideTurnsPlan.make(turns: turns, isHere: { $0.root == "/repo" }, deleted: deleted)

        #expect(plan.gaps == [OutsideTurnsPlan.Gap(end: "e-A2", begin: "b-A3")], "B1's changes lie between A1 and A2")
        #expect(plan.since == "e-A3", "nothing deleted ran after the last turn")
        #expect(Self.plan(turns).gaps.count == 2, "counted when nothing was deleted")
        let ranLater = try OutsideTurnsPlan.make(turns: turns, isHere: { $0.root == "/repo" }, deleted: [Self.interval(59, 59)])
        #expect(ranLater.since == nil)
        #expect(ranLater.gaps.count == 2)
        let endedWithIt = try OutsideTurnsPlan.make(turns: turns, isHere: { $0.root == "/repo" }, deleted: [Self.interval(58, 58)])
        #expect(endedWithIt.since == nil, "the same second: it may have written after")
    }

    @Test func aDeletedTurnOverlappingOneLeft_leavesOutTheGapItRunsInto_butNotOneItStaysWithin() throws {
        let turns = try [
            Self.turn("A1", conversation: "a", number: 1, start: 0, end: 10),
            Self.turn("A2", conversation: "a", number: 2, start: 40, end: 50)
        ]
        let isHere: (SnapshotTree) -> Bool = { $0.root == "/repo" }
        #expect(try OutsideTurnsPlan.make(turns: turns, isHere: isHere, deleted: [Self.interval(5, 15)]).gaps.isEmpty)
        #expect(try OutsideTurnsPlan.make(turns: turns, isHere: isHere, deleted: [Self.interval(2, 8)]).gaps.count == 1)
    }

    private static func interval(_ start: Int, _ end: Int) throws -> DateInterval {
        try DateInterval(
            start: #require(UnreadTurnRules.date(String(format: "2026-10-12T00:%02d:00Z", start))),
            end: #require(UnreadTurnRules.date(String(format: "2026-10-12T00:%02d:00Z", end)))
        )
    }
}
