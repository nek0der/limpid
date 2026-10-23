// RestorePresentationTests.swift
// Limpid — what a restore says and decides: the confirmation, how it ended, the record, and the turns it took back.

import Foundation
import Testing
@testable import Limpid

struct RestorePresentationTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")
    private static let other = ConversationKey(provider: .claude, conversationID: "s2", isFallback: false)

    private static let changes = #"{"kind":"changed","files":1,"added":10,"removed":2}"#

    private static func turn(
        _ number: Int,
        changes: String = changes,
        hasPrompt: Bool = true,
        root: String = "/repo",
        conversationID: String = "s1",
        startedAt: String? = nil
    ) throws -> TurnSummary {
        var extras = TurnSummaryFixture.Extras()
        extras.beginTree = SnapshotTree(tree: TurnSummaryFixture.tree("b", number), root: root)
        extras.conversationID = conversationID
        extras.startedAt = startedAt ?? String(format: "2026-10-12T00:%02d:00Z", number)
        return try TurnSummaryFixture.turn(
            "\(conversationID)-T\(number)",
            changes: changes,
            hasPrompt: hasPrompt,
            number: number,
            extras: extras
        )
    }

    private static func gate(_ turn: TurnSummary, agents: [RestoreGate.Agent] = []) -> RestoreGate.Input {
        RestoreGate.Input(turn: turn, agents: agents, isWaiting: false, isRestoring: false)
    }

    // MARK: - The confirmation

    @Test func theConfirmation_namesTheTurnsUndone_andAddsUpTheirChanges() throws {
        let turns = try [Self.turn(5), Self.turn(6), Self.turn(7, changes: #"{"kind":"unchanged"}"#)]
        let undone = RestoreConfirmation.undone(by: turns[0], in: [TurnSummaryFixture.conversation: turns])
        let confirmation = RestoreConfirmation.make(turn: turns[0], undone: undone, gate: Self.gate(turns[0]), locale: Self.english)

        #expect(undone.map(\.displayNumber) == [5, 6, 7])
        #expect(confirmation.text == "Discard the changes in T5–T7 (+20 −4) and restore the code to before turn 5.")
        #expect(confirmation.note == "The conversation, staged changes, and commits aren’t changed")
        #expect(confirmation.blockedReason == nil)
        let japanese = RestoreConfirmation.make(turn: turns[0], undone: undone, gate: Self.gate(turns[0]), locale: Self.japanese)
        #expect(japanese.text == "T5〜T7 の変更（+20 −4）を破棄し、コードを T5 の前の状態に復元します。", "a run of turns as one range")
        #expect(japanese.note == "会話、ステージ済みの変更、コミットは変わりません")
        #expect(confirmation.textRuns(locale: Self.english) == [
            ReceiptRun(text: "Discard the changes in T5–T7 (", role: .emphasized),
            ReceiptRun(text: "+20", role: .added(isEmphasized: true)),
            ReceiptRun(text: " ", role: .emphasized),
            ReceiptRun(text: "−4", role: .removed(isEmphasized: true)),
            ReceiptRun(text: ") and restore the code to before turn 5.", role: .emphasized)
        ])
    }

    @Test func theConfirmationsCounts_areGroupedAsThePanelWritesThem_andFoundForTheirColors() {
        let text = RestoreText.confirmation(first: 5, last: 5, added: 12345, removed: 2, locale: Self.english)
        #expect(text == "Discard the changes in T5 (+12,345 −2) and restore the code to before turn 5.")
        let confirmation = RestoreConfirmation(text: text, note: "", blockedReason: nil, added: 12345, removed: 2)
        #expect(confirmation.textRuns(locale: Self.english).filter { $0.role != .emphasized } == [
            ReceiptRun(text: "+12,345", role: .added(isEmphasized: true)),
            ReceiptRun(text: "−2", role: .removed(isEmphasized: true))
        ])
    }

    @Test func oneTurn_isNamedAlone() throws {
        let turn = try Self.turn(7)
        let confirmation = RestoreConfirmation.make(turn: turn, undone: [turn], gate: Self.gate(turn), locale: Self.english)
        #expect(confirmation.text == "Discard the changes in T7 (+10 −2) and restore the code to before turn 7.")
    }

    @Test func aSharedWorktree_saysOthersChangesGoToo_andABlockedGateSaysWhy() throws {
        let turn = try Self.turn(5)
        let agents = [
            RestoreGate.Agent(provider: .claude, state: .idle, isTurnsOwn: true),
            RestoreGate.Agent(provider: .codex, state: .running, isTurnsOwn: false)
        ]
        let confirmation = RestoreConfirmation.make(
            turn: turn,
            undone: [turn],
            gate: Self.gate(turn, agents: agents),
            locale: Self.japanese
        )
        #expect(confirmation.note == "会話、ステージ済みの変更、コミットは変わりません · 同じワークツリーのほかのエージェントによる変更と手動の変更も復元されます")
        let english = RestoreConfirmation.make(turn: turn, undone: [turn], gate: Self.gate(turn, agents: agents), locale: Self.english)
        #expect(english.blockedReason == "Unavailable while Codex is running in the same worktree.")
        #expect(english.help(locale: Self.english) == english.text
            + " The counts don’t include the lines of other conversations’ turns in this worktree.")
        let alone = RestoreConfirmation.make(turn: turn, undone: [turn], gate: Self.gate(turn), locale: Self.english)
        #expect(alone.help(locale: Self.english) == alone.text, "nothing else is in the worktree to leave out")
        // Japanese sentences run on without a space between them.
        #expect(confirmation.help(locale: Self.japanese)
            == confirmation.text + RestoreText.countsOwnTurnsOnly(locale: Self.japanese))
    }

    @Test func undone_leavesEarlierTurnsOtherWorktreesAndRestoredTurnsOut() throws {
        let turns = try [Self.turn(4), Self.turn(5), Self.turn(6), Self.turn(8, root: "/other")]
        let undone = RestoreConfirmation.undone(by: turns[1], in: [TurnSummaryFixture.conversation: turns]) {
            $0.displayNumber == 6
        }
        #expect(undone.map(\.displayNumber) == [5])
    }

    /// A turn nobody prompted is not in the panel's list, so the range does
    /// not name it, but its changes go too and are counted.
    @Test func anUnpromptedTurn_isCounted_butNotNamed() throws {
        let turns = try [Self.turn(5), Self.turn(6, hasPrompt: false)]
        let undone = RestoreConfirmation.undone(by: turns[0], in: [TurnSummaryFixture.conversation: turns])
        let confirmation = RestoreConfirmation.make(turn: turns[0], undone: undone, gate: Self.gate(turns[0]), locale: Self.english)
        #expect(confirmation.text == "Discard the changes in T5 (+20 −4) and restore the code to before turn 5.")
    }

    @Test func theStrip_givesWayToWhatTheAgentAsks_butNotToUnreadTurnsOrAStop() {
        let subject = AttentionSubject.runtime(id: "r", provider: .claude, paneID: UUID(), tabID: nil, projectID: nil)
        var queue = AttentionQueue()
        queue.insert(
            id: .unread(TurnID("t")),
            kind: .unread(UnreadTurn(turnID: TurnID("t"), changes: .unknown, conversation: nil)),
            subject: subject,
            arrivedAt: Date()
        )
        queue.insert(
            id: .stop(EpisodeKey(origin: .runtime("r"), episodeToken: "0")),
            kind: .stop(.processExited),
            subject: subject,
            arrivedAt: Date()
        )
        #expect(!RestoreStrip.yields(to: queue.items))
        queue.insert(
            id: .prompt(EpisodeKey(origin: .runtime("r"), episodeToken: "1")),
            kind: .prompt(PromptWait(detail: nil)),
            subject: subject,
            arrivedAt: Date()
        )
        #expect(RestoreStrip.yields(to: queue.items))
    }

    // MARK: - The palette's turn

    private static func line(through turn: TurnSummary) -> ViewedLine {
        ViewedLine(conversation: turn.conversation, position: ViewedLinePosition(turn))
    }

    /// The first unviewed turn that can be restored to, else the latest.
    @Test func thePalette_restoresToTheFirstUnviewedTurn_elseTheLatest() throws {
        let turns = try [
            Self.turn(4),
            Self.turn(5, changes: #"{"kind":"unchanged"}"#),
            Self.turn(6, hasPrompt: false),
            Self.turn(7),
            Self.turn(8)
        ]
        let viewedThrough4 = Self.line(through: turns[0])

        #expect(RestoreEntryTarget.turn(in: turns, line: viewedThrough4)?.displayNumber == 7)
        #expect(RestoreEntryTarget.turn(in: turns, line: nil) { $0.displayNumber == 4 }?.displayNumber == 7)
        let allViewed = Self.line(through: turns[4])
        #expect(RestoreEntryTarget.turn(in: turns, line: allViewed)?.displayNumber == 8)
        #expect(RestoreEntryTarget.turn(in: [turns[1]], line: nil) == nil)
        // Still running, or its start not recorded: passed over.
        let running = try TurnSummaryFixture.turn("run", phase: "started", changes: Self.changes, number: 9)
        var unrecorded = TurnSummaryFixture.Extras()
        unrecorded.beginTree = nil
        let unrecordedTurn = try TurnSummaryFixture.turn("unrec", changes: Self.changes, number: 10, extras: unrecorded)
        #expect(RestoreEntryTarget.turn(in: [running, unrecordedTurn], line: nil) == nil)
    }

    // MARK: - How it ended

    private static func journal(
        _ stage: String,
        number: Int = 5,
        turnID: String = "s1-T5",
        at: String = "2026-10-12T00:07:30Z",
        ranAt: String? = nil
    ) throws -> RestoreJournal {
        try RestoreJournalFixture.make(
            stageJSON: stage,
            fields: .init(turnID: turnID, turnNumber: number, at: at, ranAt: ranAt)
        )
    }

    @Test func eachOutcome_endsAsTheAppTakesIt() throws {
        let applied = try Self.journal(#"{"kind":"applied"}"#)
        #expect(RestoreEnding(.finished(applied)) == .applied(applied))
        let partial = try Self.journal(#"{"kind":"partiallyApplied","reason":"externalChangeDetected","kept":["a"],"currentTree":"c"}"#)
        #expect(RestoreEnding(.finished(partial)) == .partial(partial, kept: ["a"], failed: []))
        let edited = try Self.journal(#"{"kind":"aborted","reason":"externalChangeDetected"}"#)
        #expect(RestoreEnding(.finished(edited)) == .canceled(.otherChanges))
        let prompted = try Self.journal(#"{"kind":"aborted","reason":"agentStarted"}"#)
        #expect(RestoreEnding(.finished(prompted)) == .canceled(.refused(.agentStarted)))
        #expect(RestoreEnding(.refused(.mergeInProgress)) == .canceled(.refused(.mergeInProgress)))
        let elsewise = try Self.journal(#"{"kind":"aborted","reason":"someday"}"#)
        #expect(RestoreEnding(.finished(elsewise)) == .canceled(.unknown))
        // Not known: nothing may say no file was changed.
        #expect(RestoreEnding(nil) == .unknown(opID: nil))
        let writing = try Self.journal(#"{"kind":"writing"}"#)
        #expect(RestoreEnding(.finished(writing)) == .unknown(opID: "OP"))
        #expect(try RestoreEnding(.finished(Self.journal(#"{"kind":"someday"}"#))) == .unknown(opID: "OP"))
    }

    @Test func theStrip_saysWhetherFilesWereWritten() throws {
        #expect(RestoreText.ended(.canceled(.refused(.mergeInProgress)), locale: Self.english)
            == "Restore canceled. A merge, a rebase, or a conflict is in progress.")
        #expect(RestoreText.ended(.canceled(.otherChanges), locale: Self.japanese)
            == "復元を中止しました。ほかの変更が見つかったため、ファイルは変更していません。")
        #expect(RestoreText.ended(.canceled(.unknown), locale: Self.japanese) == "復元を中止しました。ファイルは変更していません。")
        // A refusal the person cannot act on says only that nothing was written.
        #expect(RestoreText.ended(.canceled(.refused(.lockUnavailable)), locale: Self.english)
            == "Restore canceled. No files were changed.")
        #expect(RestoreText.ended(.partial(kept: ["a.txt"], failed: ["b", "c", "d", "e"]), locale: Self.english)
            == "Restored only part of the code. Kept the files changed meanwhile: a.txt. Couldn’t write: b, c, d, and 1 more.")
        #expect(RestoreText.ended(.partial(kept: [], failed: ["b", "c", "d", "e"]), locale: Self.japanese)
            == "コードの一部だけを復元しました。書き込めなかったファイル：b、c、d ほか 1 件。")
        // A save another writer made into a file the restore took out was
        // moved aside, and the strip says where.
        let aside = [RestoreKeptAside(path: "a.txt", location: ".limpid-OP/ready-1/a.txt")]
        #expect(RestoreText.ended(.partial(kept: [], failed: [], keptAside: aside), locale: Self.japanese)
            == "コードの一部だけを復元しました。その間に保存された内容は .limpid-OP/ready-1/a.txt に移動しました。")
        #expect(RestoreText.ended(.canceled(.refused(.unsupportedVolume)), locale: Self.english)
            == "Restore canceled. These files can’t be swapped in one step where they are, so this isn’t available here.")
        #expect(RestoreText.ended(.canceled(.refused(.renamedInPlace(["Name.txt"]))), locale: Self.japanese)
            == "復元を中止しました。このボリュームが同じ名前として扱う名前への変更（大文字と小文字だけの違いなど）があります：Name.txt。")
        // Whole, with a save moved aside: not called partial anywhere.
        let whole = try Self.journal(#"{"kind":"partiallyApplied","reason":"keptAside","currentTree":"c","#
            + #""failed":[{"path":"a.txt","reason":"keptAside:.limpid-OP/target/ready-1/a.txt"}]}"#)
        #expect(RestoreEnding(.finished(whole)) == .applied(whole))
        #expect(RestoreText.toast(
            ToastKind.restoreInterrupted.message.resolved(in: Self.japanese),
            note: RestoreText.keptAsideSentence(whole.stage.keptAside, locale: Self.japanese),
            locale: Self.japanese
        ) == "前回の終了時に、コードの復元が途中で中断されました。その間に保存された内容は .limpid-OP/target/ready-1/a.txt に移動しました。")
        #expect(RestoreText.record(whole, locale: Self.english) == RestoreText.record(
            turnNumber: 5,
            isPartial: false,
            locale: Self.english
        ))
        #expect(RestoreText.ended(.unknown, locale: Self.english).hasPrefix("Couldn’t tell"))
    }

    @Test func theRecord_namesTheTurn_andSaysWhenOnlyPartIsThere() throws {
        #expect(try RestoreText.record(Self.journal(#"{"kind":"applied"}"#), locale: Self.japanese) == "T5 の前に復元済み")
        let partial = #"{"kind":"partiallyApplied","reason":"interrupted","currentTree":"c"}"#
        #expect(try RestoreText.record(Self.journal(partial), locale: Self.english) == "Partly restored to before T5")
        let unnamed = try RestoreJournalFixture.make(stageJSON: #"{"kind":"applied"}"#, fields: .init(turnID: "T5", at: "x"))
        #expect(RestoreText.record(unnamed, locale: Self.japanese) == "コードを復元済み")
        #expect(RestoreText.recordHelp(locale: Self.english).hasPrefix("Only the working tree was restored."))
    }

    @Test func anUndoThatFellShort_saysHow() {
        #expect(RestoreText.undoResult(.refused(.changedSinceRestore(paths: ["a", "b", "c", "d"])), locale: Self.english)
            == "Couldn’t undo the restore. Files changed since then: a, b, c, and 1 more.")
        #expect(RestoreText.undoResult(.refused(.restoreNotFound), locale: Self.japanese)
            == "復元を取り消せませんでした。ファイルは変更していません。")
        #expect(RestoreText.undoResult(.partial(keptAside: []), locale: Self.japanese) == "復元の一部だけを取り消しました。")
        let aside = [RestoreKeptAside(path: "a.txt", location: ".limpid-OP/out/a.txt")]
        #expect(RestoreText.undoResult(.partial(keptAside: aside), locale: Self.english)
            == "Undid only part of the restore. Saves made meanwhile were moved to .limpid-OP/out/a.txt.")
    }

    @Test func theUndoResult_isKeptOnlyWhenTheUndoFellShort() throws {
        let undone = try Self.journal(#"{"kind":"applied"}"#)
        #expect(RestoreCoordinator.UndoResult(.finished(undone)) == nil)
        let partial = try Self.journal(#"{"kind":"partiallyApplied","reason":"writeFailed","currentTree":"c"}"#)
        #expect(RestoreCoordinator.UndoResult(.finished(partial)) == .partial(keptAside: []))
        // An undo that is whole with a save moved aside took the restore
        // back; a toast says where the save went.
        let aside = try Self.journal(#"{"kind":"partiallyApplied","reason":"keptAside","currentTree":"c","#
            + #""failed":[{"path":"a.txt","reason":"keptAside:.limpid-OP/target/ready-1/a.txt"}]}"#)
        #expect(RestoreCoordinator.UndoResult(.finished(aside)) == nil)
        #expect(RestoreText.keptAsideNews(.finished(aside), locale: Self.japanese)
            == "その間に保存された内容は .limpid-OP/target/ready-1/a.txt に移動しました。")
        #expect(RestoreText.keptAsideNews(.finished(undone), locale: Self.japanese) == nil)
        // An undo's record also carries the saves of the restore it undid,
        // which were told then: said once.
        #expect(RestoreText.keptAsideNews(.finished(aside), besides: aside.stage.keptAside, locale: Self.japanese) == nil)
        // A refusal an agent's stop lifts may change; one of a gone
        // operation never does.
        #expect(RestoreCoordinator.UndoResult.refused(.agentActive(.claude)).mayChange)
        #expect(!RestoreCoordinator.UndoResult.refused(.notUndoable).mayChange)
        let aborted = try Self.journal(#"{"kind":"aborted","reason":"externalChangeDetected"}"#)
        #expect(RestoreCoordinator.UndoResult(.finished(aborted)) == .canceled)
        #expect(RestoreCoordinator.UndoResult(.refused(.notUndoable)) == .refused(.notUndoable))
        let writing = try Self.journal(#"{"kind":"writing"}"#)
        #expect(RestoreCoordinator.UndoResult(.finished(writing)) == .unknown)
        #expect(RestoreCoordinator.UndoResult(nil) == .unknown)
        #expect(RestoreText.undoResult(.unknown, locale: Self.japanese).hasPrefix("復元の取り消しの結果を確認できませんでした。"))
    }

    @Test func everyBlocker_hasItsReason() {
        let blockers: [RestoreGate.Blocker] = [
            .notRecorded, .turnRunning, .agentRunning(other: nil), .agentRunning(other: .claude), .agentWaiting, .restoring
        ]
        let reasons = Set(blockers.map { RestoreText.blocker($0, locale: Self.japanese) })
        #expect(reasons.count == blockers.count)
        #expect(RestoreText.blocker(.agentRunning(other: nil), locale: Self.japanese) == "エージェントの実行中は使用できません。")
    }

    // MARK: - The turns a restore took back

    private static func isRepo(_ root: String) -> Bool {
        root == "/repo"
    }

    @Test func aRestore_tookBackEveryConversationsTurnsInItsWorktree_untilItRan() throws {
        let history: [ConversationKey: [TurnSummary]] = try [
            TurnSummaryFixture.conversation: [Self.turn(4), Self.turn(5), Self.turn(6), Self.turn(9)],
            Self.other: [Self.turn(7, conversationID: "s2"), Self.turn(8, root: "/other", conversationID: "s2")]
        ]
        let journal = try Self.journal(#"{"kind":"applied"}"#)

        let restored = RestoredTurns.of(journal, history: history, isRoot: Self.isRepo)

        // T4 began before the turn restored to, T8 elsewhere, and T9 after
        // the restore ran.
        #expect(Set(restored.map(\.turnID.rawValue)) == ["s1-T5", "s1-T6", "s2-T7"])
        #expect(RestoredTurns.isSuperseded(journal, history: history, isRoot: Self.isRepo))
        var before = history
        before[TurnSummaryFixture.conversation]?.removeLast()
        #expect(!RestoredTurns.isSuperseded(journal, history: before, isRoot: Self.isRepo))
    }

    /// The turns read as restored until the restore is undone, whichever
    /// list asks: a turn begun after it ends its record, not the fact that
    /// those changes are gone.
    @Test func theTurnsARestoreTookBack_staySo_untilItIsUndone() throws {
        let history: [ConversationKey: [TurnSummary]] = try [
            TurnSummaryFixture.conversation: [Self.turn(4), Self.turn(5), Self.turn(6), Self.turn(9)],
            Self.other: [Self.turn(7, conversationID: "s2")]
        ]
        let applied = try Self.journal(#"{"kind":"applied"}"#)
        let isRoot: (String) -> (String) -> Bool = { root in { $0 == root } }
        #expect(RestoredTurns.isSuperseded(applied, history: history, isRoot: Self.isRepo))

        let ids = RestoredTurns.ids(journals: ["/repo": [applied]], history: history, isRoot: isRoot)
        #expect(Set(ids.map(\.rawValue)) == ["s1-T5", "s1-T6", "s2-T7"])
        let undone = try Self.journal(#"{"kind":"undone","by":"U"}"#)
        #expect(RestoredTurns.ids(journals: ["/repo": [undone]], history: history, isRoot: isRoot).isEmpty)
    }

    /// A restore that left some paths as another writer changed them, or
    /// could not write them, took back nothing whole: its turns keep their
    /// changes and are read as before. One that only moved saves aside is
    /// whole.
    @Test func onlyAWholeRestore_readsItsTurnsAsRestored() throws {
        let history: [ConversationKey: [TurnSummary]] = try [
            TurnSummaryFixture.conversation: [Self.turn(5), Self.turn(6)]
        ]
        let isRoot: (String) -> (String) -> Bool = { root in { $0 == root } }
        let partial = try Self.journal(#"{"kind":"partiallyApplied","reason":"externalChangeDetected","kept":["a"],"currentTree":"c"}"#)
        #expect(RestoredTurns.ids(journals: ["/repo": [partial]], history: history, isRoot: isRoot).isEmpty)
        let aside = try Self.journal(#"{"kind":"partiallyApplied","reason":"keptAside","currentTree":"c","#
            + #""failed":[{"path":"a.txt","reason":"keptAside:.limpid-OP/target/ready-1/a.txt"}]}"#)
        #expect(aside.stage.isWhole)
        #expect(RestoredTurns.ids(journals: ["/repo": [aside]], history: history, isRoot: isRoot).count == 2)
    }

    /// Times are kept to the second, so a turn can start in the second the
    /// restore ran. Such a turn counts as begun after it
    /// (`RestoredTurns.began`): it is not taken back, and it ends the
    /// record. One a second earlier is the restore's.
    @Test func aTurnStartingInTheSecondTheRestoreRan_beganAfterIt() throws {
        let journal = try Self.journal(#"{"kind":"applied"}"#, at: "2026-10-12T00:07:30Z")
        let justBefore = try [TurnSummaryFixture.conversation: [
            Self.turn(5),
            Self.turn(6, startedAt: "2026-10-12T00:07:29Z")
        ]]
        #expect(Set(RestoredTurns.of(journal, history: justBefore, isRoot: Self.isRepo).map(\.turnID.rawValue)) == ["s1-T5", "s1-T6"])
        #expect(!RestoredTurns.isSuperseded(journal, history: justBefore, isRoot: Self.isRepo))

        let sameSecond = try [TurnSummaryFixture.conversation: [
            Self.turn(5),
            Self.turn(6, startedAt: "2026-10-12T00:07:30Z")
        ]]
        #expect(RestoredTurns.of(journal, history: sameSecond, isRoot: Self.isRepo).map(\.turnID.rawValue) == ["s1-T5"])
        #expect(RestoredTurns.isSuperseded(journal, history: sameSecond, isRoot: Self.isRepo))
        let isRoot: (String) -> (String) -> Bool = { root in { $0 == root } }
        #expect(RestoredTurns.ids(journals: ["/repo": [journal]], history: sameSecond, isRoot: isRoot).map(\.rawValue) == ["s1-T5"])
    }

    /// A journal whose time cannot be read ends no record, and takes back
    /// every turn from the one it went back to.
    @Test func aRestoreWithNoTimeKnown_isNeverSuperseded() throws {
        let journal = try Self.journal(#"{"kind":"applied"}"#, at: "someday")
        let history = try [TurnSummaryFixture.conversation: [Self.turn(5), Self.turn(9)]]
        #expect(RestoredTurns.of(journal, history: history, isRoot: Self.isRepo).count == 2)
        #expect(!RestoredTurns.isSuperseded(journal, history: history, isRoot: Self.isRepo))
    }

    /// A restore a crash cut short is settled by a later recovery, which
    /// writes its journal again (`at`); when it ran stays (`ranAt`). A turn
    /// begun between the two began after the restore: its changes are not
    /// taken back, and it ends the record. One from before it still is.
    @Test func aTurnBegunBeforeRecoverySettledTheRestore_beganAfterIt() throws {
        let journal = try Self.journal(#"{"kind":"applied"}"#, at: "2026-10-12T00:20:00Z", ranAt: "2026-10-12T00:07:30Z")
        let history = try [TurnSummaryFixture.conversation: [Self.turn(5), Self.turn(6), Self.turn(9)]]

        #expect(Set(RestoredTurns.of(journal, history: history, isRoot: Self.isRepo).map(\.turnID.rawValue)) == ["s1-T5", "s1-T6"])
        #expect(RestoredTurns.isSuperseded(journal, history: history, isRoot: Self.isRepo))
    }

    /// A journal from before `ranAt` is read by its `at`, as before.
    @Test func aJournalWithoutRanAt_ranWhenItWasWritten() throws {
        let journal = try Self.journal(#"{"kind":"applied"}"#, at: "2026-10-12T00:20:00Z")
        #expect(journal.ranAt == "2026-10-12T00:20:00Z")
        let history = try [TurnSummaryFixture.conversation: [Self.turn(5), Self.turn(9)]]
        #expect(RestoredTurns.of(journal, history: history, isRoot: Self.isRepo).count == 2)
        #expect(!RestoredTurns.isSuperseded(journal, history: history, isRoot: Self.isRepo))
    }

    @Test func aRestoreWhoseTurnIsGone_tookBackNothingThatCanBeNamed() throws {
        let history = try [TurnSummaryFixture.conversation: [Self.turn(6)]]
        let journal = try Self.journal(#"{"kind":"applied"}"#)
        #expect(RestoredTurns.of(journal, history: history, isRoot: Self.isRepo).isEmpty)
    }

    /// The index built once for many journals answers as each journal
    /// asked alone does, so sharing it changes no turn's reading.
    @Test func everyStandingRestore_readFromOneIndex_answersAsEachAlone() throws {
        let history: [ConversationKey: [TurnSummary]] = try [
            TurnSummaryFixture.conversation: [Self.turn(4), Self.turn(5), Self.turn(6), Self.turn(9)],
            Self.other: [Self.turn(7, conversationID: "s2"), Self.turn(8, root: "/other", conversationID: "s2")]
        ]
        let first = try Self.journal(#"{"kind":"applied"}"#)
        let second = try Self.journal(#"{"kind":"applied"}"#, number: 4, turnID: "s1-T4", at: "2026-10-12T00:05:30Z")
        let isRoot: (String) -> (String) -> Bool = { root in { $0 == root } }

        let ids = RestoredTurns.ids(journals: ["/repo": [second, first]], history: history, isRoot: isRoot)

        let alone = [first, second].flatMap { RestoredTurns.of($0, history: history, isRoot: Self.isRepo) }
        #expect(ids == Set(alone.map(\.turnID)))
        #expect(Set(ids.map(\.rawValue)) == ["s1-T4", "s1-T5", "s1-T6", "s2-T7"])
    }

    /// The restored turns are worked out again only when the history, the
    /// journals (an Undo, a new restore, the sweep), or the path spellings
    /// moved; otherwise the kept answer is read.
    @Test func theRestoredTurns_areWorkedOutAgain_onlyWhenASourceMoved() throws {
        let applied = try Self.journal(#"{"kind":"applied"}"#)
        let undone = try Self.journal(#"{"kind":"undone","by":"U"}"#)
        let key = RestoredTurnsMemo.Key(historyRevision: 1, journals: ["/repo": [applied]], pathGeneration: 0)
        var kept: RestoredTurnsMemo?
        var computed = 0
        let compute: (RestoredTurnsMemo.Key) -> Set<TurnID> = { key in
            computed += 1
            return key.journals.values.joined().contains(where: \.isUndoable) ? [TurnID("s1-T5")] : []
        }

        #expect(RestoredTurnsMemo.ids(for: key, kept: &kept, compute: compute) == [TurnID("s1-T5")])
        #expect(RestoredTurnsMemo.ids(for: key, kept: &kept, compute: compute) == [TurnID("s1-T5")])
        #expect(computed == 1)

        let changedHistory = RestoredTurnsMemo.Key(historyRevision: 2, journals: key.journals, pathGeneration: 0)
        _ = RestoredTurnsMemo.ids(for: changedHistory, kept: &kept, compute: compute)
        #expect(computed == 2)

        let afterUndo = RestoredTurnsMemo.Key(historyRevision: 2, journals: ["/repo": [undone]], pathGeneration: 0)
        #expect(RestoredTurnsMemo.ids(for: afterUndo, kept: &kept, compute: compute).isEmpty)
        #expect(computed == 3)

        let swept = RestoredTurnsMemo.Key(historyRevision: 2, journals: [:], pathGeneration: 0)
        _ = RestoredTurnsMemo.ids(for: swept, kept: &kept, compute: compute)
        #expect(computed == 4)

        let forgotten = RestoredTurnsMemo.Key(historyRevision: 2, journals: [:], pathGeneration: 1)
        _ = RestoredTurnsMemo.ids(for: forgotten, kept: &kept, compute: compute)
        _ = RestoredTurnsMemo.ids(for: forgotten, kept: &kept, compute: compute)
        #expect(computed == 5)
    }

    /// The history's revision moves with its turns and only with them, so
    /// the kept restored turns are asked again exactly when they may differ.
    @MainActor
    @Test func theHistorysRevision_movesOnlyWhenItsTurnsChange() throws {
        let history = TurnHistory()
        let turns = try ConversationTurns(key: TurnSummaryFixture.conversation, turns: [Self.turn(5)])
        history.replace(with: [turns])
        let afterFirst = history.revision
        history.replace(with: [turns])
        #expect(history.revision == afterFirst)
        try history.replace(with: [ConversationTurns(key: TurnSummaryFixture.conversation, turns: [Self.turn(5), Self.turn(6)])])
        #expect(history.revision != afterFirst)
    }

    /// Letting go of a project's spellings moves the resolver's generation,
    /// as a folder made again may link elsewhere.
    @MainActor
    @Test func forgettingSpellings_movesThePathGeneration() {
        let paths = WorktreePathResolver(resolveLinks: { $0 })
        _ = paths.resolved("/repo")
        let before = paths.generation
        paths.forget([])
        #expect(paths.generation == before)
        paths.forget(["/repo"])
        #expect(paths.generation != before)
    }

    // MARK: - The bar after a restore

    @Test func theBar_saysTheRestoreIsNotInTheConversation_andOffersItsUndo() {
        let done = RestoreDone(opID: "OP", root: "/repo", turnNumber: 5)
        let content = DecisionBarContent.make(.init(done: .init(result: .restored(done), next: nil)))
        let model = DecisionBarModel(content: content, locale: Self.japanese)
        #expect(model.text == "T5 の前に復元済み · 会話には反映されていません")
        #expect(model.restoreDone == done)
        #expect(!model.isAtRest)
    }

    @Test func theBar_isAtRest_onlyWhileTheAgentIsNotAtWork() {
        let idle = DecisionBarModel(content: DecisionBarContent(body: .summary(.idle), position: nil, itemID: nil), locale: Self.english)
        #expect(idle.isAtRest)
        let running = DecisionBarModel(
            content: DecisionBarContent(body: .summary(.running("Bash: swift test")), position: nil, itemID: nil),
            locale: Self.english
        )
        #expect(!running.isAtRest)
    }
}
