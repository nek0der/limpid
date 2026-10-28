// ConversationHoverRule.swift
// Limpid — which tab and which turn cards are marked while a conversation is under the pointer.

import Foundation

/// A conversation under the pointer, and the kind of surface the pointer
/// is on. A plain value, so the rule below reads it without the window's
/// state (`ConversationHoverPresentation` holds it, and names the one view
/// it came from with its `Surface`, whose `source` this is).
struct ConversationHover: Equatable, Sendable {
    let conversation: ConversationKey
    let source: Source

    enum Source: Equatable, Sendable {
        /// The conversation's tab in the pane strip.
        case tab
        /// One of its turn cards in the changes panel, or the heading of
        /// its section in the list grouped by conversation.
        case card
    }
}

/// How a conversation's tab and its turn cards answer for each other under
/// the pointer: a display rule, kept beside the hover it reads rather than
/// in Domain, which holds the product's rules. The pointer on a card asks
/// "which tab is this?", so only the tab that runs it is outlined (a split
/// tab's second pane's conversation's too, in that conversation's color),
/// and the other cards stay as they are: the panel is what is being read.
/// The pointer on a tab asks "which of these cards are this tab's?", so
/// its cards are outlined and every other card is dimmed;
/// the tabs are never dimmed, as the strip is how the person moves on.
/// Every other card dims, whether or not its own conversation still holds
/// a color: one that ended with every turn viewed gave its color back, and
/// left bright it would read as the hovered tab's. Only the hovered
/// conversation needs a color: a tab or card without one (a worktree of
/// one conversation) does not report its hover at all, so it marks
/// nothing; and a card is outlined only in its own color.
enum ConversationHoverRule {
    enum Emphasis: Equatable, Sendable {
        case none
        /// Outlined in its conversation's color.
        case lit
        /// Faded behind the hovered tab's cards.
        case dimmed
    }

    /// A turn card of `conversation`, whose identity color is there or not
    /// (`hasIdentity`), while `hover` is under the pointer. The color
    /// decides only whether the card can be outlined; it never keeps the
    /// card from dimming.
    static func cardEmphasis(of conversation: ConversationKey?, hover: ConversationHover?, hasIdentity: Bool) -> Emphasis {
        guard let conversation, let hover, hover.source == .tab else { return .none }
        guard hover.conversation == conversation else { return .dimmed }
        return hasIdentity ? .lit : .none
    }

    /// The identity color a tab is outlined in, `nil` for none: the
    /// hovered conversation's, while one of its cards is under the pointer
    /// and the tab runs it in any of its panes. `running` is each
    /// conversation the tab runs that holds a color, with it
    /// (`PaneStripModel.Item.runningIdentities`).
    static func tabOutline(running: [ConversationKey: Int], hover: ConversationHover?) -> Int? {
        guard let hover, hover.source == .card else { return nil }
        return running[hover.conversation]
    }
}
