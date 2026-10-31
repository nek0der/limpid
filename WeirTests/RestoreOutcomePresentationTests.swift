// RestoreOutcomePresentationTests.swift
// Weir — what the window does once a restore or its undo ends: the strip, the viewed lines, the "Done" line, and the toast.

import Foundation
import Testing
@testable import Weir

struct RestoreOutcomePresentationTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")
    private static let opID = "6F1C2A40-8C1E-4B7A-9D55-2E0B6A3C9F10"
    private static let other = ConversationKey(provider: .claude, conversationID: "s2", isFallback: false)

    private static func journal(
        _ stage: String,
        opID: String = opID,
        number: Int? = 5,
        at: String = "2026-10-12T00:07:30Z"
    ) throws -> RestoreJournal {
        try RestoreJournalFixture.make(stageJSON: stage, fields: .init(opID: opID, turnID: "s1-T5", turnNumber: number, at: at))
    }

    private static func turn(_ number: Int, root: String = "/repo", conversationID: String = "s1") throws -> TurnSummary {
        try TurnSummaryFixture.restorable(number, root: root, conversationID: conversationID)
    }

    private static func isRoot(_ root: String) -> (String) -> Bool {
        { $0 == root }
    }

    private static func history() throws -> [ConversationKey: [TurnSummary]] {
        try [
            TurnSummaryFixture.conversation: [turn(4), turn(5), turn(6)],
            other: [turn(7, conversationID: "s2"), turn(6, root: "/other", conversationID: "s2")]
        ]
    }

    private static func finish(
        _ ending: RestoreEnding,
        recordedOpIDs: Set<String> = [],
        locale: Locale = english
    ) throws -> RestoreOutcomePresentation.Finish {
        try RestoreOutcomePresentation.finish(
            ending,
            history: history(),
            isRoot: isRoot,
            isRecorded: { recordedOpIDs.contains($0) },
            locale: locale
        )
    }

    private static let applied = #"{"kind":"applied"}"#
    private static let keptAside = #"{"kind":"partiallyApplied","reason":"keptAside","currentTree":"c","#
        + #""failed":[{"path":"a.txt","reason":"keptAside:.weir-OP/target/ready-1/a.txt"}]}"#

    // MARK: - A restore's end

    @Test func applied_namesTheTurnsTakenBack_theDoneLine_andTheToast() throws {
        let journal = try Self.journal(Self.applied)
        guard case let .applied(applied) = try Self.finish(.applied(journal)) else {
            Issue.record("an applied restore is taken as applied")
            return
        }
        #expect(applied.journal == journal)
        // Every conversation's turns in the worktree from the turn restored
        // to: T4 began before it, and the other T6 in another worktree.
        #expect(Set(applied.restoredTurns.map(\.turnID.rawValue)) == ["s1-T5", "s1-T6", "s2-T7"])
        #expect(applied.done == RestoreDone(opID: Self.opID, root: "/repo", turnNumber: 5))
        let toast = try #require(applied.toast)
        #expect(toast.id == UUID(uuidString: Self.opID), "its undo from elsewhere finds it by the operation")
        #expect(toast.message.resolved(in: Self.english) == ToastKind.codeRestored(turnNumber: 5).message.resolved(in: Self.english))
        guard case .localized = toast.message else {
            Issue.record("a toast with nothing to add follows the display language")
            return
        }
    }

    @Test func applied_withSavesMovedAside_namesWhereInTheToast() throws {
        let journal = try Self.journal(Self.keptAside)
        guard case let .applied(applied) = try Self.finish(.applied(journal)) else {
            Issue.record("a whole restore that moved saves aside is applied")
            return
        }
        let toast = try #require(applied.toast)
        #expect(toast.message == .verbatim(
            "Restored the code to before T5. Not reflected in the conversation. "
                + "Saves made meanwhile were moved to .weir-OP/target/ready-1/a.txt."
        ))
    }

    /// A journal from a build that did not name the turn shows no toast
    /// rather than a wrong number, but its lines still move and its "Done"
    /// line, which offers the undo, is still handed over.
    @Test func applied_withNoTurnNumber_showsNoToast_butStillMovesTheLines() throws {
        let journal = try Self.journal(Self.applied, number: nil)
        guard case let .applied(applied) = try Self.finish(.applied(journal)) else {
            Issue.record("an applied restore is taken as applied")
            return
        }
        #expect(applied.toast == nil)
        #expect(applied.restoredTurns.count == 3)
        #expect(applied.done == RestoreDone(opID: Self.opID, root: "/repo", turnNumber: nil))
    }

    @Test func applied_underAnOperationNotNamedByAUUID_hasAToastNothingFindsAgain() throws {
        let journal = try Self.journal(Self.applied, opID: "OP")
        guard case let .applied(applied) = try Self.finish(.applied(journal)) else {
            Issue.record("an applied restore is taken as applied")
            return
        }
        #expect(applied.toast != nil)
        #expect(applied.toast?.id == nil)
    }

    /// Part of it is in the working tree: the strip stays and says what,
    /// and nothing moves a line or offers "Done".
    @Test func partial_keepsTheStrip_sayingWhatStayed() throws {
        let journal = try Self.journal(#"{"kind":"partiallyApplied","reason":"writeFailed","currentTree":"c"}"#)
        let finish = try Self.finish(.partial(journal, kept: ["a.txt"], failed: ["b"]))
        #expect(finish == .explain(RestoreText.ended(.partial(kept: ["a.txt"], failed: ["b"]), locale: Self.english)))
        // Recorded or not, a partial restore's strip says what it left.
        #expect(try Self.finish(.partial(journal, kept: ["a.txt"], failed: ["b"]), recordedOpIDs: [Self.opID]) == finish)
    }

    /// The words themselves are `RestorePresentationTests`'s; here, that the
    /// strip says them for this reason, in the language asked for.
    @Test func refused_keepsTheStrip_sayingWhy() throws {
        #expect(try Self.finish(.canceled(.refused(.mergeInProgress)))
            == .explain(RestoreText.ended(.canceled(.refused(.mergeInProgress)), locale: Self.english)))
        #expect(try Self.finish(.canceled(.otherChanges), locale: Self.japanese)
            == .explain(RestoreText.ended(.canceled(.otherChanges), locale: Self.japanese)))
        #expect(try Self.finish(.canceled(.unknown))
            == .explain(RestoreText.ended(.canceled(.unknown), locale: Self.english)))
    }

    /// The bridge failed or the journal was read before it settled: the
    /// strip says so, unless the record, read again after the restore,
    /// shows this very operation and says what it holds.
    @Test func failed_saysTheEndIsNotKnown_unlessTheRecordShowsIt() throws {
        let unknown = RestoreText.ended(.unknown, locale: Self.english)
        #expect(try Self.finish(.unknown(opID: nil), recordedOpIDs: [Self.opID]) == .explain(unknown))
        #expect(try Self.finish(.unknown(opID: Self.opID)) == .explain(unknown))
        #expect(try Self.finish(.unknown(opID: Self.opID), recordedOpIDs: ["another"]) == .explain(unknown))
        #expect(try Self.finish(.unknown(opID: Self.opID), recordedOpIDs: [Self.opID]) == .closeStrip)
    }

    // MARK: - An undo's end

    @Test func anUndoTakenBackWhole_namesTheRestore_andItsToast_withNothingNewToTell() throws {
        let journal = try Self.journal(Self.applied)
        let undoJournal = try Self.journal(Self.applied, opID: "U")
        let undone = try #require(RestoreOutcomePresentation.undo(.finished(undoJournal), of: journal, locale: Self.english))
        #expect(undone.opID == Self.opID)
        #expect(undone.toastID == UUID(uuidString: Self.opID))
        #expect(undone.news == nil)
    }

    /// Saves the undo moved aside are told once; those the restore already
    /// moved, which its toast or strip told, are not told again.
    @Test func anUndoThatMovedSavesAside_tellsOnlyTheNewOnes() throws {
        let restore = try Self.journal(Self.applied)
        let undoJournal = try Self.journal(Self.keptAside, opID: "U")
        let undone = try #require(RestoreOutcomePresentation.undo(.finished(undoJournal), of: restore, locale: Self.english))
        #expect(undone.news == RestoreText.keptAsideSentence(undoJournal.stage.keptAside, locale: Self.english))

        let movedAlready = try Self.journal(Self.keptAside)
        let again = try #require(RestoreOutcomePresentation.undo(.finished(undoJournal), of: movedAlready, locale: Self.english))
        #expect(again.news == nil)
    }

    /// An undo that fell short, or did not run, changes nothing: the record
    /// stays and says why.
    @Test func anUndoThatFellShortOrDidNotRun_doesNothing() throws {
        let journal = try Self.journal(Self.applied)
        let short = try [
            Self.journal(#"{"kind":"partiallyApplied","reason":"writeFailed","currentTree":"c"}"#, opID: "U"),
            Self.journal(#"{"kind":"aborted","reason":"externalChangeDetected"}"#, opID: "U"),
            Self.journal(#"{"kind":"writing"}"#, opID: "U")
        ]
        for undo in short {
            #expect(RestoreOutcomePresentation.undo(.finished(undo), of: journal, locale: Self.english) == nil)
        }
        #expect(RestoreOutcomePresentation.undo(.refused(.changedSinceRestore(paths: ["a.txt"])), of: journal, locale: Self.english) == nil)
        #expect(RestoreOutcomePresentation.undo(nil, of: journal, locale: Self.english) == nil)
    }

    /// Every "Done" line that offers this restore's Undo goes, shown or
    /// waiting, and no other: another restore's, or a mark's, keeps its Undo.
    @Test func anUndo_lapsesOnlyTheDoneLinesOfItsRestore() throws {
        let journal = try Self.journal(Self.applied)
        let undone = try #require(RestoreOutcomePresentation.undo(
            .finished(Self.journal(Self.applied, opID: "U")),
            of: journal,
            locale: Self.english
        ))
        let (mine, anotherRestore, marked, answered) = (UUID(), UUID(), UUID(), UUID())
        let lines: [UUID: DecisionBarContent.DoneResult] = [
            mine: .restored(RestoreDone(opID: Self.opID, root: "/repo", turnNumber: 5)),
            anotherRestore: .restored(RestoreDone(opID: "another", root: "/repo", turnNumber: 3)),
            marked: .markedViewed(ViewedLineUndo(conversation: TurnSummaryFixture.conversation, changeID: UUID())),
            answered: .answeredInTerminal
        ]
        #expect(undone.lapsedPanes(in: lines) == [mine])
        #expect(undone.lapsedPanes(in: [:]).isEmpty)
    }
}
