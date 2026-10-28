// ChangesPanelModel+Sections.swift
// Limpid — the changes panel's list grouped by conversation: its sections, what each hides, and how far a section's move reaches.

import Foundation

extension ChangesPanelModel {
    /// The rows grouped a section per conversation: the sections in the
    /// order a menu of conversations lists them (`ConversationChoice.section`,
    /// then `ConversationChoice.byLatestActivity`), each with its rows in
    /// the timeline's order, its own fold, and its own line. A row there
    /// moves its own conversation's line alone: the section reads as
    /// that conversation's list, and a move reaching rows in other sections
    /// would change cards the person is not looking at. `conversations` is what
    /// `groupable` gave.
    static func sections(
        _ rows: [Row],
        conversations: [ConversationChoice],
        line: (ConversationKey) -> ViewedLine?
    ) -> [Section] {
        var byConversation: [ConversationKey: [Row]] = [:]
        for var row in rows {
            row.movesOtherLines = false
            row.movesOnlyItsOwnLine = true
            byConversation[row.turn.conversation, default: []].append(row)
        }
        let ordered = ConversationChoice.Section.allCases.flatMap { section in
            ConversationChoice.byLatestActivity(conversations.filter { $0.section == section })
        }
        return ordered.map { choice in
            let rows = byConversation[choice.conversation] ?? []
            return Section(
                choice: choice,
                rows: rows,
                fold: fold(rows),
                // Its own line's last mark alone: the section's "Unmark as
                // Viewed" must not move another section's line either.
                line: Self.line(rows, conversations: [choice.conversation], line: line)
            )
        }
    }

    /// The conversations the list makes a section for, the first choice
    /// of each key with a turn in `timeline` (as the rows' badges read
    /// them); `nil` where the list cannot group: with a filter, where the
    /// list is that conversation's alone, or with fewer than two
    /// conversations with turns, where one section would only repeat the
    /// list. A conversation that runs but has recorded no turn yet counts
    /// for neither. The one rule for both the sections and whether the
    /// panel offers the switch (`TurnList.canGroup`), so the switch is never
    /// shown where choosing it would change nothing.
    static func groupable(
        _ timeline: [TurnSummary],
        conversations: [ConversationChoice],
        filter: ConversationKey?
    ) -> [ConversationChoice]? {
        guard filter == nil else { return nil }
        let withTurns = Set(timeline.map(\.conversation))
        var seen: Set<ConversationKey> = []
        let withRows = conversations.filter { withTurns.contains($0.conversation) && seen.insert($0.conversation).inserted }
        return withRows.count > 1 ? withRows : nil
    }

    /// Each section with its own moves at rest and its own note
    /// (`placeBlockerNote`, `placeMovesAtRest`): a section reads as its
    /// conversation's list, so its last card is the one most often acted on
    /// there, and placed once over the whole list, every section but the
    /// last would show its moves only under the pointer.
    static func placed(_ sections: [Section]) -> [Section] {
        sections.map { section in
            var rows = section.rows
            placeBlockerNote(rows: &rows)
            placeMovesAtRest(rows: &rows)
            return Section(choice: section.choice, rows: rows, fold: section.fold, line: section.line)
        }
    }

    /// The turns a row's move of the line moves each line to: on the
    /// timeline, every conversation's up to the row's place
    /// (`WorktreeTimeline.marksThrough`, `unmarksFrom`); in a section
    /// (`Row.movesOnlyItsOwnLine`), the row's own turn alone.
    static func turnsMoved(
        by action: RowAction,
        at turn: TurnSummary,
        in timeline: [TurnSummary],
        movesOnlyItsOwnLine: Bool
    ) -> [TurnSummary] {
        guard !movesOnlyItsOwnLine else { return [turn] }
        return switch action {
        case .markViewedThrough: WorktreeTimeline.marksThrough(turn, in: timeline)
        case .markUnviewedFrom: WorktreeTimeline.unmarksFrom(turn, in: timeline)
        }
    }

    /// The rows the list grouped by conversation hides: every row of a
    /// collapsed section, and in an open one what its own fold holds
    /// (`hiddenRows(fold:isUnfolded:shownInReview:rows:)`). Collapsing is
    /// the person's own choice, so it hides even a row the review reads.
    static func hiddenRows(
        sections: [Section],
        collapsed: Set<ConversationKey>,
        unfolded: Set<ConversationKey>,
        shownInReview: Set<TurnID>
    ) -> Set<TurnID> {
        var hidden: Set<TurnID> = []
        for section in sections {
            if collapsed.contains(section.id) {
                hidden.formUnion(section.rows.map(\.id))
            } else {
                hidden.formUnion(hiddenRows(
                    fold: section.fold,
                    isUnfolded: unfolded.contains(section.id),
                    shownInReview: shownInReview,
                    rows: section.rows
                ))
            }
        }
        return hidden
    }
}
