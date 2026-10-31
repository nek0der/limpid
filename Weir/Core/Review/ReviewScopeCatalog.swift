// ReviewScopeCatalog.swift
// Weir — the comparisons "Review Scope" offers, from the worktree's turns and each conversation's.

import Foundation
import WeirDomain

/// The turns below the viewed line, as the first choice offers them.
enum ReviewUnviewedTurns: Equatable, Sendable {
    /// None: every turn that changed files is viewed ("Unviewed Turns
    /// (None)").
    case none
    /// Some, but the first one's begin or the last one's end was not taken,
    /// so there is no fixed comparison to read; the record is incomplete,
    /// and is not guessed at. Their numbers, for saying so.
    case incomplete(ClosedRange<Int>)
    case range(ReviewTurnRange)
}

/// One choice of "Review Scope".
enum ReviewScopeOption: Equatable, Sendable {
    /// The turns of one conversation below its viewed line, as one range
    /// ("Unviewed Turns (T6–T7)").
    case unviewedTurns(ReviewUnviewedTurns)
    /// Every conversation's unviewed turns in the worktree, as one range
    /// from the oldest one's begin to the end of the one that ended last,
    /// with the viewed turns between them inside it. A choice of its own, apart from a
    /// conversation's, though the two may compare the same two trees: the
    /// menu and the tab name what was chosen, and with nothing unviewed
    /// ("(None)") the two would otherwise be one value.
    case worktreeUnviewedTurns(ReviewUnviewedTurns)
    /// One turn ("T7 · {prompt}"), or the turns "Add to Scope" carried it
    /// on to ("T7–T8 · {prompt}").
    case turn(ReviewTurnRange, prompt: TurnPrompt)
    /// A turn opened from its row whose record lost a snapshot: there is no
    /// fixed comparison to read, so the review says the record is
    /// incomplete rather than guess. Never listed.
    case incompleteTurn(Int)
    /// Staged, unstaged, and untracked changes, saying when some of them
    /// were made outside any turn.
    case uncommitted(includesChangesOutsideTurns: Bool)
    /// Since the branch left `base`.
    case branch(base: String)

    /// The comparison this choice reads, `nil` when there is none to read:
    /// no unviewed turns, or a record that lost a snapshot.
    var scope: ReviewScope? {
        switch self {
        case let .unviewedTurns(.range(range)), let .worktreeUnviewedTurns(.range(range)): .turns(range)
        case .unviewedTurns, .worktreeUnviewedTurns: nil
        case let .turn(range, _): .turns(range)
        case .incompleteTurn: nil
        case .uncommitted: .uncommitted
        case let .branch(base): .branch(base: base)
        }
    }

    /// Whether the choice reads one conversation's turns, and so belongs
    /// under that conversation's heading in the menu: not the worktree's
    /// unviewed turns, nor the uncommitted changes or the branch, which no
    /// conversation owns.
    var isConversations: Bool {
        switch self {
        case .unviewedTurns, .turn, .incompleteTurn: true
        case .worktreeUnviewedTurns, .uncommitted, .branch: false
        }
    }
}

/// Builds the scope choices, and the turns that ended after a range on
/// screen. Pure, so the order and what is left out are tested without Git.
enum ReviewScopeCatalog {
    /// The choices, in the order the dropdown lists them: the unviewed turns,
    /// each turn newest first, uncommitted changes, and the branch. A turn
    /// that changed no files, one still running, one nobody prompted, one
    /// whose snapshots were not both taken, and one a restore took back
    /// (`isRestored`) are not listed: there is nothing to read, or no fixed
    /// comparison to read it in.
    static func options(
        turns: [TurnSummary],
        isViewed: (TurnSummary) -> Bool,
        isRestored: (TurnSummary) -> Bool = { _ in false },
        branchBase: String?,
        hasChangesOutsideTurns: Bool
    ) -> [ReviewScopeOption] {
        conversationOptions(turns: turns, isViewed: isViewed, isRestored: isRestored)
            + worktreeOptions(branchBase: branchBase, hasChangesOutsideTurns: hasChangesOutsideTurns)
    }

    /// One conversation's choices, as its heading in the menu lists them:
    /// its unviewed turns, then each turn newest first.
    static func conversationOptions(
        turns: [TurnSummary],
        isViewed: (TurnSummary) -> Bool,
        isRestored: (TurnSummary) -> Bool = { _ in false }
    ) -> [ReviewScopeOption] {
        var options: [ReviewScopeOption] = [
            .unviewedTurns(unviewedTurns(turns: turns, isViewed: isViewed, isRestored: isRestored))
        ]
        for turn in turns.reversed() where isReadable(turn) && !isRestored(turn) {
            if let range = ReviewTurnRange(turns: [turn]) {
                options.append(.turn(range, prompt: turn.prompt))
            }
        }
        return options
    }

    /// The choices no conversation owns, which end the menu: the
    /// uncommitted changes and the branch.
    static func worktreeOptions(branchBase: String?, hasChangesOutsideTurns: Bool) -> [ReviewScopeOption] {
        var options: [ReviewScopeOption] = [.uncommitted(includesChangesOutsideTurns: hasChangesOutsideTurns)]
        if let branchBase {
            options.append(.branch(base: branchBase))
        }
        return options
    }

    /// The turns of `timeline` whose changes the range's two trees hold, in
    /// the timeline's order: every conversation's turn that started at or
    /// after the range's first turn and ended by its end turn
    /// (`WorktreeTimeline.turns(from:through:in:)`). By time, not by place
    /// in the list: a turn of another conversation that started and ended
    /// inside a range of one long turn is among them. Empty when
    /// either end is not on the timeline.
    static func turnsThrough(_ range: ReviewTurnRange, timeline: [TurnSummary]) -> [TurnSummary] {
        WorktreeTimeline.turns(from: range.firstTurnID, through: range.endTurnID, in: timeline)
    }

    /// The turns below the viewed line as one comparison: from the begin of
    /// the one that started first to the end of the one that ended last,
    /// with what ran between them, in the timeline's order. Given a
    /// worktree's timeline (every conversation's turns), the range is the
    /// worktree's, with the viewed turns and the gaps between them inside
    /// it; a turn that started early and ran long ends it, so nothing it
    /// did is left out of the range "Mark as Viewed" marks. A turn that
    /// started inside and ended after it is no turn of the range: its
    /// later part is not in it. The ends are never moved to a turn whose
    /// snapshot was taken: a missing snapshot at either end, two turns that
    /// ended last in the same second at different trees, or a turn of the
    /// range whose start cannot be read (its place is not known) make the
    /// record incomplete, and it is not guessed at. A turn still
    /// running is none of the range's, as it has not ended.
    static func unviewedTurns(
        turns: [TurnSummary],
        isViewed: (TurnSummary) -> Bool,
        isRestored: (TurnSummary) -> Bool = { _ in false }
    ) -> ReviewUnviewedTurns {
        let ended = WorktreeTimeline.ordered(turns).filter { $0.phase != .started }
        let unviewed = ended.filter { isUnviewed($0, isViewed: isViewed, isRestored: isRestored) }
        guard let first = unviewed.first, let firstIndex = ended.firstIndex(where: { $0.turnID == first.turnID }) else {
            return .none
        }
        // Across conversations the numbers are each their own
        // conversation's, so only their span is said.
        let numbers = unviewed.map(\.displayNumber)
        let incomplete = ReviewUnviewedTurns.incomplete((numbers.min() ?? 0)...(numbers.max() ?? 0))
        guard let last = WorktreeTimeline.lastEnded(unviewed) else { return incomplete }
        let end = WorktreeTimeline.endDate(last)
        let slice = ended[firstIndex...].filter { WorktreeTimeline.endDate($0) <= end }
        guard slice.allSatisfy(WorktreeTimeline.hasStart),
              let range = ReviewTurnRange(turns: slice, endingWith: last)
        else { return incomplete }
        return .range(range)
    }

    /// What a range is said with, every count from one reading: its turns
    /// on `timeline` split into the unviewed ones (`isUnviewed`, the turns
    /// the range is there to read, and their conversations) and the rest it
    /// reads through, viewed or with nothing left to read. The menu's
    /// entry ("All Unviewed (10 turns · 6 conversations)", "Includes 16
    /// viewed turns") and the review's top edge both say these.
    struct RangeCounts: Equatable, Sendable {
        let unviewedTurns: Int
        let unviewedConversations: Int
        /// The range's turns that are not unviewed: viewed, taken back by
        /// a restore, or with no change to read. Not unviewed is what the
        /// person reads them as, so the count says them as viewed.
        let viewedTurns: Int
    }

    static func counts(
        in range: ReviewTurnRange,
        timeline: [TurnSummary],
        isViewed: (TurnSummary) -> Bool,
        isRestored: (TurnSummary) -> Bool = { _ in false }
    ) -> RangeCounts {
        let inRange = Set(range.turnIDs)
        let turns = timeline.filter { inRange.contains($0.turnID) }
        let unviewed = turns.filter { isUnviewed($0, isViewed: isViewed, isRestored: isRestored) }
        return RangeCounts(
            unviewedTurns: unviewed.count,
            unviewedConversations: Set(unviewed.map(\.conversation)).count,
            viewedTurns: turns.count - unviewed.count
        )
    }

    /// Whether `turn` is one the unviewed turns hold: one to read
    /// (`isReadable`) below its conversation's line. A turn a restore took
    /// back has nothing left to read, wherever the viewed line is.
    static func isUnviewed(
        _ turn: TurnSummary,
        isViewed: (TurnSummary) -> Bool,
        isRestored: (TurnSummary) -> Bool
    ) -> Bool {
        isReadable(turn) && !isViewed(turn) && !isRestored(turn)
    }

    /// The turns of the range's conversation that ended after it while it
    /// was open: offered, never added on their own. Only up to the
    /// last whose end was taken, since a range ends at a recorded tree; with
    /// none, nothing is offered.
    static func followingTurns(after range: ReviewTurnRange, in turns: [TurnSummary]) -> [TurnSummary] {
        let inRange = Set(range.turnIDs)
        let following = turns.filter {
            $0.conversation == range.conversation && $0.displayNumber > range.lastNumber && $0.phase != .started
                && !inRange.contains($0.turnID)
        }
        guard let last = following.lastIndex(where: { $0.endTree != nil }) else { return [] }
        return Array(following[...last])
    }

    /// Whether `turn` is one to read: it ended, someone prompted it, and it
    /// may have changed files, as the decision bar counts unread changes. A
    /// turn whose changes could not be taken is not one, though a range
    /// still reads through it when it falls between two that are: the range
    /// compares its first turn's begin with its last turn's end. Opened from
    /// its own row, it says why (`ReviewTabModel`).
    static func isReadable(_ turn: TurnSummary) -> Bool {
        turn.phase != .started && turn.hasPrompt && turn.changes.mayHaveChangedFiles
    }
}
