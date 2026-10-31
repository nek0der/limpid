// ViewedLine.swift
// Weir — how far the person has viewed one conversation's turns, and the moves they can take back.

import Foundation

/// Where a viewed line stands: below one turn.
///
/// The line is held by turn ID, so two turns that reach the same tree stay
/// two turns. It also keeps the turn's number, which orders it
/// against the conversation's other turns after its record is deleted, and
/// the tree the turn ended at, which the line's auxiliary ref points to.
package struct ViewedLinePosition: Equatable, Codable, Sendable {
    package let turnID: TurnID
    /// The turn's `displayNumber`: never reused within its conversation, so
    /// a turn is under the line exactly when its number is not greater.
    package let displayNumber: Int
    /// `nil` when the turn's end snapshot was not taken.
    package let endTree: SnapshotTree?

    package init(turnID: TurnID, displayNumber: Int, endTree: SnapshotTree?) {
        self.turnID = turnID
        self.displayNumber = displayNumber
        self.endTree = endTree
    }

    package init(_ turn: TurnSummary) {
        self.init(turnID: turn.turnID, displayNumber: turn.displayNumber, endTree: turn.endTree)
    }
}

/// Where the person moved the line from. Kept with each move for the
/// record; nothing behaves differently by it yet.
package enum ViewedLineSource: String, Codable, Sendable {
    case decisionBar
    case review
    case turnRow
    /// A restore took the turns' changes back.
    case restore
    case unknown

    package init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

/// One move of the line, kept so it can be taken back.
package struct ViewedLineChange: Equatable, Codable, Sendable, Identifiable {
    package let id: UUID
    package let from: ViewedLinePosition?
    package let to: ViewedLinePosition?
    package let source: ViewedLineSource
    package let at: Date
    /// The mark the move was made in: one press that moved several
    /// conversations' lines gives each move the same mark, and "Unmark as
    /// Viewed" takes back the moves of one mark together, whatever the
    /// panel's filter shows. A move made alone is a mark of its own.
    /// Never told by `at`: the file keeps whole seconds, so two marks a
    /// moment apart would read as one after a relaunch. Optional because
    /// a file from before it was kept has none; such a move is taken back
    /// alone (`docs/data-migration.md`).
    package var markID: UUID?
    /// The mark's place among every mark the store made, every
    /// conversation's, from 1: what tells the latest mark across lines, as
    /// `at` keeps only whole seconds in the file. Optional for the same
    /// reason as `markID`; a move without it came before every move with it.
    package var sequence: Int?
}

/// How far the person has viewed one conversation: every turn
/// at or above the line is viewed, every turn below it is not.
///
/// Keyed by conversation rather than by run, so resuming the conversation
/// in a new run keeps the line. Only the person moves it: opening a diff or
/// a pane never does.
package struct ViewedLine: Equatable, Codable, Sendable {
    /// Moves kept for undo. Undo reaches the latest move only, so a few are
    /// plenty; the rest are dropped oldest first, except those a caller
    /// keeps (`trimHistory(keeping:)`).
    static let historyLimit = 20

    package let conversation: ConversationKey
    package private(set) var position: ViewedLinePosition?
    /// Oldest first.
    package private(set) var history: [ViewedLineChange]

    package init(conversation: ConversationKey, position: ViewedLinePosition? = nil, history: [ViewedLineChange] = []) {
        self.conversation = conversation
        self.position = position
        self.history = history
    }

    var lastViewedTurnID: TurnID? {
        position?.turnID
    }

    /// Whether `turn` is at or above the line. The line's own turn is
    /// viewed only as it ended when the line was put below it: a turn whose
    /// end was taken again since at another tree (work after its stop, which
    /// the hook folds into it under the same ID) has changes nobody has
    /// seen, so it reads as not viewed until the line is moved below it
    /// again. An end taken where there was none (a snapshot that settled
    /// after the mark) is the same end, not a new one.
    package func isViewed(_ turn: ViewedLinePosition) -> Bool {
        guard let position else { return false }
        guard turn.displayNumber == position.displayNumber else {
            return turn.displayNumber < position.displayNumber
        }
        return !Self.isRetaken(position, as: turn)
    }

    /// Whether `turn` is the line's own turn ended again at another tree.
    private static func isRetaken(_ marked: ViewedLinePosition, as turn: ViewedLinePosition) -> Bool {
        guard let was = marked.endTree?.tree, let now = turn.endTree?.tree else { return false }
        return was != now
    }

    /// Moves the line below `turn`. Nothing happens, and `nil` is returned,
    /// when the line is already there or further down: marking what is
    /// already viewed takes nothing back. `keeping` are the moves the
    /// history keeps past its limit (`trimHistory(keeping:)`).
    package mutating func advance(
        to turn: ViewedLinePosition,
        source: ViewedLineSource,
        id: UUID = UUID(),
        markID: UUID? = nil,
        sequence: Int? = nil,
        at now: Date = Date(),
        keeping: Set<UUID> = []
    ) -> ViewedLineChange? {
        guard !isViewed(turn) else { return nil }
        defer { trimHistory(keeping: keeping) }
        return move(to: turn, source: source, id: id, mark: (markID, sequence), at: now)
    }

    /// Moves the line back to just above `turn`, so that turn and every
    /// later one read as not viewed. `earlier` is the latest turn before
    /// it, `nil` when it is the conversation's first. Nothing happens when
    /// the turn is already below the line. `keeping` as for `advance`.
    package mutating func retreat(
        toBefore turn: ViewedLinePosition,
        earlier: ViewedLinePosition?,
        source: ViewedLineSource,
        id: UUID = UUID(),
        markID: UUID? = nil,
        sequence: Int? = nil,
        at now: Date = Date(),
        keeping: Set<UUID> = []
    ) -> ViewedLineChange? {
        guard isViewed(turn) else { return nil }
        defer { trimHistory(keeping: keeping) }
        return move(to: earlier, source: source, id: id, mark: (markID, sequence), at: now)
    }

    /// Drops the oldest moves past `historyLimit`, but none of `kept`: a
    /// restore's moves, which its "Undo Restore" takes back for as long as
    /// its journal can be undone, however many moves came after
    /// (`ViewedLineStore.noteRestoreMoves`). The limit counts the others.
    /// An undo of one of `kept` then puts the line back where that move
    /// found it, past any older move dropped in between.
    package mutating func trimHistory(keeping kept: Set<UUID>) {
        var excess = history.count { !kept.contains($0.id) } - Self.historyLimit
        guard excess > 0 else { return }
        history.removeAll { change in
            guard excess > 0, !kept.contains(change.id) else { return false }
            excess -= 1
            return true
        }
    }

    /// Takes back the move `changeID` when it is the latest one, so an Undo
    /// left on screen cannot undo a later move it never showed. Returns the
    /// move taken back, or `nil` when nothing was.
    package mutating func undo(_ changeID: UUID) -> ViewedLineChange? {
        guard let last = history.last, last.id == changeID else { return nil }
        history.removeLast()
        position = last.from
        return last
    }

    /// A move given no mark is a mark of its own, named by its own ID.
    private mutating func move(
        to next: ViewedLinePosition?,
        source: ViewedLineSource,
        id: UUID,
        mark: (id: UUID?, sequence: Int?),
        at now: Date
    ) -> ViewedLineChange {
        let change = ViewedLineChange(
            id: id,
            from: position,
            to: next,
            source: source,
            at: now,
            markID: mark.id ?? id,
            sequence: mark.sequence
        )
        position = next
        history.append(change)
        return change
    }
}

package extension ViewedLine {
    /// Whether `turn` is at or above the line (`isViewed(_:)`).
    func isViewed(_ turn: TurnSummary) -> Bool {
        isViewed(ViewedLinePosition(turn))
    }

    /// The turn "Mark as Viewed" moves the line below: the
    /// conversation's latest turn that has ended. A turn still running is
    /// left below the line, since nobody has seen what it does.
    static func latestEnded(in turns: [TurnSummary]) -> TurnSummary? {
        turns.last { $0.phase != .started }
    }
}

/// What an Undo after marking turns viewed takes back: one move of one
/// conversation's line.
package struct ViewedLineUndo: Codable, Hashable, Sendable {
    package let conversation: ConversationKey
    package let changeID: UUID

    package init(
        conversation: ConversationKey,
        changeID: UUID
    ) {
        self.conversation = conversation
        self.changeID = changeID
    }
}
