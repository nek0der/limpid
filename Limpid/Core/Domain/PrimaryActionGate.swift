// PrimaryActionGate.swift
// Limpid — when ⌘⏎ performs the decision bar's primary button, and when the key goes to the terminal.

import Foundation

/// What the decision bar's primary button does. There is none for an
/// approval or a question: ⌘⏎ never lets a command run, since those are
/// answered in the terminal or on the approval card. Each carries the item
/// it was shown for, so the press acts on that item even if the bar moves
/// on before it runs.
enum PrimaryAction: Equatable, Sendable {
    /// Unread turns that changed files are marked as reviewed, through
    /// the last turn the bar showed (`throughTurn`, its number), so a turn
    /// joining the item a moment before the press is not marked unseen;
    /// and since the action changes with it, the key waits again.
    /// `nil` for an episode no turn record stands for.
    case markReviewed(AttentionItemID, throughTurn: Int?)
    /// A stopped agent resumes the same conversation.
    case resume(AttentionItemID)
    /// A stop at a usage limit that resets later asks to be told when it
    /// does: resuming before then would only meet the limit again.
    case notifyAtReset(AttentionItemID)
    /// A workspace whose worktree is gone closes its tabs, through
    /// Close All Tabs' own confirmation: there is no folder left to resume
    /// or start in.
    case closeAllTabs(AttentionItemID)
}

/// One press of Return or the keypad's Enter with ⌘ held, in a terminal
/// pane.
struct PrimaryKeyPress: Equatable, Sendable {
    /// ⌘ and nothing else. With ⌥, ⇧, or ⌃ too it is never the bar's, and
    /// it reaches the gate only when no binding took it.
    let isCommandOnly: Bool
    /// An input method is composing text; the key confirms it there and
    /// sends no Return of its own.
    let isComposing: Bool
    /// The key held down. A held ⌘⏎ performs at most once.
    var isRepeat = false
}

/// Decides each ⌘⏎ press against the pane's agent and what its decision bar
/// shows. The key acts only on the item the bar shows in the pane
/// that has the keyboard, and only once that item has been on screen for
/// `settleTime`, so a press meant for the item before it does not answer
/// the one that just replaced it. In a pane where Limpid sees an agent, the
/// key never reaches the terminal, whatever else is held with ⌘ and
/// whether or not the bar is drawn (review hides it): Claude Code reads it
/// as Return, so a press with no button to take it would answer whatever
/// confirmation the agent shows, and that may be an approval. A pane with
/// no agent is the terminal's.
struct PrimaryActionGate: Sendable {
    enum Decision: Equatable, Sendable {
        case perform(PrimaryAction)
        /// Taken and dropped: neither the bar nor the terminal sees it.
        case swallow
        /// Not the bar's: the terminal gets the key as it was typed.
        case passThrough
    }

    /// What one pane's bar shows, and since when.
    private struct Shown: Sendable {
        let itemID: AttentionItemID?
        let primaryAction: PrimaryAction?
        var since: SuspendingClock.Instant
        /// The bars drawing this. SwiftUI may draw a pane's new bar (after
        /// a split, a zoom, or review closing) beside the old one for a
        /// moment, and either may go first, so the entry goes only with the
        /// last of them.
        var owners: Set<UUID>
    }

    /// How long an item is on screen before ⌘⏎ acts on it.
    static let settleTime: Duration = .milliseconds(600)

    /// By pane, while its bar is drawn.
    private var shown: [UUID: Shown] = [:]
    /// The button a press already performed, by pane. Kept while the bar
    /// is drawn anew with that same button (a split, a zoom, a tab switch
    /// and back), so one item is not performed twice; dropped once the
    /// pane's bar shows any other button, or none.
    private var spent: [UUID: PrimaryAction] = [:]

    /// Records what `paneID`'s bar shows. The settle time starts over only
    /// when the item or its primary button changes, so the bar drawing the
    /// same item again, or a new bar for the same pane, does not hold the
    /// key back.
    mutating func noteShown(
        _ itemID: AttentionItemID?,
        primaryAction: PrimaryAction?,
        inPane paneID: UUID,
        by owner: UUID,
        at now: SuspendingClock.Instant
    ) {
        if let action = spent[paneID], action != primaryAction {
            spent.removeValue(forKey: paneID)
        }
        if var current = shown[paneID], current.itemID == itemID, current.primaryAction == primaryAction {
            current.owners.insert(owner)
            shown[paneID] = current
            return
        }
        shown[paneID] = Shown(itemID: itemID, primaryAction: primaryAction, since: now, owners: [owner])
    }

    /// `owner`'s bar for the pane is gone. The entry stays while another bar
    /// still draws it.
    mutating func forget(pane paneID: UUID, by owner: UUID) {
        guard var current = shown[paneID] else { return }
        current.owners.remove(owner)
        shown[paneID] = current.owners.isEmpty ? nil : current
    }

    /// The window came back to the front: what its bars show is
    /// new to the person again, and a press from habit (⌘⏎ is full screen
    /// in other terminals) must not act at once.
    mutating func restartSettling(at now: SuspendingClock.Instant) {
        for paneID in shown.keys {
            shown[paneID]?.since = now
        }
    }

    /// `hasAgent`: Limpid sees an agent in the pane, the same test that
    /// gives it a bar. `isApprovalCardFocused`: the approval card has the
    /// keyboard; the card takes ⌘⏎ and ignores it, so the key reaches
    /// neither the bar nor the terminal.
    mutating func decide(
        _ press: PrimaryKeyPress,
        inPane paneID: UUID,
        hasAgent: Bool,
        isApprovalCardFocused: Bool,
        at now: SuspendingClock.Instant
    ) -> Decision {
        if press.isComposing {
            return .passThrough
        }
        if isApprovalCardFocused {
            return .swallow
        }
        guard hasAgent else { return .passThrough }
        // A held key is never a new decision; it ends where the press did.
        guard press.isCommandOnly,
              !press.isRepeat,
              let current = shown[paneID],
              now - current.since >= Self.settleTime,
              let action = current.primaryAction,
              spent[paneID] != action
        else { return .swallow }
        spent[paneID] = action
        return .perform(action)
    }
}
