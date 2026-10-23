// OutsideTurnsPlan.swift
// Limpid — which stretches of a worktree's history no turn of any agent accounts for.

import Foundation

/// The comparisons that find what changed outside every turn in a worktree:
/// the gaps between turns, while no agent's turn ran, and what
/// changed since the last turn ended, unless one runs now.
///
/// Every agent of the worktree counts, not one conversation: a file the
/// other agent wrote during its own turn was written in a turn. Turns are
/// laid on one timeline by when they started and ended; a gap opens only
/// when every turn so far has ended, and runs to the next turn's begin. A
/// gap whose snapshots are missing, or were taken in another work tree, is
/// unknown rather than guessed, and is left out. So is one that starts from
/// turns of two conversations that ended in the same second at different
/// trees: the record keeps whole seconds, so which tree was left last is
/// not known, and taking the wrong one would count the other agent's work
/// as done outside turns. A gap that runs to turns of two conversations
/// that began in the same second from different trees is left out for the
/// same reason at its other end. The plan then says it is not complete. Nothing
/// before the first turn counts: the history before any agent is no one's
/// turn to account for.
struct OutsideTurnsPlan: Equatable, Sendable {
    /// One gap: the tree the turns had left, and the next turn's begin.
    /// Both are fixed, so what changed between them never changes.
    struct Gap: Hashable, Sendable {
        let end: String
        let begin: String
    }

    var gaps: [Gap]
    /// The tree the last ended turn left, when no turn runs now: the
    /// worktree compared against it is what changed since.
    var since: String?
    /// This is false when a gap, or what changed since, was left out because
    /// the turns it starts from ended, or the turns it runs to began, in the
    /// same second at different trees: the count may then be short, and the
    /// plan says so rather than guessing.
    var isComplete = true

    /// `isHere` says whether a snapshot was taken in this work tree.
    /// `isRecorded` says whether a conversation's turn of that number is
    /// recorded anywhere: one that is not was deleted by the retention
    /// sweep (the counter never goes back), and a gap across it is
    /// left out of the count, since what that turn changed is in it. What a
    /// person changed in that gap is left out with it: the count says too
    /// little there rather than calling the deleted turn's work theirs.
    /// `isRecorded` sees a missing number only between two turns of one
    /// conversation that follow each other here; a deleted turn between
    /// turns of other conversations leaves none. `deleted`, when the turns
    /// deleted in this worktree ran, leaves out the gaps they fell in, and
    /// what changed since when one ran after the last turn left.
    static func make(
        turns: [TurnSummary],
        isHere: (SnapshotTree) -> Bool,
        isRecorded: (ConversationKey, Int) -> Bool = { _, _ in true },
        deleted: [DateInterval] = []
    ) -> OutsideTurnsPlan {
        // We walk the turns in the timeline's order, the one the changes panel lists: by start,
        // and where starts tie, one conversation's turns by number.
        let ordered = WorktreeTimeline.ordered(turns)
        var gaps: [Gap] = []
        var coveredUntil: Date?
        var lastEnd: SnapshotTree?
        // The turn that left `lastEnd`.
        var lastEnded: TurnSummary?
        // Each conversation's latest turn that ended at `coveredUntil`: of
        // one conversation the higher number ended last; across two, the
        // order is not known.
        var endedLast: [ConversationKey: TurnSummary] = [:]
        var isComplete = true
        var isRunning = false
        for turn in ordered {
            let start = WorktreeTimeline.startDate(turn) ?? .distantPast
            let isAcrossDeleted = lastEnded.map { last in
                last.conversation == turn.conversation && last.displayNumber + 1 < turn.displayNumber
                    && (last.displayNumber + 1..<turn.displayNumber).contains { !isRecorded(turn.conversation, $0) }
            } ?? false
            if let covered = coveredUntil, !isRunning, start >= covered, !isAcrossDeleted,
               !deleted.contains(where: { $0.end >= covered && $0.start <= start }),
               let end = lastEnd, let begin = turn.beginTree, isHere(end), isHere(begin), end.tree != begin.tree
            {
                if isOrderUnknown(endedLast) || isBeginOrderUnknown(of: turn, in: ordered) {
                    isComplete = false
                } else {
                    let gap = Gap(end: end.tree, begin: begin.tree)
                    if !gaps.contains(gap) {
                        gaps.append(gap)
                    }
                }
            }
            if turn.phase == .started {
                // It runs until now: what changes from here is its agent's.
                isRunning = true
                continue
            }
            // A record from before end times were kept ended no later than
            // the next turn of its conversation began.
            let end = UnreadTurnRules.date(turn.finishedAt) ?? start
            if coveredUntil.map({ end >= $0 }) ?? true {
                if coveredUntil != end {
                    endedLast = [:]
                }
                if let earlier = endedLast[turn.conversation], earlier.displayNumber > turn.displayNumber {
                    continue
                }
                endedLast[turn.conversation] = turn
                coveredUntil = end
                lastEnd = turn.endTree
                lastEnded = turn
            }
        }
        // A turn deleted that ran after the last one left is in it too;
        // one ending in the same second may have written after it, as the
        // gaps count it.
        let isAfterDeleted = coveredUntil.map { covered in !deleted.contains { $0.end >= covered } } ?? true
        var since = isRunning || !isAfterDeleted ? nil : lastEnd.flatMap { isHere($0) ? $0.tree : nil }
        if since != nil, isOrderUnknown(endedLast) {
            since = nil
            isComplete = false
        }
        return OutsideTurnsPlan(gaps: gaps, since: since, isComplete: isComplete)
    }

    /// Whether the turns that ended last, in one second, left different
    /// trees in different conversations, so which was left last is not
    /// known.
    private static func isOrderUnknown(_ endedLast: [ConversationKey: TurnSummary]) -> Bool {
        endedLast.count > 1 && Set(endedLast.values.map(\.endTree?.tree)).count > 1
    }

    /// Whether a turn of another conversation began in the same second as
    /// `turn` from a different tree, so which of them began first, and so
    /// which tree the gap runs to, is not known. The timeline still puts
    /// one first, but only to keep its list steady, not as a record of
    /// which began first.
    private static func isBeginOrderUnknown(of turn: TurnSummary, in turns: [TurnSummary]) -> Bool {
        let start = WorktreeTimeline.startDate(turn)
        return turns.contains { other in
            other.conversation != turn.conversation && WorktreeTimeline.startDate(other) == start
                && other.beginTree?.tree != turn.beginTree?.tree
        }
    }
}
