// RestoreConfirmation.swift
// Limpid — what the restore strip asks before the code goes back to the start of a turn, and where the strip stands.

import Foundation

/// The question the restore strip asks: which turns' changes go, by
/// how much, and what stays; and whether "Restore Code" can run now.
struct RestoreConfirmation: Equatable {
    let text: String
    let note: String
    /// Why "Restore Code" is unavailable; `nil` while it can run.
    let blockedReason: String?
    /// The lines the restore takes back, as `text` counts them.
    let added: Int
    let removed: Int
    /// Whether another conversation's agent is in the worktree, whose
    /// changes the restore takes back too but `text` does not count.
    var isShared = false

    /// The question's tooltip: `text`, and with the worktree shared, that
    /// its counts are this conversation's alone. The note says the others'
    /// changes go too; without this, the "+94 −2" would read as all of them.
    func help(locale: Locale) -> String {
        guard isShared else { return text }
        // Japanese sentences follow one another with no space between.
        let separator = locale.language.languageCode == .japanese ? "" : " "
        return text + separator + RestoreText.countsOwnTurnsOnly(locale: locale)
    }

    /// `text` in runs, its "+94" and "−2" apart so the strip draws them in
    /// the diff colors, all of it as the strip's question.
    func textRuns(locale: Locale) -> [ReceiptRun] {
        ReceiptText.diffRuns(in: text, added: added, removed: removed, isEmphasized: true, locale: locale)
    }

    /// The strip for restoring to the start of `turn`. `undone` are the
    /// turns of its conversation in the same worktree from `turn` on whose
    /// changes are still there: the changes the restore takes back. The
    /// worktree is shared when another conversation's agent is in it,
    /// whose changes go too.
    static func make(
        turn: TurnSummary,
        undone: [TurnSummary],
        gate: RestoreGate.Input,
        locale: Locale
    ) -> RestoreConfirmation {
        let isShared = gate.agents.contains { !$0.isTurnsOwn }
        var added = 0
        var removed = 0
        for undoneTurn in undone {
            if case let .changed(_, plus, minus) = undoneTurn.changes {
                added += plus
                removed += minus
            }
        }
        // Named by the turns the panel lists; one nobody prompted is not
        // there to find, though its changes are counted and go too.
        let last = max(undone.filter(\.hasPrompt).map(\.displayNumber).max() ?? turn.displayNumber, turn.displayNumber)
        return RestoreConfirmation(
            text: RestoreText.confirmation(
                first: turn.displayNumber,
                last: last,
                added: added,
                removed: removed,
                locale: locale
            ),
            note: RestoreText.confirmationNote(isShared: isShared, locale: locale),
            blockedReason: RestoreGate.blocker(gate).map { RestoreText.blocker($0, locale: locale) },
            added: added,
            removed: removed,
            isShared: isShared
        )
    }

    /// The turns a restore to the start of `turn` takes back: its
    /// conversation's, from it on, in the worktree it began in. A turn an
    /// earlier restore took back (`isRestored`) has no changes left to
    /// count.
    static func undone(
        by turn: TurnSummary,
        in history: [ConversationKey: [TurnSummary]],
        isRestored: (TurnSummary) -> Bool = { _ in false }
    ) -> [TurnSummary] {
        (history[turn.conversation] ?? []).filter { other in
            other.displayNumber >= turn.displayNumber && other.beginTree?.root == turn.beginTree?.root
                && !isRestored(other)
        }
    }
}

/// The turn an entry restores to when the person did not pick one:
/// the palette's, from the conversation in the focused pane.
enum RestoreEntryTarget {
    /// The first unviewed turn that can be restored to, so the code goes
    /// back to the viewed state; with none unviewed, the latest one. A turn
    /// still running, one whose start was not recorded, one that changed
    /// nothing, one nobody prompted, or one a restore already took back is
    /// passed over.
    static func turn(
        in turns: [TurnSummary],
        line: ViewedLine?,
        isRestored: (TurnSummary) -> Bool = { _ in false }
    ) -> TurnSummary? {
        let candidates = turns.filter { turn in
            turn.phase != .started && turn.beginTree != nil && turn.changes.mayHaveChangedFiles && turn.hasPrompt
                && !isRestored(turn)
        }
        let isViewed = { (turn: TurnSummary) in line?.isViewed(turn) ?? false }
        return candidates.first { !isViewed($0) } ?? candidates.last
    }
}

/// The restore strip of one pane, where every entry opens its question:
/// asking, running, or saying how it ended without changing the
/// working tree.
struct RestoreStrip: Equatable {
    enum Phase: Equatable {
        case confirming
        case running
        /// It wrote nothing, or wrote and took it back; what it says, with
        /// "Close".
        case ended(String)
    }

    let turnID: TurnID
    var phase: Phase = .confirming

    /// Whether the pane's bar shows its items rather than the strip: an
    /// approval, a question, or a wait at the prompt is the agent asking
    /// the person now, and the gate holds the restore back while one waits.
    /// The strip stays, and comes back once they go. A stop asks nothing
    /// and holds nothing back: restoring to before the turn that stopped
    /// is one way to deal with it.
    static func yields(to items: [AttentionItem]) -> Bool {
        items.contains { item in
            switch item.kind {
            case .approval, .question, .prompt: true
            case .stop, .unread: false
            }
        }
    }
}
