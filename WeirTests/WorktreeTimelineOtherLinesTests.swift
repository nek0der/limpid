// WorktreeTimelineOtherLinesTests.swift
// Weir — whether a row's move reaches other lines, against a reading of every turn.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

/// `WorktreeTimeline.OtherLines` keeps a summary a row rather than every
/// conversation a row, so these check it gives the answers a reading of
/// the whole timeline for every row gives, and stays small for a timeline
/// of one conversation a turn.
struct WorktreeTimelineOtherLinesTests {
    /// What "Mark as Viewed up to Here" asks, read the long way: another
    /// conversation has an ended turn not viewed that ended by the row's end.
    private static func marksOthers(_ turn: TurnSummary, in timeline: [TurnSummary], isViewed: (TurnSummary) -> Bool) -> Bool {
        let end = WorktreeTimeline.endDate(turn)
        return timeline.contains { other in
            other.conversation != turn.conversation && other.phase != .started
                && !isViewed(other) && WorktreeTimeline.endDate(other) <= end
        }
    }

    /// What "Mark as Unviewed from Here" asks, read the long way: another
    /// conversation has a viewed turn at or after the row.
    private static func unmarksOthers(_ turn: TurnSummary, in timeline: [TurnSummary], isViewed: (TurnSummary) -> Bool) -> Bool {
        guard let index = timeline.firstIndex(where: { $0.turnID == turn.turnID }) else { return false }
        return timeline[index...].contains { $0.conversation != turn.conversation && isViewed($0) }
    }

    /// A generator a seed fixes, so a failure reads the same timeline again.
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    @Test(arguments: 0..<200)
    func otherLines_randomTimeline_matchesReadingEveryTurn(seed: Int) throws {
        var random = SplitMix(state: UInt64(seed))
        // No conversation (an empty timeline), one, or several.
        let conversationCount = seed % 6
        let turnCount = conversationCount == 0 ? 0 : Int.random(in: 1...30, using: &random)
        var turns: [TurnSummary] = []
        for number in 0..<turnCount {
            let start = Int.random(in: 0...40, using: &random)
            // A narrow window of times, so ends tie across conversations.
            let end = start + Int.random(in: 0...5, using: &random)
            let isRunning = Int.random(in: 0..<5, using: &random) == 0
            try turns.append(TurnSummaryFixture.timed(
                number + 1,
                conversation: "c\(Int.random(in: 0..<conversationCount, using: &random))",
                start: start,
                end: isRunning ? nil : end,
                phase: isRunning ? "started" : "finished"
            ))
        }
        let timeline = WorktreeTimeline.ordered(turns)
        let viewed = Set(timeline.filter { _ in Bool.random(using: &random) }.map(\.turnID))
        let isViewed = { (turn: TurnSummary) in viewed.contains(turn.turnID) }
        let others = WorktreeTimeline.OtherLines(timeline, isViewed: isViewed)

        for turn in timeline {
            #expect(others.marksOthers(turn) == Self.marksOthers(turn, in: timeline, isViewed: isViewed), "seed \(seed)")
            #expect(others.unmarksOthers(turn) == Self.unmarksOthers(turn, in: timeline, isViewed: isViewed), "seed \(seed)")
        }
        // A turn the timeline does not hold: no row of its own, and
        // nothing at all on an empty timeline.
        let absent = try TurnSummaryFixture.timed(999, conversation: "absent", start: 20, end: 25)
        #expect(others.marksOthers(absent) == Self.marksOthers(absent, in: timeline, isViewed: isViewed), "seed \(seed)")
        #expect(others.unmarksOthers(absent) == Self.unmarksOthers(absent, in: timeline, isViewed: isViewed), "seed \(seed)")
    }

    /// Two records with one turn ID, as a repeated record would give: the
    /// row reads from the first of them, as `unmarksFrom` finds it.
    @Test func otherLines_repeatedTurnID_readsFromItsFirstPlace() throws {
        let early = try TurnSummaryFixture.timed(1, conversation: "a", start: 0, end: 0)
        let other = try TurnSummaryFixture.timed(1, conversation: "b", start: 1, end: 1)
        let late = try TurnSummaryFixture.timed(1, conversation: "a", start: 2, end: 2)
        let timeline = [early, other, late]
        #expect(early.turnID == late.turnID)
        // Only the other conversation's turn is viewed, so a row from the
        // first place has it after, and one from the second would not.
        let isViewed = { (turn: TurnSummary) in turn.conversation == other.conversation }
        let others = WorktreeTimeline.OtherLines(timeline, isViewed: isViewed)

        for turn in timeline {
            #expect(others.marksOthers(turn) == Self.marksOthers(turn, in: timeline, isViewed: isViewed))
            #expect(others.unmarksOthers(turn) == Self.unmarksOthers(turn, in: timeline, isViewed: isViewed))
        }
        #expect(others.unmarksOthers(late))
    }

    @Test(arguments: [
        // Nothing viewed, everything viewed, and only one conversation's.
        (Set<Int>(), "none viewed"),
        (Set(0..<6), "all viewed"),
        (Set([0, 2, 4]), "one conversation viewed"),
        (Set([1, 5]), "the other's viewed"),
        (Set([5]), "only the last viewed")
    ])
    func otherLines_twoConversationsTable_matchesReadingEveryTurn(viewedIndices: Set<Int>, label: String) throws {
        // Two conversations taking turns, a turn a second.
        let timeline = try (0..<6).map { index in
            try TurnSummaryFixture.timed(index + 1, conversation: index.isMultiple(of: 2) ? "a" : "b", start: index, end: index)
        }
        let viewed = Set(viewedIndices.map { timeline[$0].turnID })
        let isViewed = { (turn: TurnSummary) in viewed.contains(turn.turnID) }
        let others = WorktreeTimeline.OtherLines(timeline, isViewed: isViewed)

        for turn in timeline {
            #expect(others.marksOthers(turn) == Self.marksOthers(turn, in: timeline, isViewed: isViewed), "\(label)")
            #expect(others.unmarksOthers(turn) == Self.unmarksOthers(turn, in: timeline, isViewed: isViewed), "\(label)")
        }
    }

    @Test func otherLines_singleConversation_neverMovesAnother() throws {
        let timeline = try (0..<4).map { try TurnSummaryFixture.timed($0 + 1, start: $0, end: $0) }
        let others = WorktreeTimeline.OtherLines(timeline) { $0.displayNumber.isMultiple(of: 2) }

        #expect(timeline.map(others.marksOthers) == [false, false, false, false])
        #expect(timeline.map(others.unmarksOthers) == [false, false, false, false])
    }

    /// The retention cap's worst case: every turn its own conversation, every
    /// other one viewed. A set a row would hold some 16 million entries here;
    /// the answers are checked against what the shape says, not timed.
    @Test func otherLines_eightThousandConversations_answersEveryRow() throws {
        let count = 8000
        let timeline = try (0..<count).map { index in
            try TurnSummaryFixture.timed(1, conversation: "c\(index)", start: index * 10, end: index * 10 + 1)
        }
        let isViewed = { (index: Int) in index.isMultiple(of: 2) }
        let viewed = Set(timeline.indices.filter(isViewed).map { timeline[$0].turnID })
        let others = WorktreeTimeline.OtherLines(timeline) { viewed.contains($0.turnID) }

        // Another conversation has a turn not viewed that ended by row `i`'s
        // end once an odd row before `i` exists (from row 2 on); another has
        // a viewed turn from row `i` on while an even row after it remains
        // (up to the last viewed row, not including it).
        let lastViewed = try #require((0..<count).last(where: isViewed))
        var marks: [Bool] = []
        var unmarks: [Bool] = []
        for turn in timeline {
            marks.append(others.marksOthers(turn))
            unmarks.append(others.unmarksOthers(turn))
        }
        #expect(marks == timeline.indices.map { $0 >= 2 })
        #expect(unmarks == timeline.indices.map { $0 < lastViewed })
    }
}
