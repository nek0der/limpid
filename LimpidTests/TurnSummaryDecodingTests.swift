// TurnSummaryDecodingTests.swift
// Limpid — reading a turn as the projection sends it: who wrote its prompt, and the tree it ended at.

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
}
