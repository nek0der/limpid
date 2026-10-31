// WorktreeTimeline.swift
// Weir — the one order of a worktree's turns across conversations, and when each ended, for the panel and the review alike.

import Foundation

/// The rules of a worktree's timeline: every conversation's turns in
/// one order, by when each started, and what "ended by then" means across
/// conversations. The changes panel lists turns in this order, and the
/// review reads ranges, file tags, and a discard's later turns by it, so
/// the two never disagree about which turn came first or ended last.
///
/// Plain values only: what a record says, never what a pane or a view
/// shows.
package enum WorktreeTimeline {
    /// The turns by when each started, as the restore orders turns across
    /// conversations. Two turns started in the same second (the
    /// record keeps seconds) keep the order of their conversations' first
    /// turns, then their numbers, so the list never reorders between two
    /// readings. A turn whose start cannot be read goes first, where its
    /// place is said to be unknown (`hasStart`). Every turn is kept: the
    /// caller leaves out what it does not list.
    package static func ordered(_ turns: [TurnSummary]) -> [TurnSummary] {
        var firstStarts: [ConversationKey: Date] = [:]
        for turn in turns {
            let start = sortStart(turn)
            firstStarts[turn.conversation] = min(firstStarts[turn.conversation] ?? start, start)
        }
        func key(_ turn: TurnSummary) -> Key {
            Key(
                start: sortStart(turn),
                conversationStart: firstStarts[turn.conversation] ?? .distantPast,
                conversationID: turn.conversation.conversationID,
                number: turn.displayNumber
            )
        }
        return turns.sorted { key($0) < key($1) }
    }

    /// The timeline the changes panel lists and the review reads its
    /// ranges from: the turns someone prompted, in order. A record nobody
    /// prompted is no turn.
    package static func listed(_ turns: [TurnSummary]) -> [TurnSummary] {
        ordered(turns.filter(\.hasPrompt))
    }

    /// Whether `turns` are in the timeline's order: by when each started,
    /// as `ordered` puts them. Two that started in the same second may be
    /// in either order, as a slice of a longer timeline breaks that tie by
    /// turns it does not hold. Within a conversation the numbers need not
    /// go up: a turn another overtook, or a clock set back, can start
    /// before the one numbered before it, and the timeline puts it first.
    package static func isInOrder(_ turns: [TurnSummary]) -> Bool {
        zip(turns, turns.dropFirst()).allSatisfy { sortStart($0) <= sortStart($1) }
    }

    /// Whether the record says when the turn started. One that does not
    /// has no known place on the timeline.
    package static func hasStart(_ turn: TurnSummary) -> Bool {
        UnreadTurnRules.date(turn.startedAt) != nil
    }

    /// When a turn started, `nil` when the record cannot be read.
    package static func startDate(_ turn: TurnSummary) -> Date? {
        UnreadTurnRules.date(turn.startedAt)
    }

    /// When a turn ended, for ordering what ended by when: the record's
    /// time, or its start for a record with none (a turn another overtook).
    package static func endDate(_ turn: TurnSummary) -> Date {
        UnreadTurnRules.date(turn.finishedAt) ?? sortStart(turn)
    }

    /// The turn of `turns` that ended last: what a comparison over them
    /// ends at. Within one conversation, of two that ended in the same
    /// second, the one numbered later, as a conversation runs one turn at a
    /// time. `nil` when there are none, or when turns of two conversations
    /// ended in the same second at different trees: which of them ended
    /// last is not recorded, and the range is not guessed at.
    package static func lastEnded(_ turns: [TurnSummary]) -> TurnSummary? {
        guard let latest = turns.map(endDate).max() else { return nil }
        let tied = turns.filter { endDate($0) == latest }
        if Set(tied.map(\.conversation)).count == 1 {
            return tied.max { $0.displayNumber < $1.displayNumber }
        }
        // Across conversations at one tree, the comparison is the same
        // whichever ends it; the one that started last names it.
        return Set(tied.map { $0.endTree?.tree }).count == 1 ? tied.last : nil
    }

    /// The turns "Mark as Viewed up to Here" on `turn`'s row moves each
    /// conversation's line below: the row's turn itself, first, then
    /// for every other conversation of `timeline` its last turn that ended
    /// by the row's turn's end. "Up to here" is a time on the timeline, so
    /// every conversation's line comes up to it; a conversation with no
    /// turn ended by then keeps its line. The caller moves nothing for a
    /// turn already viewed.
    package static func marksThrough(_ turn: TurnSummary, in timeline: [TurnSummary]) -> [TurnSummary] {
        let end = endDate(turn)
        var others: [ConversationKey: TurnSummary] = [:]
        for other in timeline
            where other.conversation != turn.conversation && other.phase != .started && endDate(other) <= end
        {
            if let last = others[other.conversation], last.displayNumber > other.displayNumber {
                continue
            }
            others[other.conversation] = other
        }
        return [turn] + others.values.sorted { $0.conversation.conversationID < $1.conversation.conversationID }
    }

    /// The turns "Mark as Unviewed from Here" on `turn`'s row moves each
    /// conversation's line above, the mirror of `marksThrough`: the
    /// row's turn itself, first, then for every other conversation of
    /// `timeline` its first turn at or after the row on the timeline. "From
    /// here" is a place on the timeline, so every row from it down reads as
    /// unviewed again and every row above keeps its state; a conversation
    /// with no turn from here on keeps its line. The caller moves nothing
    /// for a turn already unviewed.
    package static func unmarksFrom(_ turn: TurnSummary, in timeline: [TurnSummary]) -> [TurnSummary] {
        guard let index = timeline.firstIndex(where: { $0.turnID == turn.turnID }) else { return [turn] }
        var others: [ConversationKey: TurnSummary] = [:]
        for other in timeline[index...] where other.conversation != turn.conversation {
            if let first = others[other.conversation], first.displayNumber < other.displayNumber {
                continue
            }
            others[other.conversation] = other
        }
        return [turn] + others.values.sorted { $0.conversation.conversationID < $1.conversation.conversationID }
    }

    /// Whether each row's move of the line moves another conversation's
    /// line too, read once for a whole list rather than a reading of every
    /// turn's dates for every row: for "Mark as Viewed up to Here", another
    /// conversation has a turn its line has not passed that ended by the
    /// row's end (`marksThrough`); for "Mark as Unviewed from Here", another
    /// has a turn its line has passed at or after the row (`unmarksFrom`).
    /// What the move's label and tooltip say.
    package struct OtherLines: Sendable {
        /// The conversation whose ended turns not viewed end first, with
        /// that end, and the first such end of any other conversation.
        /// "Another conversation than X has one by then" needs no more:
        /// whichever X is, one of the two is not X and ends first among the
        /// rest.
        private let firstUnviewedEnds: EarliestByConversation
        /// By row, who has a viewed turn at or after it: no conversation,
        /// one, or more than one. That answers "another than X" exactly
        /// with one value per row, where a set per row would grow with the
        /// number of conversations (to half the square of the timeline's
        /// length when each turn is its own conversation).
        private let viewedFrom: [TurnID: ConversationsHolding]

        package init(_ timeline: [TurnSummary], isViewed: (TurnSummary) -> Bool) {
            var ends: [ConversationKey: Date] = [:]
            for turn in timeline where turn.phase != .started && !isViewed(turn) {
                let end = WorktreeTimeline.endDate(turn)
                ends[turn.conversation] = min(ends[turn.conversation] ?? end, end)
            }
            firstUnviewedEnds = EarliestByConversation(ends)
            var seen = ConversationsHolding.noConversation
            var from: [TurnID: ConversationsHolding] = [:]
            for turn in timeline.reversed() {
                if isViewed(turn) {
                    seen = seen.adding(turn.conversation)
                }
                from[turn.turnID] = seen
            }
            viewedFrom = from
        }

        /// Whether "Mark as Viewed up to Here" on `turn` moves another
        /// conversation's line too.
        package func marksOthers(_ turn: TurnSummary) -> Bool {
            guard let end = firstUnviewedEnds.earliest(otherThan: turn.conversation) else { return false }
            return end <= WorktreeTimeline.endDate(turn)
        }

        /// Whether "Mark as Unviewed from Here" on `turn` moves another
        /// conversation's line too.
        package func unmarksOthers(_ turn: TurnSummary) -> Bool {
            viewedFrom[turn.turnID]?.hasOther(than: turn.conversation) ?? false
        }
    }

    /// Which conversations hold something, as far as "another than X"
    /// needs: none, exactly one (which), or more than one.
    private enum ConversationsHolding: Sendable, Equatable {
        case noConversation
        case one(ConversationKey)
        case many

        /// These, with `conversation` among them.
        func adding(_ conversation: ConversationKey) -> Self {
            switch self {
            case .noConversation: .one(conversation)
            case let .one(held) where held == conversation: self
            case .one, .many: .many
            }
        }

        /// Whether a conversation other than `conversation` is among
        /// them. Of more than one, at least one is not it.
        func hasOther(than conversation: ConversationKey) -> Bool {
            switch self {
            case .noConversation: false
            case let .one(held): held != conversation
            case .many: true
            }
        }
    }

    /// The earliest of the conversations' dates, and the earliest of
    /// any other conversation's, so the earliest of every conversation
    /// but one is read without going through them all.
    private struct EarliestByConversation: Sendable {
        private let first: (conversation: ConversationKey, date: Date)?
        private let second: Date?

        init(_ dates: [ConversationKey: Date]) {
            var first: (conversation: ConversationKey, date: Date)?
            var second: Date?
            for (conversation, date) in dates {
                if let current = first, current.date <= date {
                    second = min(second ?? date, date)
                } else {
                    second = first?.date
                    first = (conversation, date)
                }
            }
            self.first = first
            self.second = second
        }

        /// The earliest date of a conversation other than
        /// `conversation`, `nil` when it has none.
        func earliest(otherThan conversation: ConversationKey) -> Date? {
            guard let first else { return nil }
            return first.conversation == conversation ? second : first.date
        }
    }

    /// The turns of `timeline` whose whole run lies within the comparison
    /// from `first`'s start to `last`'s end, every conversation's, in the
    /// timeline's order: those whose changes the comparison holds. A
    /// turn of another conversation that started and ended inside a turn
    /// of one is among them. Empty when either end has no known start or
    /// is not on the timeline. The record keeps seconds, so a turn that
    /// started and ended in the second the range ends (or one that began
    /// it) reads as inside by time alone; within the conversation of
    /// either end, the turns' numbers say which side it is on, as a
    /// conversation runs one turn at a time.
    package static func turns(from first: TurnID, through last: TurnID, in timeline: [TurnSummary]) -> [TurnSummary] {
        guard let firstTurn = timeline.first(where: { $0.turnID == first }),
              let lastTurn = timeline.first(where: { $0.turnID == last }),
              let begin = startDate(firstTurn)
        else { return [] }
        let end = endDate(lastTurn)
        guard begin <= end else { return [] }
        return timeline.filter { turn in
            let isBeforeFirst = turn.conversation == firstTurn.conversation && turn.displayNumber < firstTurn.displayNumber
            let isAfterLast = turn.conversation == lastTurn.conversation && turn.displayNumber > lastTurn.displayNumber
            return turn.phase != .started && !isBeforeFirst && !isAfterLast
                && startDate(turn).map { $0 >= begin } == true && endDate(turn) <= end
        }
    }

    /// Where a turn sorts: its start, or before every other for a start
    /// that cannot be read.
    private static func sortStart(_ turn: TurnSummary) -> Date {
        startDate(turn) ?? .distantPast
    }

    /// What orders the timeline (`ordered`), in the order compared.
    private struct Key: Comparable {
        package let start: Date
        let conversationStart: Date
        package let conversationID: String
        package let number: Int

        package init(
            start: Date,
            conversationStart: Date,
            conversationID: String,
            number: Int
        ) {
            self.start = start
            self.conversationStart = conversationStart
            self.conversationID = conversationID
            self.number = number
        }

        package static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.start != rhs.start {
                return lhs.start < rhs.start
            }
            if lhs.conversationStart != rhs.conversationStart {
                return lhs.conversationStart < rhs.conversationStart
            }
            if lhs.conversationID != rhs.conversationID {
                return lhs.conversationID < rhs.conversationID
            }
            return lhs.number < rhs.number
        }
    }
}
