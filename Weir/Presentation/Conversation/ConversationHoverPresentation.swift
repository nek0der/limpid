// ConversationHoverPresentation.swift
// Weir — the conversations a window highlights while the pointer is on a tab, a pane's header, or a turn card.

import Foundation
import Observation
import WeirDomain

/// The conversations under the pointer in one window, and where the pointer
/// is: on a tab in the pane strip, on a pane's header, or on a turn card in
/// the changes panel. The other surfaces read it to mark the same
/// conversations (`ConversationHoverRule`). One per window (`ProjectWindowState`), so a
/// pointer in one window never marks another window's tabs or cards.
@MainActor
@Observable
final class ConversationHoverPresentation {
    /// The plain value the rule reads (`ConversationHoverRule`).
    typealias Hover = ConversationHover
    typealias Source = ConversationHover.Source

    /// `nil` while the pointer is on neither a tab nor a card, and for the
    /// first moments on a tab (`tabDelay`).
    private(set) var hovered: Hover?

    /// How long the pointer rests on a tab before its cards are marked.
    /// The strip lies on the way to the terminal, so a pointer crossing it
    /// would otherwise dim the panel's cards on every pass. A card marks
    /// its tab at once: the pointer is in the panel to read it.
    static let tabDelay: Duration = .milliseconds(150)

    /// The view that reports a hover: one tab of the strip, one turn card,
    /// or the heading of a conversation's section in the list grouped by
    /// conversation. Several cards share a conversation, so the
    /// conversation alone cannot tell which view a leave comes from.
    enum Surface: Hashable {
        case tab(UUID)
        /// A pane's header, which answers as a tab does for the one
        /// conversation it runs, after the same delay: the headers lie on
        /// the way to the terminal too.
        case paneHeader(UUID)
        case card(TurnID)
        /// A section's heading, which stands for its conversation's cards:
        /// it marks the conversation's tab at once, as a card does.
        case heading(ConversationKey)

        var source: Source {
            switch self {
            case .tab, .paneHeader: .tab
            case .card, .heading: .card
            }
        }
    }

    /// The view that set `hovered`. Not observed: the views read `hovered`,
    /// which says the same for every surface of one conversation and kind.
    @ObservationIgnored private var hoveredSurface: Surface?

    /// Runs the tab's delay; tests step it by hand.
    @ObservationIgnored private let timer: HoverDelayTimer
    /// A tab hover waiting out `tabDelay`: the tab it is for, and what
    /// cancels it.
    private struct Pending {
        let conversations: Set<ConversationKey>
        let surface: Surface
        let cancel: @MainActor () -> Void
    }

    @ObservationIgnored private var pending: Pending?

    init(timer: HoverDelayTimer = .live) {
        self.timer = timer
    }

    /// The pointer came onto `surface`, a tab, a pane's header, a card, or a
    /// section heading of `conversations`. A later enter replaces an earlier
    /// one, whichever surface it came from, as SwiftUI can deliver the next
    /// view's enter before the last one's leave.
    func enter(_ conversations: Set<ConversationKey>, from surface: Surface) {
        cancelPending()
        switch surface {
        case .card, .heading:
            set(Hover(conversations: conversations, source: .card), from: surface)
        case .tab, .paneHeader:
            let cancel = timer.schedule(Self.tabDelay) { [weak self] in
                guard let self else { return }
                pending = nil
                set(Hover(conversations: conversations, source: .tab), from: surface)
            }
            pending = Pending(conversations: conversations, surface: surface, cancel: cancel)
        }
    }

    /// The pointer left `surface`, a tab, a pane's header, a card, or a
    /// section heading of `conversations`. Only the hover that view set ends:
    /// a leave that arrives after the next view's enter must not clear what
    /// that enter set, even where the next view is another card of the same
    /// conversation.
    func leave(_ conversations: Set<ConversationKey>, from surface: Surface) {
        if let pending, pending.conversations == conversations, pending.surface == surface {
            cancelPending()
        }
        if hovered?.conversations == conversations, hoveredSurface == surface {
            hovered = nil
            hoveredSurface = nil
        }
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    /// Written only on a change, so the cards and tabs that read it are
    /// not drawn again for the same hover.
    private func set(_ hover: Hover, from surface: Surface) {
        hoveredSurface = surface
        if hovered != hover {
            hovered = hover
        }
    }
}
