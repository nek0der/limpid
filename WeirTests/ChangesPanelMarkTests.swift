// ChangesPanelMarkTests.swift
// Weir — what the changes panel's end line takes back as one mark, and what its fold hides.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("Changes panel marks and fold")
struct ChangesPanelMarkTests {
    private typealias Panel = ChangesPanelFixture

    /// A line as a file from before marks were kept reads: its move has
    /// neither `markID` nor `sequence`.
    private static func oldMove(through turn: TurnSummary, at: Date) throws -> (line: ViewedLine, change: ViewedLineChange) {
        let move = ViewedLineChange(id: UUID(), from: nil, to: ViewedLinePosition(turn), source: .decisionBar, at: at)
        let line = ViewedLine(conversation: turn.conversation, position: ViewedLinePosition(turn), history: [move])
        let decoded = try JSONDecoder().decode(ViewedLine.self, from: JSONEncoder().encode(line))
        #expect(decoded.history.last?.markID == nil)
        #expect(decoded.history.last?.sequence == nil)
        return (decoded, move)
    }

    /// The panel's list over `turns`, each conversation's line from
    /// `lines`, narrowed to `chosen`.
    private static func list(
        _ turns: [TurnSummary],
        lines: [ViewedLine],
        chosen: ConversationKey? = nil
    ) throws -> ChangesPanelModel.TurnList {

        try Panel.list(ChangesPanelModel.make(Panel.input(Panel.agents(turns), lines: lines, chosen: chosen)))
    }

    /// A mark is its `markID`, never its time. Narrowed to one
    /// conversation, "Unmark as Viewed" still takes back the whole mark;
    /// two marks a moment apart, whose times the file rounds to the same
    /// second, stay two; and a move from a file without a mark goes back
    /// alone.
    @Test func theLine_takesBackOneMarkByItsID_whateverTheFilterShows() throws {
        let codex1 = try TurnSummaryFixture.timed(1, conversation: "codex", start: 0, end: 50)
        let claude1 = try TurnSummaryFixture.timed(1, conversation: "claude", start: 10, end: 60)
        let turns = [codex1, claude1]
        let second = Date(timeIntervalSince1970: 1000)
        let mark = UUID()
        let codexMove = Panel.line(through: codex1, at: second, markID: mark, sequence: 4)
        let claudeMove = Panel.line(through: claude1, at: second, markID: mark, sequence: 4)
        let both = try [
            ViewedLineUndo(conversation: claude1.conversation, changeID: #require(claudeMove.change).id),
            ViewedLineUndo(conversation: codex1.conversation, changeID: #require(codexMove.change).id)
        ].sorted { $0.conversation.conversationID < $1.conversation.conversationID }

        let narrowed = try Self.list(turns, lines: [codexMove.line, claudeMove.line], chosen: codex1.conversation)
        #expect(narrowed.line?.undo == both, "the other conversation's move of the same mark goes back too")
        // Narrowed to a conversation whose own last move was another mark,
        // the line takes back that move alone.
        let codexEarlier = Panel.line(through: codex1, at: Date(timeIntervalSince1970: 500), markID: UUID(), sequence: 1)
        let ownMark = try Self.list(turns, lines: [codexEarlier.line, claudeMove.line], chosen: codex1.conversation)
        #expect(try ownMark.line?.undo == [ViewedLineUndo(conversation: codex1.conversation, changeID: #require(codexEarlier.change).id)])

        // Two marks in the same second, as the file reads them after a
        // relaunch: the later place goes back, alone.
        let codexAlone = Panel.line(through: codex1, at: second, markID: UUID(), sequence: 5)
        let claudeAlone = Panel.line(through: claude1, at: second, markID: UUID(), sequence: 6)
        let apart = try Self.list(turns, lines: [codexAlone.line, claudeAlone.line])
        #expect(try apart.line?.undo == [ViewedLineUndo(conversation: claude1.conversation, changeID: #require(claudeAlone.change).id)])

        // From a file without marks: each move is its own.
        let oldCodex = try Self.oldMove(through: codex1, at: second)
        let oldClaude = try Self.oldMove(through: claude1, at: second)
        let old = try Self.list(turns, lines: [oldCodex.line, oldClaude.line])
        #expect(old.line?.undo.count == 1, "no mark to group by, and the same second tells nothing")
        // A move with a place comes after every one without.
        let newClaude = Panel.line(through: claude1, at: Date(timeIntervalSince1970: 0), markID: UUID(), sequence: 1)
        let mixed = try Self.list(turns, lines: [oldCodex.line, newClaude.line])
        #expect(try mixed.line?.undo == [ViewedLineUndo(conversation: claude1.conversation, changeID: #require(newClaude.change).id)])
    }

    /// "Mark as Unviewed from Here" is the mirror of the mark: every
    /// conversation's line goes back to the row's place on the timeline,
    /// the rows above keep their state, and the label says it reaches the
    /// other conversations.
    @Test func unmarkingFromARow_movesEveryLineBackToTheRowsPlace() throws {
        let codex1 = try TurnSummaryFixture.timed(1, conversation: "codex", start: 0, end: 50)
        let claude3 = try TurnSummaryFixture.timed(3, conversation: "claude", start: 10, end: 60)
        let codex2 = try TurnSummaryFixture.timed(2, conversation: "codex", start: 70, end: 80)
        let claude4 = try TurnSummaryFixture.timed(4, conversation: "claude", start: 90, end: 200)
        let codex3 = try TurnSummaryFixture.timed(3, conversation: "codex", start: 100, end: 150)
        let timeline = ChangesPanelModel.timeline([codex1, claude3, codex2, claude4, codex3])

        let unmarks = WorktreeTimeline.unmarksFrom(codex2, in: timeline)

        #expect(unmarks.map(\.turnID) == [codex2.turnID, claude4.turnID], "the row first, then Claude's first turn from here on")
        #expect(WorktreeTimeline.unmarksFrom(codex3, in: timeline).map(\.turnID) == [codex3.turnID], "nothing of Claude's from here on")
        let lines = [codex3, claude4].map { Panel.line(through: $0, at: Date(), markID: nil, sequence: nil).line }
        let viewed = try Self.list(timeline, lines: lines)
        #expect(viewed.rows.map(\.action) == Array(repeating: .markUnviewedFrom, count: 5))
        #expect(viewed.rows.map(\.movesOtherLines) == [true, true, true, true, false], "the last row has no other line after it")
        let japanese = Locale(identifier: "ja")
        #expect(ChangesPanelText.action(.markUnviewedFrom, movesOtherLines: true, locale: japanese) == "すべての会話をここから未確認にする")
    }

    /// The fold hides what it holds until opened, and never a row the
    /// review reads; a scroll place on a row it hides is no place.
    @Test func theFold_hidesItsRows_saveOneTheReviewReads_andAHiddenRowIsNoScrollPlace() throws {
        let turns = try (1...4).map { try TurnSummaryFixture.timed($0, start: $0 * 100, end: $0 * 100 + 10) }
        let viewed = Panel.line(through: turns[2], at: Date(), markID: nil, sequence: nil).line
        let list = try Self.list(turns, lines: [viewed])
        let fold = try #require(list.fold)
        let folded = Set(turns.prefix(3).map(\.turnID))

        let hidden = ChangesPanelModel.hiddenRows(fold: fold, isUnfolded: false, shownInReview: [], rows: list.rows)
        #expect(hidden == folded)
        #expect(ChangesPanelModel.hiddenRows(fold: fold, isUnfolded: true, shownInReview: [], rows: list.rows).isEmpty)
        #expect(
            ChangesPanelModel.hiddenRows(fold: fold, isUnfolded: false, shownInReview: [turns[1].turnID], rows: list.rows).isEmpty,
            "the review reads T2: the fold stays open"
        )
        #expect(ChangesPanelModel.hiddenRows(fold: nil, isUnfolded: false, shownInReview: [], rows: list.rows).isEmpty)

        // The list was left with T2 at its top, unfolded; it comes back
        // folded, so it opens where it would, on the latest unviewed.
        let drawn = ChangesPanelModel.drawnRows(list.rows, hidden: hidden)
        #expect(drawn == [turns[3].turnID])
        let remembered = ProjectScrollMemory.ChangesPlace(
            conversation: nil,
            place: ProjectScrollMemory.Place(row: turns[1].turnID, selected: turns[3].turnID)
        )
        let target = ProjectScrollMemory.changesTarget(remembered: remembered, conversation: nil, rows: drawn, selected: turns[3].turnID)
        #expect(target == .selected(turns[3].turnID))
        #expect(
            ProjectScrollMemory.changesTarget(
                remembered: remembered,
                conversation: nil,
                rows: list.rows.map(\.id),
                selected: turns[3].turnID
            )
                == .remembered(turns[1].turnID),
            "every row, hidden ones too, would take a place no view can scroll to"
        )
    }

    /// The fold's line shows only while the fold hides its rows: once
    /// opened it leaves the list, and while the review reads a row it holds
    /// it is gone too, since the rows are already shown.
    @Test func theFoldsLine_showsOnlyWhileItHidesItsRows() throws {
        let turns = try (1...4).map { try TurnSummaryFixture.timed($0, start: $0 * 100, end: $0 * 100 + 10) }
        let viewed = Panel.line(through: turns[2], at: Date(), markID: nil, sequence: nil).line
        let list = try Self.list(turns, lines: [viewed])
        let fold = try #require(list.fold)
        func line(isUnfolded: Bool, shownInReview: Set<TurnID>) -> ChangesPanelModel.Fold? {
            let hidden = ChangesPanelModel.hiddenRows(fold: fold, isUnfolded: isUnfolded, shownInReview: shownInReview, rows: list.rows)
            return ChangesPanelModel.foldLine(fold, rows: list.rows, hidden: hidden)
        }

        #expect(line(isUnfolded: false, shownInReview: []) == fold)
        #expect(line(isUnfolded: true, shownInReview: []) == nil, "opened: the line has left the list")
        #expect(line(isUnfolded: false, shownInReview: [turns[1].turnID]) == nil, "the review reads T2, so its rows are shown")
        #expect(ChangesPanelModel.foldLine(nil, rows: list.rows, hidden: []) == nil)
    }
}

extension ChangesPanelMarkTests {
    /// Grouped by conversation, a row's move reaches its own conversation's
    /// line alone, where on the timeline it reaches every line up to
    /// the row's place; the label never says it moves the others.
    @Test func make_byConversation_markViewedThrough_movesOnlyOwnLine() throws {
        let codex1 = try TurnSummaryFixture.timed(1, conversation: "codex", start: 0, end: 50)
        let claude1 = try TurnSummaryFixture.timed(1, conversation: "claude", start: 10, end: 60)
        let codex2 = try TurnSummaryFixture.timed(2, conversation: "codex", start: 70, end: 80)
        let timeline = ChangesPanelModel.timeline([codex1, claude1, codex2])
        var input = Panel.input(Panel.agents(timeline))
        let flat = try Panel.list(ChangesPanelModel.make(input))
        input.grouping = .byConversation

        let grouped = try Panel.list(ChangesPanelModel.make(input))

        let row = try #require(grouped.rows.first { $0.id == codex2.turnID })
        #expect(row.action == .markViewedThrough)
        #expect(row.movesOnlyItsOwnLine)
        #expect(grouped.rows.allSatisfy { !$0.movesOtherLines })
        #expect(ChangesPanelModel.turnsMoved(by: .markViewedThrough, at: codex2, in: timeline, movesOnlyItsOwnLine: true) == [codex2])
        #expect(ChangesPanelModel.turnsMoved(by: .markUnviewedFrom, at: codex1, in: timeline, movesOnlyItsOwnLine: true) == [codex1])
        // On the timeline the same row reaches Claude's line too.
        let flatRow = try #require(flat.rows.first { $0.id == codex2.turnID })
        #expect(flatRow.movesOtherLines)
        #expect(!flatRow.movesOnlyItsOwnLine)
        #expect(
            ChangesPanelModel.turnsMoved(by: .markViewedThrough, at: codex2, in: timeline, movesOnlyItsOwnLine: false)
                == WorktreeTimeline.marksThrough(codex2, in: timeline)
        )
    }
}
