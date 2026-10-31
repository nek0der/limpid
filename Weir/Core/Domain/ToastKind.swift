// ToastKind.swift
// Weir — the only toasts the supervision UI shows, and what each says.

import Foundation

/// A toast the supervision UI may show. Only two reasons justify one:
/// the result happens somewhere the person cannot see (a window closed
/// with its agents still running, a test notification sent), or it can be
/// undone (a turn marked as viewed, the code restored). Anything whose
/// result is on screen says so in the decision bar instead, so it has no
/// case here.
package enum ToastKind: Equatable, Sendable {
    /// A window closed while another was shown; the sessions and
    /// agents of the project it showed keep running.
    case windowClosed(projectName: String)
    case testNotificationSent
    /// Turns were marked as viewed, the line now below turn `through`;
    /// Undo moves it back. `nil` when no turn's line moved (the review
    /// marked only the changes outside turns).
    case markedViewed(through: Int?)
    /// "Mark as Viewed up to Here" on the worktree's timeline, or the
    /// review's "Mark as Viewed" on a range across conversations, moved the
    /// line of `conversation` (its name, "Claude #4") to its turn `through`
    /// and the lines of `others` other conversations to the same point;
    /// one Undo moves them all back.
    case markedViewedInConversations(through: Int, conversation: String, others: Int)
    /// "Mark as Unviewed from Here" on the worktree's timeline moved the
    /// line of `conversation` back above its turn `from`, and the lines of
    /// `others` other conversations back to the same point; one Undo
    /// moves them all back.
    case markedUnviewedInConversations(from: Int, conversation: String, others: Int)
    /// The working tree was restored to before turn `turnNumber`; Undo
    /// restores it again.
    case codeRestored(turnNumber: Int)
    /// A restore was cut short when Weir quit or crashed, and recovery
    /// found part of it in the working tree at launch; Undo takes back
    /// what it wrote.
    case restoreInterrupted
    /// A discard of review hunks was cut short the same way; Undo
    /// takes back what it wrote, as no review shows its hunks any longer.
    case discardInterrupted
    /// A discard ended as Weir quit, before its review could offer its
    /// undo; Undo takes it back.
    case discardSettled
    /// An undo of a restore or a discard was cut short; Undo takes back
    /// what the operation still has in the working tree.
    case undoInterrupted
    /// A restore or a discard ended as Weir quit, moving another
    /// writer's saves aside, which the toast's note names.
    case keptAsideAtQuit
    /// Several restores, discards, or their undos were under way as Weir
    /// quit; Undo takes back each of them.
    case operationsInterrupted(count: Int)

    /// Whether the toast carries Undo. A toast for news from elsewhere
    /// has nothing to take back.
    package var offersUndo: Bool {
        switch self {
        case .windowClosed, .testNotificationSent, .keptAsideAtQuit: false
        case .markedViewed, .markedViewedInConversations, .markedUnviewedInConversations, .codeRestored, .restoreInterrupted,
             .discardInterrupted, .discardSettled,
             .undoInterrupted, .operationsInterrupted: true
        }
    }

    /// What the toast's "Undo" takes back, for its tooltip and VoiceOver,
    /// where it is more than the message's one move: every conversation's
    /// line a mark across conversations moved. `nil` where "Undo" says it.
    package var undoLabel: LocalizedStringResource? {
        switch self {
        case let .markedViewedInConversations(_, _, others), let .markedUnviewedInConversations(_, _, others):
            LocalizedStringResource(
                "Undo in \(others + 1) Conversations",
                comment: "Toast's Undo, tooltip and VoiceOver, after a mark moved several conversations' lines; how many it moves back"
            )
        default:
            nil
        }
    }

    package var message: LocalizedStringResource {
        switch self {
        case let .windowClosed(projectName):
            LocalizedStringResource(
                "Closed the window. \(projectName)’s agents and terminals keep running.",
                comment: "Toast in a window left after another window closed; the name of the project the closed window showed"
            )
        case .testNotificationSent:
            LocalizedStringResource(
                "Sent a test notification. If it doesn’t arrive, check the macOS notification settings.",
                comment: "Toast after the notification history's Test Notification button"
            )
        // The turn the line now stands below: the toast outlasts the place
        // it was marked from, so it says how far the mark reached.
        case let .markedViewed(through?):
            LocalizedStringResource(
                "Marked as viewed up to T\(through).",
                comment: "Toast after marking turns as viewed, offered with Undo; the last turn now viewed, as in T7"
            )
        case .markedViewed(nil):
            LocalizedStringResource("Marked as viewed.", comment: "Toast after marking turns as viewed, offered with Undo")
        // Whose turn names the point, since every conversation numbers its
        // own: "T4" alone outlasts the row it was pressed on. The other
        // conversations' lines moved to the same point, which the toast
        // counts: the panel's rows show where each went.
        case let .markedViewedInConversations(through, conversation, others):
            LocalizedStringResource(
                "Marked as viewed up to T\(through) of \(conversation), and \(others) other conversations up to the same point.",
                comment: "Toast after a mark moved several conversations' lines, with Undo; the turn (T7), its conversation, the others"
            )
        case let .markedUnviewedInConversations(from, conversation, others):
            LocalizedStringResource(
                "Marked as unviewed from T\(from) of \(conversation), and \(others) other conversations from the same point.",
                comment: "Toast after an unmark moved several conversations' lines back, with Undo; the turn, its conversation, the others"
            )
        // What the record says too: the agent was not told, which
        // matters before the next instruction.
        case let .codeRestored(turnNumber):
            LocalizedStringResource(
                "Restored the code to before T\(turnNumber). Not reflected in the conversation.",
                comment: "Toast after restoring the code, offered with Undo; the turn number, as in T7"
            )
        case .restoreInterrupted:
            LocalizedStringResource(
                "A code restore stopped partway when Weir last quit.",
                comment: "Toast at launch when a restore of the code was cut short, offered with Undo, which takes back what it wrote"
            )
        case .discardInterrupted:
            LocalizedStringResource(
                "A hunk discard stopped partway when Weir last quit.",
                comment: "Toast at launch when a discard of review hunks was cut short, offered with Undo, which takes back what it wrote"
            )
        case .discardSettled:
            LocalizedStringResource(
                "A hunk discard finished as Weir last quit.",
                comment: "Toast at launch when a discard of review hunks ended as the app quit, offered with Undo, which takes it back"
            )
        case .undoInterrupted:
            LocalizedStringResource(
                "Undoing a code restore or a hunk discard stopped partway when Weir last quit.",
                comment: "Toast at launch when an undo of a restore or a discard was cut short, offered with Undo"
            )
        case .keptAsideAtQuit:
            LocalizedStringResource(
                "A code restore or a hunk discard finished as Weir last quit.",
                comment: "Toast at launch before where saves made meanwhile went; no Undo"
            )
        case let .operationsInterrupted(count):
            LocalizedStringResource(
                "\(count) code restores, hunk discards, or undos were under way when Weir last quit.",
                comment: "Toast at launch when several restores, discards, or undos were under way, offered with Undo for all; the count"
            )
        }
    }
}
