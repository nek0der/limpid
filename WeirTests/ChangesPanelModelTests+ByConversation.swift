// ChangesPanelModelTests+ByConversation.swift
// Weir — the changes panel's turns grouped a section per conversation: the sections' order, their rows, folds, and lines.

import Foundation
import Testing
@testable import Weir

/// Apart from the suite's file, which is at its length limit.
extension ChangesPanelModelTests {
    /// The panel over `turns`, grouped by conversation, with `running`
    /// run in a pane of the session.
    private static func grouped(
        _ turns: [TurnSummary],
        lines: [ViewedLine] = [],
        chosen: ConversationKey? = nil,
        running: [ConversationKey] = []
    ) throws -> ChangesPanelModel.TurnList {
        var input = Panel.input(Panel.agents(turns), lines: lines, chosen: chosen, running: running)
        input.grouping = .byConversation
        input.liveTab = { running.contains($0) ? ConversationChoice.LiveTab(title: "agent", isInSession: true) : nil }
        return try Panel.list(ChangesPanelModel.make(input))
    }

    /// The conversation run here first, however long ago it last did
    /// something; then those with turns to read, the latest first; then
    /// those read through.
    @Test func make_byConversation_ordersSectionsRunningUnviewedViewed() throws {
        let done = try TurnSummaryFixture.timed(1, conversation: "done", start: 900, end: 950)
        let running = try TurnSummaryFixture.timed(1, conversation: "running", start: 0, end: 10)
        let older = try TurnSummaryFixture.timed(1, conversation: "older", start: 100, end: 300)
        let newer = try TurnSummaryFixture.timed(1, conversation: "newer", start: 200, end: 500)
        let lines = [done, running].map { Panel.line(through: $0).line }

        let list = try Self.grouped([done, running, older, newer], lines: lines, running: [running.conversation])

        let sections = try #require(list.sections)
        #expect(sections.map(\.id) == [running, newer, older, done].map(\.conversation))
        #expect(sections.map(\.choice.section) == [.running, .unviewed, .unviewed, .viewed])
        #expect(list.rows.map(\.id) == sections.flatMap(\.rows).map(\.id), "the rows in the order drawn")
    }

    /// A section's rows run oldest first, as the timeline does, and only
    /// its own conversation's.
    @Test func make_byConversation_keepsRowsOldestFirst() throws {
        let a1 = try TurnSummaryFixture.timed(1, conversation: "a", start: 0, end: 10)
        let b1 = try TurnSummaryFixture.timed(1, conversation: "b", start: 20, end: 30)
        let a2 = try TurnSummaryFixture.timed(2, conversation: "a", start: 40, end: 50)
        let b2 = try TurnSummaryFixture.timed(2, conversation: "b", start: 60, end: 70)
        let a3 = try TurnSummaryFixture.timed(3, conversation: "a", start: 80, end: 90)

        let list = try Self.grouped([a1, b1, a2, b2, a3])

        let sections = try #require(list.sections)
        #expect(sections.map(\.id) == [a1.conversation, b1.conversation], "a ended last")
        #expect(sections[0].rows.map(\.id) == [a1, a2, a3].map(\.turnID))
        #expect(sections[1].rows.map(\.id) == [b1, b2].map(\.turnID))
        #expect(list.scrollTarget == b2.turnID, "the last unviewed row as drawn, not the one that ended last")
    }

    /// Narrowed to one conversation, the list is the timeline: no
    /// sections, and the rows, fold, and line as the timeline has them.
    @Test func make_byConversation_withFilter_isTimeline() throws {
        let turns = try [
            TurnSummaryFixture.timed(1, conversation: "a", start: 0, end: 10),
            TurnSummaryFixture.timed(1, conversation: "b", start: 20, end: 30),
            TurnSummaryFixture.timed(2, conversation: "a", start: 40, end: 50)
        ]
        let chosen = turns[0].conversation

        let list = try Self.grouped(turns, chosen: chosen)
        let timeline = try Panel.list(ChangesPanelModel.make(Panel.input(Panel.agents(turns), chosen: chosen)))

        #expect(list.sections == nil)
        #expect(list == timeline)
    }

    /// One conversation needs no sections.
    @Test func make_byConversation_singleConversation_isTimeline() throws {
        let turns = try [Panel.turn(1), Panel.turn(2)]

        let list = try Self.grouped(turns)
        let timeline = try Panel.list(ChangesPanelModel.make(Panel.input(Panel.agents(turns))))

        #expect(list.sections == nil)
        #expect(list == timeline)
    }

    /// A conversation that runs in a tab but has recorded no turn yet makes
    /// no section, so beside one with turns the list cannot group, and the
    /// panel offers no switch that would change nothing.
    @Test func make_byConversation_runningConversationWithoutTurns_cannotGroup() throws {
        let turns = try [Panel.turn(1), Panel.turn(2)]
        let idle = TurnSummaryFixture.conversation("just-launched")
        var agents = Panel.agents(turns)
        agents.append(ChangesPanelModel.Agent(conversation: idle, turns: []))
        var input = Panel.input(agents, running: [idle])
        input.grouping = .byConversation

        let list = try Panel.list(ChangesPanelModel.make(input))

        #expect(list.conversations.count == 2, "both are in the filter")
        #expect(list.sections == nil)
        #expect(!list.canGroup)
    }

    /// Two conversations with turns can group, whichever way the window
    /// lists them; narrowed to one by the filter, they cannot.
    @Test func make_twoConversationsWithTurns_canGroupWithoutFilter() throws {
        let turns = try [
            TurnSummaryFixture.timed(1, conversation: "a", start: 0, end: 10),
            TurnSummaryFixture.timed(1, conversation: "b", start: 20, end: 30)
        ]

        let grouped = try Self.grouped(turns)
        let timeline = try Panel.list(ChangesPanelModel.make(Panel.input(Panel.agents(turns))))
        let filtered = try Self.grouped(turns, chosen: turns[0].conversation)

        #expect(grouped.sections != nil)
        #expect(grouped.canGroup)
        #expect(timeline.sections == nil)
        #expect(timeline.canGroup)
        #expect(!filtered.canGroup)
    }

    /// Each section folds its own viewed rows and draws its own line; the
    /// list as a whole has neither.
    @Test func make_byConversation_foldsViewedRowsPerSection() throws {
        let a = try (1...4).map { try TurnSummaryFixture.timed($0, conversation: "a", start: $0 * 100, end: $0 * 100 + 10) }
        let b = try (1...3).map { try TurnSummaryFixture.timed($0, conversation: "b", start: $0 * 100 + 20, end: $0 * 100 + 30) }
        let aLine = Panel.line(through: a[2], markID: UUID(), sequence: 1)
        let bLine = Panel.line(through: b[2], markID: UUID(), sequence: 2)

        let list = try Self.grouped(a + b, lines: [aLine.line, bLine.line])

        let sections = try #require(list.sections)
        #expect(sections.map(\.id) == [a[0].conversation, b[0].conversation])
        #expect(sections[0].fold == ChangesPanelModel.Fold(count: 3))
        #expect(sections[0].line == nil, "a's latest turn is unviewed")
        #expect(sections[1].fold == ChangesPanelModel.Fold(count: 2), "never the section's last row")
        let bChange = try #require(bLine.change)
        #expect(sections[1].line?.undo == [ViewedLineUndo(conversation: b[0].conversation, changeID: bChange.id)])
        #expect(list.fold == nil)
        #expect(list.line == nil)
    }

    /// Each section reads as a list of its own, so each shows the moves of
    /// its own last card at rest and says why a restore waits under its own
    /// last entry; the timeline keeps one of each for the whole list.
    @Test func make_byConversation_placesMovesAndBlockerNotePerSection() throws {
        let a1 = try TurnSummaryFixture.timed(1, conversation: "a", start: 0, end: 10)
        let b1 = try TurnSummaryFixture.timed(1, conversation: "b", start: 20, end: 30)
        let a2 = try TurnSummaryFixture.timed(2, conversation: "a", start: 40, end: 50)
        let b2 = try TurnSummaryFixture.timed(2, conversation: "b", start: 60, end: 70)
        var input = Panel.input(Panel.agents([a1, b1, a2, b2]))
        input.restoreBlocker = { _ in .agentWaiting }

        var groupedInput = input
        groupedInput.grouping = .byConversation
        let grouped = try Panel.list(ChangesPanelModel.make(groupedInput))
        let timeline = try Panel.list(ChangesPanelModel.make(input))

        let sections = try #require(grouped.sections)
        #expect(sections.map(\.id) == [b1.conversation, a1.conversation], "b ended last")
        for section in sections {
            #expect(section.rows.map(\.showsMovesAtRest) == [false, true], "the section's last card")
            #expect(section.rows.map(\.showsBlockerNote) == [false, true], "under the section's last entry")
        }
        #expect(grouped.rows == sections.flatMap(\.rows), "the list's rows are the sections' as placed")
        #expect(timeline.rows.map(\.showsMovesAtRest) == [false, false, false, true])
        #expect(timeline.rows.map(\.showsBlockerNote) == [false, false, false, true])
    }

    /// One mark on the timeline that moved both lines: each section's
    /// "Unmark as Viewed" takes back its own conversation's move of it alone.
    @Test func make_byConversation_sharedMark_eachSectionUndoesItsOwnLine() throws {
        let a = try TurnSummaryFixture.timed(1, conversation: "a", start: 0, end: 10)
        let b = try TurnSummaryFixture.timed(1, conversation: "b", start: 20, end: 30)
        let mark = UUID()
        let aLine = Panel.line(through: a, markID: mark, sequence: 1)
        let bLine = Panel.line(through: b, markID: mark, sequence: 1)

        let list = try Self.grouped([a, b], lines: [aLine.line, bLine.line])

        let sections = try #require(list.sections)
        let aChange = try #require(aLine.change)
        let bChange = try #require(bLine.change)
        let undo = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0.line?.undo) })
        #expect(undo[a.conversation] == [ViewedLineUndo(conversation: a.conversation, changeID: aChange.id)])
        #expect(undo[b.conversation] == [ViewedLineUndo(conversation: b.conversation, changeID: bChange.id)])
    }

    /// A collapsed section's rows are not drawn, so the list neither scrolls
    /// to them nor moves the keyboard through them; an open section hides
    /// only what its own fold holds.
    @Test func hiddenRows_collapsedSection_hidesEveryRow() throws {
        let a = try (1...3).map { try TurnSummaryFixture.timed($0, conversation: "a", start: $0 * 100, end: $0 * 100 + 10) }
        let b = try (1...3).map { try TurnSummaryFixture.timed($0, conversation: "b", start: $0 * 100 + 20, end: $0 * 100 + 30) }
        let bLine = Panel.line(through: b[1], markID: UUID(), sequence: 1)
        let list = try Self.grouped(a + b, lines: [bLine.line])
        let sections = try #require(list.sections)
        #expect(sections.map(\.id) == [b[0].conversation, a[0].conversation])

        let hidden = ChangesPanelModel.hiddenRows(
            sections: sections,
            collapsed: [a[0].conversation],
            unfolded: [],
            shownInReview: []
        )

        #expect(hidden == Set(a.map(\.turnID) + b.prefix(2).map(\.turnID)))
        #expect(ChangesPanelModel.drawnRows(list.rows, hidden: hidden) == [b[2].turnID])

        let opened = ChangesPanelModel.hiddenRows(
            sections: sections,
            collapsed: [],
            unfolded: [b[0].conversation],
            shownInReview: []
        )
        #expect(opened.isEmpty)
    }
}
