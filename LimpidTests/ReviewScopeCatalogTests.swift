// ReviewScopeCatalogTests.swift
// Limpid — the comparisons "Review Scope" offers, and the turns offered after a range.

import Foundation
import Testing
@testable import Limpid

@Suite("Review scope catalog")
struct ReviewScopeCatalogTests {
    private typealias Fixture = TurnSummaryFixture

    private static func turn(
        _ number: Int,
        changes: String = TurnSummaryFixture.changedFiles,
        phase: String = "finished",
        hasEnd: Bool = true,
        conversationID: String = "s1",
        startedAt: String = "2026-10-12T00:00:00Z"
    ) throws -> TurnSummary {
        var extras = Fixture.Extras()
        extras.beginTree = SnapshotTree(tree: Fixture.tree("b", number), root: "/repo")
        extras.conversationID = conversationID
        extras.startedAt = startedAt
        return try Fixture.turn(
            "T\(number)-\(conversationID)",
            phase: phase,
            changes: changes,
            number: number,
            endTree: hasEnd ? SnapshotTree(tree: Fixture.tree(conversationID == "s1" ? "e" : "f", number), root: "/repo") : nil,
            extras: extras
        )
    }

    @Test func theChoices_areTheUnviewedTurns_eachTurnNewestFirst_theWorkingCopy_andTheBranch() throws {
        let turns = try [
            Self.turn(5),
            Self.turn(6),
            Self.turn(7, changes: #"{"kind":"unchanged"}"#),
            Self.turn(8),
            Self.turn(9, changes: #"{"kind":"pending"}"#, phase: "started")
        ]

        let options = ReviewScopeCatalog.options(
            turns: turns,
            isViewed: { $0.displayNumber <= 5 },
            branchBase: "main",
            hasChangesOutsideTurns: true
        )

        guard case let .unviewedTurns(.range(unviewed)) = options.first else {
            Issue.record("the unviewed turns lead")
            return
        }
        #expect(unviewed.numbers == 6...8, "the answer-only turn between them is part of the comparison")
        let each = options.compactMap { option -> Int? in
            if case let .turn(range, _) = option {
                return range.firstNumber
            }
            return nil
        }
        #expect(each == [8, 6, 5], "newest first, without the answer-only and the running turn")
        #expect(options.suffix(2) == [.uncommitted(includesChangesOutsideTurns: true), .branch(base: "main")])
    }

    /// A turn a restore took back has no changes left: it is neither among
    /// the unviewed turns nor a choice of its own.
    @Test func aRestoredTurn_isNoChoice_andNoUnviewedTurn() throws {
        let turns = try [Self.turn(5), Self.turn(6), Self.turn(7)]
        let isRestored: (TurnSummary) -> Bool = { $0.displayNumber == 7 }

        let unviewed = ReviewScopeCatalog.unviewedTurns(turns: turns, isViewed: { $0.displayNumber <= 5 }, isRestored: isRestored)
        guard case let .range(range) = unviewed else {
            Issue.record("T6 is unviewed")
            return
        }
        #expect(range.numbers == 6...6)
        let options = ReviewScopeCatalog.options(
            turns: turns,
            isViewed: { $0.displayNumber <= 5 },
            isRestored: isRestored,
            branchBase: nil,
            hasChangesOutsideTurns: false
        )
        let each = options.compactMap { option -> Int? in
            if case let .turn(range, _) = option {
                return range.firstNumber
            }
            return nil
        }
        #expect(each == [6, 5])
    }

    @Test func withNothingUnviewed_theFirstChoiceSaysNone() throws {
        let options = try ReviewScopeCatalog.options(
            turns: [Self.turn(1)],
            isViewed: { _ in true },
            branchBase: nil,
            hasChangesOutsideTurns: false
        )

        #expect(options.first == .unviewedTurns(.none))
        #expect(options.first?.scope == nil)
        #expect(options.last == .uncommitted(includesChangesOutsideTurns: false))
    }

    /// A turn of an incomplete record's case, by its number, conversation,
    /// and the seconds into the day it started and ended.
    struct Recorded: Sendable {
        let number: Int
        var conversation = "claude"
        let start: Int
        let end: Int
        var hasBegin = true
        var hasEnd = true
        /// Whether the record's start time reads as a time.
        var isStartReadable = true

        func turn() throws -> TurnSummary {
            guard isStartReadable else {
                var extras = Fixture.Extras()
                extras.conversationID = conversation
                extras.startedAt = "not a time"
                extras.finishedAt = Fixture.stamp(end)
                extras.beginTree = SnapshotTree(tree: Fixture.tree("b", 99), root: "/repo")
                return try Fixture.turn(
                    "T\(number)-\(conversation)",
                    changes: Fixture.changedFiles,
                    number: number,
                    endTree: SnapshotTree(tree: Fixture.tree("c", 99), root: "/repo"),
                    extras: extras
                )
            }
            return try Fixture.timed(
                number,
                conversation: conversation,
                start: start,
                end: end,
                hasBegin: hasBegin,
                hasEnd: hasEnd,
                endKind: conversation == "codex" ? "c" : "e"
            )
        }
    }

    /// Unviewed turns whose record cannot make a range, and the span of
    /// turn numbers the record is said to be incomplete by.
    struct Incomplete: Sendable, CustomTestStringConvertible {
        let name: String
        let turns: [Recorded]
        let span: ClosedRange<Int>

        var testDescription: String {
            name
        }
    }

    static let incomplete = [
        Incomplete(
            // An interrupted last turn often has no end snapshot.
            name: "the last turn's end was not taken",
            turns: [Recorded(number: 6, start: 0, end: 10), Recorded(number: 7, start: 20, end: 30, hasEnd: false)],
            span: 6...7
        ),
        Incomplete(
            // Claude's T4 is the first unviewed turn and Codex's T1 the
            // last: the span is T1–T4, never 4...1.
            name: "the worktree's last turn's end was not taken",
            turns: [
                Recorded(number: 4, start: 0, end: 10),
                Recorded(number: 1, conversation: "codex", start: 60, end: 70, hasEnd: false)
            ],
            span: 1...4
        ),
        Incomplete(
            name: "the first turn's begin was not taken",
            turns: [
                Recorded(number: 1, conversation: "codex", start: 0, end: 120, hasBegin: false),
                Recorded(number: 4, start: 600, end: 660)
            ],
            span: 1...4
        ),
        Incomplete(
            // Rather than the range ending at the short turn's end.
            name: "the turn that ended last lost its end",
            turns: [
                Recorded(number: 5, start: 0, end: 1800, hasEnd: false),
                Recorded(number: 1, conversation: "codex", start: 300, end: 600)
            ],
            span: 1...5
        ),
        Incomplete(
            // A turn whose start cannot be read has no known place on the
            // timeline.
            name: "a turn's start cannot be read",
            turns: [
                Recorded(number: 5, start: 0, end: 1800),
                Recorded(number: 1, conversation: "codex", start: 0, end: 1200, isStartReadable: false)
            ],
            span: 1...5
        )
    ]

    /// Unviewed turns whose record cannot make one comparison say so, by
    /// the span of their numbers, rather than none or a smaller range.
    @Test(arguments: incomplete)
    func unviewedTurnsWhoseRecordCannotMakeARange_sayTheRecordIsIncomplete(_ record: Incomplete) throws {
        let turns = try record.turns.map { try $0.turn() }

        let unviewed = ReviewScopeCatalog.unviewedTurns(turns: turns) { _ in false }

        #expect(unviewed == .incomplete(record.span))
        #expect(ReviewScopeOption.unviewedTurns(unviewed).scope == nil)
    }

    // MARK: - The worktree's unviewed turns

    /// Codex T1 (unviewed) → Claude T3 (viewed) → Claude T4 (unviewed):
    /// one comparison from Codex's begin to Claude's end, the viewed turn
    /// inside it.
    @Test func theWorktreesUnviewedTurns_areOneComparison_withViewedTurnsInside() throws {
        let codex1 = try Self.turn(1, conversationID: "codex", startedAt: "2026-10-12T09:40:00Z")
        let claude3 = try Self.turn(3, startedAt: "2026-10-12T09:58:00Z")
        let claude4 = try Self.turn(4, startedAt: "2026-10-12T10:31:00Z")
        let timeline = [codex1, claude3, claude4]
        let isViewed = { (turn: TurnSummary) in turn.turnID == claude3.turnID }

        let unviewed = ReviewScopeCatalog.unviewedTurns(turns: timeline, isViewed: isViewed)

        guard case let .range(range) = unviewed else {
            Issue.record("expected a range, got \(unviewed)")
            return
        }
        #expect(range.beginTree == Fixture.tree("b", 1))
        #expect(range.endTree == Fixture.tree("e", 4))
        #expect(range.turnIDs == [codex1.turnID, claude3.turnID, claude4.turnID])
        #expect(range.isAcrossConversations)
        #expect(ReviewScopeCatalog.counts(in: range, timeline: timeline, isViewed: isViewed)
            == .init(unviewedTurns: 2, unviewedConversations: 2, viewedTurns: 1))
        #expect(ReviewScopeCatalog.counts(in: range, timeline: timeline, isViewed: { _ in false }).viewedTurns == 0)
    }

    @Test func aTurnEndingAfterTheRange_isOfferedNotAdded_upToTheLastWithAnEnd() throws {
        let range = try #require(try ReviewTurnRange(turns: [Self.turn(6)]))
        let turns = try [Self.turn(5), Self.turn(6), Self.turn(7), Self.turn(8, hasEnd: false), Self.turn(9, phase: "started")]

        #expect(ReviewScopeCatalog.followingTurns(after: range, in: turns).map(\.displayNumber) == [7])
        #expect(try ReviewScopeCatalog.followingTurns(after: range, in: [Self.turn(7, hasEnd: false)]).isEmpty)
    }
}
