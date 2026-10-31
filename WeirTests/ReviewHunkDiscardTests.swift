// ReviewHunkDiscardTests.swift
// Weir — what a review hunk's "Discard" offers, and what a discard's outcome makes of each hunk.

import Foundation
import Testing
@testable import Weir

struct ReviewHunkDiscardTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")
    private static let key = ReviewHunkKey(
        scopeID: "turns:s1-T5",
        root: "/repo",
        fromTree: "a",
        toTree: "b",
        path: "f.txt",
        header: "@@ -1,3 +1,3 @@"
    )
    private static let other = ReviewHunkKey(
        scopeID: "turns:s1-T5",
        root: "/repo",
        fromTree: "a",
        toTree: "b",
        path: "f.txt",
        header: "@@ -7,3 +7,4 @@"
    )

    private static func input(
        isTurnRange: Bool = true,
        isRenamed: Bool = false,
        blocker: RestoreGate.Blocker? = nil,
        later: ReviewHunkDiscardRules.Later = .none,
        record: ReviewHunkDiscardRecord? = nil
    ) -> ReviewHunkDiscardRules.Input {
        .init(isTurnRange: isTurnRange, isRenamed: isRenamed, blocker: blocker, later: later, record: record)
    }

    // MARK: - What the header offers

    @Test func aTurnRangesHunk_offersDiscard_andNothingElseDoes() {
        #expect(ReviewHunkDiscardRules.action(Self.input(), locale: Self.english) == .discard(blockedReason: nil))
        #expect(ReviewHunkDiscardRules.action(Self.input(isTurnRange: false), locale: Self.english) == nil)
        #expect(ReviewHunkDiscardRules.action(Self.input(isRenamed: true), locale: Self.english) == nil)
    }

    /// The worktree's gate first, as for a restore; then a later
    /// turn's change of the file.
    @Test func discard_isOff_withTheGatesReason_orALaterTurns() {
        let waiting = ReviewHunkDiscardRules.action(
            Self.input(blocker: .agentWaiting, later: .changed(afterTurn: 6)),
            locale: Self.english
        )
        #expect(waiting == .discard(blockedReason: "Unavailable while an agent is waiting for an approval or an answer."))
        let later = ReviewHunkDiscardRules.action(Self.input(later: .changed(afterTurn: 6)), locale: Self.japanese)
        #expect(later == .discard(blockedReason: "T6 より後のターンでこのファイルが変更されているため破棄できません。最新のターンから操作してください。"))
        // Until Git says, or when it cannot, the discard waits: the match
        // check stops a hunk whose own lines changed, not its file's others.
        #expect(ReviewHunkDiscardRules.action(Self.input(later: .checking), locale: Self.english)
            == .discard(blockedReason: "Checking whether a later turn changed this file…"))
        #expect(ReviewHunkDiscardRules.action(Self.input(later: .failed), locale: Self.english)
            == .discard(blockedReason: "Couldn’t check whether a later turn changed this file."))
        #expect(ReviewHunkDiscardRules.action(Self.input(later: .unchanged), locale: Self.english) == .discard(blockedReason: nil))
    }

    @Test func aDiscardedHunk_offersItsUndo_andAFailedOneSaysWhy() {
        let discarded = ReviewHunkDiscardRules.action(
            Self.input(blocker: .agentRunning(other: nil), record: .discarded(opID: "OP", root: "/repo", note: "no")),
            locale: Self.english
        )
        #expect(discarded == .discarded(blockedReason: "Unavailable while an agent is running.", note: "no"))
        #expect(ReviewHunkDiscardRules.action(Self.input(record: .running), locale: Self.english) == .running)
        #expect(ReviewHunkDiscardRules.action(Self.input(record: .failed("why")), locale: Self.english)
            == .failed("why", blockedReason: nil))
    }

    // MARK: - What the outcome made of each hunk

    private static func journal() throws -> RestoreJournal {
        try RestoreJournalFixture.make(stageJSON: #"{"kind":"applied"}"#, fields: .init(operation: "discard"))
    }

    /// One discarded and one whose lines changed: each says its own.
    @Test func discardingHunks_reportsEachHunksOwnResult() throws {
        let outcome = try DiscardOutcome.finished(Self.journal(), [
            DiscardHunkResult(path: "f.txt", header: Self.key.header, result: .discarded),
            DiscardHunkResult(path: "f.txt", header: Self.other.header, result: .notFound)
        ])

        let records = ReviewHunkDiscardRules.records(outcome, keys: [Self.key, Self.other], locale: Self.english)

        #expect(records[Self.key] == .discarded(opID: "OP", root: "/repo", note: nil))
        #expect(records[Self.other] == .failed("Couldn’t discard. The hunk’s lines changed after the review showed them."))
        let converted = try DiscardOutcome.finished(nil, [
            DiscardHunkResult(path: "f.txt", header: Self.key.header, result: .converted)
        ])
        #expect(ReviewHunkDiscardRules.records(converted, keys: [Self.key], locale: Self.japanese)[Self.key]
            == .failed("破棄できませんでした。Git がこのファイルの改行や内容を変換するため、元どおりに書き戻せません。"))
    }

    /// A save made into the file the discard took out was moved aside: the
    /// hunk is discarded, and says where the save went.
    @Test func aSaveKeptAside_isNamedOnItsFilesHunk() throws {
        let journal = try RestoreJournalFixture.make(stageJSON: """
        {"kind":"partiallyApplied","reason":"writeFailed","currentTree":"c",
         "failed":[{"path":"f.txt","reason":"keptAside:.weir-OP/ready-1/f.txt"}]}
        """, fields: .init(operation: "discard"))
        let outcome = DiscardOutcome.finished(journal, [
            DiscardHunkResult(path: "f.txt", header: Self.key.header, result: .discarded)
        ])
        let records = ReviewHunkDiscardRules.records(outcome, keys: [Self.key], locale: Self.english)
        #expect(records[Self.key] == .discarded(
            opID: "OP",
            root: "/repo",
            note: "Saves made meanwhile were moved to .weir-OP/ready-1/f.txt."
        ))
    }

    /// Not read to its end: it may have been written, so its undo stays,
    /// and it is not called discarded.
    @Test func aHunkWhoseEndIsNotKnown_keepsItsUndo_andIsNotCalledDiscarded() throws {
        let outcome = try DiscardOutcome.finished(Self.journal(), [
            DiscardHunkResult(path: "f.txt", header: Self.key.header, result: .unknown)
        ])
        let records = ReviewHunkDiscardRules.records(outcome, keys: [Self.key], locale: Self.english)
        #expect(records[Self.key] == .uncertain(opID: "OP", root: "/repo", note: nil))
        let action = ReviewHunkDiscardRules.action(Self.input(record: records[Self.key]), locale: Self.english)
        #expect(action == .uncertain(blockedReason: nil, note: "Couldn’t tell whether the hunk was discarded. Check the file."))
    }

    /// An undo refused because Git now converts the file says why.
    @Test func anUndoRefusedForAConvertedFile_saysWhy() {
        #expect(ReviewHunkDiscardText.undoFailed(.refused(.converted(["f.txt"])), locale: Self.japanese)
            == "破棄を取り消せませんでした。Git が書き込むときにこれらのファイルを変換するようになったため、元の内容に戻せません：f.txt。")
    }

    @Test func aRefusal_saysNothingWasWritten_andNoAnswerSaysItIsNotKnown() {
        let refused = ReviewHunkDiscardRules.records(.refused(.mergeInProgress), keys: [Self.key], locale: Self.japanese)
        #expect(refused[Self.key] == .failed("破棄できませんでした。マージ、リベース、または競合の解決の途中です。"))
        let generic = ReviewHunkDiscardRules.records(.refused(.lockUnavailable), keys: [Self.key], locale: Self.japanese)
        #expect(generic[Self.key] == .failed("破棄できませんでした。ファイルは変更していません。"))
        let unknown = ReviewHunkDiscardRules.records(nil, keys: [Self.key], locale: Self.english)
        #expect(unknown[Self.key] == .failed("Couldn’t tell whether the hunk was discarded. Check the file."))
    }

    // MARK: - The turn after the range

    /// A turn of the worktree's timeline, by its number, its conversation,
    /// and when it started and ended, in seconds into the day. Two
    /// conversations' turns end at one tree when they share a number, an
    /// end, and `endKind`; Codex's never share Claude's.
    struct Timed: Sendable, CustomTestStringConvertible {
        let number: Int
        var conversation = "claude"
        let start: Int
        let end: Int?
        var phase = "finished"
        var root = "/repo"

        var testDescription: String {
            "\(conversation) T\(number)"
        }

        func turn() throws -> TurnSummary {
            try TurnSummaryFixture.timed(
                number,
                conversation: conversation,
                start: start,
                end: end,
                phase: phase,
                endKind: conversation == "codex" ? "c" : "a",
                root: root
            )
        }
    }

    private static func turns(_ timed: [Timed]) throws -> [TurnSummary] {
        try timed.map { try $0.turn() }
    }

    private static func isRepo(_ root: String) -> Bool {
        root == "/repo"
    }

    /// The turn after a range is its worktree's turn, any conversation's,
    /// that ended last after the range's end turn: one that began before the
    /// range ended and ended after it counts, one that ended inside it does not,
    /// and neither does one of another worktree or one still running. Two
    /// turns of one conversation ended in one second are in the order they
    /// are numbered, since a conversation runs one turn at a time.
    @Test func theTurnAfterTheRange_isTheWorktreesTurnThatEndedLast_afterTheRangesEnd() throws {
        let worktree = try Self.turns([
            Timed(number: 5, start: 300, end: 330),
            Timed(number: 6, start: 360, end: 390),
            Timed(number: 7, start: 420, end: 450),
            Timed(number: 8, start: 480, end: 510),
            Timed(number: 9, start: 540, end: 570, root: "/other"),
            Timed(number: 10, start: 600, end: nil, phase: "started")
        ])
        #expect(ReviewHunkDiscardRules.laterTurn(after: worktree[1], in: worktree, isRoot: Self.isRepo)?.displayNumber == 8)
        #expect(ReviewHunkDiscardRules.laterTurn(after: worktree[3], in: worktree, isRoot: Self.isRepo) == nil)

        let last = try Timed(number: 4, start: 600, end: 720).turn()
        let insideAndOn = try Timed(number: 2, conversation: "codex", start: 540, end: 900).turn()
        let inside = try Timed(number: 1, conversation: "quiet", start: 600, end: 660).turn()
        let after = try Timed(number: 5, start: 780, end: 840).turn()
        #expect(
            ReviewHunkDiscardRules.laterTurn(after: last, in: [inside, last, insideAndOn, after], isRoot: Self.isRepo)?.turnID
                == insideAndOn.turnID,
            "began before the range ended, ended last"
        )
        #expect(ReviewHunkDiscardRules.laterTurn(after: last, in: [inside, last], isRoot: Self.isRepo) == nil)

        let tied = try Self.turns([Timed(number: 1, start: 0, end: 65), Timed(number: 2, start: 0, end: 65)])
        #expect(ReviewHunkDiscardRules.laterTurn(after: tied[0], in: tied, isRoot: Self.isRepo)?.turnID == tied[1].turnID)
        #expect(ReviewHunkDiscardRules.laterTurn(after: tied[1], in: tied, isRoot: Self.isRepo) == nil, "T1 ended before T2")
        let otherTied = try Timed(number: 1, conversation: "codex", start: 0, end: 65).turn()
        #expect(ReviewHunkDiscardRules.laterTurn(after: tied[0], in: [tied[0], otherTied], isRoot: Self.isRepo) == nil)
    }

    /// Turns around a range's end turn, and whether it is unknown which of
    /// them the file holds after the range: it is when a turn of another
    /// conversation ended in the same recorded second at another tree, and
    /// no turn is known to have ended later.
    struct Order: Sendable, CustomTestStringConvertible {
        let name: String
        let turns: [Timed]
        /// The range's end turn, in `turns`.
        let end: Int
        var root = "/repo"
        let isUnknown: Bool

        var testDescription: String {
            name
        }
    }

    static let orders = [
        Order(
            name: "a later turn of the same conversation in the same second",
            turns: [Timed(number: 1, start: 0, end: 65), Timed(number: 2, start: 0, end: 65)],
            end: 0,
            isUnknown: false
        ),
        Order(
            name: "another conversation's turn in the same second, at another tree",
            turns: [Timed(number: 1, start: 0, end: 65), Timed(number: 1, conversation: "codex", start: 0, end: 65)],
            end: 0,
            isUnknown: true
        ),
        Order(
            name: "the same conversation's later turn and another's, all in one second",
            turns: [
                Timed(number: 1, start: 0, end: 65),
                Timed(number: 2, start: 0, end: 65),
                Timed(number: 1, conversation: "codex", start: 0, end: 65)
            ],
            end: 0,
            isUnknown: true
        ),
        Order(
            name: "the conversation's own earlier turn in that second",
            turns: [Timed(number: 3, start: 300, end: 720), Timed(number: 4, start: 600, end: 720)],
            end: 1,
            isUnknown: false
        ),
        Order(
            name: "a tied turn, read for another worktree",
            turns: [Timed(number: 4, start: 600, end: 720), Timed(number: 2, conversation: "codex", start: 660, end: 720)],
            end: 0,
            root: "/other",
            isUnknown: false
        ),
        Order(
            name: "a tied turn, and a turn known to have ended later",
            turns: [
                Timed(number: 4, start: 600, end: 720),
                Timed(number: 2, conversation: "codex", start: 660, end: 720),
                Timed(number: 5, start: 780, end: 840)
            ],
            end: 0,
            isUnknown: false
        ),
        Order(
            name: "two later turns of two conversations in one second, at two trees",
            turns: [
                Timed(number: 4, start: 600, end: 720),
                Timed(number: 5, start: 780, end: 900),
                Timed(number: 2, conversation: "codex", start: 780, end: 900)
            ],
            end: 0,
            isUnknown: true
        ),
        Order(
            name: "the same two, listed the other way round",
            turns: [
                Timed(number: 4, start: 600, end: 720),
                Timed(number: 2, conversation: "codex", start: 780, end: 900),
                Timed(number: 5, start: 780, end: 900)
            ],
            end: 0,
            isUnknown: true
        ),
        Order(
            name: "two later turns in one second, at one tree",
            turns: [
                Timed(number: 4, start: 600, end: 720),
                Timed(number: 5, start: 780, end: 900),
                Timed(number: 5, conversation: "quiet", start: 780, end: 900)
            ],
            end: 0,
            isUnknown: false
        ),
        Order(
            name: "two later turns of one conversation in one second",
            turns: [
                Timed(number: 4, start: 600, end: 720),
                Timed(number: 6, start: 840, end: 900),
                Timed(number: 5, start: 780, end: 900)
            ],
            end: 0,
            isUnknown: false
        ),
        Order(
            name: "two tied later turns, and one known to have ended after both",
            turns: [
                Timed(number: 4, start: 600, end: 720),
                Timed(number: 5, start: 780, end: 900),
                Timed(number: 2, conversation: "codex", start: 780, end: 900),
                Timed(number: 7, start: 960, end: 1020)
            ],
            end: 0,
            isUnknown: false
        )
    ]

    @Test(arguments: orders)
    func whichTurnTheFileHoldsAfterTheRange_isUnknown_onlyForATieAtTwoTrees(_ order: Order) throws {
        let turns = try Self.turns(order.turns)
        let root = order.root
        #expect(ReviewHunkDiscardRules.isLaterOrderUnknown(after: turns[order.end], in: turns) { $0 == root } == order.isUnknown)
    }

    /// What turns say after a range is read once per history revision and
    /// path generation, however often the review draws, and read again
    /// as soon as either moves, so a kept reading never answers for turns
    /// it did not see.
    @MainActor
    @Test func whatTurnsSayAfterARange_isReadAgainOnlyWhenTheHistoryOrSpellingsMove() throws {
        let tied = try Self.turns([
            Timed(number: 4, start: 600, end: 720),
            Timed(number: 5, start: 780, end: 900),
            Timed(number: 2, conversation: "codex", start: 780, end: 900)
        ])
        let history = TurnHistory()
        let conversations = { (turns: [TurnSummary]) in
            Dictionary(grouping: turns, by: \.conversation).map { ConversationTurns(key: $0.key, turns: $0.value) }
        }
        history.replace(with: conversations(tied))
        let range = try #require(ReviewTurnRange(turns: [tied[0]]))
        let paths = WorktreePathResolver(resolveLinks: { $0 })
        let cache = ReviewLaterTurns()

        let first = cache.later(after: range, history: history, paths: paths)
        #expect(first?.isOrderUnknown == true)
        #expect(first == ReviewLaterTurns.read(after: range, history: history, paths: paths))
        _ = cache.later(after: range, history: history, paths: paths)
        _ = cache.later(after: range, history: history, paths: paths)
        #expect(cache.readCount == 1)

        // A turn known to have ended after both settles the tie.
        let settled = try tied + [Timed(number: 7, start: 960, end: 1020).turn()]
        history.replace(with: conversations(settled))
        let after = cache.later(after: range, history: history, paths: paths)
        #expect(cache.readCount == 2)
        #expect(after?.isOrderUnknown == false)
        #expect(after?.turn?.displayNumber == 7)

        paths.forget(["/repo"])
        _ = cache.later(after: range, history: history, paths: paths)
        #expect(cache.readCount == 3)
    }

    /// The two refusals a later turn makes, in both languages: a later turn
    /// that changed the file, and a tie whose order is not recorded.
    @Test func aLaterTurnsRefusal_saysWhy_inEnglishAndJapanese() {
        let file = ReviewFile(path: "a.swift", layer: .turns, status: .modified)
        let changed = ReviewHunkDiscardRules.actions(
            files: [(file, ["@@ -1 +1 @@"])],
            blocker: nil,
            laterPaths: .known(["a.swift"], afterTurn: nil),
            record: { _, _ in nil },
            locale: Self.japanese
        )
        #expect(changed.values.first?.values.first == .discard(
            blockedReason: "この範囲より後のターンでこのファイルが変更されているため破棄できません。最新のターンから操作してください。"
        ))
        #expect(ReviewHunkDiscardText.changedAfter(turnNumber: nil, locale: Self.english)
            == "This file changed in a turn after this scope, so the hunk can’t be discarded. Start from the latest turn.")

        let tied = ReviewHunkDiscardRules.actions(
            files: [(file, ["@@ -1 +1 @@"])],
            blocker: nil,
            laterPaths: .undecidable,
            record: { _, _ in nil },
            locale: Self.english
        )
        #expect(tied.values.first?.values.first == .discard(
            blockedReason: "Another turn ended in the same second as this scope’s end, so whether it changed this file afterward"
                + " can’t be checked, and the hunk can’t be discarded. Start from the latest turn."
        ))
        #expect(ReviewHunkDiscardText.laterOrderUnknown(locale: Self.japanese)
            == "この範囲の終わりと同じ秒に別のターンが終了したため、その後にこのファイルが変更されたかを確認できず、"
            + "ハンクを破棄できません。最新のターンから操作してください。")
    }

    // MARK: - Several files at once

    /// The stacked diff asks for every file on screen at once: each
    /// file is judged by its own path, layer, and whether it was renamed.
    @Test func severalFiles_eachJudgedOnItsOwn() {
        let changed = ReviewFile(path: "a.txt", layer: .turns, status: .modified)
        let untouched = ReviewFile(path: "b.txt", layer: .turns, status: .modified)
        let renamed = ReviewFile(path: "c.txt", oldPath: "old.txt", layer: .turns, status: .renamed)
        let uncommitted = ReviewFile(path: "d.txt", layer: .unstaged, status: .modified)
        let header = "@@ -1,3 +1,3 @@"
        let files = [changed, untouched, renamed, uncommitted].map { ($0, [header]) }

        let actions = ReviewHunkDiscardRules.actions(
            files: files,
            blocker: nil,
            laterPaths: .known(["a.txt"], afterTurn: 6),
            record: { _, _ in nil },
            locale: Self.english
        )

        #expect(actions[changed.id]?[header] == .discard(
            blockedReason: "This file changed in a turn after T6, so the hunk can’t be discarded. Start from the latest turn."
        ))
        #expect(actions[untouched.id]?[header] == .discard(blockedReason: nil), "by the file's own path")
        #expect(actions[renamed.id]?[header] == nil, "a rename's content alone would not undo it")
        #expect(actions[uncommitted.id]?[header] == nil, "only a range of turns")
        let checking = ReviewHunkDiscardRules.actions(
            files: files,
            blocker: .agentWaiting,
            laterPaths: .checking,
            record: { _, _ in nil },
            locale: Self.english
        )
        #expect(checking[untouched.id]?[header] == .discard(
            blockedReason: "Unavailable while an agent is waiting for an approval or an answer."
        ), "the gate, once for every file")
    }

}
