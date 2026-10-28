// ChangesPanelModelTests.swift
// Limpid — the changes panel's timeline: its order, its rows and their viewed state, the fold, the end line, the filter, and the empty
// states.

import Foundation
import SwiftUI
import Testing
@testable import Limpid

@Suite("Changes panel model")
struct ChangesPanelModelTests {
    typealias Panel = ChangesPanelFixture
    static let english = Locale(identifier: "en")
    static let japanese = Locale(identifier: "ja")
    static let changed = TurnSummaryFixture.changedFiles

    /// A card's second line as it reads, its columns set apart by " | "
    /// and the empty ones left out; and the head's totals, run after run.
    static func detail(_ row: ChangesPanelModel.Row, locale: Locale) -> String {
        let facts = ChangesPanelText.facts(row, locale: locale)
        let changes = (facts.files.map { "\($0) " } ?? "") + facts.changes.map(\.text).joined()
        return [changes, facts.checks.map(\.text).joined(), facts.tokens ?? "", facts.duration ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
    }

    static func totals(_ list: ChangesPanelModel.TurnList, locale: Locale) -> String {
        ChangesPanelText.totalsLines(list, locale: locale).map { $0.map(\.text).joined() }.joined(separator: "\n")
    }

    /// The comparison the totals read over `timeline`, with every turn
    /// unviewed unless `isViewed` says otherwise.
    static func totalsComparison(
        _ timeline: [TurnSummary],
        isViewed: (TurnSummary) -> Bool = { _ in false }
    ) -> WorktreeChanges.Comparison? {
        guard case let .range(range) = ReviewScopeCatalog.unviewedTurns(turns: timeline, isViewed: isViewed) else { return nil }
        return ChangesPanelModel.comparison(range)
    }

    // MARK: - One conversation

    @Test func theRows_runOldestFirst_eachWithItsOwnViewedState() throws {
        let turns = try [Panel.turn(5), Panel.turn(6), Panel.turn(7)]
        let viewed = Panel.line(through: turns[1]).line

        let list = try Panel.list(ChangesPanelModel.make(Panel.input([Panel.agent(turns)], lines: [viewed])))

        #expect(list.rows.map(\.turn.displayNumber) == [5, 6, 7])
        #expect(list.rows.map(\.status) == [.viewed, .viewed, .unviewed])
        #expect(list.rows.map(\.isViewed) == [true, true, false])
        #expect(list.rows.map(\.action) == [.markUnviewedFrom, .markUnviewedFrom, .markViewedThrough])
        #expect(list.line == nil, "a row is unviewed: no line below the latest turn")
        #expect(list.fold == Fold(count: 2), "the viewed rows at the top fold")
        #expect(list.turnCount == 3)
        #expect(list.unviewedCount == 1)
        #expect(list.conversations.isEmpty, "one conversation needs no filter")
        #expect(list.rows.allSatisfy { $0.conversation == nil }, "and no badge on its rows")
        #expect(list.scrollTarget == turns[2].turnID, "the latest unviewed turn")
    }

    private typealias Fold = ChangesPanelModel.Fold

    @Test func noTurnViewed_drawsNoLine_andFoldsNothing() throws {
        let turn = try Panel.turn(1)
        let list = try Panel.list(ChangesPanelModel.make(Panel.input([Panel.agent([turn])])))

        #expect(list.line == nil)
        #expect(list.fold == nil)
        #expect(list.rows.first?.action == .markViewedThrough)
    }

    @Test func theLineBelowTheLatestTurn_offersUndo_untilTheNextTurnArrives() throws {
        let first = try Panel.turn(1)
        let latest = try Panel.turn(2)
        let (line, change) = Panel.line(through: latest)
        let moved = try #require(change)

        let list = try Panel.list(ChangesPanelModel.make(Panel.input([Panel.agent([first, latest])], lines: [line])))
        #expect(list.line?.undo == [ViewedLineUndo(conversation: latest.conversation, changeID: moved.id)])
        #expect(list.fold == nil, "the last row never folds, and one row alone is no fold")
        #expect(list.scrollTarget == latest.turnID, "nothing unviewed: the latest")

        // A turn running below it is news the Undo never saw.
        let running = try Panel.turn(3, phase: "started")
        let later = try Panel.list(ChangesPanelModel.make(Panel.input([Panel.agent([first, latest, running])], lines: [line])))
        #expect(later.line == nil)
        #expect(later.fold == Fold(count: 2), "the two viewed rows above the running one fold")
        #expect(later.rows.last?.status == .running)
        #expect(later.rows.last?.action == nil, "nobody has seen it")
        #expect(later.rows.last?.isSelectable == false)
        let runningRow = try #require(later.rows.last)
        #expect(Self.detail(runningRow, locale: Self.english) == "Running")
        #expect(ChangesPanelText.moves(runningRow, locale: Self.english).isEmpty, "nothing to move or restore yet")
        #expect(later.rows.map(\.showsMovesAtRest) == [false, true, false], "the last card with moves only")
    }

    @Test func theLineMovedPastARecordNobodyPrompted_stillOffersUndo() throws {
        // The decision bar moves the line below the latest record, which can
        // be an answer to background work the panel does not list.
        let prompted = try Panel.turn(1)
        let unprompted = try Panel.turn(2, hasPrompt: false)
        let (line, change) = Panel.line(through: unprompted)
        let moved = try #require(change)

        let list = try Panel.list(ChangesPanelModel.make(Panel.input([Panel.agent([prompted, unprompted])], lines: [line])))

        #expect(list.rows.count == 1)
        #expect(list.line?.undo == [ViewedLineUndo(conversation: prompted.conversation, changeID: moved.id)])
    }

    @Test func theLine_offersNoUndo_onceALaterMoveStandsOverTheLast() throws {
        let first = try Panel.turn(1)
        let latest = try Panel.turn(2)
        var line = ViewedLine(conversation: latest.conversation)
        let marked = line.advance(to: ViewedLinePosition(latest), source: .decisionBar)
        #expect(marked != nil)
        // Back above T2 and then below it again: the Undo on screen is for
        // the first move, which is no longer the line's last.
        _ = line.retreat(toBefore: ViewedLinePosition(latest), earlier: ViewedLinePosition(first), source: .turnRow)
        let again = line.advance(to: ViewedLinePosition(latest), source: .turnRow)

        let list = try Panel.list(ChangesPanelModel.make(Panel.input([Panel.agent([first, latest])], lines: [line])))

        #expect(try list.line?.undo == [ViewedLineUndo(conversation: latest.conversation, changeID: #require(again).id)])
    }

    @Test func aRowsState_saysWhatItsRecordKnows_andOnlyAReadableOneOpens() throws {
        let answer = try Panel.turn(1, changes: #"{"kind":"unchanged"}"#)
        let lost = try Panel.turn(2, changes: #"{"kind":"unavailable","reason":"endMissing"}"#)
        let failed = try Panel.turn(3, changes: #"{"kind":"unavailable","reason":"snapshotFailed"}"#)
        let pending = try Panel.turn(4, changes: #"{"kind":"pending"}"#)
        let unprompted = try Panel.turn(5, hasPrompt: false)

        let list = try Panel.list(ChangesPanelModel.make(Panel.input([Panel.agent([answer, lost, failed, pending, unprompted])])))

        #expect(
            list.rows.map(\.status) == [.answerOnly, .incompleteRecord, .changesUnavailable, .unviewed],
            "a record nobody prompted is no turn"
        )
        #expect(list.rows.map(\.isSelectable) == [false, true, false, true], "an incomplete record opens to say so")
        #expect(list.rows.allSatisfy { $0.action == .markViewedThrough }, "the line moves past any ended turn")
        #expect(list.unviewedCount == 1, "only the one that may have changed files waits to be read")
        let failedRow = try #require(list.rows.first { $0.status == .changesUnavailable })
        #expect(Self.detail(failedRow, locale: Self.english) == "Couldn’t get the changes", "never No file changes")
        let pendingRow = try #require(list.rows.last)
        #expect(Self.detail(pendingRow, locale: Self.english) == "Getting the changes…", "its state is in its pill and its sentence")
        // A card with no counts says its state in words, which take the
        // room of a column it leaves empty.
        #expect(list.rows.prefix(2).map { Self.detail($0, locale: Self.english) } == ["No file changes", "Incomplete record"])
        #expect(list.rows.allSatisfy { ChangesPanelText.facts($0, locale: Self.english).isStatus })
    }

    @Test func aCardsMoves_areTheSameValuesEverywhere_andAHeldBackRestoreSaysWhy() throws {
        var extras = TurnSummaryFixture.Extras()
        extras.beginTree = SnapshotTree(tree: TurnSummaryFixture.tree("b", 1), root: "/repo")
        let turn = try Panel.turn(1, extras: extras)
        var input = Panel.input([Panel.agent([turn])])
        input.restoreBlocker = { _ in .turnRunning }
        let row = try #require(Panel.list(ChangesPanelModel.make(input)).rows.first)

        let moves = ChangesPanelText.moves(row, locale: Self.english)
        #expect(moves.map(\.kind) == [.line(.markViewedThrough), .restore])
        #expect(moves.map(\.isEnabled) == [true, false])
        let reason = RestoreText.blocker(.turnRunning, locale: Self.english)
        #expect(moves.last?.help == "\(RestoreText.entry(locale: Self.english))\n\(reason)")
        #expect(moves.first?.help == "Mark as Viewed up to Here")
        #expect(row.showsMovesAtRest && row.showsBlockerNote)
    }

    @Test func theEmptyStates_sayWhyThereAreNoTurns() throws {
        var input = Panel.input([])
        #expect(try Panel.list(ChangesPanelModel.make(input)).hasAgents == false)
        #expect(ChangesPanelText.empty(ChangesPanelModel.make(input)) == .noTurns)
        input.repository = .waiting
        #expect(ChangesPanelModel.make(input) == .waitingForRepository)
        #expect(ChangesPanelText.empty(.waitingForRepository) == nil, "not yet a reason")
        input.repository = .unavailable
        #expect(ChangesPanelModel.make(input) == .repositoryUnavailable)
        #expect(ChangesPanelText.empty(.repositoryUnavailable) == .changesUnavailable)
        input.repository = .notRepository
        #expect(ChangesPanelModel.make(input) == .notGitRepository)
        #expect(ChangesPanelText.empty(.notGitRepository) == .notGitRepository)
        input.hasWorktree = false
        #expect(ChangesPanelModel.make(input) == .noWorktree, "and no counts")
        #expect(ChangesPanelText.empty(.noWorktree) == .noWorktreeSelected)
    }

    @Test func theRow_readsAsTheReceiptWithThePromptTimeAndDuration() throws {
        var extras = TurnSummaryFixture.Extras()
        extras.check = #"{"command":"swift test --filter Turn","isFiltered":true,"exitCode":0}"#
        extras.durationSeconds = 185
        extras.promptHead = "Add tests for TurnTimelineStore"
        extras.finishedAt = "2026-10-12T00:03:05Z"
        let turn = try Panel.turn(7, extras: extras)
        let list = try Panel.list(ChangesPanelModel.make(Panel.input([Panel.agent([turn])])))
        let row = try #require(list.rows.first)
        let utc = try #require(TimeZone(identifier: "UTC"))

        // A record from before the runs were kept shows its last check alone.
        #expect(Self.detail(row, locale: Self.english) == "2 +3 −1 | ✓ | 3m")
        // The counts in the diff colors; the state is the card's rule.
        let facts = ChangesPanelText.facts(row, locale: Self.english)
        #expect(facts.changes.filter { $0.role != .plain && $0.role != .quiet } == [
            ReceiptRun(text: "+3", role: .added(isEmphasized: false)),
            ReceiptRun(text: "−1", role: .removed(isEmphasized: false))
        ])
        // A pass of part of the suite is quieter than a whole one.
        #expect(facts.checks == [ReceiptRun(text: "✓", role: .quietMark)])
        // In the card's order, the changes whole, as the card may cut them.
        #expect(ChangesPanelText.help(row, locale: Self.japanese, timeZone: utc)
            == [
                "T7 をレビューで開く", "Add tests for TurnTimelineStore", "2 ファイル +3 −1", "✓ テスト（絞り込み）",
                "swift test --filter Turn", "所要 3 分 05 秒", "開始 0:00 · 終了 0:03"
            ].joined(separator: "\n"))
        #expect(ChangesPanelText.turnDetails(turn, showsChanges: true, locale: Self.english) == [
            "Add tests for TurnTimelineStore",
            "2 files +3 −1",
            "✓ Tests (filtered)",
            "swift test --filter Turn",
            "Took 3m 05s"
        ])
        #expect(ChangesPanelText.time(turn, locale: Self.japanese, timeZone: utc) == "0:00", "the row's time is the start")
        // The clock's narrow space before AM reads as a plain one here.
        #expect(Panel.plainSpaces(ChangesPanelText.times(turn, locale: Self.english, timeZone: utc)) == "Started 12:00 AM · Ended 12:03 AM")
        #expect(
            Panel.plainSpaces(ChangesPanelText.rowSpoken(row, locale: Self.english, timeZone: utc))
                == "Turn 7, Add tests for TurnTimelineStore, Unviewed, 2 files +3 −1, ✓ Tests (filtered), took 3m 05s, 12:00 AM"
        )
        #expect(ChangesPanelText.summary(turns: 3, unviewed: 1, locale: Self.japanese) == "3 ターン · 未確認 1")
        #expect(ChangesPanelText.summary(turns: 1, unviewed: 0, locale: Self.english) == "1 turn · 0 unviewed", "quiet, not gone")
        #expect(ChangesPanelText.line(locale: Self.japanese) == "ここまで確認済み")
        #expect(ChangesPanelText.unmarkViewed(locale: Self.japanese) == "確認済みを取り消す")
    }

    @Test(arguments: [
        (185, "3m 05s", "3 分 05 秒"),
        (45, "45s", "45 秒"),
        (59, "59s", "59 秒"),
        (60, "1m 00s", "1 分 00 秒"),
        (600, "10m 00s", "10 分 00 秒"),
        (3599, "59m 59s", "59 分 59 秒"),
        (3600, "1h 00m", "1 時間 00 分"),
        (3725, "1h 02m", "1 時間 02 分"),
        (-5, "0s", "0 秒")
    ])
    func aDuration_takesItsTwoLargestUnits_theSmallerInTwoFigures(_ seconds: Int, _ english: String, _ japanese: String) {
        #expect(ChangesPanelText.duration(seconds, locale: Self.english) == english)
        #expect(ChangesPanelText.duration(seconds, locale: Self.japanese) == japanese, "as in 3 分 05 秒")
        // The row names what the number measures.
        #expect(ChangesPanelText.took(seconds, locale: Self.english) == "took \(english)")
        #expect(ChangesPanelText.took(seconds, locale: Self.japanese) == "所要 \(japanese)")
    }

    /// The first column is as wide as the list's longest number needs, so
    /// a short conversation's prompts stand close to their numbers, and
    /// grows with the digits so a long one's numbers still line up.
    @Test(arguments: [false, true])
    @MainActor
    func theTurnNumberColumn_fitsTheListsDigits(hasConversation: Bool) {
        typealias Layout = LimpidLayout.Supervision
        let one = Layout.turnFirstColumnWidth(hasConversation: hasConversation, digits: 1)
        let four = Layout.turnFirstColumnWidth(hasConversation: hasConversation, digits: 4)
        let width = ("T1000" as NSString).size(withAttributes: [.font: Layout.turnNumberFont]).width
        #expect(ceil(width) + Layout.turnUnviewedPillPadding.width <= four, "a long conversation's numbers still line up")
        #expect(one < four)
    }

    /// The note under a card starts where its prompt does, whether the row
    /// carries its conversation's badge in a wider first column or not.
    @Test(arguments: [false, true])
    @MainActor
    func theNoteUnderACard_startsWhereItsPromptDoes(hasConversation: Bool) {
        typealias Layout = LimpidLayout.Supervision
        let column = Layout.turnFirstColumnWidth(hasConversation: hasConversation, digits: 2)
        let prompt = Layout.turnCardInsets.leading + column + Layout.turnColumnSpacing
        #expect(Layout.turnNoteInsets(hasConversation: hasConversation, digits: 2).leading == prompt)
    }

    @Test(arguments: [
        (40, "40s", "40秒"),
        (185, "3m", "3分"),
        (3725, "62m", "62分"),
        (5999, "99m", "99分"),
        (6000, "1h", "1時間"),
        (9000, "2h", "2時間"),
        (-5, "0s", "0秒")
    ])
    func aCardsDuration_keepsToOneUnit(_ seconds: Int, _ english: String, _ japanese: String) {
        #expect(ChangesPanelText.compactDuration(seconds, locale: Self.english) == english)
        #expect(ChangesPanelText.compactDuration(seconds, locale: Self.japanese) == japanese)
    }

    /// The card's checks run in order, the last ones shown, "…" for the
    /// rest; the tokens leave the cache reads out; the tooltip has them all.
    @Test func aCard_showsItsChecksInOrder_andTheTokensItUsed() throws {
        var extras = TurnSummaryFixture.Extras()
        extras.check = #"{"command":"cargo test","isFiltered":false,"exitCode":0}"#
        extras.checks = """
        [{"exitCode":101,"isFiltered":false},{"isFiltered":false},{"exitCode":101,"isFiltered":false},{"exitCode":0,"isFiltered":false}]
        """
        extras.checkCount = 7
        extras.usage = #"{"inputTokens":3000,"cacheWriteTokens":75000,"cacheReadTokens":2100000,"outputTokens":6200}"#
        extras.durationSeconds = 662
        let turn = try Panel.turn(4, changes: Self.changed, extras: extras)
        let list = try Panel.list(ChangesPanelModel.make(Panel.input([Panel.agent([turn])])))
        let row = try #require(list.rows.first)

        #expect(Self.detail(row, locale: Self.english) == "2 +3 −1 | …–✗✓ | 84K | 11m")
        #expect(ChangesPanelText.facts(row, locale: Self.japanese).tokens == "84K", "K and M in every language")
        #expect(ChangesPanelText.facts(row, locale: Self.english).checks.map(\.role) == [.quiet, .quiet, .failed, .plain])
        #expect(turn.lastCheck?.earlierFailures == 2, "of the runs the record holds, without a count of failures")
        #expect(try ReceiptText.check(#require(turn.lastCheck), locale: Self.english) == "✓ Tests (after 2 failures)")
        #expect(try ReceiptText.check(#require(turn.lastCheck), locale: Self.japanese) == "✓ テスト（失敗 2 回）")
        #expect(ChangesPanelText.turnDetails(turn, showsChanges: true, locale: Self.english) == [
            "2 files +3 −1",
            "Ran tests 7 times · 2 failed",
            "Latest: ✓ Tests (after 2 failures)",
            "cargo test",
            "84,200 tokens",
            "Input 3,000 · Cache writes 75,000 · Output 6,200",
            "Not counted: 2,100,000 read from the cache",
            "Took 11m 02s"
        ])
        #expect(try ChangesPanelText.usageDetails(#require(turn.usage), locale: Self.japanese).last == "キャッシュ読み込み 2,100,000（合計外）")
        #expect(ChangesPanelText.turnDetails(turn, showsChanges: false, locale: Self.japanese).prefix(2) == [
            "テスト実行 7 回 · 失敗 2 回",
            "最新：✓ テスト（失敗 2 回）"
        ])
        #expect(
            ChangesPanelText.rowSpoken(row, locale: Self.english).contains("✓ Tests (after 2 failures), 84K tokens, took 11m 02s"),
            "the sentence says every fact the card shows"
        )
    }

    @Test func aShortCount_saysSo_inWordsWhereItIsRead() {
        let usage = TurnUsage(inputTokens: 900, cacheWriteTokens: 0, cacheReadTokens: 0, outputTokens: 100, isPartial: true)
        #expect(ChangesPanelText.tokens(usage, locale: Self.english) == "≥1K")
        #expect(ChangesPanelText.usageDetails(usage, locale: Self.japanese) == [
            "1,000 トークン以上",
            "入力 900 · キャッシュ書き込み 0 · 出力 100",
            "ターンの一部を読めなかったため、実際より少ない可能性があります"
        ])
        // VoiceOver hears words, never the "≥" it reads as a symbol.
        #expect(ChangesPanelText.tokenTotal(usage, isExact: false, locale: Self.english) == "At least 1K tokens")
        #expect(ChangesPanelText.tokenUnit(locale: Self.japanese) == "tok")
    }

    /// A count the record says may be short reads so: "…" before the marks,
    /// "at least" in the tooltip, whose count stands even when the last
    /// check itself could not be read.
    @Test func checksThatMayBeShort_saySo_andTheCountStandsWithoutTheLastCheck() throws {
        var extras = TurnSummaryFixture.Extras()
        extras.checks = #"[{"exitCode":1,"isFiltered":false},{"exitCode":0,"isFiltered":false}]"#
        extras.check = #"{"command":"cargo test","isFiltered":false,"exitCode":0}"#
        extras.areChecksPartial = true
        let turn = try Panel.turn(4, extras: extras)
        #expect(ChangesPanelText.checkMarkRuns(turn).map(\.text).joined() == "…✗✓")
        #expect(ChangesPanelText.checkDetails(turn, locale: Self.english).first == "Ran tests at least 2 times · 1 failed")
        #expect(ChangesPanelText.checkDetails(turn, locale: Self.japanese).first == "テスト実行 2 回以上 · 失敗 1 回")

        // A partial reading of a turn that ran no checks says nothing of
        // them: no "at least 0".
        var none = TurnSummaryFixture.Extras()
        none.areChecksPartial = true
        #expect(try ChangesPanelText.checkDetails(Panel.turn(6, extras: none), locale: Self.english).isEmpty)

        extras.check = #"{"command":"cargo test","exitCode":"zero"}"#
        extras.areChecksPartial = nil
        let unreadLast = try Panel.turn(5, extras: extras)
        #expect(unreadLast.lastCheck == nil)
        #expect(ChangesPanelText.checkDetails(unreadLast, locale: Self.english) == ["Ran tests 2 times · 1 failed"])
    }

    @Test(arguments: [
        (999, "999"),
        (1000, "1K"),
        (1234, "1.2K"),
        (84200, "84K"),
        (99999, "100K"),
        (125_000, "130K"),
        (1_240_000, "1.2M")
    ])
    func aCardsCount_isShortWithKOrM_inEveryLanguage(_ count: Int, _ short: String) {
        #expect(ChangesPanelText.compactCount(count, locale: Self.english) == short)
        #expect(ChangesPanelText.compactCount(count, locale: Self.japanese) == short)
    }

    @Test func theTurnsTheReviewTabReads_areMarked_onlyWhileItIsInFront_whateverTheirConversation() throws {
        let turn = try TurnSummaryFixture.turn(
            "T7",
            changes: TurnSummaryFixture.changedFiles,
            number: 7,
            endTree: SnapshotTree(tree: TurnSummaryFixture.tree("e", 7), root: "/repo"),
            extras: .init(beginTree: SnapshotTree(tree: TurnSummaryFixture.tree("b", 7), root: "/repo"))
        )
        let range = try #require(ReviewTurnRange(turns: [turn]))
        var review = ReviewTabState(
            root: "/repo",
            selection: .turn(range, prompt: TurnPrompt(head: nil)),
            fixedPoint: ReviewTabFixedPoint(),
            agentPaneID: nil,
            destinationPaneID: nil,
            opening: UUID()
        )

        #expect(ChangesPanelModel.turnsShownInReview(review) == [turn.turnID])
        review.isShown = false
        #expect(ChangesPanelModel.turnsShownInReview(review).isEmpty, "behind a terminal tab")
        review.isShown = true
        review.selection = .uncommitted(includesChangesOutsideTurns: false)
        #expect(ChangesPanelModel.turnsShownInReview(review).isEmpty, "it reads no turns")
        #expect(ChangesPanelModel.turnsShownInReview(nil).isEmpty)
    }

    // MARK: - The totals: one comparison

    @Test func theTotals_areOneComparison_fromTheEarliestBeginToTheLatestEnd_neverTheTurnsAddedUp() throws {
        // T1 and T2 ran over the same file: added up they would count it
        // twice. T2 started before T1 ended, and ended last.
        let first = try TurnSummaryFixture.timed(1, start: 0, end: 100)
        let second = try TurnSummaryFixture.timed(2, start: 50, end: 200)
        var input = Panel.input([Panel.agent([first, second])])
        var asked: [WorktreeChanges.Comparison] = []
        input.counts = { comparison in
            asked.append(comparison)
            return .changed(files: 3, added: 5, removed: 1)
        }

        let list = try Panel.list(ChangesPanelModel.make(input))

        let expected = try WorktreeChanges.Comparison(begin: #require(first.beginTree).tree, end: #require(second.endTree).tree)
        #expect(asked == [expected], "asked once, for the one comparison")
        #expect(Self.totalsComparison(ChangesPanelModel.timeline([first, second])) == expected)
        #expect(list.fileCount == 3 && list.added == 5 && list.removed == 1)
        #expect(Self.totals(list, locale: Self.english) == "Unviewed range: 3 files +5 −1")
        #expect(list.showsTotals)
    }

    /// The totals are the unviewed range's, which "Review Unviewed" reads:
    /// a missing begin at its start is an incomplete record, said by no
    /// number rather than a smaller one; a running turn is no end.
    @Test func theComparison_isTheUnviewedRanges_andNoneWhenItsRecordIsIncomplete() throws {
        let noBegin = try TurnSummaryFixture.timed(1, start: 0, end: 10, hasBegin: false)
        let whole = try TurnSummaryFixture.timed(2, start: 20, end: 30)
        let running = try TurnSummaryFixture.timed(3, start: 40, end: nil, phase: "started")
        let timeline = ChangesPanelModel.timeline([noBegin, whole, running])

        #expect(Self.totalsComparison(timeline) == nil, "T1 begins the range and its begin was not taken")
        let fromWhole = Self.totalsComparison(timeline) { $0.turnID == noBegin.turnID }
        #expect(fromWhole?.begin == whole.beginTree?.tree, "with T1 viewed, the range is T2's")
        #expect(fromWhole?.end == whole.endTree?.tree, "a running turn has no end")
        #expect(try Self.totalsComparison([TurnSummaryFixture.timed(1, start: 0, end: nil, phase: "started")]) == nil)
        let endless = try TurnSummaryFixture.timed(5, conversation: "claude", start: 0, end: 1800, hasEnd: false)
        let short = try TurnSummaryFixture.timed(1, conversation: "codex", start: 300, end: 600, endKind: "f")
        #expect(
            ChangesPanelModel.totalsComparison(Panel.input(Panel.agents([endless, short]))) == nil,
            "the turn that ended last lost its end"
        )
        #expect(Self.totalsComparison([]) == nil)

        // The line says the record is incomplete, rather than nothing,
        // which would read as nothing to count.
        let list = try Panel.list(ChangesPanelModel.make(Panel.input([Panel.agent([noBegin, whole, running])])))
        #expect(list.isTotalsIncomplete && list.showsTotals && !list.showsTurnCounts)
        #expect(Self.totals(list, locale: Self.english) == "Unviewed range: incomplete record")
        #expect(Self.totals(list, locale: Self.japanese) == "未確認の範囲：記録が不完全")
        let viewedFirst = try Panel.list(ChangesPanelModel.make(Panel.input(
            [Panel.agent([noBegin, whole, running])],
            lines: [Panel.line(through: noBegin).line]
        )))
        #expect(!viewedFirst.isTotalsIncomplete, "a whole range, counted once read")
    }

    /// The totals cover the unviewed range only, so the pulls
    /// and merges between turns long viewed are never counted; with
    /// nothing unviewed there are no totals, and Git is not asked.
    @Test func theTotals_coverTheUnviewedRangeOnly_andNothingWhenNothingIsUnviewed() throws {
        let bash = #"{"kind":"changed","files":1,"added":5,"removed":0,"hasBashChanges":true}"#
        let old = try TurnSummaryFixture.timed(1, start: 0, end: 10, changes: bash)
        let recent = try TurnSummaryFixture.timed(2, start: 1000, end: 1100)
        let viewedOld = Panel.line(through: old).line
        var input = Panel.input([Panel.agent([old, recent])], lines: [viewedOld])
        var asked: [WorktreeChanges.Comparison] = []
        input.counts = { comparison in
            asked.append(comparison)
            return .changed(files: 2, added: 7, removed: 3)
        }

        let list = try Panel.list(ChangesPanelModel.make(input))
        let expected = try WorktreeChanges.Comparison(begin: #require(recent.beginTree).tree, end: #require(recent.endTree).tree)
        #expect(asked == [expected], "from the oldest unviewed begin, not the first turn's")
        #expect(ChangesPanelModel.totalsComparison(input) == expected, "the comparison Git is asked to count")
        #expect(list.fileCount == 2 && list.showsTurnCounts)
        #expect(!list.hasShellChanges, "the shell's changes were in a viewed turn, outside the range")

        asked = []
        let allViewed = Panel.line(through: recent).line
        var viewed = Panel.input([Panel.agent([old, recent])], lines: [allViewed])
        viewed.counts = input.counts
        let none = try Panel.list(ChangesPanelModel.make(viewed))
        #expect(asked.isEmpty, "nothing unviewed: no comparison to count")
        #expect(!none.showsTurnCounts && none.fileCount == nil)
        #expect(!none.showsTotals, "no total line")
        #expect(ChangesPanelModel.totalsComparison(viewed) == nil)
    }

    @Test func theTotals_sayWhatTheTurnsDoNotAccountFor_onceCounted() throws {
        let bash = #"{"kind":"changed","files":1,"added":5,"removed":0,"hasBashChanges":true}"#
        var input = try Panel.input([Panel.agent([TurnSummaryFixture.timed(1, start: 0, end: 10, changes: bash)])])

        let counting = try Panel.list(ChangesPanelModel.make(input))
        #expect(
            Self.totals(counting, locale: Self.english) == "Includes changes by shell commands",
            "no counts until the comparison is read"
        )

        input.counts = { _ in .changed(files: 1, added: 5, removed: 0) }
        input.pathsOutsideTurns = 1
        let list = try Panel.list(ChangesPanelModel.make(input))
        #expect(list.hasShellChanges)
        #expect(
            Self.totals(list, locale: Self.english)
                == "Unviewed range: 1 file +5 −0\nIncludes changes by shell commands\n1 file changed outside turns",
            "in the receipt's order, as every count of a diff reads, one fact to a line so none wraps"
        )
        #expect(Self.totals(list, locale: Self.japanese)
            == "未確認の範囲：1 ファイル +5 −0\nシェルによる変更を含む\nターン外の変更 1 ファイル")
        #expect(ChangesPanelText.totalsLines(list, locale: Self.english).first == [
            ReceiptRun(text: "Unviewed range: ", role: .plain),
            ReceiptRun(text: "1 file ", role: .plain),
            ReceiptRun(text: "+5", role: .added(isEmphasized: false)),
            ReceiptRun(text: " ", role: .plain),
            ReceiptRun(text: "−0", role: .removed(isEmphasized: false))
        ])
    }

    /// Each of the totals' lines fits the panel's default width, in either language.
    @Test @MainActor func theTotalsLines_eachFitThePanelsDefaultWidth() throws {
        let ran = try TurnSummaryFixture.timed(
            1,
            start: 0,
            end: 1,
            changes: #"{"kind":"changed","files":1,"added":1,"removed":0,"hasBashChanges":true}"#
        )
        var input = Panel.input([Panel.agent([ran])])
        input.counts = { _ in .changed(files: 12, added: 1234, removed: 567) }
        input.pathsOutsideTurns = 12
        let list = try Panel.list(ChangesPanelModel.make(input))
        let insets = LimpidLayout.Supervision.changesHeadInsets
        let room = LimpidLayout.Supervision.changesPanelDefaultWidth - insets.leading - insets.trailing
        for locale in [Self.english, Self.japanese] {
            for line in ChangesPanelText.totalsLines(list, locale: locale) {
                let view = ReceiptRunsText(runs: line, size: .row).fixedSize().environment(\.locale, locale)
                let width = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 4000, height: 40)).width
                #expect(width <= room, "\(line.map(\.text).joined()) is \(width)pt, past \(room)pt")
            }
        }
    }

    @Test func outsideTurnsAlone_isSaidWithoutTheTurnsZeroes() throws {
        var input = try Panel.input([Panel.agent([Panel.turn(1, changes: #"{"kind":"unchanged"}"#)])])
        input.pathsOutsideTurns = 2

        let list = try Panel.list(ChangesPanelModel.make(input))

        #expect(Self.totals(list, locale: Self.japanese) == "ターン外の変更 2 ファイル")
    }

    @Test func anIncompleteCountOutsideTurns_saysSo_withItsFilesOrAlone() throws {
        var input = try Panel.input([Panel.agent([Panel.turn(1, changes: #"{"kind":"unchanged"}"#)])])
        input.isOutsideTurnsIncomplete = true
        #expect(try !Panel.list(ChangesPanelModel.make(input)).showsTotals, "nothing to qualify while it is being counted")

        input.pathsOutsideTurns = 2
        let counted = try Panel.list(ChangesPanelModel.make(input))
        #expect(Self.totals(counted, locale: Self.english) == "2 files changed outside turns (incomplete record)")
        #expect(Self.totals(counted, locale: Self.japanese) == "ターン外の変更 2 ファイル（記録が不完全）")

        input.pathsOutsideTurns = 0
        let none = try Panel.list(ChangesPanelModel.make(input))
        #expect(none.showsTotals, "none counted is not none changed")
        #expect(Self.totals(none, locale: Self.english) == "Changed outside turns: incomplete record")
        #expect(Self.totals(none, locale: Self.japanese) == "ターン外の変更：記録が不完全")
    }

    @Test func theTotals_showOnlyOnceSomethingChanged() throws {
        let answer = try Panel.list(ChangesPanelModel.make(Panel.input([Panel.agent([Panel.turn(1, changes: #"{"kind":"unchanged"}"#)])])))
        #expect(!answer.showsTotals, "+0 −0 says nothing")

        var input = try Panel.input([Panel.agent([Panel.turn(1, changes: #"{"kind":"unchanged"}"#)])])
        input.pathsOutsideTurns = 2
        #expect(try Panel.list(ChangesPanelModel.make(input)).showsTotals)
        var counted = try Panel.input([Panel.agent([TurnSummaryFixture.timed(1, start: 0, end: 10)])])
        counted.counts = { _ in .unchanged }
        #expect(try !Panel.list(ChangesPanelModel.make(counted)).showsTotals, "a comparison that changed nothing says nothing")
        counted.counts = { _ in .changed(files: 2, added: 3, removed: 1) }
        #expect(try Panel.list(ChangesPanelModel.make(counted)).showsTotals)
    }
}

extension ChangesPanelModelTests {

    // MARK: - Several conversations: the timeline

    @Test func theTimeline_ordersEveryConversationsTurnsByStart_withBadgesAndPerRowState() throws {
        // Claude T3 (viewed), Codex T1, Claude T4, Codex T2: by start, not
        // by conversation.
        let claude3 = try TurnSummaryFixture.timed(3, conversation: "claude", start: 100, end: 200)
        let codex1 = try TurnSummaryFixture.timed(1, conversation: "codex", start: 150, end: 250)
        let claude4 = try TurnSummaryFixture.timed(4, conversation: "claude", start: 300, end: 400)
        let codex2 = try TurnSummaryFixture.timed(2, conversation: "codex", start: 500, end: 600)
        let claudeLine = Panel.line(through: claude3).line
        let agents = Panel.agents([claude3, claude4, codex1, codex2])

        let list = try Panel.list(ChangesPanelModel.make(Panel.input(agents, lines: [claudeLine])))

        #expect(list.rows.map(\.turn.turnID) == [claude3, codex1, claude4, codex2].map(\.turnID))
        #expect(list.rows.map(\.status) == [.viewed, .unviewed, .unviewed, .unviewed], "each row against its own conversation's line")
        #expect(list.turnCount == 4)
        #expect(list.unviewedCount == 3)
        #expect(list.conversations.map(\.conversation) == [claude3.conversation, codex1.conversation])
        #expect(list.conversations.map(\.ordinal) == [1, 2], "the fixture's conversations are both Claude's: numbered")
        #expect(
            list.rows.map { $0.conversation?.conversation } == [claude3, codex1, claude4, codex2].map(\.conversation),
            "every row carries its badge"
        )
        #expect(list.fold == nil, "one viewed row at the top is no fold")
        #expect(list.line == nil)
    }

    @Test func twoTurnsStartedInTheSameSecond_keepTheirConversationsOrder_thenTheirNumbers() throws {
        // The record keeps seconds: a tie is broken by which conversation
        // started first, then by number, so two readings never swap rows.
        let early1 = try TurnSummaryFixture.timed(1, conversation: "early", start: 0, end: 5)
        let late1 = try TurnSummaryFixture.timed(1, conversation: "late", start: 10, end: 15)
        let early2 = try TurnSummaryFixture.timed(2, conversation: "early", start: 20, end: 25)
        let late2 = try TurnSummaryFixture.timed(2, conversation: "late", start: 20, end: 30)
        let early3 = try TurnSummaryFixture.timed(3, conversation: "early", start: 20, end: 40)

        let timeline = ChangesPanelModel.timeline([late2, early3, late1, early2, early1])

        #expect(timeline.map(\.turnID) == [early1, late1, early2, early3, late2].map(\.turnID))
        #expect(
            ChangesPanelModel.timeline([late2, early3, early2]).map(\.turnID) == [early2, early3, late2].map(\.turnID),
            "stable from any order"
        )
    }

    @Test func overlappingTurns_areListedByStart_andTheRowsTimeIsTheStart() throws {
        // Claude's T4 ran 10:31–10:34; Codex's T1 started at 10:32 and
        // ended at 10:33, before it.
        let claude = try TurnSummaryFixture.timed(4, conversation: "claude", start: 10 * 3600 + 31 * 60, end: 10 * 3600 + 34 * 60)
        let codex = try TurnSummaryFixture.timed(1, conversation: "codex", start: 10 * 3600 + 32 * 60, end: 10 * 3600 + 33 * 60)
        let utc = try #require(TimeZone(identifier: "UTC"))

        let list = try Panel.list(ChangesPanelModel.make(Panel.input(Panel.agents([codex, claude]))))

        #expect(list.rows.map(\.turn.turnID) == [claude.turnID, codex.turnID])
        #expect(
            list.rows.map { ChangesPanelText.time($0.turn, locale: Self.japanese, timeZone: utc) } == ["10:31", "10:32"],
            "in the list's order"
        )
        #expect(ChangesPanelText.times(claude, locale: Self.japanese, timeZone: utc) == "開始 10:31 · 終了 10:34")
    }

    @Test func anIncompleteRecord_isOrderedByItsStart_andTheComparisonLeavesItOut() throws {
        // Another turn overtook T1: no end time, no end tree, phase
        // unknown, and its changes unknown for it.
        let overtaken = try TurnSummaryFixture.timed(
            1,
            conversation: "claude",
            start: 0,
            end: nil,
            phase: "unknown",
            changes: #"{"kind":"unavailable","reason":"endMissing"}"#
        )
        let codex = try TurnSummaryFixture.timed(1, conversation: "codex", start: 50, end: 60)
        let later = try TurnSummaryFixture.timed(2, conversation: "claude", start: 100, end: 110)

        let timeline = ChangesPanelModel.timeline([later, codex, overtaken])
        let comparison = Self.totalsComparison(timeline)

        #expect(timeline.map(\.turnID) == [overtaken, codex, later].map(\.turnID))
        #expect(comparison?.begin == codex.beginTree?.tree, "the overtaken turn is no unviewed one to read")
        #expect(comparison?.end == later.endTree?.tree)
        let list = try Panel.list(ChangesPanelModel.make(Panel.input(Panel.agents(timeline))))
        #expect(list.rows.first?.status == .incompleteRecord)
    }

    @Test func theFilter_narrowsTheRows_whileTheCountsStayTheWorktrees() throws {
        let claude1 = try TurnSummaryFixture.timed(1, conversation: "claude", start: 0, end: 10)
        let codex1 = try TurnSummaryFixture.timed(1, conversation: "codex", start: 20, end: 30)
        let claude2 = try TurnSummaryFixture.timed(2, conversation: "claude", start: 40, end: 50)
        let agents = Panel.agents([claude1, claude2, codex1])

        let all = try Panel.list(ChangesPanelModel.make(Panel.input(agents)))
        #expect(all.filter == nil)
        #expect(all.rows.count == 3)

        let narrowed = try Panel.list(ChangesPanelModel.make(Panel.input(agents, chosen: codex1.conversation)))
        #expect(narrowed.filter == codex1.conversation)
        #expect(narrowed.rows.map(\.turn.turnID) == [codex1.turnID])
        #expect(narrowed.turnCount == 3 && narrowed.unviewedCount == 3, "the head counts the worktree")
        #expect(narrowed.conversations.count == 2, "the filter lists every conversation whatever it shows")
        #expect(narrowed.rows.first?.conversation != nil, "the badge stays while narrowed")

        let gone = ConversationKey(provider: .codex, conversationID: "gone", isFallback: false)
        let stale = try Panel.list(ChangesPanelModel.make(Panel.input(agents, chosen: gone)))
        #expect(stale.filter == nil, "a filter of a conversation no longer here narrows nothing")
        #expect(stale.rows.count == 3)
    }

    @Test func theFiltersEntries_areNumberedAmongEveryConversationOfTheirKind() throws {
        var extras = TurnSummaryFixture.Extras()
        let turns = try ["first", "second", "third"].map { id in
            extras.conversationID = id
            return try Panel.turn(1, extras: extras)
        }
        // A Codex running here with no turn recorded yet.
        let codex = ChangesPanelModel.Agent(
            conversation: ConversationKey(provider: .codex, conversationID: "x", isFallback: false),
            turns: []
        )
        let agents = Panel.agents(turns) + [codex]
        var input = Panel.input(agents, lines: [Panel.line(through: turns[0]).line], running: [turns[2].conversation, codex.conversation])
        let tab = ConversationChoice.LiveTab(title: "claude", isInSession: true)
        input.liveTab = { $0 == turns[2].conversation ? tab : nil }

        let list = try Panel.list(ChangesPanelModel.make(input))

        #expect(list.conversations.map(\.ordinal) == [1, 2, 3, nil], "Claude #1 to #3, and the one Codex")
        #expect(list.conversations.map(\.unviewedCount) == [0, 1, 1, 0])
        #expect(list.conversations.map(\.section) == [.viewed, .unviewed, .running, .viewed])
        #expect(list.conversations[2].liveTab == tab)
    }

    @Test func theFold_takesTheViewedRunAtTheTop_andLeavesTheRestAsItIs() throws {
        let claude1 = try TurnSummaryFixture.timed(1, conversation: "claude", start: 0, end: 10)
        let claude2 = try TurnSummaryFixture.timed(2, conversation: "claude", start: 20, end: 30)
        let codex1 = try TurnSummaryFixture.timed(1, conversation: "codex", start: 40, end: 50)
        let claude3 = try TurnSummaryFixture.timed(3, conversation: "claude", start: 60, end: 70)
        let codex2 = try TurnSummaryFixture.timed(2, conversation: "codex", start: 80, end: 90)
        // Claude viewed through T3, Codex through nothing: T3 is a viewed
        // row between two unviewed ones.
        let lines = [Panel.line(through: claude3).line]

        let list = try Panel.list(ChangesPanelModel.make(Panel.input(
            Panel.agents([claude1, claude2, claude3, codex1, codex2]),
            lines: lines
        )))

        #expect(list.rows.map(\.isViewed) == [true, true, false, true, false])
        #expect(list.fold == Fold(count: 2), "only the run at the top")
        #expect(list.line == nil)

        // Everything viewed: all but the last row fold, and the line is
        // below the latest turn.
        let codexLine = Panel.line(through: codex2).line
        let all = try Panel.list(ChangesPanelModel.make(Panel.input(
            Panel.agents([claude1, claude2, claude3, codex1, codex2]),
            lines: lines + [codexLine]
        )))
        #expect(all.fold == Fold(count: 4))
        #expect(all.line != nil)
    }

    @Test func thePanelOpens_onTheFocusedConversationsLatestUnviewedTurn() throws {
        let claude1 = try TurnSummaryFixture.timed(1, conversation: "claude", start: 0, end: 10)
        let codex1 = try TurnSummaryFixture.timed(1, conversation: "codex", start: 20, end: 30)
        let claude2 = try TurnSummaryFixture.timed(2, conversation: "claude", start: 40, end: 50)
        let agents = Panel.agents([claude1, claude2, codex1])

        let focused = try Panel.list(ChangesPanelModel.make(Panel.input(agents, focused: codex1.conversation)))
        #expect(focused.scrollTarget == codex1.turnID)
        let unfocused = try Panel.list(ChangesPanelModel.make(Panel.input(agents)))
        #expect(unfocused.scrollTarget == claude2.turnID, "the latest unviewed")
        let viewedCodex = try Panel.list(ChangesPanelModel.make(Panel.input(
            agents,
            lines: [Panel.line(through: codex1).line],
            focused: codex1.conversation
        )))
        #expect(viewedCodex.scrollTarget == claude2.turnID, "nothing of the focused one is unviewed")
    }

    // MARK: - Mark as Viewed up to Here, across conversations

    @Test func markingThroughARow_reachesEachOtherConversationsLastTurnEndedByThen() throws {
        let codex1 = try TurnSummaryFixture.timed(1, conversation: "codex", start: 0, end: 50)
        let claude3 = try TurnSummaryFixture.timed(3, conversation: "claude", start: 10, end: 60)
        let codex2 = try TurnSummaryFixture.timed(2, conversation: "codex", start: 70, end: 80)
        let claude4 = try TurnSummaryFixture.timed(4, conversation: "claude", start: 90, end: 200)
        let codex3 = try TurnSummaryFixture.timed(3, conversation: "codex", start: 100, end: 150)
        let codex4 = try TurnSummaryFixture.timed(4, conversation: "codex", start: 160, end: 250)
        let running = try TurnSummaryFixture.timed(5, conversation: "codex", start: 180, end: nil, phase: "started")
        let timeline = ChangesPanelModel.timeline([codex1, claude3, codex2, claude4, codex3, codex4, running])

        let marks = WorktreeTimeline.marksThrough(claude4, in: timeline)

        #expect(marks.map(\.turnID) == [claude4.turnID, codex3.turnID], "the row first, then Codex's last turn ended by 200")
        #expect(
            WorktreeTimeline.marksThrough(codex1, in: timeline).map(\.turnID) == [codex1.turnID],
            "nothing of Claude's had ended by 50"
        )
        let list = try Panel.list(ChangesPanelModel.make(Panel.input(Panel.agents(timeline))))
        #expect(list.rows.map(\.movesOtherLines) == [false, true, true, true, true, true, false])
        #expect(ChangesPanelText.action(.markViewedThrough, movesOtherLines: true, locale: Self.japanese) == "すべての会話をここまで確認済みにする")

        // With Codex's ended turns all viewed, Claude's rows move Claude's
        // line alone, and say the short label: another conversation's turn
        // ended by then is not enough, it must be one still to read.
        let codexViewed = try Panel.list(ChangesPanelModel.make(Panel.input(
            Panel.agents(timeline),
            lines: [Panel.line(through: codex4).line]
        )))
        let claudeRows = codexViewed.rows.filter { $0.turn.conversation == claude4.conversation }
        #expect(claudeRows.map(\.movesOtherLines) == [false, false], "nothing of Codex's left to mark")
        // Codex's viewed rows each offer to mark unviewed from there down,
        // which would move Claude's line only where it has passed a Claude
        // turn from that place on.
        let codexRows = codexViewed.rows.filter { $0.turn.conversation == codex1.conversation && $0.action == .markUnviewedFrom }
        #expect(codexRows.map(\.movesOtherLines) == [false, false, false, false], "Claude's line has passed none of its turns")
    }

    @Test func theReviewOpensFrom_theFocusedConversation_elseTheNewestUnviewedTurns() throws {
        let codex1 = try TurnSummaryFixture.timed(1, conversation: "codex", start: 0, end: 50)
        let claude1 = try TurnSummaryFixture.timed(1, conversation: "claude", start: 10, end: 60)
        let timeline = ChangesPanelModel.timeline([codex1, claude1])

        #expect(ChangesPanelModel.reviewConversation(timeline, focused: codex1.conversation, isViewed: { _ in
            false
        }) == codex1.conversation)
        #expect(
            ChangesPanelModel.reviewConversation(timeline, focused: nil, isViewed: { _ in false }) == claude1.conversation,
            "ended last"
        )
        #expect(
            ChangesPanelModel.reviewConversation(
                timeline,
                focused: codex1.conversation,
                isViewed: { $0.conversation == codex1.conversation }
            )
                == claude1.conversation,
            "the focused one has nothing unviewed"
        )
        #expect(ChangesPanelModel.reviewConversation(timeline, focused: nil, isViewed: { _ in true }) == nil)
    }

    // MARK: - The agents of a worktree

    @Test func theSessionsAgents_areTheConversationsWithTurnsHere_thenOnesRunningWithoutAny() throws {
        let here = SnapshotTree(tree: TurnSummaryFixture.tree("e", 1), root: "/repo")
        let elsewhere = SnapshotTree(tree: TurnSummaryFixture.tree("e", 2), root: "/other")
        var second = TurnSummaryFixture.Extras()
        second.conversationID = "s2"
        var third = TurnSummaryFixture.Extras()
        third.conversationID = "s3"
        let first = try TurnSummaryFixture.turn("A1", changes: Self.changed, number: 1, endTree: here)
        let moved = try TurnSummaryFixture.turn("B1", changes: Self.changed, number: 1, endTree: elsewhere, extras: second)
        let away = try TurnSummaryFixture.turn("C1", changes: Self.changed, number: 1, endTree: elsewhere, extras: third)
        let history = [first.conversation: [first], moved.conversation: [moved], away.conversation: [away]]
        let waiting = ConversationKey(provider: .codex, conversationID: "new", isFallback: false)

        let agents = ChangesPanelModel.agents(
            history: history,
            running: [moved.conversation, waiting, waiting],
            root: "/repo",
            isRoot: { $0 == "/repo" }
        )

        // One whose turns were all recorded elsewhere is listed only while
        // it runs here, with none of them.
        #expect(agents.map(\.conversation) == [first.conversation, moved.conversation, waiting])
        #expect(agents.first?.turns == [first])
        #expect(agents.last?.turns.isEmpty == true, "running here, nothing recorded yet")
    }

    @Test func theDecisionBarsReceiptTooltip_namesEachTurnsPromptAndTime_andTheCheck() throws {
        var extras = TurnSummaryFixture.Extras()
        extras.promptHead = "Save the changed files"
        extras.durationSeconds = 250
        let first = try Panel.turn(6, extras: extras)
        extras.promptHead = "Add tests"
        extras.durationSeconds = 185
        extras.check = #"{"command":"swift test --filter Turn","isFiltered":true,"exitCode":0}"#
        let second = try Panel.turn(7, extras: extras)
        let check = try #require(second.lastCheck)
        let unread = UnreadTurn(turnID: second.turnID, numbers: 6...7, changes: .unknown, check: check, conversation: second.conversation)

        let help = ChangesPanelText.receiptHelp(unread, history: [second.conversation: [first, second]], locale: Self.english)

        #expect(help == "T6 · Save the changed files · took 4m 10s\nT7 · Add tests · took 3m 05s\nswift test --filter Turn")

        // The bar's check is the range's last one run, not the last turn's.
        extras.check = nil
        extras.promptHead = "Reply"
        let answer = try Panel.turn(8, changes: #"{"kind":"unchanged"}"#, extras: extras)
        let last = try Panel.turn(9, extras: extras)
        let later = UnreadTurn(
            turnID: last.turnID,
            numbers: 7...9,
            changes: .changed(files: 1, added: 1, removed: 0),
            check: check,
            conversation: last.conversation
        )
        let laterHelp = ChangesPanelText.receiptHelp(later, history: [last.conversation: [second, answer, last]], locale: Self.english)
        #expect(laterHelp?.hasSuffix("swift test --filter Turn") == true)
        #expect(laterHelp?.contains("T8") == false, "an answer between is a receipt of its own")
        #expect(ChangesPanelText.receiptHelp(
            UnreadTurn(turnID: TurnID("x"), changes: .unknown),
            history: [:],
            locale: Self.english
        ) == nil, "an episode no record stands for")
        #expect(ChangesPanelText.sidebarFolded(locale: Self.japanese) == "変更パネルの幅を確保するため、サイドバーを一時的に非表示にしています")
    }

    @Test func aTurnWhoseRecordSkippedLargeFiles_saysHowMany() throws {
        var extras = TurnSummaryFixture.Extras()
        extras.promptHead = "Add the fixtures"
        let skipped = #"{"kind":"changed","files":2,"added":5,"removed":0,"largeFilesSkipped":1}"#
        let turn = try Panel.turn(7, changes: skipped, extras: extras)

        #expect(ChangesPanelText.turnDetails(turn, showsChanges: false, locale: Self.japanese) == [
            "Add the fixtures",
            "大きなファイルを 1 件記録していません"
        ])
        #expect(ChangesPanelText.turnDetails(turn, showsChanges: false, locale: Self.english).last == "Skipped 1 large file")
        let three = try Panel.turn(8, changes: skipped.replacingOccurrences(of: ":1}", with: ":3}"), extras: extras)
        #expect(ChangesPanelText.turnDetails(three, showsChanges: false, locale: Self.english).last == "Skipped 3 large files")
        // The decision bar's receipt says it on the turn's line.
        let unread = UnreadTurn(turnID: turn.turnID, numbers: 7...7, changes: .unknown, conversation: turn.conversation)
        #expect(ChangesPanelText.receiptHelp(unread, history: [turn.conversation: [turn]], locale: Self.english)
            == "T7 · Add the fixtures · Skipped 1 large file")
        // Nothing to say for a turn that skipped none.
        #expect(try ChangesPanelText
            .turnDetails(Panel.turn(9, extras: extras), showsChanges: false, locale: Self.english) == ["Add the fixtures"])
    }

    @Test func theRailsCount_isTheTurnsWaitingToBeRead() throws {
        let turns = try [
            Panel.turn(1),
            Panel.turn(2, changes: #"{"kind":"unchanged"}"#),
            Panel.turn(3),
            Panel.turn(4, phase: "started")
        ]

        #expect(ChangesPanelModel.unviewedCount(turns, line: Panel.line(through: turns[0]).line) == 1)
        #expect(ChangesPanelModel.unviewedCount(turns, line: nil) == 2)
    }
}
