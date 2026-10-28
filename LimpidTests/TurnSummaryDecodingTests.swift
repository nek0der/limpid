// TurnSummaryDecodingTests.swift
// Limpid — reading a turn as the projection sends it: who wrote its prompt, the tree it ended at, and its reply.

import Foundation
import Testing
@testable import Limpid

@Suite("Turn summary decoding")
struct TurnSummaryDecodingTests {
    private typealias Fixture = TurnSummaryFixture

    private static func turn(head: String?, kind: TurnPromptKind?) throws -> TurnSummary {
        try Fixture.turn("A", number: 7, extras: .init(promptHead: head, promptKind: kind))
    }

    private static func turn(head: String?, kindJSON: String) throws -> TurnSummary {
        try Fixture.turn("A", number: 7, extras: .init(promptHead: head, promptKindJSON: kindJSON))
    }

    @Test func aProjectionWithoutAKind_readsAsThePersonsWords() throws {
        let turn = try Self.turn(head: "add tests", kind: nil)
        #expect(turn.promptKind == .text)
        #expect(turn.prompt == TurnPrompt(kind: .text, head: "add tests"))
    }

    @Test(arguments: [TurnPromptKind.text, .backgroundTask, .subagentMessage, .injected])
    func eachKind_decodes(_ kind: TurnPromptKind) throws {
        #expect(try Self.turn(head: "x", kind: kind).promptKind == kind)
    }

    @Test func aKindThisBuildDoesNotKnow_readsAsText_withoutCostingTheTurn() throws {
        let unknown = try Self.turn(head: "x", kindJSON: #""fromTheFuture""#)
        #expect(unknown.promptKind == .text)
        #expect(unknown.displayNumber == 7)
        let malformed = try Self.turn(head: "x", kindJSON: #"{"kind":"backgroundTask"}"#)
        #expect(malformed.promptKind == .text)
    }

    @Test func theTreeATurnEndedAt_isReadOnlyWhenItWasTaken() throws {
        let taken = try TurnSummaryFixture.turn("a", endTree: SnapshotTree(tree: "abc", root: "/repo"))
        #expect(taken.endTree == SnapshotTree(tree: "abc", root: "/repo"))

        let untaken = try [
            #"{"kind":"pending"}"#,
            #"{"kind":"failed","reason":"git"}"#,
            #"{"kind":"notGit"}"#,
            #"{"kind":"somethingNew","tree":"abc","root":"/repo"}"#,
            nil
        ].map { try TurnSummaryFixture.turn("b", endStatus: $0) }
        #expect(untaken.allSatisfy { $0.endTree == nil })
    }

    @Test func checksAndUsage_decode_andOneOfAShapeThisBuildCannotRead_costsOnlyItself() throws {
        var extras = TurnSummaryFixture.Extras()
        extras.check = #"{"command":"cargo test","isFiltered":false,"exitCode":0}"#
        extras.checks = #"[{"exitCode":1,"isFiltered":false},{"exitCode":0,"isFiltered":true}]"#
        extras.usage = #"{"inputTokens":1,"cacheWriteTokens":2,"cacheReadTokens":3,"outputTokens":4,"isPartial":true}"#
        let turn = try Fixture.turn("a", extras: extras)
        #expect(turn.checks == [CheckMark(exitCode: 1, isFiltered: false), CheckMark(exitCode: 0, isFiltered: true)])
        #expect(turn.checkCount == 2, "never fewer than the marks it holds")
        #expect(turn.lastCheck?.earlierFailures == 1)
        #expect(turn.usage == TurnUsage(inputTokens: 1, cacheWriteTokens: 2, cacheReadTokens: 3, outputTokens: 4, isPartial: true))
        #expect(turn.usage.map(ChangesPanelText.shownTokens) == 7, "the cache reads left out")

        extras.checks = #"{"exitCode":1}"#
        extras.usage = #"{"tokens":12}"#
        let odd = try Fixture.turn("b", number: 3, extras: extras)
        #expect(odd.displayNumber == 3)
        #expect(odd.checks.isEmpty)
        #expect(odd.usage == nil)
        #expect(odd.lastCheck?.earlierFailures == 0)

        let older = try Fixture.turn("c")
        #expect(older.checks.isEmpty && older.checkCount == 0 && older.usage == nil)

        // A record from before the runs were kept still ran its last check.
        var lastOnly = TurnSummaryFixture.Extras()
        lastOnly.check = #"{"command":"cargo test","isFiltered":false,"exitCode":0}"#
        #expect(try Fixture.turn("d", extras: lastOnly).checkCount == 1)
    }

    /// The count of failures holds those the record's marks no longer
    /// keep; the check a failure is not among its earlier ones.
    @Test func theFailureCount_holdsTheFailuresTheMarksNoLongerKeep() throws {
        var extras = TurnSummaryFixture.Extras()
        extras.check = #"{"command":"cargo test","isFiltered":false,"exitCode":0}"#
        extras.checks = #"[{"exitCode":1,"isFiltered":false},{"exitCode":0,"isFiltered":false}]"#
        extras.checkCount = 20
        extras.failureCount = 9
        let passed = try Fixture.turn("a", extras: extras)
        #expect(passed.failureCount == 9)
        #expect(passed.lastCheck?.earlierFailures == 9)

        extras.check = #"{"command":"cargo test","isFiltered":false,"exitCode":1}"#
        extras.checks = #"[{"exitCode":0,"isFiltered":false},{"exitCode":1,"isFiltered":false}]"#
        let failed = try Fixture.turn("b", extras: extras)
        #expect(failed.lastCheck?.earlierFailures == 8, "the last failure is the check's own")

        // A record that kept the runs but not the count counts the runs.
        extras.failureCount = nil
        #expect(try Fixture.turn("c", extras: extras).failureCount == 1)
    }

    /// Only a turn that still reads as finished says its reply: one that
    /// failed after, or that an end never came for, ended on something else.
    @Test func theReply_isSaidOnlyWhileTheTurnReadsAsFinished() throws {
        var extras = Fixture.Extras()
        extras.replyHead = "Added two tests."
        #expect(try Fixture.turn("a", extras: extras).reply == "Added two tests.")
        #expect(try Fixture.turn("b", phase: "failed", extras: extras).reply == nil)
        #expect(try Fixture.turn("c", phase: "started", extras: extras).reply == nil)
        extras.replyHead = ""
        #expect(try Fixture.turn("d", extras: extras).reply == nil)
        #expect(try Fixture.turn("e").reply == nil, "a record from before the reply was kept")
    }
}
