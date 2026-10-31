// ViewedLineActions.swift
// Weir — "Mark as Viewed" and its Undo, from the decision bar's button or ⌘⏎.

import Foundation
import WeirDomain

/// What marking a pane's turns viewed does, and how it is taken back.
///
/// Apart from the window's actions so it can be driven with the stores it
/// touches, without the app.
@MainActor
struct ViewedLineActions {
    let queue: AttentionQueue
    let attention: AttentionState
    let history: [ConversationKey: [TurnSummary]]
    let lines: ViewedLineStore
    let toasts: ToastCenter
    let window: ProjectWindowState

    /// Moves the line of the item's conversation below the last turn the
    /// bar showed (`throughTurn`), or below its latest ended turn when the
    /// press does not say, so every turn shown reads as viewed; the
    /// bar then says so with Undo, and so does a toast, which stays
    /// reachable after the person moves on. An episode no turn record
    /// stands for has no line to move, so its run is marked viewed instead.
    /// Returns whether anything was marked.
    @discardableResult
    func markViewed(_ itemID: AttentionItemID, through throughTurn: Int? = nil, inPane paneID: UUID) -> Bool {
        guard let item = queue.items.first(where: { $0.id == itemID }),
              case let .unread(unread) = item.kind
        else { return false }
        guard let conversation = unread.conversation else {
            guard let runtime = attention.allRuntimes.first(where: { $0.id == item.subject.runtimeID }),
                  attention.viewedRuntimeTokens[runtime.id] != runtime.attentionEventToken
            else { return false }
            attention.markFinishedRuntimesViewed(matching: [runtime.id: [runtime.attentionEventToken]])
            return true
        }
        let turns = (history[conversation] ?? []).filter { turn in throughTurn.map { turn.displayNumber <= $0 } ?? true }
        guard let turn = ViewedLine.latestEnded(in: turns),
              let change = lines.markViewed(through: turn, source: .decisionBar) else { return false }
        let undo = ViewedLineUndo(conversation: conversation, changeID: change.id)
        window.decisionBarDone[paneID] = .markedViewed(undo)
        // A "Done" the review tab left waiting is for a move this one replaces.
        window.pendingDecisionBarDone[paneID] = nil
        // The window is held weakly: the toast moves to a window left when
        // this one closes (`WindowClosing.tidy`), and its Undo still takes
        // the line back then, with no bar of this window left to clear.
        toasts.show(ToastItem(.markedViewed(through: turn.displayNumber), id: change.id) { [lines, toasts, weak window] in
            Self.takeBack(undo, inPane: paneID, lines: lines, toasts: toasts, window: window)
        }, in: window.id)
        return true
    }

    /// "Mark as Viewed up to Here" under a turn's row in the changes panel:
    /// the line moves below `turn`, and a toast offers Undo.
    /// A bar's "Done" for an earlier move of this conversation's line no
    /// longer describes it, so it goes, waiting or shown.
    @discardableResult
    func markViewed(through turn: TurnSummary) -> ViewedLineChange? {
        markViewed(through: [turn]).first?.change
    }

    /// The same on the worktree's timeline, where the row's turn comes
    /// first and the rest are the other conversations' last turns ended
    /// by then (`WorktreeTimeline.marksThrough`): every line moves as one
    /// mark, and one toast, named after the row's turn, takes them all
    /// back. The review's "Mark as Viewed" on a range across
    /// conversations moves them the same way, from `.review`, with the
    /// range's last turn first. Returns the moves made, the first turn's
    /// conversation's first; none when every turn was viewed already.
    /// `name` names a conversation as the changes panel does
    /// ("Claude #4"), which a toast for several lines says, as each
    /// conversation numbers its own turns.
    @discardableResult
    func markViewed(
        through turns: [TurnSummary],
        source: ViewedLineSource = .turnRow,
        named name: (ConversationKey) -> String? = { _ in nil }
    ) -> [ViewedLineStore.Move] {
        let earlier = Set(turns.flatMap { lines.line(of: $0.conversation)?.history.map(\.id) ?? [] })
        let moves = lines.markViewed(through: turns, source: source)
        guard let toast = Self.toastFacts(of: moves, among: turns, named: name) else { return [] }
        for move in moves {
            forgetDone(of: move.conversation)
        }
        dismissToast(among: earlier)
        let kind: ToastKind = toast.others > 0
            ? .markedViewedInConversations(through: toast.turn, conversation: toast.name, others: toast.others)
            : .markedViewed(through: toast.turn)
        offerUndo(of: moves, kind: kind)
        return moves
    }

    /// "Mark as Unviewed from Here" under a viewed turn's row: the line
    /// goes back above `turn`. The row then offers the way forward again,
    /// so no toast.
    @discardableResult
    func markNotViewed(from turn: TurnSummary) -> ViewedLineChange? {
        markNotViewed(from: [turn]).first?.change
    }

    /// The same on the worktree's timeline, the mirror of
    /// `markViewed(through:source:named:)`: the row's turn first, the rest
    /// the other conversations' first turns from the row on
    /// (`WorktreeTimeline.unmarksFrom`), every line moved back as one
    /// mark. Moving one line needs no toast, as the row offers the way
    /// forward again; moving several does, with one Undo for all of them,
    /// since the rows the filter hides moved too.
    @discardableResult
    func markNotViewed(
        from turns: [TurnSummary],
        named name: (ConversationKey) -> String? = { _ in nil }
    ) -> [ViewedLineStore.Move] {
        let earlier = Set(turns.flatMap { lines.line(of: $0.conversation)?.history.map(\.id) ?? [] })
        let moves = lines.markNotViewed(from: turns, history: history, source: .turnRow)
        guard let toast = Self.toastFacts(of: moves, among: turns, named: name) else { return [] }
        for move in moves {
            forgetDone(of: move.conversation)
        }
        dismissToast(among: earlier)
        if toast.others > 0 {
            offerUndo(
                of: moves,
                kind: .markedUnviewedInConversations(from: toast.turn, conversation: toast.name, others: toast.others)
            )
        }
        return moves
    }

    /// A toast whose Undo takes every move of the mark back.
    private func offerUndo(of moves: [ViewedLineStore.Move], kind: ToastKind) {
        guard let first = moves.first else { return }
        let undos = moves.map(\.undo)
        toasts.show(ToastItem(kind, id: first.change.id) { [lines, toasts] in
            for undo in undos {
                lines.undo(undo.changeID, in: undo.conversation)
            }
            toasts.dismiss(first.change.id)
        }, in: window.id)
    }

    /// What a toast for `moves` says: the turn it is named after, that
    /// turn's conversation, and how many other conversations moved. Read
    /// from the moves made, not from the turns asked for: a line already
    /// past its turn moves nothing, and the toast must neither name nor
    /// count it. The first move's turn names it, as `turns` lists the
    /// row's or the range's turn first; its conversation is named as the
    /// caller names it, else by its kind. `nil` when nothing moved.
    private static func toastFacts(
        of moves: [ViewedLineStore.Move],
        among turns: [TurnSummary],
        named name: (ConversationKey) -> String?
    ) -> ToastFacts? {
        guard let first = moves.first,
              let turn = turns.first(where: { $0.conversation == first.conversation })
        else { return nil }
        let named = name(turn.conversation)
            ?? SessionRowFactText.agentName(.agent(turn.conversation.provider), locale: .current)
        return ToastFacts(turn: turn.displayNumber, name: named, others: Set(moves.map(\.conversation)).count - 1)
    }

    /// What a toast for a mark across conversations says (`toastFacts`).
    private struct ToastFacts {
        let turn: Int
        let name: String
        let others: Int
    }

    /// After a restore: the turns it took back have no changes left
    /// to read, so they no longer wait as unviewed. Each conversation's
    /// line moves below the last of them, with no toast of its own: the
    /// restore's says what happened, and "Undo Restore" moves the line
    /// back (`takeBackRestored`). A conversation with an unviewed turn
    /// before them that may have changed files keeps its line: moving it
    /// would mark that turn too, whose changes are still there. One that
    /// only answered has nothing to read, and the line passes it. Every
    /// conversation's move is one mark, so "Unmark as Viewed" takes them
    /// back together, as the restore's undo does.
    func markRestored(_ turns: [TurnSummary]) -> [ViewedLineUndo] {
        let byConversation = Dictionary(grouping: turns, by: \.conversation)
        let lasts = byConversation.keys.sorted { $0.conversationID < $1.conversationID }.compactMap { conversation -> TurnSummary? in
            let restored = byConversation[conversation] ?? []
            guard let first = restored.map(\.displayNumber).min(),
                  let last = restored.max(by: { $0.displayNumber < $1.displayNumber })
            else { return nil }
            let isUnread = (history[conversation] ?? []).contains { turn in
                turn.displayNumber < first && turn.hasPrompt && turn.changes.mayHaveChangedFiles && !lines.isViewed(turn)
            }
            return isUnread ? nil : last
        }
        let earlier = Dictionary(
            lasts.map { ($0.conversation, Set(lines.line(of: $0.conversation)?.history.map(\.id) ?? [])) },
            uniquingKeysWith: { first, _ in first }
        )
        let moves = lines.markViewed(through: lasts, source: .restore)
        for move in moves {
            forgetDone(of: move.conversation)
            dismissToast(among: earlier[move.conversation] ?? [])
        }
        return moves.map(\.undo)
    }

    /// "Undo Restore": the moves `markRestored` made go back, each while it
    /// is still its line's last.
    func takeBackRestored(_ undos: [ViewedLineUndo]) {
        for undo in undos {
            lines.undo(undo.changeID, in: undo.conversation)
        }
    }

    /// "Unmark as Viewed" on the line below the latest turn: the move that
    /// put it there goes back, and its toast and any bar's "Done" with it.
    /// Several moves for the one mark that moved several conversations'
    /// lines (`ChangesPanelModel.Line.undo`).
    func unmark(_ undos: [ViewedLineUndo]) {
        for undo in undos {
            lines.undo(undo.changeID, in: undo.conversation)
            forgetDone(of: undo.conversation)
            toasts.dismiss(undo.changeID)
        }
    }

    func unmark(_ undo: ViewedLineUndo) {
        unmark([undo])
    }

    /// Takes away the toast of an earlier move of the line, in whichever
    /// window it is up: its Undo reaches only the line's last move, so it
    /// would do nothing now.
    private func dismissToast(among earlier: Set<UUID>) {
        for id in earlier {
            toasts.dismiss(id)
        }
    }

    /// Ends every bar's "Done" for a move of `conversation`'s line: after
    /// another move, its Undo would take back one it never showed.
    private func forgetDone(of conversation: ConversationKey) {
        for (paneID, done) in window.decisionBarDone {
            if case let .markedViewed(undo) = done, undo.conversation == conversation {
                window.decisionBarDone[paneID] = nil
            }
        }
        for (paneID, done) in window.pendingDecisionBarDone {
            if case let .markedViewed(undo) = done, undo.conversation == conversation {
                window.pendingDecisionBarDone[paneID] = nil
            }
        }
    }

    /// Undo after "Mark as Viewed", from the bar or the toast: the line goes
    /// back, and neither offers Undo for that move any longer.
    func takeBack(_ undo: ViewedLineUndo, inPane paneID: UUID) {
        Self.takeBack(undo, inPane: paneID, lines: lines, toasts: toasts, window: window)
    }

    private static func takeBack(
        _ undo: ViewedLineUndo,
        inPane paneID: UUID,
        lines: ViewedLineStore,
        toasts: ToastCenter,
        window: ProjectWindowState?
    ) {
        lines.undo(undo.changeID, in: undo.conversation)
        if let window, window.decisionBarDone[paneID] == .markedViewed(undo) {
            window.decisionBarDone[paneID] = nil
        }
        if let window, window.pendingDecisionBarDone[paneID] == .markedViewed(undo) {
            window.pendingDecisionBarDone[paneID] = nil
        }
        toasts.dismiss(undo.changeID)
    }
}
