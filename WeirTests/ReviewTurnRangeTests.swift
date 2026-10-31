// ReviewTurnRangeTests.swift
// Weir — a run of turns fixed for review, and what it refuses to be.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("Review turn range")
struct ReviewTurnRangeTests {
    private typealias Fixture = TurnSummaryFixture

    private static func turn(
        _ id: String,
        _ number: Int,
        hasBegin: Bool = true,
        hasEnd: Bool = true,
        phase: String = "finished",
        root: String = "/repo",
        endRoot: String? = nil,
        conversationID: String = "s1",
        startedAt: String = "2026-10-12T00:00:00Z",
        finishedAt: String? = nil
    ) throws -> TurnSummary {
        var extras = Fixture.Extras()
        extras.beginTree = hasBegin ? SnapshotTree(tree: Fixture.tree("b", number), root: root) : nil
        extras.conversationID = conversationID
        extras.startedAt = startedAt
        extras.finishedAt = finishedAt
        return try Fixture.turn(
            id,
            phase: phase,
            changes: Fixture.changedFiles,
            number: number,
            endTree: hasEnd ? SnapshotTree(tree: Fixture.tree("e", number), root: endRoot ?? root) : nil,
            extras: extras
        )
    }

    @Test func aRange_runsFromTheFirstTurnsBeginToTheLastTurnsEnd() throws {
        let range = try #require(ReviewTurnRange(turns: [Self.turn("T6", 6), Self.turn("T7", 7)]))

        #expect(range.beginTree == Fixture.tree("b", 6))
        #expect(range.endTree == Fixture.tree("e", 7))
        #expect(range.numbers == 6...7)
        #expect(range.turnIDs == [TurnID("T6"), TurnID("T7")])
        #expect(range.endTurnID == TurnID("T7"))
        #expect(range.scopeID.hasPrefix("turns:"))
    }

    @Test func noTurns_aRunningTurn_aMissingEnd_orAnotherWorkTree_makeNoRange() throws {
        #expect(ReviewTurnRange(turns: []) == nil, "empty")
        #expect(try ReviewTurnRange(turns: [Self.turn("T1", 1, hasBegin: false)]) == nil, "the begin was not taken")
        #expect(try ReviewTurnRange(turns: [Self.turn("T1", 1), Self.turn("T2", 2, hasEnd: false)]) == nil, "the end was not taken")
        #expect(try ReviewTurnRange(turns: [Self.turn("T1", 1, phase: "started")]) == nil, "still running")
        #expect(try ReviewTurnRange(turns: [Self.turn("T1", 1), Self.turn("T2", 2, root: "/other")]) == nil, "two work trees")
        // A turn in the middle taken elsewhere is caught too, not only the ends.
        #expect(try ReviewTurnRange(turns: [
            Self.turn("T1", 1),
            Self.turn("T2", 2, endRoot: "/other"),
            Self.turn("T3", 3)
        ]) == nil)
        #expect(try ReviewTurnRange(turns: [
            Self.turn("T2", 2, startedAt: "2026-10-12T00:05:00Z"),
            Self.turn("T1", 1, startedAt: "2026-10-12T00:00:00Z")
        ]) == nil, "out of the timeline's order")
    }

    /// The range ends where the turn that ended last ended, not
    /// at its last turn, which started last: a long turn's later part is in
    /// the comparison.
    @Test func aRange_endsAtTheTurnThatEndedLast_notTheOneThatStartedLast() throws {
        let long = try Self.turn(
            "C5", 5, conversationID: "claude",
            startedAt: "2026-10-12T10:00:00Z", finishedAt: "2026-10-12T10:30:00Z"
        )
        let short = try Self.turn(
            "X1", 1, conversationID: "codex",
            startedAt: "2026-10-12T10:05:00Z", finishedAt: "2026-10-12T10:10:00Z"
        )

        let range = try #require(ReviewTurnRange(turns: [long, short]))

        #expect(range.turnIDs == [long.turnID, short.turnID], "in the timeline's order")
        #expect(range.endTurnID == long.turnID)
        #expect(range.endTree == long.endTree?.tree)
        #expect(range.conversation == long.conversation, "the end turn's, where one is read")
        #expect(range.lastNumber == 5)
        #expect(ReviewTurnRange(turns: [long, short], endingWith: short)?.endTree == short.endTree?.tree, "an end given is kept")
        #expect(ReviewTurnRange(turns: [long], endingWith: short) == nil, "an end not among the turns")

        // Two conversations' turns ended in the same second at different
        // trees: which ended last is not recorded.
        let tied = try Self.turn(
            "X2", 2, conversationID: "codex",
            startedAt: "2026-10-12T10:20:00Z", finishedAt: "2026-10-12T10:30:00Z"
        )
        #expect(ReviewTurnRange(turns: [long, short, tied]) == nil)
    }

    @Test func theScope_isTheTurnsNotTheirTrees() throws {
        // Two turns reaching the same trees are still two ranges.
        let first = try #require(ReviewTurnRange(turns: [Self.turn("A", 1)]))
        let second = try #require(ReviewTurnRange(turns: [Self.turn("B", 1)]))

        #expect(first.beginTree == second.beginTree)
        #expect(first.scopeID != second.scopeID)
        #expect(try first.scopeID == #require(ReviewTurnRange(turns: [Self.turn("A", 1)])).scopeID, "stable")
    }

    @Test func aRange_roundTrips_andRefusesWhatNoTurnsCouldMake() throws {
        let range = try #require(ReviewTurnRange(turns: [Self.turn("T6", 6), Self.turn("T7", 7)]))
        let data = try JSONEncoder().encode(range)
        let json = try #require(String(bytes: data, encoding: .utf8))
        #expect(try JSONDecoder().decode(ReviewTurnRange.self, from: data) == range)

        // Numbers may run backwards: a turn can start before the one
        // numbered before it, and the timeline puts it first.
        let backwards = json.replacingOccurrences(of: #""firstNumber":6"#, with: #""firstNumber":9"#)
        #expect(try JSONDecoder().decode(ReviewTurnRange.self, from: Data(backwards.utf8)).firstNumber == 9)
        let strayEnd = json.replacingOccurrences(of: #""endTurnID":"T7""#, with: #""endTurnID":"T9""#)
        #expect(strayEnd != json)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ReviewTurnRange.self, from: Data(strayEnd.utf8)) }
        // A "tree" Git would read as an option.
        let option = json.replacingOccurrences(of: Fixture.tree("b", 6), with: "--output=/tmp/x")
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ReviewTurnRange.self, from: Data(option.utf8)) }
    }

    // MARK: - Across conversations

    @Test func aRangeAcrossConversations_runsByStart_fromTheFirstBeginToTheLastEnd() throws {
        // Claude's T4 started at 10:31, Codex's T1 at 10:32, and Codex's
        // T2 at 10:40: the worktree's unviewed turns as one comparison.
        let claude4 = try Self.turn("C4", 4, conversationID: "claude", startedAt: "2026-10-12T10:31:00Z")
        let codex1 = try Self.turn("X1", 1, conversationID: "codex", startedAt: "2026-10-12T10:32:00Z")
        let codex2 = try Self.turn("X2", 2, conversationID: "codex", startedAt: "2026-10-12T10:40:00Z")

        let range = try #require(ReviewTurnRange(turns: [claude4, codex1, codex2]))

        #expect(range.beginTree == Fixture.tree("b", 4))
        #expect(range.endTree == Fixture.tree("e", 2))
        #expect(range.turnIDs == [TurnID("C4"), TurnID("X1"), TurnID("X2")])
        #expect(range.conversation == codex2.conversation, "the last turn's, where one is read")
        #expect(range.conversations == [claude4.conversation, codex2.conversation])
        #expect(range.isAcrossConversations)
        #expect(range.firstNumber == 4 && range.lastNumber == 2, "each its own conversation's")
        #expect(range.numbers == 2...4, "only their span")
        #expect(try !#require(ReviewTurnRange(turns: [claude4])).isAcrossConversations)
    }

    @Test func aRangeAcrossConversations_refusesTurnsOutOfStartOrder() throws {
        let claude4 = try Self.turn("C4", 4, conversationID: "claude", startedAt: "2026-10-12T10:31:00Z")
        let codex1 = try Self.turn("X1", 1, conversationID: "codex", startedAt: "2026-10-12T10:32:00Z")
        let claude5 = try Self.turn("C5", 5, conversationID: "claude", startedAt: "2026-10-12T10:30:00Z")

        #expect(ReviewTurnRange(turns: [codex1, claude4]) == nil, "Codex's started after Claude's")
        #expect(ReviewTurnRange(turns: [claude4, codex1, claude5]) == nil, "T5 started before T4")
        // The same second, in either order, is in order.
        let same = try Self.turn(
            "X9", 9, conversationID: "codex",
            startedAt: "2026-10-12T10:31:00Z", finishedAt: "2026-10-12T10:35:00Z"
        )
        #expect(ReviewTurnRange(turns: [claude4, same]) != nil)
        #expect(ReviewTurnRange(turns: [same, claude4]) != nil)
        #expect(ReviewTurnRange.isInOrder([claude4, codex1]))
    }

    /// The range's order is the timeline's. Within one
    /// conversation a turn numbered later can start earlier (one overtook
    /// another, a clock set back); the timeline puts it first, and the
    /// range takes it in that order rather than call the record broken.
    @Test func isInOrder_agreesWithTheTimeline_whenNumbersAndStartsAreInvertedWithinOneConversation() throws {
        let t4 = try Self.turn("T4", 4, startedAt: "2026-10-12T10:00:00Z", finishedAt: "2026-10-12T10:20:00Z")
        let t3 = try Self.turn("T3", 3, startedAt: "2026-10-12T10:05:00Z", finishedAt: "2026-10-12T10:10:00Z")
        let timeline = WorktreeTimeline.ordered([t3, t4])

        #expect(timeline.map(\.turnID) == [t4.turnID, t3.turnID])
        #expect(ReviewTurnRange.isInOrder(timeline))
        let range = try #require(ReviewTurnRange(turns: timeline))
        #expect(range.beginTree == t4.beginTree?.tree)
        #expect(range.endTurnID == t4.turnID, "T4 ended last")
        #expect(ReviewScopeCatalog.unviewedTurns(turns: [t3, t4]) { _ in false } == .range(range), "not an incomplete record")
    }

    /// A draft written before `endTurnID` was saved ends at its last turn,
    /// and reads so.
    @Test func aDraftWithoutTheEndTurn_endsAtItsLastTurn() throws {
        let range = try #require(ReviewTurnRange(turns: [Self.turn("T6", 6), Self.turn("T7", 7)]))
        let json = try #require(String(bytes: Self.sortedEncoder().encode(range), encoding: .utf8))
        #expect(json.contains(#""endTurnID":"T7""#), "the new key is written")
        let old = json.replacingOccurrences(of: #""endTurnID":"T7","#, with: "")
        #expect(!old.contains("endTurnID"))

        let decoded = try JSONDecoder().decode(ReviewTurnRange.self, from: Data(old.utf8))
        #expect(decoded == range)
        #expect(decoded.endTurnID == TurnID("T7"))
    }

    /// The encoder with its keys in order, so a key can be cut out by
    /// name with what follows it.
    private static func sortedEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    @Test func aDraftWithOnlyTheOldKeys_readsAsOneConversationsRange() throws {
        let range = try #require(ReviewTurnRange(turns: [Self.turn("T6", 6), Self.turn("T7", 7)]))
        let json = try #require(String(bytes: Self.sortedEncoder().encode(range), encoding: .utf8))
        #expect(json.contains(#""conversations":"#), "the new key is written")

        // The draft an older build wrote: no `conversations`.
        let old = json.replacingOccurrences(of: #""conversations":\[[^\]]*\],"#, with: "", options: .regularExpression)
        #expect(!old.contains("conversations"))
        let decoded = try JSONDecoder().decode(ReviewTurnRange.self, from: Data(old.utf8))

        #expect(decoded == range, "one conversation, the range's own")
        #expect(decoded.conversations == [range.conversation])
        #expect(!decoded.isAcrossConversations)
    }

    @Test func aRangeAcrossConversations_roundTrips_andRefusesAConversationNotAmongItsOwn() throws {
        let claude4 = try Self.turn("C4", 4, conversationID: "claude", startedAt: "2026-10-12T10:31:00Z")
        let codex1 = try Self.turn("X1", 1, conversationID: "codex", startedAt: "2026-10-12T10:32:00Z")
        let range = try #require(ReviewTurnRange(turns: [claude4, codex1]))
        let data = try Self.sortedEncoder().encode(range)
        let json = try #require(String(bytes: data, encoding: .utf8))

        #expect(
            try JSONDecoder().decode(ReviewTurnRange.self, from: data) == range,
            "numbers running backwards are allowed across conversations"
        )
        #expect(range.scopeID.hasPrefix("turns:"))

        let without = json.replacingOccurrences(
            of: #""conversations":\[[^\]]*\],"#,
            with: #""conversations":[],"#,
            options: .regularExpression
        )
        #expect(without != json)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ReviewTurnRange.self, from: Data(without.utf8)) }
    }

    @Test func extending_addsLaterTurnsOfTheSameConversationInOrder() throws {
        let range = try #require(ReviewTurnRange(turns: [Self.turn("T6", 6)]))

        let extended = try #require(try range.extended(with: [Self.turn("T7", 7)]))

        #expect(extended.numbers == 6...7)
        #expect(extended.beginTree == Fixture.tree("b", 6))
        #expect(extended.endTree == Fixture.tree("e", 7))
        #expect(try range.extended(with: [Self.turn("T5", 5)]) == nil, "not after it")
        #expect(try range.extended(with: [Self.turn("T7", 7, hasEnd: false)]) == nil, "no end to read to")
        #expect(try range.extended(with: [Self.turn("T8", 8), Self.turn("T7", 7)]) == nil, "out of order")
    }
}
