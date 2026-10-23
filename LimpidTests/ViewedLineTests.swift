// ViewedLineTests.swift
// Limpid — how a conversation's viewed line moves, and which moves Undo takes back.

import Foundation
import Testing
@testable import Limpid

@Suite("Viewed line")
struct ViewedLineTests {
    private static func position(_ number: Int, tree: String? = nil) -> ViewedLinePosition {
        ViewedLinePosition(
            turnID: TurnID("t\(number)"),
            displayNumber: number,
            endTree: tree.map { SnapshotTree(tree: $0, root: "/repo") }
        )
    }

    private func line() -> ViewedLine {
        ViewedLine(conversation: TurnSummaryFixture.conversation)
    }

    @Test func advancing_viewsEveryTurnUpToTheLine() throws {
        var line = line()
        let moved = line.advance(to: Self.position(3), source: .decisionBar)
        let change = try #require(moved)

        #expect(change.from == nil)
        #expect(change.to == Self.position(3))
        #expect(line.lastViewedTurnID == TurnID("t3"))
        #expect(line.isViewed(Self.position(1)))
        #expect(line.isViewed(Self.position(3)))
        #expect(!line.isViewed(Self.position(4)))
    }

    @Test func advancingToATurnAlreadyViewed_movesNothing() {
        var line = line()
        _ = line.advance(to: Self.position(5), source: .decisionBar)

        let again = line.advance(to: Self.position(5), source: .decisionBar)
        let above = line.advance(to: Self.position(2), source: .review)

        #expect(again == nil)
        #expect(above == nil, "the line never moves up by marking")
        #expect(line.history.count == 1)
        #expect(line.lastViewedTurnID == TurnID("t5"))
    }

    @Test func retreating_putsTheTurnAndEveryLaterOneBackBelowTheLine() throws {
        var line = line()
        _ = line.advance(to: Self.position(5), source: .decisionBar)

        let moved = line.retreat(toBefore: Self.position(4), earlier: Self.position(3), source: .turnRow)
        let change = try #require(moved)

        #expect(change.from == Self.position(5))
        #expect(line.lastViewedTurnID == TurnID("t3"))
        #expect(!line.isViewed(Self.position(4)))
        let again = line.retreat(toBefore: Self.position(4), earlier: Self.position(3), source: .turnRow)
        #expect(again == nil, "already below")
        _ = line.retreat(toBefore: Self.position(1), earlier: nil, source: .turnRow)
        #expect(line.position == nil, "back before the first turn")
    }

    @Test func theLinesOwnTurn_endedAgainAtAnotherTree_isNoLongerViewed() throws {
        // Work after the stop is folded into the turn under the same ID; the
        // line was put below what the turn changed before it.
        var line = line()
        _ = line.advance(to: Self.position(3, tree: "tree-1"), source: .decisionBar)

        #expect(line.isViewed(Self.position(3, tree: "tree-1")))
        #expect(!line.isViewed(Self.position(3, tree: "tree-2")))
        #expect(line.isViewed(Self.position(2, tree: "tree-0")), "the turns above it stay viewed")
        let moved = line.advance(to: Self.position(3, tree: "tree-2"), source: .decisionBar)
        let again = try #require(moved)
        #expect(again.from == Self.position(3, tree: "tree-1"))
        #expect(line.isViewed(Self.position(3, tree: "tree-2")))
    }

    @Test func theLinesOwnTurn_whoseEndSettledAfterTheMark_staysViewed() {
        var line = line()
        _ = line.advance(to: Self.position(3), source: .decisionBar)

        #expect(line.isViewed(Self.position(3, tree: "tree-1")))
    }

    @Test func undo_takesBackOnlyTheLatestMove() throws {
        var line = line()
        let firstMove = line.advance(to: Self.position(2), source: .decisionBar)
        let secondMove = line.advance(to: Self.position(4), source: .decisionBar)
        let first = try #require(firstMove)
        let second = try #require(secondMove)

        let stale = line.undo(first.id)
        #expect(stale == nil, "an Undo left on screen cannot take back a later move")
        #expect(line.lastViewedTurnID == TurnID("t4"))
        let undone = line.undo(second.id)
        #expect(undone == second)
        #expect(line.lastViewedTurnID == TurnID("t2"))
        let twice = line.undo(second.id)
        #expect(twice == nil, "taken back once")
        let earlier = line.undo(first.id)
        #expect(earlier == first, "the earlier move is the latest again")
        #expect(line.position == nil)
        #expect(line.history.isEmpty)
    }

    @Test func history_keepsTheLatestMovesOnly() {
        var line = line()
        for number in 1...ViewedLine.historyLimit + 5 {
            _ = line.advance(to: Self.position(number), source: .decisionBar)
        }

        #expect(line.history.count == ViewedLine.historyLimit)
        #expect(line.history.last?.to == Self.position(ViewedLine.historyLimit + 5))
    }

    @Test func aLine_roundTripsThroughJSON_andReadsAnUnknownSource() throws {
        var line = line()
        _ = line.advance(to: Self.position(2, tree: "abc"), source: .review, at: Date(timeIntervalSince1970: 0))
        let data = try JSONEncoder().encode(line)
        #expect(try JSONDecoder().decode(ViewedLine.self, from: data) == line)

        let newer = try #require(String(bytes: data, encoding: .utf8)).replacingOccurrences(of: "\"review\"", with: "\"palette\"")
        let decoded = try JSONDecoder().decode(ViewedLine.self, from: Data(newer.utf8))
        #expect(decoded.history.first?.source == .unknown)
    }

    @Test func theLatestEndedTurn_isTheLastThatFinished_notOneStillRunning() throws {
        let turns = try [
            TurnSummaryFixture.turn("a", number: 1),
            TurnSummaryFixture.turn("b", number: 2),
            TurnSummaryFixture.turn("c", phase: "started", changes: #"{"kind":"pending"}"#, number: 3)
        ]

        #expect(ViewedLine.latestEnded(in: turns)?.turnID == TurnID("b"))
        #expect(ViewedLine.latestEnded(in: []) == nil)
    }

}
