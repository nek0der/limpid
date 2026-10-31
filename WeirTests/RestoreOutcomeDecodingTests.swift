// RestoreOutcomeDecodingTests.swift
// Weir — reading what Rust says became of a restore or a discard, including words a newer bridge adds.
//
// The journals and codes come from `rust/fixtures/restore`, which the Rust
// model's tests check are what it writes, so the two sides read one copy.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite(.disabled(if: !RepoFixture.hasLocalRepo, "the shared fixtures are in the source tree"))
struct RestoreOutcomeDecodingTests {
    /// The codes a stage reason is written as (`stage-reasons.json`).
    struct StageCodes: Decodable {
        let written: [String]
        let later: String
    }

    private static func fixture(_ name: String) throws -> Data {
        let root = try #require(RepoFixture.weirRoot)
        return try Data(contentsOf: root.appendingPathComponent("rust/fixtures/restore/\(name)"))
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func stageCodes() throws -> StageCodes {
        try JSONDecoder().decode(StageCodes.self, from: fixture("stage-reasons.json"))
    }

    private static func decode(_ json: String) throws -> RestoreOutcome {
        try JSONDecoder().decode(RestoreOutcome.self, from: Data(json.utf8))
    }

    /// The restore journal Rust writes, at `stage`, as a finished outcome.
    /// It also carries what a newer build may add: a field this build does
    /// not model and a path of a kind it does not name.
    private static func finished(stage: String, undoes: String? = nil) throws -> RestoreOutcome {
        var journal = try object(fixture("journal-without-operation.json"))
        journal["stage"] = try JSONSerialization.jsonObject(with: Data(stage.utf8))
        if let undoes {
            journal["undoes"] = undoes
        }
        journal["laterField"] = 1
        var planned = try #require(journal["plannedPaths"] as? [Any])
        planned.append(["path": "b", "kind": "renamed"])
        journal["plannedPaths"] = planned
        let outcome = try JSONSerialization.data(withJSONObject: ["outcome": "finished", "journal": journal])
        return try JSONDecoder().decode(RestoreOutcome.self, from: outcome)
    }

    private static func journal(stage: String, undoes: String? = nil) throws -> RestoreJournal? {
        let outcome = try finished(stage: stage, undoes: undoes)
        guard case let .finished(journal) = outcome else {
            Issue.record("not finished: \(outcome)")
            return nil
        }
        return journal
    }

    @Test func refusals_areReadByKind_andAnUnknownOneIsUnknown() throws {
        #expect(try Self.decode(#"{"outcome":"refused","refusal":{"kind":"agentActive","provider":"codex"}}"#)
            == .refused(.agentActive(.codex)))
        #expect(try Self.decode(#"{"outcome":"refused","refusal":{"kind":"changedSinceRestore","paths":["a.txt"]}}"#)
            == .refused(.changedSinceRestore(paths: ["a.txt"])))
        #expect(try Self.decode(#"{"outcome":"refused","refusal":{"kind":"mergeInProgress"}}"#) == .refused(.mergeInProgress))
        #expect(try Self.decode(#"{"outcome":"refused","refusal":{"kind":"journalUnwritable","cause":"refs file: denied"}}"#)
            == .refused(.journalUnwritable(cause: "refs file: denied")))
        #expect(try Self.decode(#"{"outcome":"refused","refusal":{"kind":"somethingNew"}}"#) == .refused(.unknown))
        #expect(try Self.decode(#"{"outcome":"refused","refusal":{"kind":"unsupportedVolume"}}"#) == .refused(.unsupportedVolume))
        #expect(try Self.decode(#"{"outcome":"refused","refusal":{"kind":"converted","paths":["f.txt"]}}"#)
            == .refused(.converted(["f.txt"])))
        #expect(try Self.decode(#"{"outcome":"refused","refusal":{"kind":"renamedInPlace","paths":["Name.txt"]}}"#)
            == .refused(.renamedInPlace(["Name.txt"])))
    }

    @Test func aJournal_isReadWithItsStage() throws {
        let applied = try #require(try Self.journal(stage: #"{"kind":"applied"}"#))
        #expect(applied.stage == .applied)
        #expect(applied.turnID == TurnID("T"))
        #expect(applied.turnNumber == 7)
        #expect(applied.plannedPaths.map(\.kind) == [.modify, .unknown])
        #expect(applied.isUndoable)

        let partial = #"{"kind":"partiallyApplied","reason":"interrupted","currentTree":"c","kept":["a.txt"],"#
            + #""failed":[{"path":"b","reason":"x"}]}"#
        let stopped = try #require(try Self.journal(stage: partial))
        #expect(stopped.stage == .partiallyApplied(reason: .interrupted, kept: ["a.txt"], failed: ["b"]))
        #expect(stopped.stage.isInterrupted)
        #expect(stopped.isUndoable)
    }

    /// A save kept aside is not a path that could not be written: it is
    /// read apart, with where it went, from its own field or, as earlier
    /// journals wrote it, from the reason. A diagnostic an earlier build put
    /// in the reason is a path not written.
    @Test func aSaveKeptAside_isReadApartFromThePathsNotWritten() throws {
        let paths = try Self.object(Self.fixture("kept-aside.json"))
        let failed = try ["writeFailed", "written", "earlier", "earlierDiagnostic"].map { try #require(paths[$0]) }
        let stage: [String: Any] = ["kind": "partiallyApplied", "reason": "writeFailed", "currentTree": "c", "failed": failed]
        let data = try JSONSerialization.data(withJSONObject: stage)
        let json = try #require(String(bytes: data, encoding: .utf8))
        let kept = try #require(try Self.journal(stage: json))
        #expect(kept.stage == .partiallyApplied(
            reason: .writeFailed,
            kept: [],
            failed: ["b", "d.txt"],
            keptAside: [
                RestoreKeptAside(path: "a.txt", location: ".weir-OP/target/ready-1/a.txt"),
                RestoreKeptAside(path: "c.txt", location: ".weir-OP/target/ready-1/c.txt")
            ]
        ))
    }

    /// The cases below run once per code, so an empty list would pass them
    /// all by running none.
    @Test func theStageReasonsRustWrites_areListed() throws {
        #expect(try !Self.stageCodes().written.isEmpty)
    }

    /// Every code Rust writes for a reason is one this build reads as itself.
    @Test(arguments: try RestoreOutcomeDecodingTests.stageCodes().written)
    func aStageReasonRustWrites_isReadAsItself(_ code: String) throws {
        let reason = try #require(RestoreStageReason(rawValue: code), "this build does not name \(code)")
        let journal = try #require(try Self.journal(stage: #"{"kind":"aborted","reason":"\#(code)"}"#))
        #expect(journal.stage == .aborted(reason: reason))
    }

    /// A code a newer bridge added is read as unknown rather than failing
    /// the journal.
    @Test func aStageReasonANewerBridgeAdded_isUnknown() throws {
        let code = try Self.stageCodes().later
        let journal = try #require(try Self.journal(stage: #"{"kind":"aborted","reason":"\#(code)"}"#))
        #expect(journal.stage == .aborted(reason: .unknown))
    }

    /// A journal's stage, and the restore it undoes, if it is an undo.
    struct Undoable: Sendable, CustomTestStringConvertible {
        let stage: String
        var undoes: String?
        let isUndoable: Bool

        var testDescription: String {
            undoes.map { "\(stage), undoing \($0)" } ?? stage
        }
    }

    /// Only a restore whose work stays can be undone: not one undone, cut
    /// short before it wrote, still writing, or squashed, and not an undo.
    @Test(arguments: [
        Undoable(stage: #"{"kind":"applied"}"#, isUndoable: true),
        Undoable(stage: #"{"kind":"undone","by":"OP2"}"#, isUndoable: false),
        Undoable(stage: #"{"kind":"aborted","reason":"externalChangeDetected"}"#, isUndoable: false),
        Undoable(stage: #"{"kind":"writing","done":[]}"#, isUndoable: false),
        Undoable(stage: #"{"kind":"squashed"}"#, isUndoable: false),
        Undoable(stage: #"{"kind":"applied"}"#, undoes: "OP0", isUndoable: false)
    ])
    func onlyARestoreWhoseWorkStays_isUndoable(_ journal: Undoable) throws {
        let read = try #require(try Self.journal(stage: journal.stage, undoes: journal.undoes))
        #expect(read.isUndoable == journal.isUndoable)
    }

    @Test func aDiscardsOutcome_isRead_andAJournalWithoutAnOperationIsARestore() throws {
        let json = """
        {"outcome":"finished","journal":null,"hunks":[{"path":"f.txt","header":"@@ -1 +1 @@","result":"notFound"},
         {"path":"g.txt","header":"@@ -2 +2 @@","result":"somethingNew"}]}
        """
        let outcome = try JSONDecoder().decode(DiscardOutcome.self, from: Data(json.utf8))
        #expect(outcome == .finished(nil, [
            DiscardHunkResult(path: "f.txt", header: "@@ -1 +1 @@", result: .notFound),
            DiscardHunkResult(path: "g.txt", header: "@@ -2 +2 @@", result: .unknown)
        ]))
        let discard = try JSONDecoder().decode(RestoreJournal.self, from: Self.fixture("journal-discard.json"))
        #expect(discard.operation == .discard)
        let restore = try JSONDecoder().decode(RestoreJournal.self, from: Self.fixture("journal-without-operation.json"))
        #expect(restore.operation == .restore)
        // When it ran is its own field, which recovery does not rewrite.
        #expect(restore.at == "2026-10-13T00:00:00Z")
        #expect(restore.ranAt == "2026-10-12T23:59:00Z")
    }

    /// A refusal to undo a restore whose journal could not be read passes
    /// once it can be: it is not "no such restore", which never does.
    @Test func anUnreadableJournal_isARefusalThatPasses() throws {
        let outcome = try Self.decode(#"{"outcome":"refused","refusal":{"kind":"journalUnreadable","cause":"EACCES"}}"#)
        #expect(outcome == .refused(.journalUnreadable(cause: "EACCES")))
        #expect(!RestoreRefusal.journalUnreadable(cause: "EACCES").isLasting)
    }
}
